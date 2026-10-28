import Foundation
import Photos

final class MediaSave {
  static func Run(Path: String, Completion: @escaping (Bool) -> Void) {
    guard FileManager.default.fileExists(atPath: Path) else {
      Completion(false)
      return
    }
    let Status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    if Status == .authorized || Status == .limited {
      Perform(Path: Path, Completion: Completion)
      return
    }
    if Status == .notDetermined {
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { Granted in
        if Granted == .authorized || Granted == .limited {
          Perform(Path: Path, Completion: Completion)
        } else {
          DispatchQueue.main.async { Completion(false) }
        }
      }
      return
    }
    Completion(false)
  }

  private static func Perform(Path: String, Completion: @escaping (Bool) -> Void) {
    let Url = URL(fileURLWithPath: Path)
    PHPhotoLibrary.shared().performChanges({
      PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: Url)
    }) { Ok, _ in
      DispatchQueue.main.async { Completion(Ok) }
    }
  }
}
