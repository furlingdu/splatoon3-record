import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splatoon3record/config/constants.dart';
import 'package:splatoon3record/domain/models.dart';
import 'package:splatoon3record/media/capture/mobile.dart';
import 'package:splatoon3record/media/capture/mobile/recorder.dart';
import 'package:splatoon3record/media/capture/mobile/source.dart';
import 'package:splatoon3record/media/ffmpeg/ffmpegService.dart';

class _FakeMobileCaptureSource extends MobileCaptureSource {
  late void Function(String State) OnState;
  final PrepareEntered = Completer<void>();
  final StartEntered = Completer<void>();
  final StopEntered = Completer<void>();
  Completer<void>? PrepareCompletion;
  Completer<void>? StartCompletion;
  Completer<void>? StopCompletion;
  int PrepareCalls = 0;
  int StartCalls = 0;
  int StopCalls = 0;
  int ReleaseCalls = 0;
  bool Ready = false;
  String? RecordingPath;

  @override
  String get Prefix => 'external';

  @override
  bool get Prepared => Ready;

  void Emit(String State) => OnState(State);

  void Unblock() {
    for (final Completion in <Completer<void>?>[PrepareCompletion, StartCompletion, StopCompletion]) {
      if (Completion != null && !Completion.isCompleted) Completion.complete();
    }
  }

  @override
  Future<List<CaptureDevice>> Devices() async {
    return <CaptureDevice>[CaptureDevice(Id: 'external:fake', Name: 'Fake capture card', Kind: 'video')];
  }

  @override
  Future<List<CaptureMode>> Modes(String Id) async {
    return <CaptureMode>[CaptureMode(Format: 'avfoundation', Width: 1920, Height: 1080, MinFps: 60, MaxFps: 60)];
  }

  @override
  Future<CaptureMode> Prepare(CaptureDevice Device, CaptureMode Mode, RecordSettings Value) async {
    PrepareCalls++;
    // Keep legacy Dispose idle events to verify the Dart guard even when newer
    // native implementations release sessions silently.
    await Release();
    if (!PrepareEntered.isCompleted) PrepareEntered.complete();
    await PrepareCompletion?.future;
    Ready = true;
    return Mode;
  }

  @override
  Future<String> StartRecording(String Path) async {
    StartCalls++;
    RecordingPath = Path.replaceFirst(RegExp(r'[.]mp4$'), '.mov');
    // Native state events can arrive before the Start method reply.
    Emit('recording');
    if (!StartEntered.isCompleted) StartEntered.complete();
    await StartCompletion?.future;
    return RecordingPath!;
  }

  @override
  Future<String?> StopRecording() async {
    StopCalls++;
    // Simulate legacy Stop/EndWriter idle events, including normal Roll.
    Emit('idle');
    if (!StopEntered.isCompleted) StopEntered.complete();
    await StopCompletion?.future;
    return RecordingPath;
  }

  @override
  Future<void> Release() async {
    ReleaseCalls++;
    Ready = false;
    RecordingPath = null;
    Emit('idle');
  }

  @override
  Widget BuildPreview() => const SizedBox.shrink();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory Temp;
  late AppDirectories Directories;
  late _FakeMobileCaptureSource Source;
  late MobileCaptureService Capture;
  late RecordSettings Settings;
  late List<String> Logs;
  late List<String> States;

  setUp(() async {
    Temp = await Directory.systemTemp.createTemp('s3r-mobile-capture-');
    Directories = AppDirectories(Root: Temp.path);
    await Directories.Create();
    Source = _FakeMobileCaptureSource();
    Capture = MobileCaptureService(Directories, FFmpegService(Directories), Sources: <MobileCaptureSource>[Source]);
    Source.OnState = (State) => Capture.HandleEvent(<String, dynamic>{'type': 'state', 'value': State});
    Logs = <String>[];
    States = <String>[];
    Capture.OnLog = Logs.add;
    Capture.State.addListener(() => States.add(Capture.State.value));
    Settings = RecordSettings(MobileSource: 'external', MobileDevice: 'external:fake', MobileAudio: false);
  });

