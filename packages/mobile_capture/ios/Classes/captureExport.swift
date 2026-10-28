import AVFoundation

final class CaptureExport {
  static func Run(Input: String, Output: String, Completion: @escaping (Bool) -> Void) {
    let Source = URL(fileURLWithPath: Input)
    let Target = URL(fileURLWithPath: Output)
    if Source.standardizedFileURL == Target.standardizedFileURL {
      Completion(FileManager.default.fileExists(atPath: Output))
      return
    }
    try? FileManager.default.removeItem(at: Target)
    if Source.pathExtension.lowercased() == "mp4" {
      do {
        try FileManager.default.copyItem(at: Source, to: Target)
        Completion(true)
      } catch {
        Completion(false)
      }
      return
    }
    let Asset = AVAsset(url: Source)
    guard let Session = AVAssetExportSession(asset: Asset, presetName: AVAssetExportPresetPassthrough) else {
      Completion(false)
      return
    }
    Session.outputURL = Target
    Session.outputFileType = .mp4
    Session.shouldOptimizeForNetworkUse = true
    Session.exportAsynchronously {
      DispatchQueue.main.async {
        Completion(Session.status == .completed)
      }
    }
  }
}
