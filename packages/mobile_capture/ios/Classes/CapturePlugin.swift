import AVFoundation
import Flutter

@objc public class MobileCapturePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let Capture = CaptureSession()
  private var Sink: FlutterEventSink?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let Instance = MobileCapturePlugin()
    let Channel = FlutterMethodChannel(name: "splatoon3record/mobile_capture", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(Instance, channel: Channel)
    let Events = FlutterEventChannel(name: "splatoon3record/mobile_capture/events", binaryMessenger: registrar.messenger())
    Events.setStreamHandler(Instance)
    let Media = FlutterMethodChannel(name: "splatoon3record/mobile_media", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(Instance, channel: Media)
    registrar.register(CapturePreviewFactory(Capture: Instance.Capture), withId: "splatoon3record/capture_preview")
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let Arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "Enumerate":
      result(Capture.Enumerate())
    case "Modes":
      result(Capture.Modes(Arguments["device"] as? String ?? ""))
    case "EnumerateAudio":
      result(Capture.AudioDevices())
    case "Prepare":
      Capture.Configure(
        DeviceId: Arguments["device"] as? String ?? "",
        Width: Arguments["width"] as? Int ?? 1920,
        Height: Arguments["height"] as? Int ?? 1080,
        Fps: Arguments["fps"] as? Int ?? 30,
        Audio: Arguments["audio"] as? Bool ?? false,
        AudioDeviceId: Arguments["audioDevice"] as? String ?? "",
        Orientation: Arguments["orientation"] as? String ?? "auto"
      ) { Mode, Error in
        if let Error = Error {
          result(FlutterError(code: "capture", message: Error, details: nil))
          return
        }
        result([
          "width": Mode?.Width ?? 0,
          "height": Mode?.Height ?? 0,
          "fps": Mode?.Fps ?? 0,
        ])
      }
    case "Start":
      Capture.StartRecording(Arguments["path"] as? String ?? "") { Error in
        if let Error = Error {
          result(FlutterError(code: "capture", message: Error, details: nil))
          return
        }
        result(nil)
      }
    case "Stop":
      Capture.StopRecording { Path in
        result(Path)
      }
    case "Dispose":
      Capture.Dispose()
      result(nil)
    case "Export":
      CaptureExport.Run(
        Input: Arguments["input"] as? String ?? "",
        Output: Arguments["output"] as? String ?? ""
      ) { Ok in
        result(Ok)
      }
    case "SaveVideo":
      MediaSave.Run(Path: Arguments["path"] as? String ?? "") { Ok in
        result(Ok)
      }
    case "SetMonitor":
      Capture.SetMonitor(Arguments["enabled"] as? Bool ?? false)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    Sink = events
    Capture.OnState = { Value in
      DispatchQueue.main.async {
        events(["type": "state", "value": Value])
      }
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    Sink = nil
    Capture.OnState = nil
    return nil
  }
}

final class CapturePreviewFactory: NSObject, FlutterPlatformViewFactory {
  init(Capture: CaptureSession) {
    self.Capture = Capture
    super.init()
  }

  let Capture: CaptureSession

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    return CapturePreviewView(Frame: frame, Capture: Capture)
  }
}

final class CapturePreviewView: NSObject, FlutterPlatformView {
  init(Frame: CGRect, Capture: CaptureSession) {
    Container = CapturePreviewContainer(Frame: Frame, Capture: Capture)
    super.init()
  }

  private let Container: CapturePreviewContainer

  func view() -> UIView {
    return Container
  }
}

final class CapturePreviewContainer: UIView {
  init(Frame: CGRect, Capture: CaptureSession) {
    self.Capture = Capture
    super.init(frame: Frame)
    backgroundColor = .black
    Preview.session = Capture.Session
    Preview.videoGravity = .resizeAspect
    layer.addSublayer(Preview)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  private let Capture: CaptureSession
  private let Preview = AVCaptureVideoPreviewLayer()

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    Preview.session = Capture.Session
    if Preview.superlayer !== layer {
      Preview.removeFromSuperlayer()
      layer.addSublayer(Preview)
    }
    Preview.frame = bounds
    if let Connection = Preview.connection {
      if #available(iOS 17.0, *) {
        if Connection.isVideoRotationAngleSupported(Capture.VideoRotationAngle) {
          Connection.videoRotationAngle = Capture.VideoRotationAngle
        }
      }
      Connection.automaticallyAdjustsVideoMirroring = false
      if Connection.isVideoMirroringSupported {
        Connection.isVideoMirrored = false
      }
      Connection.isEnabled = true
    }
    CATransaction.commit()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      Preview.session = Capture.Session
      setNeedsLayout()
    }
  }
}
