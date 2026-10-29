import Flutter
import UIKit
import UniformTypeIdentifiers

final class TextDrop: NSObject, UIDropInteractionDelegate {
  init(Messenger: FlutterBinaryMessenger) {
    Channel = FlutterMethodChannel(name: "splatoon3record/text_drop", binaryMessenger: Messenger)
    super.init()
    Channel.setMethodCallHandler(Handle)
  }

  private static let Types: [String] = [UTType.url.identifier, UTType.text.identifier, UTType.plainText.identifier]

  private let Channel: FlutterMethodChannel
  private var Interaction: UIDropInteraction?

  private func Handle(_ Call: FlutterMethodCall, _ Result: @escaping FlutterResult) {
    switch Call.method {
    case "Enable":
      Attach()
      Result(nil)
    case "Disable":
      Detach()
      Result(nil)
    default:
      Result(FlutterMethodNotImplemented)
    }
  }

  private func Attach() {
    DispatchQueue.main.async {
      if self.Interaction != nil { return }
      guard let View = TextDrop.RootView() else { return }
      let Interaction = UIDropInteraction(delegate: self)
      View.addInteraction(Interaction)
      self.Interaction = Interaction
    }
  }

  private func Detach() {
    DispatchQueue.main.async {
      guard let Interaction = self.Interaction else { return }
      Interaction.view?.removeInteraction(Interaction)
      self.Interaction = nil
    }
  }

  private static func RootView() -> UIView? {
    let Scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for Scene in Scenes {
      for Window in Scene.windows where Window.isKeyWindow {
        return Window.rootViewController?.view ?? Window
      }
    }
    for Scene in Scenes {
      if let Window = Scene.windows.first {
        return Window.rootViewController?.view ?? Window
      }
    }
    return nil
  }

  private func Report(_ Value: Bool) {
    Channel.invokeMethod("Active", arguments: Value)
  }

  private static func Read(_ Value: NSSecureCoding?) -> String? {
    var Text = ""
    if let Url = Value as? NSURL {
      Text = Url.absoluteString ?? ""
    } else if let StringValue = Value as? NSString {
      Text = StringValue as String
    } else if let Attributed = Value as? NSAttributedString {
      Text = Attributed.string
    } else if let DataValue = Value as? NSData, let Decoded = String(data: DataValue as Data, encoding: .utf8) {
      Text = Decoded
    }
    let Trimmed = Text.trimmingCharacters(in: .whitespacesAndNewlines)
    return Trimmed.isEmpty ? nil : Trimmed
  }

  func dropInteraction(_ Interaction: UIDropInteraction, canHandle Session: UIDropSession) -> Bool {
    return Session.hasItemsConforming(toTypeIdentifiers: TextDrop.Types)
  }

  func dropInteraction(_ Interaction: UIDropInteraction, sessionDidEnter Session: UIDropSession) {
    Report(true)
  }

  func dropInteraction(_ Interaction: UIDropInteraction, sessionDidExit Session: UIDropSession) {
    Report(false)
  }

  func dropInteraction(_ Interaction: UIDropInteraction, sessionDidEnd Session: UIDropSession) {
    Report(false)
  }

  func dropInteraction(_ Interaction: UIDropInteraction, sessionDidUpdate Session: UIDropSession) -> UIDropProposal {
    return UIDropProposal(operation: .copy)
  }

  func dropInteraction(_ Interaction: UIDropInteraction, performDrop Session: UIDropSession) {
    Report(false)
    guard let Item = Session.items.first else { return }
    Load(Item.itemProvider)
  }

  private func Load(_ Provider: NSItemProvider) {
    for Type in TextDrop.Types where Provider.hasItemConformingToTypeIdentifier(Type) {
      _ = Provider.loadItem(forTypeIdentifier: Type, options: nil) { Value, _ in
        guard let Text = TextDrop.Read(Value) else { return }
        DispatchQueue.main.async {
          self.Channel.invokeMethod("Drop", arguments: Text)
        }
      }
      return
    }
  }
}
