import AVFoundation
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
  private let Context = CIContext(options: nil)
  private let Texture = MacCaptureTexture()
  private var VideoInput: AVCaptureDeviceInput?
  private var AudioInput: AVCaptureDeviceInput?
  private var Stdin: FileHandle?
  private var AudioFile: FileHandle?
  private var ProcessRef: Process?
  private var Pool: CVPixelBufferPool?
  private var StatsTimer: Timer?
  private var Width = 0
  private var Height = 0
  private var Fps = 0
  private var Frames = 0
  private var Written = 0
  private var LastTick = Date()
  private var LastPreview = 0.0
  private var Prepared = false
  private var Stopping = false
  private var AudioFifo = ""

  var TextureId: Int64 = -1
  var OnState: ((String) -> Void)?
  var OnStats: (([String: Any]) -> Void)?
  var OnError: ((String) -> Void)?

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
    if let AudioDevice = FindAudio(AudioDeviceId), !AudioFifoPath.isEmpty {
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
          unlink(AudioFifoPath)
          if mkfifo(AudioFifoPath, 0o666) == 0 {
            AudioFifo = AudioFifoPath
          }
        }
      } catch {
      }
    } else if let Old = AudioInput {
      Session.removeInput(Old)
      AudioInput = nil
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

  func Start(Exe: String, Args: [String], Completion: @escaping (String?) -> Void) {
    guard Prepared else {
      Completion("采集设备未准备")
      return
    }
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
    LastPreview = 0
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
    if Session.isRunning { Session.stopRunning() }
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
    if Session.isRunning { Session.stopRunning() }
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
      WriteAudio(sampleBuffer)
      return
    }
    guard let Pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    Frames += 1
    Write(Pixel)
    Preview(Pixel)
  }

  private func WriteAudio(_ Sample: CMSampleBuffer) {
    guard let File = AudioFile else { return }
    var List = AudioBufferList()
    var Block: CMBlockBuffer?
    let Status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      Sample,
      bufferListSizeNeededOut: nil,
      bufferListOut: &List,
      bufferListSize: MemoryLayout<AudioBufferList>.size,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
      blockBufferOut: &Block)
    if Status != noErr { return }
    let Buffers = UnsafeMutableAudioBufferListPointer(&List)
    if Buffers.count == 1 {
      guard let DataPtr = Buffers[0].mData else { return }
      let Size = Int(Buffers[0].mDataByteSize)
      if Size <= 0 { return }
      try? File.write(contentsOf: Data(bytes: DataPtr, count: Size))
      return
    }
    if Buffers.count >= 2 {
      guard let LeftPtr = Buffers[0].mData, let RightPtr = Buffers[1].mData else { return }
      let Frames = Int(min(Buffers[0].mDataByteSize, Buffers[1].mDataByteSize)) / 2
      if Frames <= 0 { return }
      let Left = LeftPtr.assumingMemoryBound(to: Int16.self)
      let Right = RightPtr.assumingMemoryBound(to: Int16.self)
      var Scratch = [Int16](repeating: 0, count: Frames * 2)
      for Index in 0..<Frames {
        Scratch[Index * 2] = Left[Index]
        Scratch[Index * 2 + 1] = Right[Index]
      }
      Scratch.withUnsafeBufferPointer { Pointer in
        if let Base = Pointer.baseAddress {
          try? File.write(contentsOf: Data(bytes: Base, count: Frames * 4))
        }
      }
    }
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
    let Now = Date().timeIntervalSince1970
    if Now - LastPreview < 1.0 / 30.0 { return }
    LastPreview = Now
    guard let Pool = EnsurePool() else { return }
    var Destination: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, Pool, &Destination) == kCVReturnSuccess, let Destination = Destination else { return }
    let Image = CIImage(cvPixelBuffer: Pixel)
    Context.render(Image, to: Destination)
    Texture.Submit(Destination)
  }

  private func PushStats() {
    let Now = Date()
    let Span = max(0.001, Now.timeIntervalSince(LastTick))
    let Rate = Double(Frames) / Span
    Frames = 0
    LastTick = Now
    OnStats?([
      "captureFps": Rate,
      "previewFps": min(Rate, 30),
      "latency": 0,
      "dropped": 0,
      "written": Written,
      "queue": 0,
      "convertMs": 0,
      "fps": Fps,
    ])
  }

  func Register(Textures: FlutterTextureRegistry) {
    TextureId = Textures.register(Texture)
  }

  func PulseTexture() -> Int64 {
    return TextureId
  }
}
