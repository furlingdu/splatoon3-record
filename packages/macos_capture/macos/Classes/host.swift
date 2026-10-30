import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import FlutterMacOS
import Foundation

final class MacCaptureHost: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
  let Session = AVCaptureSession()

  private let VideoOutput = AVCaptureVideoDataOutput()
  private let AudioOutput = AVCaptureAudioDataOutput()
  private let Queue = DispatchQueue(label: "splatoon3record.mac.capture")
  private let AudioQueue = DispatchQueue(label: "splatoon3record.mac.audio")
  private let PreviewQueue = DispatchQueue(label: "splatoon3record.mac.preview")
  private let MonitorQueue = DispatchQueue(label: "splatoon3record.mac.monitor")
  private let PreviewLock = NSLock()
  private let Context = CIContext(options: nil)
  private let Texture = MacCaptureTexture()
  private var VideoInput: AVCaptureDeviceInput?
  private var AudioInput: AVCaptureDeviceInput?
  private var Stdin: FileHandle?
  private var AudioFile: FileHandle?
  private var ProcessRef: Process?
  private var Pool: CVPixelBufferPool?
  private var PreviewPending: CVPixelBuffer?
  private var PreviewScheduled = false
  private var StatsTimer: Timer?
  private var Width = 0
  private var Height = 0
  private var Fps = 0
  private var Frames = 0
  private var Written = 0
  private var LastTick = Date()
  private var Prepared = false
  private var Stopping = false
  private var NativeMode = false
  private var Recorder: MacRecorder?
  private var AudioFifo = ""
  private var MonitorEngine: AVAudioEngine?
  private var MonitorPlayer: AVAudioPlayerNode?
  private var MonitorFormat: AVAudioFormat?
  private var MonitorEnabled = false
  private let VisionLock = NSLock()
  private var VisionData: Data?
  private var VisionEnabled = false
  private var LastVisionTick = Date.distantPast

  var TextureId: Int64 = -1
  var OnState: ((String) -> Void)?
  var OnStats: (([String: Any]) -> Void)?
  var OnError: ((String) -> Void)?
  var OnLog: ((String) -> Void)?

  private var DeviceTypes: [AVCaptureDevice.DeviceType] {
    return [.builtInWideAngleCamera, .externalUnknown]
  }

  private var AudioTypes: [AVCaptureDevice.DeviceType] {
    if #available(macOS 14.0, *) {
      return [.microphone, .externalUnknown]
    }
    return [.builtInMicrophone, .externalUnknown]
  }

  private func Find(_ DeviceId: String) -> AVCaptureDevice? {
    let Devices = AVCaptureDevice.DiscoverySession(deviceTypes: DeviceTypes, mediaType: .video, position: .unspecified).devices
    return Devices.first(where: { $0.uniqueID == DeviceId })
  }

  private func AudioDevices() -> [AVCaptureDevice] {
    var Result = AVCaptureDevice.DiscoverySession(deviceTypes: AudioTypes, mediaType: .audio, position: .unspecified).devices
    for Device in AVCaptureDevice.devices(for: .audio) {
      if !Result.contains(where: { $0.uniqueID == Device.uniqueID }) {
        Result.append(Device)
      }
    }
    return Result
  }

  private func FindAudio(_ DeviceId: String) -> AVCaptureDevice? {
    guard !DeviceId.isEmpty else { return nil }
    return AudioDevices().first(where: { $0.uniqueID == DeviceId })
  }

  func Enumerate() -> [[String: Any]] {
    var Result: [[String: Any]] = []
    let Videos = AVCaptureDevice.DiscoverySession(deviceTypes: DeviceTypes, mediaType: .video, position: .unspecified).devices
    for Device in Videos {
      Result.append(["id": Device.uniqueID, "name": Device.localizedName, "kind": "video"])
    }
    let Audios = AudioDevices()
    for Device in Audios {
      Result.append(["id": Device.uniqueID, "name": Device.localizedName, "kind": "audio"])
    }
    return Result
  }

  func Modes(_ DeviceId: String) -> [[String: Any]] {
    guard let Device = Find(DeviceId) else { return [] }
    var Seen = Set<String>()
    var Result: [[String: Any]] = []
    for Format in Device.formats {
      let Size = CMVideoFormatDescriptionGetDimensions(Format.formatDescription)
      let Range = Format.videoSupportedFrameRateRanges.first
      let Fps = Int((Range?.maxFrameRate ?? 30).rounded())
      let Key = "\(Size.width)x\(Size.height)@\(Fps)"
      if !Seen.insert(Key).inserted { continue }
      Result.append(["format": "nv12", "width": Int(Size.width), "height": Int(Size.height), "fps": Fps])
    }
    return Result
  }

  func Prepare(DeviceId: String, Width: Int, Height: Int, Fps: Int, AudioDeviceId: String, AudioFifoPath: String, Completion: @escaping ([String: Any]?, String?) -> Void) {
    guard let Device = Find(DeviceId) else {
      Completion(nil, "未找到采集设备")
      return
    }
    if Session.isRunning { Session.stopRunning() }
    Session.beginConfiguration()
    do {
      let Input = try AVCaptureDeviceInput(device: Device)
      if let Old = VideoInput { Session.removeInput(Old) }
      guard Session.canAddInput(Input) else {
        Session.commitConfiguration()
        Completion(nil, "无法打开采集设备")
        return
      }
      Session.addInput(Input)
      VideoInput = Input
    } catch {
      Session.commitConfiguration()
      Completion(nil, "无法打开采集设备")
      return
    }
    var UseFps = max(1, Fps)
    if let Format = PickFormat(Device, Width, Height) {
      do {
        try Device.lockForConfiguration()
        Device.activeFormat = Format
        if let Range = Format.videoSupportedFrameRateRanges.first {
          UseFps = min(UseFps, max(1, Int(Range.maxFrameRate.rounded())))
        }
        let Duration = CMTime(value: 1, timescale: CMTimeScale(UseFps))
        Device.activeVideoMinFrameDuration = Duration
        Device.activeVideoMaxFrameDuration = Duration
        Device.unlockForConfiguration()
      } catch {
      }
    }
    VideoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    ]
    VideoOutput.alwaysDiscardsLateVideoFrames = true
    VideoOutput.setSampleBufferDelegate(self, queue: Queue)
    if !Session.outputs.contains(VideoOutput) {
      if Session.canAddOutput(VideoOutput) { Session.addOutput(VideoOutput) }
    }
    AudioFifo = ""
    if let AudioDevice = FindAudio(AudioDeviceId), !AudioDeviceId.isEmpty {
      do {
        if let Old = AudioInput {
          Session.removeInput(Old)
          AudioInput = nil
        }
        let Input = try AVCaptureDeviceInput(device: AudioDevice)
        if Session.canAddInput(Input) {
          Session.addInput(Input)
          AudioInput = Input
          AudioOutput.audioSettings = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
          ]
          AudioOutput.setSampleBufferDelegate(self, queue: AudioQueue)
          if !Session.outputs.contains(AudioOutput) {
            if Session.canAddOutput(AudioOutput) { Session.addOutput(AudioOutput) }
          }
          if !AudioFifoPath.isEmpty {
            unlink(AudioFifoPath)
            if mkfifo(AudioFifoPath, 0o666) == 0 {
              AudioFifo = AudioFifoPath
            }
          }
        }
      } catch {
      }
    } else {
      if let Old = AudioInput {
        Session.removeInput(Old)
        AudioInput = nil
      }
      if Session.outputs.contains(AudioOutput) {
        Session.removeOutput(AudioOutput)
      }
    }
    Session.commitConfiguration()
    let Size = CMVideoFormatDescriptionGetDimensions(Device.activeFormat.formatDescription)
    self.Width = Int(Size.width)
    self.Height = Int(Size.height)
    self.Fps = UseFps
    Prepared = true
    Completion([
      "width": self.Width,
      "height": self.Height,
      "fps": UseFps,
      "fpsNum": UseFps,
      "fpsDen": 1,
      "format": "nv12",
      "audioFifo": AudioFifo,
    ], nil)
  }

  private func PickFormat(_ Device: AVCaptureDevice, _ Width: Int, _ Height: Int) -> AVCaptureDevice.Format? {
    var Best: AVCaptureDevice.Format?
    var BestScore = Int.max
    for Format in Device.formats {
      let Size = CMVideoFormatDescriptionGetDimensions(Format.formatDescription)
      let Score = abs(Int(Size.width) - Width) + abs(Int(Size.height) - Height)
      if Score < BestScore {
        BestScore = Score
        Best = Format
      }
    }
    return Best
  }

  func StartNative(Directory: String, Quality: Int, SegmentSeconds: Int, Audio: Bool, Monitor: Bool, Completion: @escaping (String?) -> Void) {
    guard Prepared else {
      Completion("采集设备未准备")
      return
    }
    Recorder?.Stop()
    NativeMode = true
    Stopping = false
    Frames = 0
    Written = 0
    LastTick = Date()
    let Engine = MacRecorder(Directory: Directory, Width: Width, Height: Height, Fps: Fps, Quality: Quality, SegmentSeconds: SegmentSeconds, Audio: Audio && AudioInput != nil)
    Engine.OnError = { [weak self] Text in
      self?.OnError?(Text)
    }
    Recorder = Engine
    guard Engine.Start() else {
      Recorder = nil
      NativeMode = false
      Completion("无法启动原生录制编码")
      return
    }
    Queue.async {
      if !self.Session.isRunning { self.Session.startRunning() }
    }
    if Monitor {
      self.Monitor(true)
    }
    OnState?("recording")
    StatsTimer?.invalidate()
    StatsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      self?.PushStats()
    }
    Completion(nil)
  }

  func Start(Exe: String, Args: [String], Completion: @escaping (String?) -> Void) {
    guard Prepared else {
      Completion("采集设备未准备")
      return
    }
    NativeMode = false
    Recorder = nil
    let Task = Process()
    Task.executableURL = URL(fileURLWithPath: Exe)
    Task.arguments = Args
    let InputPipe = Pipe()
    let ErrorPipe = Pipe()
    Task.standardInput = InputPipe
    Task.standardError = ErrorPipe
    Task.standardOutput = Pipe()
    ErrorPipe.fileHandleForReading.readabilityHandler = { [weak self] Handle in
      let Data = Handle.availableData
      if Data.isEmpty { return }
      let Text = String(data: Data, encoding: .utf8) ?? ""
      let Trimmed = Text.trimmingCharacters(in: .whitespacesAndNewlines)
      if Trimmed.isEmpty { return }
      if Trimmed.contains("error") || Trimmed.contains("Error") || Trimmed.contains("failed") {
        self?.OnError?(Trimmed)
      }
    }
    do {
      try Task.run()
    } catch {
      Completion("无法启动编码进程：\(error.localizedDescription)")
      return
    }
    ProcessRef = Task
    Stdin = InputPipe.fileHandleForWriting
    Stopping = false
    Frames = 0
    Written = 0
    LastTick = Date()
    Task.terminationHandler = { [weak self] Value in
      guard let Strong = self else { return }
      if Strong.Stopping { return }
      Strong.OnError?("编码进程退出 \(Value.terminationStatus)")
      Strong.OnState?("error")
    }
    if !AudioFifo.isEmpty {
      let Path = AudioFifo
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
        self.AudioFile = FileHandle(forWritingAtPath: Path)
      }
    }
    Queue.async {
      self.Session.startRunning()
    }
    OnState?("recording")
    StatsTimer?.invalidate()
    StatsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      self?.PushStats()
    }
    Completion(nil)
  }

  func Stop(Fast: Bool, Completion: @escaping () -> Void) {
    Stopping = true
    StatsTimer?.invalidate()
    StatsTimer = nil
    Monitor(false)
    if Session.isRunning { Session.stopRunning() }
    Recorder?.Stop()
    Recorder = nil
    NativeMode = false
    try? AudioFile?.close()
    AudioFile = nil
    try? Stdin?.close()
    Stdin = nil
    let Task = ProcessRef
    ProcessRef = nil
    if let Task = Task, Task.isRunning {
      Task.terminate()
      Task.waitUntilExit()
    }
    if !AudioFifo.isEmpty {
      unlink(AudioFifo)
      AudioFifo = ""
    }
    OnState?("idle")
    Completion()
  }

  func Dispose() {
    Prepared = false
    StatsTimer?.invalidate()
    StatsTimer = nil
    Monitor(false)
    if Session.isRunning { Session.stopRunning() }
    Recorder?.Stop()
    Recorder = nil
    NativeMode = false
    Session.beginConfiguration()
    for Input in Session.inputs { Session.removeInput(Input) }
    for Output in Session.outputs { Session.removeOutput(Output) }
    Session.commitConfiguration()
    VideoInput = nil
    AudioInput = nil
    Pool = nil
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    if output === AudioOutput {
      if NativeMode {
        Recorder?.AppendAudio(sampleBuffer)
      } else {
        WriteAudio(sampleBuffer)
      }
      MonitorQueue.async { [weak self] in
        self?.PushMonitor(sampleBuffer)
      }
      return
    }
    guard let Pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    Frames += 1
    if NativeMode {
      Recorder?.AppendVideo(sampleBuffer)
    } else {
      Write(Pixel)
    }
    Preview(Pixel)
    CaptureVision(Pixel)
  }

  func SetVision(_ Enabled: Bool) {
    VisionEnabled = Enabled
    if !Enabled {
      VisionLock.lock()
      VisionData = nil
      VisionLock.unlock()
    }
  }

  func VisionSnapshot() -> [String: Any]? {
    VisionLock.lock()
    let Value = VisionData
    VisionLock.unlock()
    guard let Value = Value else { return nil }
    return [
      "width": 1280,
      "height": 720,
      "bytes": FlutterStandardTypedData(bytes: Value),
    ]
  }

  private func CaptureVision(_ Pixel: CVPixelBuffer) {
    guard VisionEnabled else { return }
    let Now = Date()
    if Now.timeIntervalSince(LastVisionTick) < 0.5 { return }
    LastVisionTick = Now
    PreviewQueue.async { [weak self] in
      self?.RenderVision(Pixel)
    }
  }

  private func RenderVision(_ Pixel: CVPixelBuffer) {
    let Width = 1280
    let Height = 720
    var Destination: CVPixelBuffer?
    let Attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferWidthKey as String: Width,
      kCVPixelBufferHeightKey as String: Height,
    ]
    guard CVPixelBufferCreate(nil, Width, Height, kCVPixelFormatType_32BGRA, Attributes as CFDictionary, &Destination) == kCVReturnSuccess,
          let Destination = Destination else { return }
    let Image = CIImage(cvPixelBuffer: Pixel)
    Context.render(Image, to: Destination, bounds: CGRect(x: 0, y: 0, width: Width, height: Height), colorSpace: CGColorSpaceCreateDeviceRGB())
    CVPixelBufferLockBaseAddress(Destination, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(Destination, .readOnly) }
    guard let Base = CVPixelBufferGetBaseAddress(Destination) else { return }
    let Stride = CVPixelBufferGetBytesPerRow(Destination)
    var DataValue = Data(count: Width * Height * 4)
    DataValue.withUnsafeMutableBytes { Target in
      guard let TargetBase = Target.baseAddress else { return }
      for Row in 0..<Height {
        memcpy(TargetBase.advanced(by: Row * Width * 4), Base.advanced(by: Row * Stride), Width * 4)
      }
    }
    VisionLock.lock()
    VisionData = DataValue
    VisionLock.unlock()
  }

  private func WriteAudio(_ Sample: CMSampleBuffer) {
    guard let File = AudioFile, let Block = CMSampleBufferGetDataBuffer(Sample) else { return }
    let Length = CMBlockBufferGetDataLength(Block)
    if Length <= 0 { return }
    var Bytes = Data(count: Length)
    let Status = Bytes.withUnsafeMutableBytes { Target in
      guard let Base = Target.baseAddress else { return OSStatus(-1) }
      return CMBlockBufferCopyDataBytes(Block, atOffset: 0, dataLength: Length, destination: Base)
    }
    if Status == noErr { try? File.write(contentsOf: Bytes) }
  }

  private func Write(_ Pixel: CVPixelBuffer) {
    guard let Stdin = Stdin else { return }
    CVPixelBufferLockBaseAddress(Pixel, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(Pixel, .readOnly) }
    let PlaneCount = CVPixelBufferGetPlaneCount(Pixel)
    if PlaneCount < 2 { return }
    guard let YBase = CVPixelBufferGetBaseAddressOfPlane(Pixel, 0),
          let UVBase = CVPixelBufferGetBaseAddressOfPlane(Pixel, 1) else { return }
    let YStride = CVPixelBufferGetBytesPerRowOfPlane(Pixel, 0)
    let UVStride = CVPixelBufferGetBytesPerRowOfPlane(Pixel, 1)
    let Size = Width * Height + Width * (Height / 2)
    var Buffer = Data(count: Size)
    Buffer.withUnsafeMutableBytes { Raw in
      guard let Base = Raw.baseAddress else { return }
      let YTarget = Base.assumingMemoryBound(to: UInt8.self)
      let YSource = YBase.assumingMemoryBound(to: UInt8.self)
      for Row in 0..<Height {
        memcpy(YTarget + Row * Width, YSource + Row * YStride, Width)
      }
      let UVTarget = YTarget + Width * Height
      let UVSource = UVBase.assumingMemoryBound(to: UInt8.self)
      for Row in 0..<(Height / 2) {
        memcpy(UVTarget + Row * Width, UVSource + Row * UVStride, Width)
      }
    }
    do {
      try Stdin.write(contentsOf: Buffer)
      Written += 1
    } catch {
      OnError?("写入编码进程失败：\(error.localizedDescription)")
    }
  }

  private func EnsurePool() -> CVPixelBufferPool? {
    if let Pool = Pool { return Pool }
    let Attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferWidthKey as String: Width,
      kCVPixelBufferHeightKey as String: Height,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    var Created: CVPixelBufferPool?
    let Status = CVPixelBufferPoolCreate(nil, nil, Attributes as CFDictionary, &Created)
    if Status != kCVReturnSuccess { return nil }
    Pool = Created
    return Created
  }

  private func Preview(_ Pixel: CVPixelBuffer) {
    PreviewLock.lock()
    PreviewPending = Pixel
    let ShouldSchedule = !PreviewScheduled
    PreviewScheduled = true
    PreviewLock.unlock()
    if ShouldSchedule {
      PreviewQueue.async { [weak self] in
        self?.DrainPreview()
      }
    }
  }

  private func DrainPreview() {
    while true {
      PreviewLock.lock()
      guard let Pixel = PreviewPending else {
        PreviewScheduled = false
        PreviewLock.unlock()
        return
      }
      PreviewPending = nil
      PreviewLock.unlock()
      RenderPreview(Pixel)
    }
  }

  private func RenderPreview(_ Pixel: CVPixelBuffer) {
    guard let Pool = EnsurePool() else { return }
    var Destination: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, Pool, &Destination) == kCVReturnSuccess, let Destination = Destination else { return }
    let Image = CIImage(cvPixelBuffer: Pixel)
    Context.render(Image, to: Destination)
    Texture.Submit(Destination)
  }

  func Monitor(_ Enabled: Bool) {
    MonitorQueue.async { [weak self] in
      guard let self = self, self.MonitorEnabled != Enabled else { return }
      if Enabled {
        guard self.AudioInput != nil else {
          self.OnLog?("未检测到可返听的音频输入")
          return
        }
        self.MonitorEnabled = true
        self.StartMonitor()
        if self.MonitorPlayer == nil {
          self.MonitorEnabled = false
        }
      } else {
        self.MonitorEnabled = false
        self.StopMonitor()
      }
    }
  }

  private func StartMonitor() {
    if let Player = MonitorPlayer {
      Player.play()
      return
    }
    guard let Format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false) else {
      return
    }
    let Engine = AVAudioEngine()
    let Player = AVAudioPlayerNode()
    Engine.attach(Player)
    Engine.connect(Player, to: Engine.mainMixerNode, format: Format)
    Engine.prepare()
    do {
      try Engine.start()
      Player.play()
    } catch {
      OnLog?("声音返听启动失败：\(error.localizedDescription)")
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

  private func PushMonitor(_ Sample: CMSampleBuffer) {
    guard MonitorEnabled, NativeMode, let Player = MonitorPlayer, let Format = MonitorFormat else { return }
    let Frames = CMSampleBufferGetNumSamples(Sample)
    if Frames <= 0 { return }
    let Capacity = AVAudioFrameCount(max(Frames, 1024) * 2)
    guard let Buffer = AVAudioPCMBuffer(pcmFormat: Format, frameCapacity: Capacity) else { return }
    if !CopyMonitor(Sample, To: Buffer, Format: Format) { return }
    Player.scheduleBuffer(Buffer, completionHandler: nil)
  }

  private func CopyMonitor(_ Sample: CMSampleBuffer, To Buffer: AVAudioPCMBuffer, Format: AVAudioFormat) -> Bool {
    guard let Description = CMSampleBufferGetFormatDescription(Sample),
          var Stream = CMAudioFormatDescriptionGetStreamBasicDescription(Description)?.pointee else { return false }
    guard let SourceFormat = AVAudioFormat(streamDescription: &Stream) else { return false }
    let Frames = CMSampleBufferGetNumSamples(Sample)
    if Frames <= 0 { return false }
    guard let Input = AVAudioPCMBuffer(pcmFormat: SourceFormat, frameCapacity: AVAudioFrameCount(Frames)) else { return false }
    Input.frameLength = AVAudioFrameCount(Frames)
    let Copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(Sample, at: 0, frameCount: Int32(Frames), into: Input.mutableAudioBufferList)
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

  private func PushStats() {
    let Now = Date()
    let Span = max(0.001, Now.timeIntervalSince(LastTick))
    let Rate = Double(Frames) / Span
    Frames = 0
    LastTick = Now
    OnStats?([
      "captureFps": Rate,
      "previewFps": Rate,
      "latency": 0,
      "dropped": NativeMode ? (Recorder?.Dropped ?? 0) : 0,
      "written": NativeMode ? (Recorder?.Written ?? 0) : Written,
      "queue": 0,
      "convertMs": 0,
      "fps": Fps,
      "previewWidth": Width,
      "previewHeight": Height,
    ])
  }

  func Register(Textures: FlutterTextureRegistry) {
    Texture.Registry = Textures
    TextureId = Textures.register(Texture)
    Texture.TextureId = TextureId
  }

  func PulseTexture() -> Int64 {
    return TextureId
  }

  func PreviewState() -> [String: Any] {
    return [
      "active": Session.isRunning && Width > 0 && Height > 0,
      "width": Width,
      "height": Height,
      "publish": Written,
    ]
  }
}
