import AVFoundation
import Flutter

@objc public class MobileCapturePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let Capture = MobileCaptureSession()
  private var Sink: FlutterEventSink?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let Instance = MobileCapturePlugin()
    let Channel = FlutterMethodChannel(name: "splatoon3record/mobile_capture", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(Instance, channel: Channel)
    let Events = FlutterEventChannel(name: "splatoon3record/mobile_capture/events", binaryMessenger: registrar.messenger())
    Events.setStreamHandler(Instance)
    registrar.register(MobileCapturePreviewFactory(Capture: Instance.Capture), withId: "splatoon3record/capture_preview")
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
        AudioDeviceId: Arguments["audioDevice"] as? String ?? ""
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
      MobileCaptureExport.Run(
        Input: Arguments["input"] as? String ?? "",
        Output: Arguments["output"] as? String ?? ""
      ) { Ok in
        result(Ok)
      }
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

final class MobileCapturePreviewFactory: NSObject, FlutterPlatformViewFactory {
  init(Capture: MobileCaptureSession) {
    self.Capture = Capture
    super.init()
  }

  let Capture: MobileCaptureSession

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    return MobileCapturePreviewView(Frame: frame, Capture: Capture)
  }
}

final class MobileCapturePreviewView: NSObject, FlutterPlatformView {
  init(Frame: CGRect, Capture: MobileCaptureSession) {
    Container = MobileCapturePreviewContainer(Frame: Frame, Session: Capture.Session)
    super.init()
  }

  private let Container: MobileCapturePreviewContainer

  func view() -> UIView {
    return Container
  }
}

final class MobileCapturePreviewContainer: UIView {
  init(Frame: CGRect, Session: AVCaptureSession) {
    super.init(frame: Frame)
    backgroundColor = .black
    Preview.session = Session
    Preview.videoGravity = .resizeAspect
    layer.addSublayer(Preview)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  private let Preview = AVCaptureVideoPreviewLayer()

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    Preview.frame = bounds
    if let Connection = Preview.connection {
      Connection.automaticallyAdjustsVideoMirroring = false
      if Connection.isVideoMirroringSupported {
        Connection.isVideoMirrored = false
      }
    }
    CATransaction.commit()
  }
}
