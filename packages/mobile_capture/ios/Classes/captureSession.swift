import AVFoundation
import Flutter

struct CaptureModeInfo {
  let Width: Int
  let Height: Int
  let Fps: Int
}

final class CaptureSession: NSObject, AVCaptureFileOutputRecordingDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
  let Session = AVCaptureSession()

  private let Output = AVCaptureMovieFileOutput()
  private let CaptureQueue = DispatchQueue(label: "splatoon3record.mobile_capture")
  private let MonitorQueue = DispatchQueue(label: "splatoon3record.audio_monitor")
  private var VideoInput: AVCaptureDeviceInput?
  private var AudioInput: AVCaptureDeviceInput?
  private var Pending: ((String?) -> Void)?
  private var Prepared = false
  private var AudioOutput: AVCaptureAudioDataOutput?
  private var MonitorEngine: AVAudioEngine?
  private var MonitorPlayer: AVAudioPlayerNode?
  private var MonitorFormat: AVAudioFormat?
  private var MonitorEnabled = false

  var OnState: ((String) -> Void)?
  var VideoAngle: CGFloat = 0

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

  private var AudioTypes: [AVCaptureDevice.DeviceType] {
    if #available(iOS 17.0, *) {
      return [.external]
    }
    return []
  }

  private func ListAudio() -> [AVCaptureDevice] {
    guard #available(iOS 17.0, *) else { return [] }
    return AVCaptureDevice.DiscoverySession(deviceTypes: AudioTypes, mediaType: .audio, position: .unspecified).devices
  }

  private func AudioDevice(_ DeviceId: String) -> AVCaptureDevice? {
    let Devices = ListAudio()
    if DeviceId.isEmpty { return Devices.first }
    return Devices.first(where: { $0.uniqueID == DeviceId })
  }

  func AudioDevices() -> [[String: Any]] {
    return ListAudio().map { Device in
      [
        "id": Device.uniqueID,
        "name": Device.localizedName,
        "external": IsExternal(Device),
      ]
    }
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
    Request(Video: true) { VideoOk in
      guard VideoOk else {
        Completion(nil, "相机权限被拒绝")
        return
      }
      if Audio, self.AudioDevice(AudioDeviceId) != nil {
        AVCaptureDevice.requestAccess(for: .audio) { Granted in
          self.Apply(DeviceId: DeviceId, Width: Width, Height: Height, Fps: Fps, Audio: Granted, AudioDeviceId: AudioDeviceId, Orientation: Orientation, Completion: Completion)
        }
      } else {
        self.Apply(DeviceId: DeviceId, Width: Width, Height: Height, Fps: Fps, Audio: false, AudioDeviceId: "", Orientation: Orientation, Completion: Completion)
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
        DispatchQueue.main.async { Completion(nil, "未找到 USB 采集设备，需要 iPadOS 17 或更高版本") }
        return
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
      if Audio {
        if let AudioDevice = self.AudioDevice(AudioDeviceId) {
          if let Old = self.AudioInput { self.Session.removeInput(Old) }
          if let Input = try? AVCaptureDeviceInput(device: AudioDevice), self.Session.canAddInput(Input) {
            self.Session.addInput(Input)
            self.AudioInput = Input
          }
        }
        if self.AudioInput != nil { self.AttachAudio() }
      } else {
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
      if !self.Session.outputs.contains(self.Output) {
        if self.Session.canAddOutput(self.Output) { self.Session.addOutput(self.Output) }
      }
      let Size = CMVideoFormatDescriptionGetDimensions(Device.activeFormat.formatDescription)
      self.VideoAngle = Self.Angle(Orientation, Width: Int(Size.width), Height: Int(Size.height))
      self.Session.commitConfiguration()
      if let Connection = self.Output.connection(with: .video) {
        self.Rotate(Connection, Angle: self.VideoAngle)
        Connection.automaticallyAdjustsVideoMirroring = false
        if Connection.isVideoMirroringSupported {
          Connection.isVideoMirrored = false
        }
      }
      self.Prepared = true
      self.Session.startRunning()
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

  private func Rotate(_ Connection: AVCaptureConnection?, Angle: CGFloat) {
    guard let Connection = Connection else { return }
    if #available(iOS 17.0, *) {
      if Connection.isVideoRotationAngleSupported(Angle) {
        Connection.videoRotationAngle = Angle
      }
    }
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
          return
        }
        self.MonitorEnabled = true
        self.StartMonitor()
      } else {
        self.MonitorEnabled = false
        self.StopMonitor()
      }
    }
  }

  private func StartMonitor() {
    if MonitorEngine != nil {
      MonitorPlayer?.play()
      return
    }
    let AudioSession = AVAudioSession.sharedInstance()
    try? AudioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
    try? AudioSession.setActive(true)
    guard let Format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true) else { return }
    let Engine = AVAudioEngine()
    let Player = AVAudioPlayerNode()
    Engine.attach(Player)
    Engine.connect(Player, to: Engine.mainMixerNode, format: Format)
    Engine.prepare()
    do {
      try Engine.start()
      Player.play()
    } catch {
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
          let Stream = CMAudioFormatDescriptionGetStreamBasicDescription(Description)?.pointee else { return false }
    var StreamValue = Stream
    guard let SourceFormat = AVAudioFormat(streamDescription: &StreamValue) else { return false }
    let Frames = CMSampleBufferGetNumSamples(SampleBuffer)
    if Frames <= 0 { return false }
    guard SourceFormat.isInterleaved else { return false }
    guard let Input = AVAudioPCMBuffer(pcmFormat: SourceFormat, frameCapacity: AVAudioFrameCount(Frames)) else { return false }
    Input.frameLength = AVAudioFrameCount(Frames)
    guard let Block = CMSampleBufferGetDataBuffer(SampleBuffer) else { return false }
    let Targets = UnsafeMutableAudioBufferListPointer(Input.mutableAudioBufferList)
    guard Targets.count > 0, let Target = Targets[0].mData else { return false }
    let Length = min(CMBlockBufferGetDataLength(Block), Int(Targets[0].mDataByteSize))
    if CMBlockBufferCopyDataBytes(Block, atOffset: 0, dataLength: Length, destination: Target) != noErr { return false }
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

  func StartRecording(_ Path: String, Completion: @escaping (String?) -> Void) {
    CaptureQueue.async {
      guard self.Prepared, self.Session.isRunning else {
        DispatchQueue.main.async { Completion("采集会话未启动") }
        return
      }
      if self.Output.isRecording { self.Output.stopRecording() }
      try? FileManager.default.removeItem(atPath: Path)
      self.Output.startRecording(to: URL(fileURLWithPath: Path), recordingDelegate: self)
      self.OnState?("recording")
      DispatchQueue.main.async { Completion(nil) }
    }
  }

  func StopRecording(_ Completion: @escaping (String?) -> Void) {
    CaptureQueue.async {
      guard self.Output.isRecording else {
        DispatchQueue.main.async { Completion(nil) }
        return
      }
      self.Pending = Completion
      self.Output.stopRecording()
    }
  }

  func Dispose() {
    CaptureQueue.async {
      if self.Output.isRecording { self.Output.stopRecording() }
      self.MonitorEnabled = false
      self.StopMonitor()
      if let Output = self.AudioOutput {
        self.Session.beginConfiguration()
        self.Session.removeOutput(Output)
        self.Session.commitConfiguration()
        self.AudioOutput = nil
      }
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

  func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
    let Path = error == nil ? outputFileURL.path : nil
    let Callback = Pending
    Pending = nil
    OnState?("idle")
    if let Callback = Callback {
      DispatchQueue.main.async { Callback(Path) }
    }
  }
}
