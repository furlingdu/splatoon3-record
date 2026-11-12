import AudioToolbox
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Flutter
import os

struct CaptureModeInfo {
  let Width: Int
  let Height: Int
  let Fps: Int
}

final class CaptureSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
  private let Session = AVCaptureSession()

  private let SnapshotOutput = AVCaptureVideoDataOutput()
  private let CaptureQueue = DispatchQueue(label: "splatoon3record.mobile_capture")
  private let StorageQueue = DispatchQueue(label: "splatoon3record.mobile_storage", qos: .utility)
  private var Previews: [ObjectIdentifier: AVCaptureVideoPreviewLayer] = [:]
  private let RequestLock = NSLock()
  private var RequestVersion = 0
  private let RecordLock = NSLock()
  private var RecordToken = 0
  private var PreparedVersion = 0
  private let SnapshotQueue = DispatchQueue(label: "splatoon3record.mobile_snapshot")
  // Snapshot conversion must not share the sample buffer queue: a slow render
  // there drops recorded frames (alwaysDiscardsLateVideoFrames).
  private let SnapshotWorkQueue = DispatchQueue(label: "splatoon3record.mobile_snapshot_work")
  private let MonitorQueue = DispatchQueue(label: "splatoon3record.audio_monitor")
  // Segment writes happen on their own serial queue so a slow encoder never
  // blocks session control (start / stop / monitor) and vice versa.
  private let RecordQueue = DispatchQueue(label: "splatoon3record.mobile_record")
  private let SampleLock = NSLock()
  private var RecordingSamples = false
  private var SampleVersion = 0
  private var PendingVideo = 0
  private var PendingAudio = 0
  private var Finishing = 0
  private var FinishWaiters: [(String?) -> Void] = []
  private let SnapshotLock = NSLock()
  private let TimingLog = Logger(subsystem: "splatoon3record.mobile_capture", category: "capture")
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
  private var LastMonitorRestart: TimeInterval = 0
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
  private var WriterAudioFailed = false
  private var WriterStart = CMTime.invalid
  private var AudioSampleRate = 48000.0
  private var AudioChannels = 2
  private var RecordSize = CGSize.zero
  private var RecordFps = 30
  private var RecordAudio = false

  var OnState: ((String) -> Void)?
  var OnAudio: ((String) -> Void)?
  var OnLog: ((String) -> Void)?
  private var VideoAngle: CGFloat = 0

  private func Trace(_ Name: String, Since Start: TimeInterval) {
    let Message = "\(Name) 耗时=\(Int((ProcessInfo.processInfo.systemUptime - Start) * 1000))ms"
    TimingLog.info("\(Message, privacy: .public)")
    OnLog?(Message)
  }

  private func NewRequest() -> Int {
    RequestLock.lock()
    defer { RequestLock.unlock() }
    RequestVersion += 1
    return RequestVersion
  }

  private func IsCurrent(_ Version: Int) -> Bool {
    RequestLock.lock()
    defer { RequestLock.unlock() }
    return RequestVersion == Version
  }

  private func BeginRecordRequest() -> Int {
    RecordLock.lock()
    defer { RecordLock.unlock() }
    RecordToken += 1
    return RecordToken
  }

  private func CancelRecordRequest() {
    RecordLock.lock()
    RecordToken += 1
    RecordLock.unlock()
  }

  private func IsRecordCurrent(_ Token: Int) -> Bool {
    RecordLock.lock()
    defer { RecordLock.unlock() }
    return RecordToken == Token
  }

  func AttachPreview(_ Preview: AVCaptureVideoPreviewLayer, Completion: @escaping () -> Void) {
    CaptureQueue.async {
      let Start = ProcessInfo.processInfo.systemUptime
      self.Previews[ObjectIdentifier(Preview)] = Preview
      if self.Prepared { self.ConfigurePreview(Preview) }
      self.Trace("预览挂接", Since: Start)
      DispatchQueue.main.async(execute: Completion)
    }
  }

  func DetachPreview(_ Preview: AVCaptureVideoPreviewLayer) {
    CaptureQueue.async {
      guard self.Previews.removeValue(forKey: ObjectIdentifier(Preview)) != nil else { return }
      Preview.session = nil
      self.OnLog?("预览层卸载")
    }
  }

  private func ConfigurePreview(_ Preview: AVCaptureVideoPreviewLayer) {
    if Preview.session !== Session { Preview.session = Session }
    guard let Connection = Preview.connection else { return }
    _ = Self.Rotate(Connection, Angle: VideoAngle)
    Connection.automaticallyAdjustsVideoMirroring = false
    if Connection.isVideoMirroringSupported { Connection.isVideoMirrored = false }
    Connection.isEnabled = true
  }

  private func ConfigurePreviews() {
    for Preview in Previews.values { ConfigurePreview(Preview) }
  }

  override init() {
    super.init()
    NotificationCenter.default.addObserver(self, selector: #selector(RouteChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(MonitorConfigurationChanged(_:)), name: .AVAudioEngineConfigurationChange, object: nil)
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
    CaptureQueue.async {
      guard self.AudioInput != nil else { return }
      self.RouteMonitorOutput()
      self.ReportAudio()
    }
  }

  // Plugging in headphones or a Bluetooth headset stops the engine; without
  // restarting it the monitor stays silent even though the route is available.
  @objc private func MonitorConfigurationChanged(_ Note: Notification) {
    // Wait for the engine to settle: it stops right after posting this change,
    // and restarting an engine that is still running would loop.
    CaptureQueue.asyncAfter(deadline: .now() + 0.3) {
      guard self.MonitorEnabled, let Engine = self.MonitorEngine, !Engine.isRunning else { return }
      let Now = ProcessInfo.processInfo.systemUptime
      guard Now - self.LastMonitorRestart > 0.5 else { return }
      self.LastMonitorRestart = Now
      self.OnLog?("声音返听输出变化，正在恢复")
      self.StopMonitor()
      self.RouteMonitorOutput()
      self.StartMonitor()
      self.LogAudioRoute()
    }
  }

  private func ReportAudio() {
    let Session = AVAudioSession.sharedInstance()
    let Input = Session.currentRoute.inputs.first
    let Name = Input?.portName ?? "无"
    let Type = Input?.portType.rawValue ?? ""
    OnAudio?("音频输入：\(Name) \(Type)")
    LogAudioRoute()
  }

  private func LogAudioRoute() {
    let Inputs = AudioSession.currentRoute.inputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: "、")
    let Outputs = AudioSession.currentRoute.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: "、")
    OnLog?("音频路由 输入=\(Inputs.isEmpty ? "无" : Inputs) 输出=\(Outputs.isEmpty ? "无" : Outputs)")
  }

  // Playback must follow the system default output. With a USB capture card
  // attached, playAndRecord routes the monitor to the card's line-out, so the
  // iPad speaker and wired or Bluetooth headphones stay silent. Force the
  // speaker only when the card itself is the output and no headset is present.
  private func RouteMonitorOutput() {
    guard let Card = AudioInput?.device.localizedName, !Card.isEmpty else { return }
    let Outputs = AudioSession.currentRoute.outputs
    let Headset = Outputs.contains { Port -> Bool in
      switch Port.portType {
      case .headphones, .headsetMic, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
        return true
      case .usbAudio:
        return Port.portName != Card
      default:
        return false
      }
    }
    do {
      if Headset {
        try AudioSession.overrideOutputAudioPort(.none)
      } else if Outputs.contains(where: { $0.portType == .usbAudio }) {
        try AudioSession.overrideOutputAudioPort(.speaker)
      } else {
        try AudioSession.overrideOutputAudioPort(.none)
      }
    } catch {
      OnLog?("音频输出路由设置失败：\(error.localizedDescription)")
    }
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
    do {
      try AudioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothA2DP])
    } catch {
      OnLog?("音频类别设置失败：\(error.localizedDescription)")
    }
    do {
      try AudioSession.setActive(true)
      // Only a successful activation counts: if it failed because the
      // microphone permission was still pending, Prepare must retry it.
      AudioConfigured = true
    } catch {
      OnLog?("音频会话激活失败：\(error.localizedDescription)")
    }
  }

  private func InputPorts() -> [AVAudioSessionPortDescription] {
    return AudioSession.availableInputs ?? []
  }

  private func InputPort(_ DeviceId: String) -> AVAudioSessionPortDescription? {
    let Ports = InputPorts()
    let Name = AudioInputs().first(where: { $0.uniqueID == DeviceId })?.localizedName
    if !DeviceId.isEmpty, let Exact = Ports.first(where: { $0.uid == DeviceId || $0.portName == DeviceId || $0.portName == Name }) {
      return Exact
    }
    return Ports.first(where: { $0.portType == .usbAudio }) ?? Ports.first(where: { IsExternal($0) })
  }

  private func AudioInputs() -> [AVCaptureDevice] {
    var Types: [AVCaptureDevice.DeviceType] = [.builtInMicrophone]
    if #available(iOS 17.0, *) { Types = [.microphone, .external] }
    return AVCaptureDevice.DiscoverySession(deviceTypes: Types, mediaType: .audio, position: .unspecified).devices
  }

  /// The capture session does not follow the AVAudioSession route, so the input
  /// device has to be matched to the selected port by name; otherwise the iPad
  /// microphone is recorded instead of the capture card audio.
  private func AudioDevice(_ PortName: String) -> AVCaptureDevice? {
    var Devices = AudioInputs()
    if !PortName.isEmpty {
      if let Match = Devices.first(where: { $0.localizedName == PortName }) {
        return Match
      }
      // The external device can take a moment to appear in the discovery session
      // after the route changes; without the retry the segment silently records
      // the built-in microphone while monitoring plays the capture card.
      for _ in 0..<12 {
        Thread.sleep(forTimeInterval: 0.1)
        Devices = AudioInputs()
        if let Match = Devices.first(where: { $0.localizedName == PortName }) {
          return Match
        }
      }
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
    let Enumerate: () -> Void = {
      self.CaptureQueue.async {
        // availableInputs stays empty until the audio session has a recording
        // category, which is why the settings page used to report "no audio
        // input" while monitoring already played the capture card. Configure the
        // session once here; Prepare then reuses it instead of reconfiguring.
        self.ConfigureAudio()
        self.ReadAudioDevices(Attempt: 0, Completion: Completion)
      }
    }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
      Enumerate()
      return
    }
    var Finished = false
    let Lock = NSLock()
    let Finish: () -> Void = {
      Lock.lock()
      guard !Finished else {
        Lock.unlock()
        return
      }
      Finished = true
      Lock.unlock()
      Enumerate()
    }
    AVCaptureDevice.requestAccess(for: .audio) { _ in Finish() }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) { Finish() }
  }

  // Runs on CaptureQueue. A capture card that was just plugged in, or a port the
  // system is still activating, only shows up after a moment; retry briefly
  // instead of reporting that the device has no audio input.
  private func ReadAudioDevices(Attempt: Int, Completion: @escaping ([[String: Any]]) -> Void) {
    let Items = InputAudioDevices()
    let External = Items.contains { ($0["external"] as? Bool) == true }
    if External || Attempt >= 4 {
      OnLog?("音频输入 \(Items.count) 个：" + Items.map { "\($0["name"] ?? "")" }.joined(separator: "、"))
      DispatchQueue.main.async { Completion(Items) }
      return
    }
    CaptureQueue.asyncAfter(deadline: .now() + 0.25) {
      self.ReadAudioDevices(Attempt: Attempt + 1, Completion: Completion)
    }
  }

  private func InputAudioDevices() -> [[String: Any]] {
    var Items = InputPorts().map { Port -> [String: Any] in
      [
        "id": Port.uid,
        "name": Port.portName,
        "external": IsExternal(Port),
      ]
    }
    for Device in AudioInputs() where !Items.contains(where: { ($0["name"] as? String) == Device.localizedName }) {
      Items.append(["id": Device.uniqueID, "name": Device.localizedName, "external": IsExternal(Device)])
    }
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
    let Version = NewRequest()
    OnLog?("准备采集 device=\(DeviceId) \(Width)x\(Height)@\(Fps) audio=\(Audio) audioDevice=\(AudioDeviceId) orientation=\(Orientation)")
    Request(Video: true) { VideoOk in
      guard VideoOk else {
        DispatchQueue.main.async { Completion(nil, "相机权限被拒绝") }
        return
      }
      guard Audio else {
        self.Apply(Version: Version, DeviceId: DeviceId, Width: Width, Height: Height, Fps: Fps, Audio: false, AudioDeviceId: "", Orientation: Orientation, Completion: Completion)
        return
      }
      AVCaptureDevice.requestAccess(for: .audio) { Granted in
        self.Apply(Version: Version, DeviceId: DeviceId, Width: Width, Height: Height, Fps: Fps, Audio: Granted, AudioDeviceId: AudioDeviceId, Orientation: Orientation, Completion: Completion)
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

  private func Apply(Version: Int, DeviceId: String, Width: Int, Height: Int, Fps: Int, Audio: Bool, AudioDeviceId: String, Orientation: String, Completion: @escaping (CaptureModeInfo?, String?) -> Void) {
    CaptureQueue.async {
      guard self.IsCurrent(Version) else {
        DispatchQueue.main.async { Completion(nil, "采集准备已取消") }
        return
      }
      let Start = ProcessInfo.processInfo.systemUptime
      guard let Device = self.Find(DeviceId) else {
        self.OnLog?("未找到采集设备：\(DeviceId)")
        DispatchQueue.main.async { Completion(nil, "未找到 USB 采集设备，需要 iPadOS 17 或更高版本") }
        return
      }
      var AudioPort: AVAudioSessionPortDescription?
      if Audio {
        self.ConfigureAudio()
        AudioPort = self.InputPort(AudioDeviceId)
        if let Port = AudioPort {
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
      let InputSize = Turned ? CGSize(width: CGFloat(Size.height), height: CGFloat(Size.width)) : CGSize(width: CGFloat(Size.width), height: CGFloat(Size.height))
      let AudioEnabled = self.AudioInput != nil
      let ActualFps = UseFps
      self.SampleLock.lock()
      self.AudioSampleRate = 48000
      self.AudioChannels = 2
      self.SampleLock.unlock()
      self.RecordQueue.async {
        self.RecordAudio = AudioEnabled
        self.RecordSize = InputSize
        self.RecordFps = ActualFps
      }
      self.Prepared = true
      self.PreparedVersion = Version
      let PreviewStart = ProcessInfo.processInfo.systemUptime
      self.ConfigurePreviews()
      self.Trace("预览连接配置", Since: PreviewStart)
      let RunningStart = ProcessInfo.processInfo.systemUptime
      self.Session.startRunning()
      self.Trace("采集会话启动", Since: RunningStart)
      guard self.IsCurrent(Version) else {
        self.Session.stopRunning()
        self.Prepared = false
        DispatchQueue.main.async { Completion(nil, "采集准备已取消") }
        return
      }
      self.Trace("采集准备", Since: Start)
      self.RouteMonitorOutput()
      self.OnLog?("采集已启动 \(Int(Size.width))x\(Int(Size.height))@\(UseFps) 音频输入=\(self.AudioInput?.device.localizedName ?? "无")")
      self.LogAudioRoute()
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
        self.RouteMonitorOutput()
        self.StartMonitor()
        self.LogAudioRoute()
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

  private func SetSampleAdmission(_ Enabled: Bool) {
    SampleLock.lock()
    RecordingSamples = Enabled
    SampleLock.unlock()
  }

  private func InvalidateSamples() {
    SampleLock.lock()
    RecordingSamples = false
    SampleVersion += 1
    SampleLock.unlock()
  }

  private func EnqueueSample(_ Sample: CMSampleBuffer, Video: Bool) {
    SampleLock.lock()
    // Bound retained capture buffers even while writer creation is slow.
    let Allowed = Video ? PendingVideo < 3 : PendingAudio < 8
    guard RecordingSamples, Allowed else {
      SampleLock.unlock()
      return
    }
    let Version = SampleVersion
    if Video { PendingVideo += 1 } else { PendingAudio += 1 }
    SampleLock.unlock()
    RecordQueue.async {
      defer {
        self.SampleLock.lock()
        if Video { self.PendingVideo -= 1 } else { self.PendingAudio -= 1 }
        self.SampleLock.unlock()
      }
      self.SampleLock.lock()
      let Active = self.RecordingSamples && self.SampleVersion == Version
      self.SampleLock.unlock()
      guard Active else { return }
      if Video {
        self.AppendVideo(Sample)
      } else {
        self.AppendAudio(Sample)
      }
    }
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    if output === SnapshotOutput {
      if let Pixel = CMSampleBufferGetImageBuffer(sampleBuffer) {
        SnapshotLock.lock()
        SnapshotPixel = Pixel
        SnapshotLock.unlock()
      }
      EnqueueSample(sampleBuffer, Video: true)
      return
    }
    if let Format = Self.AudioFormat(sampleBuffer), Format.0 >= 8000, Format.1 > 0 {
      SampleLock.lock()
      AudioSampleRate = Format.0
      AudioChannels = Format.1
      SampleLock.unlock()
    }
    EnqueueSample(sampleBuffer, Video: false)
    guard MonitorEnabled, let Player = MonitorPlayer, let Format = MonitorFormat else { return }
    let Frames = CMSampleBufferGetNumSamples(sampleBuffer)
    if Frames <= 0 { return }
    let Capacity = AVAudioFrameCount(max(Frames, 1024) * 2)
    guard let Buffer = AVAudioPCMBuffer(pcmFormat: Format, frameCapacity: Capacity) else { return }
    if !CopyAudio(sampleBuffer, To: Buffer, Format: Format) { return }
    Player.scheduleBuffer(Buffer, completionHandler: nil)
  }

  private static func AudioFormat(_ Sample: CMSampleBuffer) -> (Double, Int)? {
    guard let Description = CMSampleBufferGetFormatDescription(Sample),
          let Stream = CMAudioFormatDescriptionGetStreamBasicDescription(Description)?.pointee else { return nil }
    return (Stream.mSampleRate, Int(Stream.mChannelsPerFrame))
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

  private func FreeMegabytes(_ Folder: String) -> Int64? {
    let Volume = URL(fileURLWithPath: Folder)
    if let Values = try? Volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
       let Capacity = Values.volumeAvailableCapacityForImportantUsage {
      return Int64(Capacity) / (1024 * 1024)
    }
    return nil
  }

  func StartRecording(_ Path: String, Completion: @escaping (String?) -> Void) {
    CaptureQueue.async {
      guard self.Prepared, self.Session.isRunning, self.IsCurrent(self.PreparedVersion) else {
        DispatchQueue.main.async { Completion("采集会话未启动") }
        return
      }
      let Token = self.BeginRecordRequest()
      let Version = self.PreparedVersion
      self.StorageQueue.async {
        let Start = ProcessInfo.processInfo.systemUptime
        let Folder = (Path as NSString).deletingLastPathComponent
        do {
          try FileManager.default.createDirectory(atPath: Folder, withIntermediateDirectories: true)
        } catch {
          DispatchQueue.main.async { Completion("无法创建录制目录：\(error.localizedDescription)") }
          return
        }
        let Free = self.FreeMegabytes(Folder)
        self.Trace("录制目录与空间预检", Since: Start)
        self.CaptureQueue.async {
          guard self.IsRecordCurrent(Token), self.IsCurrent(Version), self.Prepared, self.Session.isRunning else {
            DispatchQueue.main.async { Completion("录制启动已取消") }
            return
          }
          if let Free = Free, Free < 512 {
            self.OnLog?("存储空间不足：剩余 \(Free)MB")
            DispatchQueue.main.async { Completion("存储空间不足（剩余 \(Free) MB），请清理缓存后重试") }
            return
          }
          self.RecordQueue.async {
            guard self.IsRecordCurrent(Token), self.IsCurrent(Version) else {
              DispatchQueue.main.async { Completion("录制启动已取消") }
              return
            }
            let WriterStart = ProcessInfo.processInfo.systemUptime
            var Failure = self.BeginWriter(Path)
            self.Trace("录制写入器启动", Since: WriterStart)
            let HasAudio = self.WriterAudio != nil
            if Failure == nil {
              // Stop or Dispose may have arrived while the writer was created.
              if self.IsRecordCurrent(Token), self.IsCurrent(Version) {
                self.SetSampleAdmission(true)
                self.OnState?("recording")
              } else {
                self.InvalidateSamples()
                self.EndWriter(nil)
                Failure = "录制启动已取消"
              }
            }
            let Capacity = Free.map { "\($0)MB" } ?? "未知"
            self.OnLog?("开始录制：\(Path) 剩余空间=\(Capacity) 尺寸=\(Int(self.RecordSize.width))x\(Int(self.RecordSize.height)) 音频=\(HasAudio) 结果=\(Failure ?? "ok")")
            let Posted = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
              self.Trace("录制启动主线程回调等待", Since: Posted)
              Completion(Failure)
            }
          }
        }
      }
    }
  }

  func StopRecording(_ Completion: @escaping (String?) -> Void) {
    CaptureQueue.async {
      self.CancelRecordRequest()
      self.SetSampleAdmission(false)
      self.RecordQueue.async { self.EndWriter(Completion) }
    }
  }

  // Runs on RecordQueue; never holds the sample delegate queues while creating
  // the hardware H.264 / AAC writer.
  private func BeginWriter(_ Path: String) -> String? {
    EndWriter(nil)
    try? FileManager.default.removeItem(atPath: Path)
    guard let Writer = try? AVAssetWriter(outputURL: URL(fileURLWithPath: Path), fileType: .mov) else {
      return "无法创建录制文件"
    }
    var Width = Int(RecordSize.width)
    var Height = Int(RecordSize.height)
    if Width <= 0 || Height <= 0 {
      Width = 1920
      Height = 1080
    }
    let Fps = max(1, RecordFps)
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
    if RecordAudio {
      SampleLock.lock()
      let Channels = AudioChannels
      let SampleRate = AudioSampleRate
      SampleLock.unlock()
      let Input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: max(1, Channels),
        AVSampleRateKey: SampleRate > 0 ? SampleRate : 48000,
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
    WriterAudioFailed = false
    WriterStart = CMTime.invalid
    self.Writer = Writer
    return nil
  }

  // Runs on RecordQueue. Closes the segment and reports its path once the file
  // is fully written, so the Dart side never merges a half written file.
  private func EndWriter(_ Completion: ((String?) -> Void)?) {
    SetSampleAdmission(false)
    guard let Writer = self.Writer else {
      guard let Completion = Completion else { return }
      if Finishing > 0 {
        FinishWaiters.append(Completion)
      } else {
        DispatchQueue.main.async { Completion(nil) }
      }
      return
    }
    let Path = self.WriterPath
    let Video = self.WriterVideo
    let Audio = self.WriterAudio
    let Wrote = self.WriterVideoWritten
    let Started = self.WriterStarted
    self.Writer = nil
    self.WriterVideo = nil
    self.WriterAudio = nil
    self.WriterPath = ""
    self.WriterStarted = false
    self.WriterVideoWritten = false
    self.WriterAudioWritten = false
    let Finish: (String?) -> Void = { Reason in
      self.OnLog?(Reason == nil ? "录制分段结束 path=\(Path)" : "录制分段失败 \(Reason ?? "") path=\(Path)")
      if let Completion = Completion { DispatchQueue.main.async { Completion(Reason == nil ? Path : nil) } }
    }
    guard Writer.status == .writing else {
      try? FileManager.default.removeItem(atPath: Path)
      Finish("写入未开始 状态=\(Writer.status.rawValue) 错误=\(Writer.error?.localizedDescription ?? "无")")
      return
    }
    // No session start means no frame was ever written: finishing such a writer
    // only produces a broken asset, so cancel it instead.
    guard Started else {
      Writer.cancelWriting()
      try? FileManager.default.removeItem(atPath: Path)
      Finish("没有写入任何视频帧")
      return
    }
    Video?.markAsFinished()
    Audio?.markAsFinished()
    Finishing += 1
    Writer.finishWriting {
      self.RecordQueue.async {
        if Writer.status == .completed, Wrote {
          Finish(nil)
        } else {
          try? FileManager.default.removeItem(atPath: Path)
          Finish("状态=\(Writer.status.rawValue) 错误=\(Writer.error?.localizedDescription ?? "无")")
        }
        let Waiters = self.FinishWaiters
        self.FinishWaiters = []
        self.Finishing -= 1
        if self.Finishing == 0 {
          for Waiter in Waiters { DispatchQueue.main.async { Waiter(nil) } }
        }
      }
    }
  }

  private func RecordingFailed(_ Reason: String) {
    guard self.Writer != nil else { return }
    OnLog?(Reason)
    OnState?("idle")
    EndWriter(nil)
  }

  private func AppendVideo(_ Sample: CMSampleBuffer) {
    guard let Writer = self.Writer, let Input = self.WriterVideo else { return }
    guard Writer.status == .writing else {
      RecordingFailed("录制写入器已停止：\(Writer.error?.localizedDescription ?? "未知错误")")
      return
    }
    guard CMSampleBufferDataIsReady(Sample), Input.isReadyForMoreMediaData else { return }
    if !WriterStarted {
      WriterStart = CMSampleBufferGetPresentationTimeStamp(Sample)
      Writer.startSession(atSourceTime: WriterStart)
      WriterStarted = true
    }
    if Input.append(Sample) {
      WriterVideoWritten = true
    } else if !WriterAppendFailed {
      WriterAppendFailed = true
      RecordingFailed("写入视频帧失败：\(Writer.error?.localizedDescription ?? "无")")
    }
  }

  private func AppendAudio(_ Sample: CMSampleBuffer) {
    guard WriterStarted, WriterStart.isValid, let Writer = self.Writer, let Input = self.WriterAudio, Writer.status == .writing else { return }
    guard CMSampleBufferDataIsReady(Sample), Input.isReadyForMoreMediaData else { return }
    // Frames older than the session start are rejected by the writer, and a
    // rejected append fails the whole segment.
    guard CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(Sample), WriterStart) >= 0 else { return }
    if Input.append(Sample) {
      WriterAudioWritten = true
    } else if !WriterAudioFailed {
      WriterAudioFailed = true
      RecordingFailed("写入音频帧失败：\(Writer.error?.localizedDescription ?? "无")")
    }
  }

  func Dispose(_ Completion: @escaping () -> Void) {
    _ = NewRequest()
    CancelRecordRequest()
    InvalidateSamples()
    CaptureQueue.async {
      let Start = ProcessInfo.processInfo.systemUptime
      self.OnLog?("释放采集会话")
      self.Prepared = false
      self.MonitorEnabled = false
      self.StopMonitor()
      if self.Session.isRunning { self.Session.stopRunning() }
      for Preview in self.Previews.values { Preview.session = nil }
      self.Session.beginConfiguration()
      if let Output = self.AudioOutput { self.Session.removeOutput(Output) }
      if self.Session.outputs.contains(self.SnapshotOutput) { self.Session.removeOutput(self.SnapshotOutput) }
      for Input in self.Session.inputs { self.Session.removeInput(Input) }
      self.Session.commitConfiguration()
      self.AudioOutput = nil
      self.VideoInput = nil
      self.AudioInput = nil
      self.SnapshotLock.lock()
      self.SnapshotPixel = nil
      self.SnapshotLock.unlock()
      self.Trace("采集会话释放", Since: Start)
      self.RecordQueue.async {
        self.EndWriter { _ in Completion() }
      }
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
    SnapshotWorkQueue.async(execute: Task)
  }
}
