import '../../../domain/models.dart';

abstract final class MobileModes {
  static const List<String> FormatOrder = <String>['mjpeg', 'h264', 'yuy2'];

  static int FormatRank(String Format) {
    final Index = FormatOrder.indexOf(Format.toLowerCase());
    return Index < 0 ? FormatOrder.length : Index;
  }

  static int Area(CaptureMode Item) => Item.Width * Item.Height;

  static List<String> Resolutions(List<CaptureMode> Items) {
    final Values = <String>{};
    for (final Item in Items) {
      if (Item.Width <= 0 || Item.Height <= 0) continue;
      Values.add('${Item.Width}x${Item.Height}');
    }
    final Result = Values.toList();
    Result.sort((Left, Right) {
      final LeftParts = Left.split('x').map(int.tryParse).whereType<int>().toList();
      final RightParts = Right.split('x').map(int.tryParse).whereType<int>().toList();
      final LeftArea = LeftParts.length == 2 ? LeftParts[0] * LeftParts[1] : 0;
      final RightArea = RightParts.length == 2 ? RightParts[0] * RightParts[1] : 0;
      return RightArea.compareTo(LeftArea);
    });
    return Result;
  }

  static List<int> FpsList(List<CaptureMode> Items, int Width, int Height) {
    final Values = <int>{};
    for (final Item in Items) {
      if (Item.Width != Width || Item.Height != Height || Item.MaxFps <= 0) continue;
      Values.add(Item.MaxFps);
    }
    final Result = Values.toList();
    Result.sort((Left, Right) => Right.compareTo(Left));
    return Result;
  }

  static bool Contains(List<CaptureMode> Items, int Width, int Height, int Fps) {
    return Items.any((Item) => Item.Width == Width && Item.Height == Height && Item.MaxFps == Fps);
  }

  static CaptureMode? Pick(List<CaptureMode> Items, int Width, int Height, int Fps) {
    final ExactSize = Items.where((Item) => Item.Width == Width && Item.Height == Height).toList();
    if (ExactSize.isEmpty) return null;
    final ExactFps = ExactSize.where((Item) => Item.MaxFps == Fps).toList();
    final Pool = ExactFps.isNotEmpty ? ExactFps : ExactSize;
    Pool.sort((Left, Right) {
      final LeftGap = (Left.MaxFps - Fps).abs();
      final RightGap = (Right.MaxFps - Fps).abs();
      if (LeftGap != RightGap) return LeftGap.compareTo(RightGap);
      if (Left.MaxFps != Right.MaxFps) return Right.MaxFps.compareTo(Left.MaxFps);
      return FormatRank(Left.Format).compareTo(FormatRank(Right.Format));
    });
    return Pool.first;
  }

  static CaptureMode? Best(List<CaptureMode> Items, {int PreferredWidth = 1920, int PreferredHeight = 1080, int PreferredFps = 60}) {
    final Valid = Items.where((Item) => Item.Width > 0 && Item.Height > 0 && Item.MaxFps > 0).toList();
    if (Valid.isEmpty) return null;
    final PreferredArea = PreferredWidth * PreferredHeight;
    final Smaller = Valid.where((Item) => Area(Item) <= PreferredArea).toList();
    final Pool = Smaller.isNotEmpty ? Smaller : Valid;
    var MaxArea = 0;
    for (final Item in Pool) {
      if (Area(Item) > MaxArea) MaxArea = Area(Item);
    }
    final ResolutionPool = Pool.where((Item) => Area(Item) == MaxArea).toList();
    final Within = ResolutionPool.where((Item) => Item.MaxFps <= PreferredFps).toList();
    final Candidate = Within.isNotEmpty ? Within : ResolutionPool;
    Candidate.sort((Left, Right) {
      if (Left.MaxFps != Right.MaxFps) return Right.MaxFps.compareTo(Left.MaxFps);
      return FormatRank(Left.Format).compareTo(FormatRank(Right.Format));
    });
    return Candidate.first;
  }
}