  tearDown(() async {
    await Temp.delete(recursive: true);
  });

  // pump advances the recovery delay without sleeping. Always release blocked
  // operations and drain a queued recovery before disposing the notifiers.
  void CaptureTest(String Description, Future<void> Function(WidgetTester Tester) Body) {
    testWidgets(Description, (Tester) async {
      try {
        await Body(Tester);
      } finally {
        Source.Unblock();
        await Tester.pump();
        await Capture.Stop();
        await Tester.pump(const Duration(seconds: 2));
        await Capture.Dispose();
      }
    });
  }

  CaptureTest('Prepare disposal idle does not interrupt startup or schedule recovery', (Tester) async {
    Source.PrepareCompletion = Completer<void>();
    final Starting = Capture.Start(Settings);
    await Tester.pump();

    expect(Source.PrepareEntered.isCompleted, true);
    expect(Source.ReleaseCalls, 1);
    expect(Source.StartCalls, 0);
    expect(Capture.State.value, 'starting');
    expect(Capture.PendingIdle, false);
    expect(Capture.Error.value, isNull);

    Source.PrepareCompletion!.complete();
    await Starting;
    expect(Capture.State.value, 'recording');
    expect(Capture.PreviewActive.value, true);
    expect(Capture.Error.value, isNull);
    expect(States, <String>['starting', 'recording']);

    await Tester.pump(const Duration(seconds: 2));
    expect(Source.PrepareCalls, 1);
    expect(Source.StartCalls, 1);
    expect(Capture.Recovered, false);
    expect(Logs.where((Item) => Item.contains('中断')), isEmpty);
  });

  CaptureTest('Recording then idle before Start completes is detected and recovered', (Tester) async {
    Source.StartCompletion = Completer<void>();
    final Starting = Capture.Start(Settings);
    await Tester.pump();

    expect(Source.StartEntered.isCompleted, true);
    expect(Capture.State.value, 'starting');
    expect(Capture.RecordingStarted, true);
    Source.Emit('idle');
    Source.Emit('idle');
    expect(Capture.PendingIdle, true);
    expect(Capture.State.value, 'starting');
    expect(Source.StartCalls, 1);

    Source.StartCompletion!.complete();
    await Starting;
    expect(Capture.State.value, 'idle');
    expect(Capture.PreviewActive.value, false);
    expect(Capture.Error.value, isNull);
    expect(Logs.where((Item) => Item == '录制启动后立即中断'), hasLength(1));

    await Tester.pump(const Duration(milliseconds: 999));
    expect(Source.StartCalls, 1);
    await Tester.pump(const Duration(milliseconds: 1));
    expect(Source.StartCalls, 2);
    expect(Capture.State.value, 'recording');
    expect(Capture.PreviewActive.value, true);
    expect(Capture.Error.value, isNull);
  });

  CaptureTest('Normal Roll idle keeps recording without scheduling recovery', (Tester) async {
    await Capture.Start(Settings);
    final Recorder = Capture.Recorder!;
    Source.StopCompletion = Completer<void>();
    Source.StartCompletion = Completer<void>();
    final Rolling = Recorder.Roll();
    await Tester.pump();

    expect(Source.StopEntered.isCompleted, true);
    expect(Recorder.Busy, true);
    expect(Capture.State.value, 'recording');
    expect(Capture.Error.value, isNull);
    expect(Source.StartCalls, 1);

    Source.StopCompletion!.complete();
    await Tester.pump();
    expect(Source.StartCalls, 2);
    expect(Recorder.Busy, true);
    expect(Capture.State.value, 'recording');
    Source.StartCompletion!.complete();
    await Rolling;

    expect(Recorder.Busy, false);
    expect(Recorder.Segments, 2);
    expect(Capture.Recorder, same(Recorder));
    await Tester.pump(const Duration(seconds: 2));
    expect(Source.PrepareCalls, 1);
    expect(Source.StartCalls, 2);
    expect(Capture.Recovered, false);
    expect(Capture.Error.value, isNull);
    expect(States, <String>['starting', 'recording']);
    expect(Logs.where((Item) => Item.contains('中断')), isEmpty);
  });

