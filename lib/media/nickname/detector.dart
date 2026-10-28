import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

import '../../config/constants.dart';

class NicknameBox {
  const NicknameBox({required this.Left, required this.Top, required this.Width, required this.Height, required this.Conf});

  final double Left;
  final double Top;
  final double Width;
  final double Height;
  final double Conf;
}

class NicknameDetector {
  OrtSession? _Session;
  bool _Started = false;

  Future<void> Start() async {
    if (_Started) return;
    OrtEnv.instance.init();
    final Model = await rootBundle.load(Config.ModelPath);
    _Session = OrtSession.fromBuffer(Model.buffer.asUint8List(), OrtSessionOptions());
    _Started = true;
  }

  Future<List<NicknameBox>> Detect(Uint8List Rgba, int Width, int Height, {double Conf = 0.25}) async {
    await Start();
    final Session = _Session;
    if (Session == null) return <NicknameBox>[];
    const Size = 960;
    final Scale = Size / Width < Size / Height ? Size / Width : Size / Height;
    final InnerWidth = (Width * Scale).round();
    final InnerHeight = (Height * Scale).round();
    final Left = (Size - InnerWidth) ~/ 2;
    final Top = (Size - InnerHeight) ~/ 2;
    final Area = Size * Size;
    final Blob = Float32List(3 * Area)..fillRange(0, 3 * Area, 114 / 255);
    for (var Y = 0; Y < InnerHeight; Y++) {
      final SourceY = (Y / Scale).floor().clamp(0, Height - 1);
      for (var X = 0; X < InnerWidth; X++) {
        final SourceX = (X / Scale).floor().clamp(0, Width - 1);
        final Source = (SourceY * Width + SourceX) * 4;
        final Target = (Top + Y) * Size + Left + X;
        Blob[Target] = Rgba[Source] / 255;
        Blob[Area + Target] = Rgba[Source + 1] / 255;
        Blob[2 * Area + Target] = Rgba[Source + 2] / 255;
      }
    }
    final Input = OrtValueTensor.createTensorWithDataList(Blob, <int>[1, 3, Size, Size]);
    final Options = OrtRunOptions();
    try {
      final Outputs = Session.run(Options, <String, OrtValue>{Session.inputNames.first: Input});
      final Output = Outputs.first?.value;
      final Result = <NicknameBox>[];
      if (Output is List && Output.isNotEmpty && Output.first is List) {
        for (final Row in Output.first as List) {
          if (Row is! List || Row.length < 5) continue;
          final Score = (Row[4] as num).toDouble();
          if (Score < Conf) continue;
          final X1 = (((Row[0] as num) - Left) / Scale).clamp(0, Width).toDouble();
          final Y1 = (((Row[1] as num) - Top) / Scale).clamp(0, Height).toDouble();
          final X2 = (((Row[2] as num) - Left) / Scale).clamp(0, Width).toDouble();
          final Y2 = (((Row[3] as num) - Top) / Scale).clamp(0, Height).toDouble();
          if (X2 <= X1 || Y2 <= Y1) continue;
          Result.add(NicknameBox(Left: X1, Top: Y1, Width: X2 - X1, Height: Y2 - Y1, Conf: Score));
        }
      }
      for (final Item in Outputs) {
        Item?.release();
      }
      return Result;
    } finally {
      Input.release();
      Options.release();
    }
  }

  void Release() {
    _Session?.release();
    _Session = null;
    _Started = false;
    OrtEnv.instance.release();
  }
}









