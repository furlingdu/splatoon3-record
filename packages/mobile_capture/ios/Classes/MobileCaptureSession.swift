import AVFoundation
import Flutter

struct MobileCaptureModeInfo {
  let Width: Int
  let Height: Int
  let Fps: Int
}

final class MobileCaptureSession: NSObject, AVCaptureFileOutputRecordingDelegate {
  let Session = AVCaptureSession()

  private let Output = AVCaptureMovieFileOutput()
  private let CaptureQueue = DispatchQueue(label: "splatoon3record.mobile_capture")
  private var VideoInput: AVCaptureDeviceInput?
  private var AudioInput: AVCaptureDeviceInput?
  private var Pending: ((String?) -> Void)?
  private var Prepared = false

  var OnState: ((String) -> Void)?

  private var DeviceTypes: [AVCaptureDevice.DeviceType] {
    var Types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera]
    if #available(iOS 17.0, *) {
      Types.append(.external)
    }
    return Types
  }

  private func Find(_ DeviceId: String) -> AVCaptureDevice? {
    let Devices = AVCaptureDevice.DiscoverySession(deviceTypes: DeviceTypes, mediaType: .video, position: .unspecified).devices
    if let Exact = Devices.first(where: { $0.uniqueID == DeviceId }) { return Exact }
    return nil
  }

  private var AudioTypes: [AVCaptureDevice.DeviceType] {
    if #available(iOS 17.0, *) {
      return [.microphone, .external]
    }
    return [.builtInMicrophone]
  }

  private func AudioDevicesList() -> [AVCaptureDevice] {
    var Devices = AVCaptureDevice.DiscoverySession(deviceTypes: AudioTypes, mediaType: .audio, position: .unspecified).devices
    for Device in AVCaptureDevice.devices(for: .audio) where !Devices.contains(where: { $0.uniqueID == Device.uniqueID }) {
      Devices.append(Device)
    }
    return Devices
  }

  private func FindAudio(_ DeviceId: String) -> AVCaptureDevice? {
    guard !DeviceId.isEmpty else { return AVCaptureDevice.default(for: .audio) }
    return AudioDevicesList().first(where: { $0.uniqueID == DeviceId }) ?? AVCaptureDevice.default(for: .audio)
  }

  func AudioDevices() -> [[String: Any]] {
    return AudioDevicesList().map { Device in
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

  func Configure(DeviceId: String, Width: Int, Height: Int, Fps: Int, Audio: Bool, AudioDeviceId: String, Completion: @escaping (MobileCaptureModeInfo?, String?) -> Void) {
    RequestAccess(Video: true) { VideoOk in
      guard VideoOk else {
        Completion(nil, "相机权限被拒绝")
        return
      }
      if Audio {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
          self.ConfigureNow(DeviceId: DeviceId, Width: Width, Height: Height, Fps: Fps, Audio: Audio, AudioDeviceId: AudioDeviceId, Completion: Completion)
        }
      } else {
        self.ConfigureNow(DeviceId: DeviceId, Width: Width, Height: Height, Fps: Fps, Audio: false, AudioDeviceId: "", Completion: Completion)
      }
    }
  }

  private func RequestAccess(Video: Bool, Completion: @escaping (Bool) -> Void) {
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

  private func ConfigureNow(DeviceId: String, Width: Int, Height: Int, Fps: Int, Audio: Bool, AudioDeviceId: String, Completion: @escaping (MobileCaptureModeInfo?, String?) -> Void) {
    CaptureQueue.async {
      guard let Device = self.Find(DeviceId) else {
        DispatchQueue.main.async { Completion(nil, "未找到采集设备") }
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
        if let Format = Self.PickFormat(Device, Width: Width, Height: Height) {
          Device.activeFormat = Format
        }
        if let Range = Device.activeFormat.videoSupportedFrameRateRanges.first {
          UseFps = min(UseFps, max(1, Int(Range.maxFrameRate.rounded())))
        }
        let Duration = CMTime(value: 1, timescale: CMTimeScale(UseFps))
        Device.activeVideoMinFrameDuration = Duration
        Device.activeVideoMaxFrameDuration = Duration
        Device.unlockForConfiguration()
      } catch {
      }
      if Audio {
        if let AudioDevice = FindAudio(AudioDeviceId) {
          if let Old = self.AudioInput { self.Session.removeInput(Old) }
          if let Input = try? AVCaptureDeviceInput(device: AudioDevice), self.Session.canAddInput(Input) {
            self.Session.addInput(Input)
            self.AudioInput = Input
          }
        }
      } else if let Old = self.AudioInput {
        self.Session.removeInput(Old)
        self.AudioInput = nil
      }
      if !self.Session.outputs.contains(self.Output) {
        if self.Session.canAddOutput(self.Output) { self.Session.addOutput(self.Output) }
      }
      self.Session.commitConfiguration()
      self.Prepared = true
      self.Session.startRunning()
      let Size = CMVideoFormatDescriptionGetDimensions(Device.activeFormat.formatDescription)
      let Mode = MobileCaptureModeInfo(Width: Int(Size.width), Height: Int(Size.height), Fps: UseFps)
      DispatchQueue.main.async { Completion(Mode, nil) }
    }
  }

  private static func PickFormat(_ Device: AVCaptureDevice, Width: Int, Height: Int) -> AVCaptureDevice.Format? {
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