  CaptureTest('Unexpected idle recovers once and a second interruption reports an error', (Tester) async {
    await Capture.Start(Settings);
    Source.Emit('idle');
    Source.Emit('idle');
    expect(Capture.State.value, 'idle');
    expect(Capture.Error.value, isNull);
    expect(Logs.where((Item) => Item == '录制意外中断，正在自动恢复'), hasLength(1));

    await Tester.pump(const Duration(milliseconds: 999));
    expect(Source.StartCalls, 1);
    await Tester.pump(const Duration(milliseconds: 1));
    expect(Source.PrepareCalls, 2);
    expect(Source.StartCalls, 2);
    expect(Capture.State.value, 'recording');
    expect(Capture.PreviewActive.value, true);
    expect(Capture.Error.value, isNull);

    Source.Emit('idle');
    Source.Emit('idle');
    expect(Capture.State.value, 'error');
    expect(Capture.Error.value, '录制意外中断，请检查采集卡连接与存储空间后点击重试采集');
    await Tester.pump(const Duration(seconds: 2));
    expect(Source.StartCalls, 2);
    expect(Logs.where((Item) => Item == '录制意外中断，正在自动恢复'), hasLength(1));
  });

  CaptureTest('An interruption during the recovery Start reports an error without a third Start', (Tester) async {
    await Capture.Start(Settings);
    Source.StartCompletion = Completer<void>();
    Source.Emit('idle');
    await Tester.pump(const Duration(seconds: 1));
    expect(Source.StartCalls, 2);
    expect(Capture.State.value, 'starting');

    Source.Emit('idle');
    Source.StartCompletion!.complete();
    await Tester.pump();
    expect(Capture.State.value, 'error');
    expect(Capture.Error.value, '录制意外中断，请检查采集卡连接与存储空间后点击重试采集');
    await Tester.pump(const Duration(seconds: 2));
    expect(Source.StartCalls, 2);
  });

  CaptureTest('Explicit Stop ignores idle during StopRecording and Release', (Tester) async {
    await Capture.Start(Settings);
    Source.StopCompletion = Completer<void>();
    final Stopping = Capture.Stop();
    await Tester.pump();

    expect(Source.StopEntered.isCompleted, true);
    expect(Capture.Stopping, true);
    Source.Emit('idle');
    await Tester.pump(const Duration(seconds: 2));
    expect(Source.StartCalls, 1);
    expect(Capture.Recovered, false);
    expect(Capture.Error.value, isNull);

    Source.StopCompletion!.complete();
    await Stopping;
    expect(Source.ReleaseCalls, 2);
    expect(Capture.State.value, 'idle');
    expect(Capture.PreviewActive.value, false);
    await Tester.pump(const Duration(seconds: 2));
    expect(Source.StartCalls, 1);
    expect(Capture.Error.value, isNull);
    expect(Logs.where((Item) => Item.contains('中断')), isEmpty);
  });

  CaptureTest('Explicit Stop cancels queued recovery after unexpected idle', (Tester) async {
    await Capture.Start(Settings);
    Source.Emit('idle');
    expect(Capture.State.value, 'idle');
    expect(Source.StartCalls, 1);
    await Tester.pump(const Duration(milliseconds: 500));
    expect(Source.StartCalls, 1);
    expect(Capture.State.value, 'idle');

    // Stopping during the one-second retry delay must invalidate that retry.
    await Capture.Stop();
    await Tester.pump(const Duration(seconds: 2));
    expect(Source.StartCalls, 1, reason: 'A pending automatic recovery must not restart capture after an explicit Stop.');
    expect(Source.PrepareCalls, 1);
    expect(Capture.State.value, 'idle');
    expect(Capture.PreviewActive.value, false);
    expect(Capture.Error.value, isNull);
  });

