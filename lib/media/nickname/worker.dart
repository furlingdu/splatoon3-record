import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:onnxruntime/onnxruntime.dart';

import '../../config/constants.dart';
import 'detect.dart';

void VisionWorker(List<Object> Args) {
  final Main = Args[0] as SendPort;
  final Model = (Args[1] as TransferableTypedData).materialize().asUint8List();
  final Port = ReceivePort();
  OrtSession? Session;
  OrtSessionOptions? SessionOptions;
  OrtRunOptions? RunOptions;
  try {
    OrtEnv.instance.init();
    SessionOptions = OrtSessionOptions();
    final Threads = (Platform.numberOfProcessors ~/ 2).clamp(1, 4);
    SessionOptions.setIntraOpNumThreads(Threads);
    SessionOptions.setInterOpNumThreads(1);
    SessionOptions.setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
    Session = OrtSession.fromBuffer(Model, SessionOptions);
    RunOptions = OrtRunOptions();
    Main.send(Port.sendPort);
  } catch (Cause) {
    Main.send(<Object>[Port.sendPort, '$Cause']);
    Port.close();
    return;
  }
  Port.listen((Message) {
    if (Message is! List || Message.isEmpty) return;
    final Id = (Message[0] as num).toInt();
    if (Id < 0) {
      try {
        RunOptions?.release();
        Session?.release();
        SessionOptions?.release();
        OrtEnv.instance.release();
      } catch (_) {}
      Port.close();
      return;
    }
    try {
      final Frame = (Message[1] as TransferableTypedData).materialize().asUint8List();
      final Width = (Message[2] as num).toInt();
      final Height = (Message[3] as num).toInt();
      final Confidence = (Message[4] as num).toDouble();
      final Shot = BuildLetterbox(Frame, Width, Height, Config.DetectInputSize);
      final Input = OrtValueTensor.createTensorWithDataList(Shot.Blob, <int>[1, 3, Config.DetectInputSize, Config.DetectInputSize]);
      final Outputs = Session!.run(RunOptions!, <String, OrtValue>{Session.inputNames.first: Input});
      try {
        final Value = Outputs.first?.value;
        final Boxes = DecodeDetections(Value, Width: Width, Height: Height, InputSize: Config.DetectInputSize, Confidence: Confidence);
        final Encoded = Float32List(Boxes.length * 6);
        for (var Index = 0; Index < Boxes.length; Index++) {
          final Box = Boxes[Index];
          final Offset = Index * 6;
          Encoded[Offset] = Box.Label.toDouble();
          Encoded[Offset + 1] = Box.Confidence;
          Encoded[Offset + 2] = Box.Left;
          Encoded[Offset + 3] = Box.Top;
          Encoded[Offset + 4] = Box.Right;
          Encoded[Offset + 5] = Box.Bottom;
        }
        Main.send(<Object>[Id, TransferableTypedData.fromList(<TypedData>[Encoded])]);
      } finally {
        for (final Item in Outputs) {
          Item?.release();
        }
        Input.release();
      }
    } catch (Cause) {
      Main.send(<Object?>[Id, null, '$Cause']);
    }
  });
}
