import FlutterMacOS
import Foundation

public final class MacCapturePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let Host = MacCaptureHost()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let Instance = MacCapturePlugin()
    Instance.Host.Register(Textures: registrar.textures)
    let Channel = FlutterMethodChannel(name: "splatoon3record/capture", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(Instance, channel: Channel)
    let Events = FlutterEventChannel(name: "splatoon3record/capture/events", binaryMessenger: registrar.messenger)
    Events.setStreamHandler(Instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let Arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "Enumerate":
      result(Host.Enumerate())
    case "Modes":
      result(Host.Modes(Arguments["device"] as? String ?? ""))
    case "Prepare":
      let Device = Arguments["device"] as? String ?? ""
      let Width = Arguments["width"] as? Int ?? 1920
      let Height = Arguments["height"] as? Int ?? 1080
      let Fps = Arguments["fps"] as? Int ?? 30
      let AudioDevice = Arguments["audioDevice"] as? String ?? ""
      let AudioFifo = Arguments["audioFifo"] as? String ?? ""
      DispatchQueue.global(qos: .userInitiated).async {
        self.Host.Prepare(DeviceId: Device, Width: Width, Height: Height, Fps: Fps, AudioDeviceId: AudioDevice, AudioFifoPath: AudioFifo) { Info, Error in
          DispatchQueue.main.async {
            if let Error = Error {
              result(FlutterError(code: "capture", message: Error, details: nil))
              return
            }
            result(Info)
          }
        }
      }
    case "StartNative":
      let Directory = Arguments["directory"] as? String ?? ""
      let Quality = Arguments["quality"] as? Int ?? 28
      let SegmentSeconds = Arguments["segmentSeconds"] as? Int ?? 600
      let Audio = Arguments["audio"] as? Bool ?? false
      let Monitor = Arguments["monitor"] as? Bool ?? false
      DispatchQueue.global(qos: .userInitiated).async {
        self.Host.StartNative(Directory: Directory, Quality: Quality, SegmentSeconds: SegmentSeconds, Audio: Audio, Monitor: Monitor) { Error in
          DispatchQueue.main.async {
            if let Error = Error {
              result(FlutterError(code: "capture", message: Error, details: nil))
              return
            }
            result(nil)
          }
        }
      }
    case "Start":
      let Exe = Arguments["exe"] as? String ?? ""
      let Args = Arguments["args"] as? [String] ?? []
      DispatchQueue.global(qos: .userInitiated).async {
        self.Host.Start(Exe: Exe, Args: Args) { Error in
          DispatchQueue.main.async {
            if let Error = Error {
              result(FlutterError(code: "capture", message: Error, details: nil))
              return
            }
            result(nil)
          }
        }
      }
    case "Monitor":
      let Enabled = Arguments["enabled"] as? Bool ?? false
      Host.Monitor(Enabled)
      result(nil)
    case "Stop":
      let Fast = Arguments["fast"] as? Bool ?? false
      DispatchQueue.global(qos: .userInitiated).async {
        self.Host.Stop(Fast: Fast) {
          DispatchQueue.main.async { result(nil) }
        }
      }
    case "PreviewTexture":
      result(Int(Host.PulseTexture()))
    case "PreviewState":
      result(Host.PreviewState())
    case "Snapshot":
      result(nil)
    case "Vision":
      Host.SetVision(Arguments["enabled"] as? Bool ?? false)
      result(nil)
    case "VisionSnapshot":
      result(Host.VisionSnapshot())
    case "Mask":
      result(nil)
    case "OpenMaskPipe":
      result(nil)
    case "CloseMaskPipe":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    Host.OnState = { Value in
      DispatchQueue.main.async {
        events(["type": "state", "value": Value])
      }
    }
    Host.OnStats = { Value in
      DispatchQueue.main.async {
        var Data = Value
        Data["type"] = "stats"
        events(Data)
      }
    }
    Host.OnError = { Text in
      DispatchQueue.main.async {
        events(["type": "error", "text": Text])
      }
    }
    Host.OnLog = { Text in
      DispatchQueue.main.async {
        events(["type": "log", "text": Text])
      }
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    Host.OnState = nil
    Host.OnStats = nil
    Host.OnError = nil
    Host.OnLog = nil
    return nil
  }
}