  CaptureTest('Explicit Stop during blocked Prepare never starts recording', (Tester) async {
    Source.PrepareCompletion = Completer<void>();
    final Starting = Capture.Start(Settings);
    await Tester.pump();
    expect(Source.PrepareEntered.isCompleted, true);
    expect(Source.StartCalls, 0);

    final Stopping = Capture.Stop();
    Source.PrepareCompletion!.complete();
    await Starting;
    await Stopping;
    await Tester.pump(const Duration(seconds: 2));

    expect(Source.StartCalls, 0, reason: 'A stopped startup must not keep going after Prepare resolves.');
    expect(Capture.State.value, 'idle');
    expect(Capture.PreviewActive.value, false);
    expect(Source.ReleaseCalls, greaterThanOrEqualTo(2));
    expect(Logs.where((Item) => Item.contains('中断')), isEmpty);
  });

  CaptureTest('Explicit Stop during a blocked Roll does not open another segment', (Tester) async {
    await Capture.Start(Settings);
    final Recorder = Capture.Recorder!;
    Source.StopCompletion = Completer<void>();
    final Rolling = Recorder.Roll();
    await Tester.pump();
    expect(Source.StopCalls, 1);
    expect(Recorder.Busy, true);

    final Stopping = Capture.Stop();
    Source.StopCompletion!.complete();
    await Rolling;
    await Stopping;
    await Tester.pump(const Duration(seconds: 2));

    expect(Source.StopCalls, 1, reason: 'Stop must not close the same segment twice.');
    expect(Source.StartCalls, 1, reason: 'A stopped roll must not begin a new segment.');
    expect(Recorder.Segments, 1);
    expect(Recorder.Busy, false);
    expect(Capture.State.value, 'idle');
    expect(Logs.where((Item) => Item.contains('中断')), isEmpty);
  });

  test('SweepCache removes expired media but keeps active, recent and unrelated files', () async {
    addTearDown(Capture.Dispose);
    final Old = DateTime.now().subtract(const Duration(milliseconds: Config.CacheKeepMs + 60000));
    File CacheFile(String Name, {bool Expired = true}) {
      final Item = File('${Directories.Cache}${Platform.pathSeparator}$Name');
      Item.writeAsBytesSync(<int>[1, 2, 3]);
      if (Expired) Item.setLastModifiedSync(Old);
      return Item;
    }

    final Expired = <File>[CacheFile('expired.mp4'), CacheFile('expired.MOV'), CacheFile('expired.m4a')];
    final Target = CacheFile('active.mp4');
    final Actual = CacheFile('active.mov');
    final Audio = CacheFile('active.m4a');
    final Recent = CacheFile('recent.mp4', Expired: false);
    final Unrelated = CacheFile('notes.txt');
    final Nested = Directory('${Directories.Cache}${Platform.pathSeparator}nested.mov')..createSync();
    final NestedFile = File('${Nested.path}${Platform.pathSeparator}old.mp4')..writeAsBytesSync(<int>[1]);
    NestedFile.setLastModifiedSync(Old);
    // Install the active paths directly so Start's background sweep cannot race
    // with file creation in this cache-specific test.
    Capture.Recorder = MobileRecorder(Source, Directories, false)
      ..Target = Target.path
      ..Actual = Actual.path
      ..AudioPath = Audio.path;

    await Capture.SweepCache();

    for (final Item in Expired) {
      expect(Item.existsSync(), false, reason: Item.path);
    }
    for (final Item in <File>[Target, Actual, Audio, Recent, Unrelated, NestedFile]) {
      expect(Item.existsSync(), true, reason: Item.path);
    }
    expect(Logs, contains('清理过期缓存 3 个'));
  });
}
