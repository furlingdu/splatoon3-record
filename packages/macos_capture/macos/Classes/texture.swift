import CoreVideo
import FlutterMacOS

final class MacCaptureTexture: NSObject, FlutterTexture {
  private let Lock = NSLock()
  private var Buffer: CVPixelBuffer?
  var Registry: FlutterTextureRegistry?
  var TextureId: Int64 = -1

  func Submit(_ Value: CVPixelBuffer) {
    Lock.lock()
    Buffer = Value
    Lock.unlock()
    if TextureId >= 0 {
      Registry?.textureFrameAvailable(TextureId)
    }
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    Lock.lock()
    let Value = Buffer
    Lock.unlock()
    if let Value = Value {
      return Unmanaged.passRetained(Value)
    }
    return nil
  }
}
