import AudioToolbox
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Flutter

struct CaptureModeInfo {
  let Width: Int
  let Height: Int
  let Fps: Int
}

final class CaptureSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
  let Session = AVCaptureSession()

  private let SnapshotOutput = AVCaptureVideoDataOutput()
  private let CaptureQueue = DispatchQueue(label: "splatoon3record.mobile_capture")
  private let SnapshotQueue = DispatchQueue(label: "splatoon3record.mobile_snapshot")
  private let MonitorQueue = DispatchQueue(label: "splatoon3record.audio_monitor")
  // Segment writes happen on their own serial queue so a slow encoder never
  // blocks session control (start / stop / monitor) and vice versa.
  private let RecordQueue = DispatchQueue(label: "splatoon3record.mobile_record")
  private let SnapshotLock = NSLock()
  private let SnapshotContext = CIContext(options: nil)
  private var SnapshotPixel: CVPixelBuffer?
  private var VideoInput: AVCaptureDeviceInput?
  private var AudioInput: AVCaptureDeviceInput?
  private var Prepared = false
  private var AudioOutput: AVCaptureAudioDataOutput?
  private var MonitorEngine: AVAudioEngine?
  private var MonitorPlayer: AVAudioPlayerNode?
  private var MonitorFormat: AVAudioFormat?
  private var MonitorEnabled = false
  private var PreferredInputId = ""
  private var LastRouteFix: TimeInterval = 0
  private var AudioConfigured = false
  // AVCaptureMovieFileOutput refuses to start on this capture chain
  // ("Cannot Record", AVFoundationErrorDomain -11805) and blocks for seconds on
  // 1080p120, so segments are written with AVAssetWriter instead: hardware
  // H.264 for video plus AAC for audio, using the device frame timestamps.
  private var Writer: AVAssetWriter?
  private var WriterVideo: AVAssetWriterInput?
  private var WriterAudio: AVAssetWriterInput?
  private var WriterPath = ""
  private var WriterStarted = false
  private var WriterVideoWritten = false
  private var WriterAudioWritten = false
  private var WriterAppendFailed = false
  private var WriterInputSize = CGSize.zero
  private var CaptureFps = 30

  var OnState: ((String) -> Void)?
  var OnAudio: ((String) -> Void)?
  var OnLog: ((String) -> Void)?
  var VideoAngle: CGFloat = 0

  override init() {
    super.init()
    NotificationCenter.default.addObserver(self, selector: #selector(RouteChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(SessionInterrupted(_:)), name: AVCaptureSession.wasInterruptedNotification, object: Session)
    NotificationCenter.default.addObserver(self, selector: #selector(SessionResumed(_:)), name: AVCaptureSession.interruptionEndedNotification, object: Session)
    NotificationCenter.default.addObserver(self, selector: #selector(SessionFailed(_:)), name: AVCaptureSession.runtimeErrorNotification, object: Session)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func SessionInterrupted(_ Note: Notification) {
    OnLog?("采集会话被系统中断")
  }

  @objc private func SessionResumed(_ Note: Notification) {
    OnLog?("采集会话中断结束")
  }

  @objc private func SessionFailed(_ Note: Notification) {
    let Failure = Note.userInfo?[AVCaptureSessionErrorKey] as? NSError
    OnLog?("采集会话错误：\(Failure?.localizedDescription ?? "未知")")
  }

  @objc private func RouteChanged(_ Note: Notification) {
    guard AudioInput != nil, !PreferredInputId.isEmpty else { return }
    // Switching the preferred input mid-recording renegotiates the audio graph
    // and can truncate the segment, so only do it while idle.
    if Writer != nil {
      ReportAudio()
      return
    }
    let Session = AVAudioSession.sharedInstance()
    if Session.currentRoute.inputs.first?.uid != PreferredInputId, let Port = Session.availableInputs?.first(where: { $0.uid == PreferredInputId }) {
      let Now = Date().timeIntervalSince1970
      if Now - LastRouteFix > 2 {
        LastRouteFix = Now
        try? Session.setPreferredInput(Port)
        OnLog?("音频路由被系统切换，已切回采集卡输入：\(Port.portName)")
      }
    }
    ReportAudio()
  }

  private func ReportAudio() {
    let Session = AVAudioSession.sharedInstance()
    let Input = Session.currentRoute.inputs.first
    let Name = Input?.portName ?? "无"
    let Type = Input?.portType.rawValue ?? ""
    OnAudio?("音频输入：\(Name) \(Type)")
  }

  private var DeviceTypes: [AVCaptureDevice.DeviceType] {
    if #available(iOS 17.0, *) {
      return [.external]
    }
    return []
  }

  private func Find(_ DeviceId: String) -> AVCaptureDevice? {
    guard #available(iOS 17.0, *) else { return nil }
    let Devices = AVCaptureDevice.DiscoverySession(deviceTypes: DeviceTypes, mediaType: .video, position: .unspecified).devices
    if let Exact = Devices.first(where: { $0.uniqueID == DeviceId }) { return Exact }
    return nil
  }

  private var AudioSession: AVAudioSession {
    return AVAudioSession.sharedInstance()
  }

  // The audio category is configured exactly once per process. Re-asserting it
  // (setCategory / setActive) while the capture session is running tears down
  // the audio graph, which is what used to abort every iOS segment.
  private func ConfigureAudio() {
    guard !AudioConfigured else { return }
    AudioConfigured = true
    do {
      try AudioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothA2DP])
    } catch {
      OnLog?("音频类别设置失败：\(error.localizedDescription)")
    }
    do {
      try AudioSession.setActive(true)
    } catch {
      OnLog?("音频会话激活失败：\(error.localizedDescription)")
    }
  }

  private func InputPorts() -> [AVAudioSessionPortDescription] {
    ConfigureAudio()
    return AudioSession.availableInputs ?? []
  }

  private func InputPort(_ DeviceId: String) -> AVAudioSessionPortDescription? {
    let Ports = InputPorts()
    if !DeviceId.isEmpty, let Exact = Ports.first(where: { $0.uid == DeviceId || $0.portName == DeviceId }) {
      return Exact
    }
    return Ports.first(where: { $0.portType == .usbAudio }) ?? Ports.first(where: { IsExternal($0) })
  }

  /// The capture session does not follow the AVAudioSession route, so the input
  /// device has to be matched to the selected port by name; otherwise the iPad
  /// microphone is recorded instead of the capture card audio.
  private func AudioDevice(_ PortName: String) -> AVCaptureDevice? {
    var Types: [AVCaptureDevice.DeviceType] = [.builtInMicrophone]
    if #available(iOS 17.0, *) {
      Types = [.microphone]
    }
    let Devices = AVCaptureDevice.DiscoverySession(deviceTypes: Types, mediaType: .audio, position: .unspecified).devices
    if !PortName.isEmpty, let Match = Devices.first(where: { $0.localizedName == PortName }) {
      return Match
    }
    if let External = Devices.first(where: { IsExternal($0) }) {
      return External
    }
    let Fallback = AVCaptureDevice.default(for: .audio)
    if let Fallback = Fallback {
      OnLog?("音频输入未匹配到「\(PortName)」，回退到 \(Fallback.localizedName)")
    }
    return Fallback
  }

  private func IsExternal(_ Port: AVAudioSessionPortDescription) -> Bool {
    return Port.portType != .builtInMic
  }

  func AudioDevices(_ Completion: @escaping ([[String: Any]]) -> Void) {
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
      Completion(InputAudioDevices())
      return
    }
    var Finished = false
    let Lock = NSLock()
    let Finish: ([[String: Any]]) -> Void = { Items in
      Lock.lock()
      if Finished {
        Lock.unlock()
        return
      }
      Finished = true
      Lock.unlock()
      DispatchQueue.main.async { Completion(Items) }
    }
    AVCaptureDevice.requestAccess(for: .audio) { _ in
      Finish(self.InputAudioDevices())
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      Finish(self.InputAudioDevices())
    }
  }

  private func InputAudioDevices() -> [[String: Any]] {
    let Items = InputPorts().map { Port in
      [
        "id": Port.uid,
        "name": Port.portName,
        "external": IsExternal(Port),
      ]
    }
    OnLog?("音频输入 \(Items.count) 个：" + Items.map({ "\($0["name"] ?? "")" }).joined(separator: "、"))
    return Items
  }

  private func IsExternal(_ Device: AVCaptureDevice) -> Bool {
    if #available(iOS 17.0, *) {
      return Device.deviceType == .external
    }
    return false
  }

  func Enumerate() -> [[String: Any]] {
    guard #available(iOS 17.0, *) else { return [] }
    let Devices = AVCaptureDevice.DiscoverySession(deviceTypes: DeviceTypes, mediaType: .video, position: .unspecified).devices
    return Devices.map { Device in
      [
        "id": Device.uniqueID,
        "name": Device.localizedName,
        "external": IsExternal(Device),
      ]
    }
  }

  func Modes(_ DeviceId: String) -> [[String: Any]] {
    guard let Device = Find(DeviceId) else { return [] }
    var Result: [[String: Any]] = []
    var Seen = Set<String>()
    for Format in Device.formats {
      let Size = CMVideoFormatDescriptionGetDimensions(Format.formatDescription)
      var Fps = 30
      if let Range = Format.videoSupportedFrameRateRanges.first {
        Fps = Int(Range.maxFrameRate.rounded())
      }
      let Key = "\(Size.width)x\(Size.height)@\(Fps)"
      if Seen.insert(Key).inserted {
        Result.append(["width": Int(Size.width), "height": Int(Size.height), "fps": Fps])
      }
    }
    return Result.sorted { Left, Right in
      let LeftArea = (Left["width"] as? Int ?? 0) * (Left["height"] as? Int ?? 0)
      let RightArea = (Right["width"] as? Int ?? 0) * (Right["height"] as? Int ?? 0)
      return LeftArea > RightArea
    }
  }

  func Prepare(DeviceId: String, Width: Int, Height: Int, Fps: Int, Audio: Bool, AudioDeviceId: String, Orientation: String, Completion: @escaping (CaptureModeInfo?, String?) -> Void) {
    OnLog?("准备采集 device=\(DeviceId) \(Width)x\(Height)@\(Fps) audio=\(Audio) audioDevice=\(AudioDeviceId) orientation=\(Orientation)")
    Request(Video: true) { VideoOk in
      guard VideoOk else {
        Completion(nil, "相机权限被拒绝")
        return
      }
      guard Audio else {
        self.Apply(DeviceId: DeviceId, Width: Width, Height: Height, Fps: Fps, Audio: false, AudioDeviceId: "", Orientation: Orientation, Completion: Completion)
        return
      }
      AVCaptureDevice.requestAccess(for: .audio) { Granted in
        self.Apply(DeviceId: DeviceId, Width: Width, Height: Height, Fps: Fps, Audio: Granted, AudioDeviceId: AudioDeviceId, Orientation: Orientation, Completion: Completion)
      }
    }
  }

  private func Request(Video: Bool, Completion: @escaping (Bool) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      Completion(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { Granted in
        Completion(Granted)
      }
    default:
      Completion(false)
    }
  }

  private func Apply(DeviceId: String, Width: Int, Height: Int, Fps: Int, Audio: Bool, AudioDeviceId: String, Orientation: String, Completion: @escaping (CaptureModeInfo?, String?) -> Void) {
    CaptureQueue.async {
      guard let Device = self.Find(DeviceId) else {
        self.OnLog?("未找到采集设备：\(DeviceId)")
        DispatchQueue.main.async { Completion(nil, "未找到 USB 采集设备，需要 iPadOS 17 或更高版本") }
        return
      }
      var AudioPort: AVAudioSessionPortDescription?
      if Audio {
        AudioPort = self.InputPort(AudioDeviceId)
        if let Port = AudioPort {
          self.PreferredInputId = Port.uid
          try? self.AudioSession.setPreferredInput(Port)
          self.OnLog?("音频路由选择：\(Port.portName)（\(Port.portType.rawValue)）")
          let Deadline = Date().addingTimeInterval(1.5)
          while Date() < Deadline, self.AudioSession.currentRoute.inputs.first?.uid != Port.uid {
            Thread.sleep(forTimeInterval: 0.05)
          }
          self.OnLog?("当前音频路由：\(self.AudioSession.currentRoute.inputs.first?.portName ?? "无")")
        }
      }
      if self.Session.isRunning { self.Session.stopRunning() }
      self.Session.beginConfiguration()
      self.Session.sessionPreset = .inputPriority
      do {
        let Input = try AVCaptureDeviceInput(device: Device)
        if let Old = self.VideoInput { self.Session.removeInput(Old) }
        guard self.Session.canAddInput(Input) else {
          self.Session.commitConfiguration()
          DispatchQueue.main.async { Completion(nil, "无法打开采集设备") }
          return
        }
        self.Session.addInput(Input)
        self.VideoInput = Input
      } catch {
        self.Session.commitConfiguration()
        DispatchQueue.main.async { Completion(nil, "无法打开采集设备") }
        return
      }
      var UseFps = max(1, Fps)
      do {
        try Device.lockForConfiguration()
        if let Format = Self.Pick(Device, Width: Width, Height: Height, Fps: Fps) {
          Device.activeFormat = Format
        }
        if let Range = Device.activeFormat.videoSupportedFrameRateRanges.first {
          UseFps = min(max(UseFps, max(1, Int(Range.minFrameRate.rounded()))), max(1, Int(Range.maxFrameRate.rounded())))
        }
        let Duration = CMTime(value: 1, timescale: CMTimeScale(UseFps))
        Device.activeVideoMinFrameDuration = Duration
        Device.activeVideoMaxFrameDuration = Duration
        Device.unlockForConfiguration()
      } catch {
      }
      if Audio, let Port = AudioPort {
        self.OnLog?("音频路由确认：\(Port.portName)")
        if let Old = self.AudioInput {
          self.Session.removeInput(Old)
          self.AudioInput = nil
        }
        if let Mic = self.AudioDevice(Port.portName), let Input = try? AVCaptureDeviceInput(device: Mic), self.Session.canAddInput(Input) {
          self.Session.addInput(Input)
          self.AudioInput = Input
          self.OnLog?("已加入音频输入：\(Mic.localizedName)")
        } else {
          self.OnLog?("无法加入音频输入")
        }
        if self.AudioInput != nil { self.AttachAudio() }
      } else {
        self.OnLog?("音频采集已关闭或没有可用的外部输入")
        if let Old = self.AudioInput {
          self.Session.removeInput(Old)
          self.AudioInput = nil
        }
        if let Output = self.AudioOutput {
          self.Session.removeOutput(Output)
          self.AudioOutput = nil
        }
        self.MonitorEnabled = false
        self.StopMonitor()
      }
      if !self.Session.outputs.contains(self.SnapshotOutput) {
        // NV12 keeps the 1080p120 path cheap and is what the hardware H.264
        // encoder in AVAssetWriter wants; BGRA at that rate wastes bandwidth.
        self.SnapshotOutput.videoSettings = [
          kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        ]
        self.SnapshotOutput.alwaysDiscardsLateVideoFrames = true
        self.SnapshotOutput.setSampleBufferDelegate(self, queue: self.SnapshotQueue)
        if self.Session.canAddOutput(self.SnapshotOutput) { self.Session.addOutput(self.SnapshotOutput) }
      }
      let Size = CMVideoFormatDescriptionGetDimensions(Device.activeFormat.formatDescription)
      self.CaptureFps = UseFps
      self.VideoAngle = Self.Angle(Orientation, Width: Int(Size.width), Height: Int(Size.height))
      self.Session.commitConfiguration()
      var Applied: CGFloat = 0
      if let Connection = self.SnapshotOutput.connection(with: .video) {
        Applied = Self.Rotate(Connection, Angle: self.VideoAngle)
        Connection.automaticallyAdjustsVideoMirroring = false
        if Connection.isVideoMirroringSupported {
          Connection.isVideoMirrored = false
        }
      }
      let Turned = Applied == 90 || Applied == 270
      self.WriterInputSize = Turned ? CGSize(width: CGFloat(Size.height), height: CGFloat(Size.width)) : CGSize(width: CGFloat(Size.width), height: CGFloat(Size.height))
      self.Prepared = true
      self.Session.startRunning()
      self.OnLog?("采集已启动 \(Int(Size.width))x\(Int(Size.height))@\(UseFps) 音频输入=\(self.AudioInput?.device.localizedName ?? "无") 当前路由=\(self.AudioSession.currentRoute.inputs.first?.portName ?? "无")")
      let Mode = CaptureModeInfo(Width: Int(Size.width), Height: Int(Size.height), Fps: UseFps)
      DispatchQueue.main.async { Completion(Mode, nil) }
    }
  }

  private static func Angle(_ Orientation: String, Width: Int, Height: Int) -> CGFloat {
    switch Orientation {
    case "landscape":
      return 0
    case "portrait":
      return 90
    case "landscapeFlipped":
      return 180
    case "portraitFlipped":
      return 270
    default:
      return Width >= Height ? 0 : 90
    }
  }

  /// Returns the rotation actually applied, so the writer can size its frames to
  /// the pixel buffers the connection really delivers.
  private static func Rotate(_ Connection: AVCaptureConnection, Angle: CGFloat) -> CGFloat {
    if #available(iOS 17.0, *) {
      if Connection.isVideoRotationAngleSupported(Angle) {
        Connection.videoRotationAngle = Angle
        return Angle
      }
    }
    return 0
  }

  private static func Pick(_ Device: AVCaptureDevice, Width: Int, Height: Int, Fps: Int) -> AVCaptureDevice.Format? {
    var Best: AVCaptureDevice.Format?
    var BestScore = Int.max
    for Format in Device.formats {
      let Size = CMVideoFormatDescriptionGetDimensions(Format.formatDescription)
      let Range = Format.videoSupportedFrameRateRanges.first
      let MaxFps = Int((Range?.maxFrameRate ?? 30).rounded())
      let MinFps = Int((Range?.minFrameRate ?? 1).rounded())
      let FpsScore = Fps > MaxFps ? (Fps - MaxFps) * 100 : Fps < MinFps ? (MinFps - Fps) * 20 : 0
      let Score = abs(Int(Size.width) - Width) + abs(Int(Size.height) - Height) + FpsScore
      if Score < BestScore {
        BestScore = Score
        Best = Format
      }
    }
    return Best
  }

  private func AttachAudio() {
    if AudioOutput != nil { return }
    let Data = AVCaptureAudioDataOutput()
    Data.setSampleBufferDelegate(self, queue: MonitorQueue)
    if Session.canAddOutput(Data) {
      Session.addOutput(Data)
      AudioOutput = Data
    }
  }

  func Monitor(_ Enabled: Bool) {
    CaptureQueue.async {
      if self.MonitorEnabled == Enabled { return }
      if Enabled {
        guard self.AudioInput != nil, self.AudioOutput != nil else {
          self.MonitorEnabled = false
          self.OnLog?("声音返听不可用：未检测到音频输入")
          return
        }
        self.MonitorEnabled = true
        self.StartMonitor()
        self.OnLog?("声音返听已开启")
      } else {
        self.MonitorEnabled = false
        self.StopMonitor()
        self.OnLog?("声音返听已关闭")
      }
    }
  }

  private func StartMonitor() {
    if MonitorEngine != nil {
      MonitorPlayer?.play()
      return
    }
    ConfigureAudio()
    guard let Format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false) else { return }
    let Engine = AVAudioEngine()
    let Player = AVAudioPlayerNode()
    Engine.attach(Player)
    Engine.connect(Player, to: Engine.mainMixerNode, format: Format)
    Engine.prepare()
    do {
      try Engine.start()
      Player.play()
    } catch {
      OnLog?("声音返听启动失败：\(error)")
      return
    }
    MonitorEngine = Engine
    MonitorPlayer = Player
    MonitorFormat = Format
  }

  private func StopMonitor() {
    MonitorPlayer?.stop()
    MonitorEngine?.stop()
    if let Player = MonitorPlayer {
      MonitorEngine?.detach(Player)
    }
    MonitorEngine = nil
    MonitorPlayer = nil
    MonitorFormat = nil
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    if output === SnapshotOutput {
      if let Pixel = CMSampleBufferGetImageBuffer(sampleBuffer) {
        SnapshotLock.lock()
        SnapshotPixel = Pixel
        SnapshotLock.unlock()
      }
      RecordQueue.async { self.AppendVideo(sampleBuffer) }
      return
    }
    RecordQueue.async { self.AppendAudio(sampleBuffer) }
    guard MonitorEnabled, let Player = MonitorPlayer, let Format = MonitorFormat else { return }
    let Frames = CMSampleBufferGetNumSamples(sampleBuffer)
    if Frames <= 0 { return }
    let Capacity = AVAudioFrameCount(max(Frames, 1024) * 2)
    guard let Buffer = AVAudioPCMBuffer(pcmFormat: Format, frameCapacity: Capacity) else { return }
    if !CopyAudio(sampleBuffer, To: Buffer, Format: Format) { return }
    Player.scheduleBuffer(Buffer, completionHandler: nil)
  }

  private func CopyAudio(_ SampleBuffer: CMSampleBuffer, To Buffer: AVAudioPCMBuffer, Format: AVAudioFormat) -> Bool {
    guard let Description = CMSampleBufferGetFormatDescription(SampleBuffer),
          var Stream = CMAudioFormatDescriptionGetStreamBasicDescription(Description)?.pointee else { return false }
    guard let SourceFormat = AVAudioFormat(streamDescription: &Stream) else { return false }
    let Frames = CMSampleBufferGetNumSamples(SampleBuffer)
    if Frames <= 0 { return false }
    guard let Input = AVAudioPCMBuffer(pcmFormat: SourceFormat, frameCapacity: AVAudioFrameCount(Frames)) else { return false }
    Input.frameLength = AVAudioFrameCount(Frames)
    let Copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(SampleBuffer, at: 0, frameCount: Int32(Frames), into: Input.mutableAudioBufferList)
    if Copied != noErr { return false }
    guard let Converter = AVAudioConverter(from: SourceFormat, to: Format) else { return false }
    var ConversionError: NSError?
    var Consumed = false
    let Result = Converter.convert(to: Buffer, error: &ConversionError) { _, Status in
      if Consumed {
        Status.pointee = .endOfStream
        return nil
      }
      Consumed = true
      Status.pointee = .haveData
      return Input
    }
    return Result != .error && ConversionError == nil
  }

  private func FreeBytes() -> Int64 {
    let Home = URL(fileURLWithPath: NSHomeDirectory())
    if let Values = try? Home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
       let Capacity = Values.volumeAvailableCapacityForImportantUsage {
      return Int64(Capacity)
    }
    return 0
  }

  private func FreeMegabytes() -> Int64 {
    return FreeBytes() / (1024 * 1024)
  }

  func StartRecording(_ Path: String, Completion: @escaping (String?) -> Void) {
    CaptureQueue.async {
      guard self.Prepared, self.Session.isRunning else {
        DispatchQueue.main.async { Completion("采集会话未启动") }
        return
      }
      let Folder = (Path as NSString).deletingLastPathComponent
      try? FileManager.default.createDirectory(atPath: Folder, withIntermediateDirectories: true)
      let Free = self.FreeMegabytes()
      if Free > 0, Free < 512 {
        self.OnLog?("存储空间不足：剩余 \(Free)MB")
        DispatchQueue.main.async { Completion("存储空间不足（剩余 \(Free) MB），请清理缓存后重试") }
        return
      }
      self.RecordQueue.async {
        let Failure = self.BeginWriter(Path)
        self.OnLog?("开始录制：\(Path) 剩余空间=\(Free)MB 尺寸=\(Int(self.WriterInputSize.width))x\(Int(self.WriterInputSize.height)) 音频=\(self.WriterAudio != nil) 结果=\(Failure ?? "ok")")
        if Failure == nil { self.OnState?("recording") }
        DispatchQueue.main.async { Completion(Failure) }
      }
    }
  }

  func StopRecording(_ Completion: @escaping (String?) -> Void) {
    CaptureQueue.async {
      self.RecordQueue.async {
        guard self.Writer != nil else {
          DispatchQueue.main.async { Completion(nil) }
          return
        }
        self.EndWriter(Completion)
      }
    }
  }

  // Runs on RecordQueue. Creating the writer is fast, so this never blocks the
  // capture pipeline the way AVCaptureMovieFileOutput did on 1080p120.
  private func BeginWriter(_ Path: String) -> String? {
    EndWriter(nil, Silent: true)
    try? FileManager.default.removeItem(atPath: Path)
    guard let Writer = try? AVAssetWriter(outputURL: URL(fileURLWithPath: Path), fileType: .mov) else {
      return "无法创建录制文件"
    }
    var Width = Int(WriterInputSize.width)
    var Height = Int(WriterInputSize.height)
    if Width <= 0 || Height <= 0 {
      Width = 1920
      Height = 1080
    }
    let Fps = max(1, CaptureFps)
    let Bitrate = max(4_000_000, min(45_000_000, Int(Double(Width * Height * Fps) * 0.08)))
    let Compression: [String: Any] = [
      AVVideoAverageBitRateKey: Bitrate,
      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      AVVideoExpectedSourceFrameRateKey: Fps,
      AVVideoMaxKeyFrameIntervalKey: Fps,
      AVVideoAllowFrameReorderingKey: false,
    ]
    let Video = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Width,
      AVVideoHeightKey: Height,
      AVVideoCompressionPropertiesKey: Compression,
    ])
    Video.expectsMediaDataInRealTime = true
    guard Writer.canAdd(Video) else { return "录制编码器初始化失败" }
    Writer.add(Video)
    var Audio: AVAssetWriterInput?
    if AudioInput != nil {
      let Input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: 2,
        AVSampleRateKey: 48000,
        AVEncoderBitRateKey: 128000,
      ])
      Input.expectsMediaDataInRealTime = true
      if Writer.canAdd(Input) {
        Writer.add(Input)
        Audio = Input
      } else {
        OnLog?("录制音频轨道不可用")
      }
    }
    guard Writer.startWriting() else {
      return Writer.error?.localizedDescription ?? "无法开始写入录制文件"
    }
    WriterVideo = Video
    WriterAudio = Audio
    WriterPath = Path
    WriterStarted = false
    WriterVideoWritten = false
    WriterAudioWritten = false
    WriterAppendFailed = false
    self.Writer = Writer
    return nil
  }

  // Runs on RecordQueue. Closes the segment and reports its path once the file
  // is fully written, so the Dart side never merges a half written file.
  private func EndWriter(_ Completion: ((String?) -> Void)?, Silent: Bool = false) {
    guard let Writer = self.Writer else {
      if let Completion = Completion { DispatchQueue.main.async { Completion(nil) } }
      return
    }
    let Path = self.WriterPath
    let Video = self.WriterVideo
    let Audio = self.WriterAudio
    let Wrote = self.WriterVideoWritten
    self.Writer = nil
    self.WriterVideo = nil
    self.WriterAudio = nil
    self.WriterPath = ""
    self.WriterStarted = false
    self.WriterVideoWritten = false
    self.WriterAudioWritten = false
    let Finish: (String?) -> Void = { Reason in
      self.OnLog?(Reason == nil ? "录制分段结束 path=\(Path) 剩余空间=\(self.FreeMegabytes())MB" : "录制分段失败 \(Reason ?? "") path=\(Path) 剩余空间=\(self.FreeMegabytes())MB")
      if !Silent { self.OnState?("idle") }
      if let Completion = Completion { DispatchQueue.main.async { Completion(Reason == nil ? Path : nil) } }
    }
    guard Writer.status == .writing else {
      try? FileManager.default.removeItem(atPath: Path)
      Finish("写入未开始 状态=\(Writer.status.rawValue) 错误=\(Writer.error?.localizedDescription ?? "无")")
      return
    }
    Video?.markAsFinished()
    Audio?.markAsFinished()
    Writer.finishWriting {
      if Writer.status == .completed, Wrote {
        Finish(nil)
      } else {
        try? FileManager.default.removeItem(atPath: Path)
        Finish("状态=\(Writer.status.rawValue) 错误=\(Writer.error?.localizedDescription ?? "无")")
      }
    }
  }

  private func AppendVideo(_ Sample: CMSampleBuffer) {
    guard let Writer = self.Writer, let Input = self.WriterVideo, Writer.status == .writing else { return }
    guard CMSampleBufferDataIsReady(Sample), Input.isReadyForMoreMediaData else { return }
    if !WriterStarted {
      Writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(Sample))
      WriterStarted = true
    }
    if Input.append(Sample) {
      WriterVideoWritten = true
    } else if !WriterAppendFailed {
      WriterAppendFailed = true
      OnLog?("写入视频帧失败：\(Writer.error?.localizedDescription ?? "无")")
    }
  }

  private func AppendAudio(_ Sample: CMSampleBuffer) {
    guard WriterStarted, let Writer = self.Writer, let Input = self.WriterAudio, Writer.status == .writing else { return }
    guard CMSampleBufferDataIsReady(Sample), Input.isReadyForMoreMediaData else { return }
    if Input.append(Sample) { WriterAudioWritten = true }
  }

  func Dispose() {
    CaptureQueue.async {
      self.OnLog?("释放采集会话")
      self.RecordQueue.async { self.EndWriter(nil) }
      self.MonitorEnabled = false
      self.StopMonitor()
      if let Output = self.AudioOutput {
        self.Session.beginConfiguration()
        self.Session.removeOutput(Output)
        self.Session.commitConfiguration()
        self.AudioOutput = nil
      }
      if self.Session.outputs.contains(self.SnapshotOutput) {
        self.Session.beginConfiguration()
        self.Session.removeOutput(self.SnapshotOutput)
        self.Session.commitConfiguration()
      }
      self.SnapshotLock.lock()
      self.SnapshotPixel = nil
      self.SnapshotLock.unlock()
      if self.Session.isRunning { self.Session.stopRunning() }
      self.Session.beginConfiguration()
      for Input in self.Session.inputs { self.Session.removeInput(Input) }
      self.Session.commitConfiguration()
      self.VideoInput = nil
      self.AudioInput = nil
      self.Prepared = false
      self.OnState?("idle")
    }
  }

  func Snapshot(Width: Int, Height: Int, Completion: @escaping (Data?) -> Void) {
    SnapshotLock.lock()
    let Pixel = SnapshotPixel
    SnapshotLock.unlock()
    guard let Pixel = Pixel else {
      Completion(nil)
      return
    }
    let TargetWidth = max(1, Width)
    let TargetHeight = max(1, Height)
    let Task = DispatchWorkItem { [weak self] in
      guard let self = self else {
        DispatchQueue.main.async { Completion(nil) }
        return
      }
      var Destination: CVPixelBuffer?
      let Attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferWidthKey as String: TargetWidth,
        kCVPixelBufferHeightKey as String: TargetHeight,
      ]
      guard CVPixelBufferCreate(nil, TargetWidth, TargetHeight, kCVPixelFormatType_32BGRA, Attributes as CFDictionary, &Destination) == kCVReturnSuccess,
            let Destination = Destination else {
        DispatchQueue.main.async { Completion(nil) }
        return
      }
      let Image = CIImage(cvPixelBuffer: Pixel)
      self.SnapshotContext.render(Image, to: Destination, bounds: CGRect(x: 0, y: 0, width: TargetWidth, height: TargetHeight), colorSpace: CGColorSpaceCreateDeviceRGB())
      CVPixelBufferLockBaseAddress(Destination, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(Destination, .readOnly) }
      guard let Base = CVPixelBufferGetBaseAddress(Destination) else {
        DispatchQueue.main.async { Completion(nil) }
        return
      }
      let Stride = CVPixelBufferGetBytesPerRow(Destination)
      var DataValue = Data(count: TargetWidth * TargetHeight * 4)
      DataValue.withUnsafeMutableBytes { Target in
        guard let TargetBase = Target.baseAddress else { return }
        for Row in 0..<TargetHeight {
          memcpy(TargetBase.advanced(by: Row * TargetWidth * 4), Base.advanced(by: Row * Stride), TargetWidth * 4)
        }
      }
      DispatchQueue.main.async { Completion(DataValue) }
    }
    SnapshotQueue.async(execute: Task)
  }
}
