import Flutter
import UIKit
import UniformTypeIdentifiers

final class TextDrop: NSObject, UIDropInteractionDelegate {
  init(Messenger: FlutterBinaryMessenger) {
    Channel = FlutterMethodChannel(name: "splatoon3record/text_drop", binaryMessenger: Messenger)
    super.init()
    Channel.setMethodCallHandler(Handle)
  }

  private static let Types: [String] = [
    UTType.url.identifier,
    UTType.text.identifier,
    UTType.utf8PlainText.identifier,
    UTType.plainText.identifier,
  ]

  private let Channel: FlutterMethodChannel
  private var Interaction: UIDropInteraction?
  // The login panel exists both inline (setup page) and inside a dialog. Each
  // panel enables the drop on start and disables it on dispose; without the
  // count, closing either one removed the interaction for everybody else.
  private var Owners = 0
  private var AttachAttempts = 0

  var Log: ((String) -> Void)?

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
      self.Owners += 1
      self.Install()
    }
  }

  private func Install() {
    if let Interaction = Interaction, let View = Interaction.view, View.window != nil { return }
    guard let View = TextDrop.DropView() else {
      // The window can briefly be unavailable while Flutter is swapping scenes.
      AttachAttempts += 1
      if AttachAttempts <= 10 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.Install() }
      } else {
        Log?("拖入：没有可挂接的窗口")
      }
      return
    }
    AttachAttempts = 0
    if let Old = Interaction {
      Old.view?.removeInteraction(Old)
    }
    let Interaction = UIDropInteraction(delegate: self)
    View.addInteraction(Interaction)
    self.Interaction = Interaction
    Log?("拖入已启用 view=\(type(of: View))")
  }

  private func Detach() {
    DispatchQueue.main.async {
      self.Owners = max(0, self.Owners - 1)
      if self.Owners > 0 { return }
      guard let Interaction = self.Interaction else { return }
      Interaction.view?.removeInteraction(Interaction)
      self.Interaction = nil
    }
  }

  private static func DropView() -> UIView? {
    let Scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for Scene in Scenes {
      if let Window = Scene.windows.first(where: { $0.isKeyWindow }) ?? Scene.windows.first {
        // Attach to the window so drops anywhere in the app, including over the
        // Flutter text field, reach the delegate.
        return Window
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
    let Ok = Session.hasItemsConforming(toTypeIdentifiers: TextDrop.Types)
    if Ok { Log?("拖入进入范围") }
    return Ok
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
    guard let Item = Session.items.first else {
      Log?("拖入没有内容")
      return
    }
    Log?("收到拖入内容")
    Load(Item.itemProvider, Index: 0)
  }

  private func Load(_ Provider: NSItemProvider, Index: Int) {
    guard Index < TextDrop.Types.count else {
      Log?("拖入内容无法解析")
      return
    }
    let Type = TextDrop.Types[Index]
    guard Provider.hasItemConformingToTypeIdentifier(Type) else {
      Load(Provider, Index: Index + 1)
      return
    }
    Provider.loadItem(forTypeIdentifier: Type, options: nil) { Value, Error in
      if let Text = TextDrop.Read(Value) {
        DispatchQueue.main.async {
          self.Log?("拖入文本 \(Text.count) 字")
          self.Channel.invokeMethod("Drop", arguments: Text)
        }
        return
      }
      DispatchQueue.main.async {
        if let Error = Error { self.Log?("拖入读取失败：\(Error.localizedDescription)") }
        self.Load(Provider, Index: Index + 1)
      }
    }
  }
}
