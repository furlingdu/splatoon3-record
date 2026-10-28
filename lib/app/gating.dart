import '../domain/models.dart';

abstract final class SetupGating {
  static bool NSOReady(Iterable<NSOAccount> Accounts) {
    return Accounts.any((Item) => Item.State == 'connected');
  }

  static bool QQReady(String State, bool OwnerBound) {
    return State == 'connected' && OwnerBound;
  }

  static bool ModeReady(List<CaptureMode> Modes, int Width, int Height, int Fps) {
    return Modes.any((Item) => Item.Width == Width && Item.Height == Height && Item.MaxFps == Fps);
  }

  static bool DeviceReady(String DeviceId, List<CaptureMode> Modes, int Width, int Height, int Fps) {
    return DeviceId.isNotEmpty && ModeReady(Modes, Width, Height, Fps);
  }
}
