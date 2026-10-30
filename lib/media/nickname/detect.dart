import 'dart:typed_data';

class DetectedBox {
  const DetectedBox({required this.Label, required this.Confidence, required this.Left, required this.Top, required this.Right, required this.Bottom});

  final int Label;
  final double Confidence;
  final double Left;
  final double Top;
  final double Right;
  final double Bottom;

  double get Width => Right - Left;
  double get Height => Bottom - Top;

  Map<String, dynamic> ToMap() => <String, dynamic>{
        'label': Label,
        'conf': Confidence,
        'left': Left,
        'top': Top,
        'right': Right,
        'bottom': Bottom,
      };
}

class Letterbox {
  const Letterbox({required this.Blob, required this.Scale, required this.PadX, required this.PadY});

  final Float32List Blob;
  final double Scale;
  final double PadX;
  final double PadY;
}

Letterbox BuildLetterbox(Uint8List Rgba, int Width, int Height, int Size) {
  final ScaleValue = Size / Width < Size / Height ? Size / Width : Size / Height;
  final InnerWidth = (Width * ScaleValue).round().clamp(1, Size);
  final InnerHeight = (Height * ScaleValue).round().clamp(1, Size);
  final PadX = (Size - InnerWidth) ~/ 2;
  final PadY = (Size - InnerHeight) ~/ 2;
  final Area = Size * Size;
  final Blob = Float32List(3 * Area)..fillRange(0, 3 * Area, 114 / 255);
  for (var Y = 0; Y < InnerHeight; Y++) {
    final SourceY = (Y / ScaleValue).floor().clamp(0, Height - 1);
    final SourceRow = SourceY * Width;
    final TargetRow = (PadY + Y) * Size + PadX;
    for (var X = 0; X < InnerWidth; X++) {
      final SourceX = (X / ScaleValue).floor().clamp(0, Width - 1);
      final Source = (SourceRow + SourceX) * 4;
      final Target = TargetRow + X;
      Blob[Target] = Rgba[Source] / 255;
      Blob[Area + Target] = Rgba[Source + 1] / 255;
      Blob[2 * Area + Target] = Rgba[Source + 2] / 255;
    }
  }
  return Letterbox(Blob: Blob, Scale: ScaleValue, PadX: PadX.toDouble(), PadY: PadY.toDouble());
}

List<List<dynamic>> DetectionRows(dynamic Output) {
  if (Output is! List || Output.isEmpty) return <List<dynamic>>[];
  final First = Output.first;
  if (First is List && First.isNotEmpty) {
    final Inner = First.first;
    if (Inner is List) {
      return First.whereType<List>().toList();
    }
    if (Inner is num) {
      return Output.whereType<List>().toList();
    }
  }
  if (First is num && Output.length % 6 == 0) {
    final Rows = <List<dynamic>>[];
    for (var Index = 0; Index < Output.length; Index += 6) {
      Rows.add(Output.sublist(Index, Index + 6));
    }
    return Rows;
  }
  return <List<dynamic>>[];
}

List<DetectedBox> DecodeDetections(dynamic Output, {required int Width, required int Height, required int InputSize, required double Confidence}) {
  final Rows = DetectionRows(Output);
  if (Rows.isEmpty) return <DetectedBox>[];
  final Scale = InputSize / Width < InputSize / Height ? InputSize / Width : InputSize / Height;
  final InnerWidth = (Width * Scale).round().clamp(1, InputSize);
  final InnerHeight = (Height * Scale).round().clamp(1, InputSize);
  final PadX = (InputSize - InnerWidth) ~/ 2;
  final PadY = (InputSize - InnerHeight) ~/ 2;
  final Result = <DetectedBox>[];
  for (final Row in Rows) {
    if (Row.length < 6) continue;
    final Score = (Row[4] as num?)?.toDouble();
    final Label = (Row[5] as num?)?.round();
    if (Score == null || Label == null || Score < Confidence) continue;
    final X1 = (((Row[0] as num).toDouble() - PadX) / Scale).clamp(0.0, Width.toDouble());
    final Y1 = (((Row[1] as num).toDouble() - PadY) / Scale).clamp(0.0, Height.toDouble());
    final X2 = (((Row[2] as num).toDouble() - PadX) / Scale).clamp(0.0, Width.toDouble());
    final Y2 = (((Row[3] as num).toDouble() - PadY) / Scale).clamp(0.0, Height.toDouble());
    if (X2 <= X1 || Y2 <= Y1) continue;
    Result.add(DetectedBox(
      Label: Label,
      Confidence: Score,
      Left: X1 / Width,
      Top: Y1 / Height,
      Right: X2 / Width,
      Bottom: Y2 / Height,
    ));
  }
  return Result;
}

Uint8List BuildMask(List<DetectedBox> Boxes, int Width, int Height, {int Padding = 4}) {
  final Mask = Uint8List(Width * Height);
  for (final Box in Boxes) {
    if (Box.Label != 0 && Box.Label != 1) continue;
    final Left = ((Box.Left * Width).round() - Padding).clamp(0, Width - 1);
    final Top = ((Box.Top * Height).round() - Padding).clamp(0, Height - 1);
    final Right = ((Box.Right * Width).round() + Padding).clamp(Left + 1, Width);
    final Bottom = ((Box.Bottom * Height).round() + Padding).clamp(Top + 1, Height);
    for (var Y = Top; Y < Bottom; Y++) {
      Mask.fillRange(Y * Width + Left, Y * Width + Right, 255);
    }
  }
  return Mask;
}
