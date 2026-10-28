import Flutter
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

final class MobilePicker: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
  private var PickCompletion: ((String?) -> Void)?
  private var SaveCompletion: ((Bool) -> Void)?
  private var SavePicker: UIDocumentPickerViewController?

  func Pick(Completion: @escaping (String?) -> Void) {
    guard PickCompletion == nil, SaveCompletion == nil, let Controller = MobilePicker.Top() else {
      Completion(nil)
      return
    }
    PickCompletion = Completion
    var Config = PHPickerConfiguration(photoLibrary: PHPhotoLibrary.shared())
    Config.filter = .images
    Config.selectionLimit = 1
    Config.preferredAssetRepresentationMode = .current
    let Picker = PHPickerViewController(configuration: Config)
    Picker.delegate = self
    Controller.present(Picker, animated: true)
  }

  func Save(Path: String, Completion: @escaping (Bool) -> Void) {
    guard PickCompletion == nil, SaveCompletion == nil,
      FileManager.default.fileExists(atPath: Path), let Controller = MobilePicker.Top()
    else {
      Completion(false)
      return
    }
    SaveCompletion = Completion
    let Picker = UIDocumentPickerViewController(
      forExporting: [URL(fileURLWithPath: Path)], asCopy: true)
    SavePicker = Picker
    Picker.delegate = self
    Controller.present(Picker, animated: true)
  }

  func picker(_ Picker: PHPickerViewController, didFinishPicking Results: [PHPickerResult]) {
    Picker.dismiss(animated: true)
    guard let Provider = Results.first?.itemProvider else {
      FinishPick(nil)
      return
    }
    let Type = Provider.registeredTypeIdentifiers.first {
      UTType($0)?.conforms(to: .image) == true
    } ?? UTType.image.identifier
    guard Provider.hasItemConformingToTypeIdentifier(Type) else {
      FinishPick(nil)
      return
    }
    Provider.loadFileRepresentation(forTypeIdentifier: Type) { Url, _ in
      guard let Url = Url else {
        self.FinishPick(nil)
        return
      }
      let Ext = Url.pathExtension.isEmpty ? "jpg" : Url.pathExtension
      let Target = FileManager.default.temporaryDirectory.appendingPathComponent(
        "background-\(UUID().uuidString).\(Ext)")
      do {
        try FileManager.default.copyItem(at: Url, to: Target)
        self.FinishPick(Target.path)
      } catch {
        self.FinishPick(nil)
      }
    }
  }

  func documentPicker(
    _ Controller: UIDocumentPickerViewController, didPickDocumentsAt Urls: [URL]
  ) {
    FinishSave(true)
  }

  func documentPickerWasCancelled(_ Controller: UIDocumentPickerViewController) {
    FinishSave(false)
  }

  private func FinishPick(_ Path: String?) {
    DispatchQueue.main.async {
      let Completion = self.PickCompletion
      self.PickCompletion = nil
      Completion?(Path)
    }
  }

  private func FinishSave(_ Ok: Bool) {
    DispatchQueue.main.async {
      let Completion = self.SaveCompletion
      self.SaveCompletion = nil
      self.SavePicker = nil
      Completion?(Ok)
    }
  }

  private static func Top() -> UIViewController? {
    let Scene = UIApplication.shared.connectedScenes.first {
      $0.activationState == .foregroundActive
    } as? UIWindowScene
    let Windows = Scene?.windows ?? []
    guard let Window = Windows.first(where: { $0.isKeyWindow }) ?? Windows.first else {
      return nil
    }
    var Controller = Window.rootViewController
    while let Presented = Controller?.presentedViewController {
      Controller = Presented
    }
    return Controller
  }
}
