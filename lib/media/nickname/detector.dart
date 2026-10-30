import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../../config/constants.dart';
import 'detect.dart';
import 'worker.dart';

export 'detect.dart';

class SplatoonVision {
  ReceivePort? _Port;
  Isolate? _Isolate;
  SendPort? _Worker;
  Completer<SendPort>? _Ready;
  Future<List<DetectedBox>> _Chain = Future<List<DetectedBox>>.value(<DetectedBox>[]);
  final Map<int, Completer<List<DetectedBox>>> _Pending = <int, Completer<List<DetectedBox>>>{};
  Future<void>? _Starting;
  int _NextId = 1;
  bool _Failed = false;
  bool _Released = false;
  String? ErrorText;

  bool get Ready => _Worker != null && !_Failed;

  Future<void> Start() {
    if (Ready) return Future<void>.value();
    final Pending = _Starting;
    if (Pending != null) return Pending;
    final Task = _Start();
    _Starting = Task;
    return Task.whenComplete(() {
      if (identical(_Starting, Task)) _Starting = null;
    });
  }

  Future<void> _Start() async {
    _Failed = false;
    _Released = false;
    ErrorText = null;
    final Model = await rootBundle.load(Config.ModelPath);
    final Bytes = Model.buffer.asUint8List(Model.offsetInBytes, Model.lengthInBytes);
    final Port = ReceivePort();
    final Ready = Completer<SendPort>();
    _Port = Port;
    _Ready = Ready;
    Port.listen(_OnMessage);
    try {
      _Isolate = await Isolate.spawn(
        VisionWorker,
        <Object>[
          Port.sendPort,
          TransferableTypedData.fromList(<TypedData>[Bytes]),
        ],
        debugName: 'splatoon3record.vision',
        errorsAreFatal: true,
        onError: Port.sendPort,
        onExit: Port.sendPort,
      );
      _Worker = await Ready.future.timeout(const Duration(seconds: 30));
    } catch (Cause) {
      _Failed = true;
      ErrorText = '$Cause';
      await _ClosePort();
      rethrow;
    }
  }

  Future<List<DetectedBox>> Detect(Uint8List Rgba, int Width, int Height, {double Confidence = Config.DetectConfidence}) {
    final Task = _Chain.then((_) => _Run(Rgba, Width, Height, Confidence));
    _Chain = Task.catchError((Object Cause) => <DetectedBox>[]);
    return Task;
  }

  Future<List<DetectedBox>> _Run(Uint8List Rgba, int Width, int Height, double Confidence) async {
    await Start();
    final Worker = _Worker;
    if (Worker == null || _Failed) throw StateError(ErrorText ?? '画面识别未就绪');
    if (Rgba.length != Width * Height * 4) throw StateError('画面数据长度不符');
    final Id = _NextId++;
    final Done = Completer<List<DetectedBox>>();
    _Pending[Id] = Done;
    Worker.send(<Object>[
      Id,
      TransferableTypedData.fromList(<TypedData>[Rgba]),
      Width,
      Height,
      Confidence,
    ]);
    try {
      return await Done.future.timeout(const Duration(seconds: 20));
    } finally {
      _Pending.remove(Id);
    }
  }

  void _OnMessage(dynamic Message) {
    if (Message is SendPort) {
      if (_Ready != null && !_Ready!.isCompleted) _Ready!.complete(Message);
      return;
    }
    if (Message is List && Message.isNotEmpty && Message.first is SendPort) {
      final Text = Message.length > 1 ? '${Message[1]}' : '画面识别启动失败';
      ErrorText = Text;
      _Failed = true;
      if (_Ready != null && !_Ready!.isCompleted) _Ready!.completeError(StateError(Text));
      _FailPending(StateError(Text));
      return;
    }
    if (Message is List && Message.length == 2 && Message.first is String) {
      final Text = '${Message[0]}\n${Message[1]}';
      ErrorText = Text;
      _Failed = true;
      if (_Ready != null && !_Ready!.isCompleted) _Ready!.completeError(StateError(Text));
      _FailPending(StateError(Text));
      return;
    }
    if (Message == null) {
      if (!_Released) {
        ErrorText = '画面识别进程已退出';
        _Failed = true;
        _FailPending(StateError(ErrorText!));
      }
      return;
    }
    if (Message is! List || Message.isEmpty || Message.first is! num) return;
    final Id = (Message[0] as num).toInt();
    final Done = _Pending.remove(Id);
    if (Done == null || Done.isCompleted) return;
    final Data = Message.length > 1 ? Message[1] : null;
    if (Data is! TransferableTypedData) {
      final Text = Message.length > 2 ? '${Message[2]}' : '画面识别失败';
      Done.completeError(StateError(Text));
      return;
    }
    final Values = Data.materialize().asFloat32List();
    final Boxes = <DetectedBox>[];
    for (var Index = 0; Index + 5 < Values.length; Index += 6) {
      Boxes.add(DetectedBox(
        Label: Values[Index].round(),
        Confidence: Values[Index + 1],
        Left: Values[Index + 2],
        Top: Values[Index + 3],
        Right: Values[Index + 4],
        Bottom: Values[Index + 5],
      ));
    }
    Done.complete(Boxes);
  }

  void _FailPending(Object Cause) {
    for (final Item in _Pending.values.toList()) {
      if (!Item.isCompleted) Item.completeError(Cause);
    }
    _Pending.clear();
  }

  Future<void> _ClosePort() async {
    _Worker = null;
    _Port?.close();
    _Port = null;
    final IsolateRef = _Isolate;
    _Isolate = null;
    IsolateRef?.kill(priority: Isolate.immediate);
  }

  Future<void> Stop() async {
    _Released = true;
    try {
      await _Chain.timeout(const Duration(seconds: 5));
    } catch (_) {}
    final Worker = _Worker;
    if (Worker != null) {
      try {
        Worker.send(<Object>[-1]);
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    _FailPending(StateError('画面识别已停止'));
    await _ClosePort();
    _Failed = true;
  }
}
