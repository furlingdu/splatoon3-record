import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../config/constants.dart';
import '../../../domain/models.dart';
import 'source.dart';

/// Platform channel failures carry their message inside the exception, which is
/// unreadable in the UI ("PlatformException(...)"). Keep only the message.
String CauseText(Object Cause) {
  if (Cause is PlatformException) return Cause.message ?? Cause.code;
  if (Cause is StateError) return Cause.message;
  return '$Cause';
}

class MobileRecorder {
  MobileRecorder(this.Source, this.Directories, this.AudioRequested);

  final MobileCaptureSource Source;
  final AppDirectories Directories;
  final bool AudioRequested;

  final ValueNotifier<String?> Error = ValueNotifier<String?>(null);
  Timer? Clock;
  String? Target;
  String? Actual;
  String? AudioPath;
  int AudioOffsetUs = 0;
  bool Busy = false;
  bool Stopping = false;
  bool AudioActive = false;
  String? AudioError;
  int Segments = 0;
  Future<void> Finalizes = Future<void>.value();
  Future<void>? Operation;
  Future<void>? StopTask;

  String NextPath([DateTime? Now]) {
    final Base = Now ?? DateTime.now();
    for (var Index = 0; Index < 120; Index++) {
      final At = Base.add(Duration(seconds: Index));
      final Stamp = '${At.year.toString().padLeft(4, '0')}${At.month.toString().padLeft(2, '0')}${At.day.toString().padLeft(2, '0')}'
          '-${At.hour.toString().padLeft(2, '0')}${At.minute.toString().padLeft(2, '0')}${At.second.toString().padLeft(2, '0')}';
      final Path = '${Directories.Cache}${Platform.pathSeparator}Cache-$Stamp.mp4';
      final Mov = Path.replaceFirst(RegExp(r'[.]mp4$'), '.mov');
      final Audio = AudioFor(Path);
      if (!File(Path).existsSync() && !File(Mov).existsSync() && !File(Audio).existsSync()) return Path;
    }
    throw StateError('缓存文件名冲突');
  }

  String AudioFor(String Value) {
    return Value.replaceFirst(RegExp(r'[.]mp4$'), '.m4a');
  }

  Future<void> Monitor(bool Value) async {
    await Source.Monitor(Value);
  }

  Future<void> Start() {
    if (Stopping) return Future<void>.value();
    return RunOperation(StartCapture);
  }

  Future<void> RunOperation(Future<void> Function() Action) {
    final Task = Action();
    Operation = Task;
    return Task.whenComplete(() {
      if (identical(Operation, Task)) Operation = null;
    });
  }

  Future<void> StartCapture() async {
    Error.value = null;
    AudioError = null;
    AudioActive = AudioRequested;
    await BeginSegment();
    if (Stopping) return;
    Segments = 1;
    Clock?.cancel();
    Clock = Timer.periodic(const Duration(seconds: Config.SegmentSeconds), (_) => Roll());
  }

  Future<void> BeginSegment() async {
    AudioActive = AudioRequested;
    AudioError = null;
    final Next = NextPath();
    Target = Next;
    Actual = await Source.StartRecording(Next);
    final VideoStartNs = Source.HasSeparateAudio ? await Source.MonotonicNs() : 0;
    AudioPath = null;
    AudioOffsetUs = 0;
    if (!Source.HasSeparateAudio) return;
    if (!AudioRequested) {
      AudioActive = false;
      return;
    }
    final NextAudio = AudioFor(Next);
    try {
      final Clip = await Source.StartAudio(NextAudio);
      if (Clip == null) {
        AudioActive = false;
        AudioError = '未启动音频录制';
        return;
      }
      AudioPath = Clip.Path;
      AudioActive = true;
      AudioOffsetUs = (Clip.StartNs - VideoStartNs) ~/ 1000;
    } catch (Cause) {
      AudioActive = false;
      AudioError = CauseText(Cause);
    }
  }

  Future<void> Roll() async {
    if (Busy || Stopping || Target == null) return;
    Busy = true;
    try {
      await RunOperation(RollSegment);
    } catch (Cause) {
      Error.value = CauseText(Cause);
      Clock?.cancel();
      Clock = null;
    } finally {
      Busy = false;
    }
  }

  Future<void> RollSegment() async {
    final OldTarget = Target;
    final OldActual = Actual;
    final OldAudio = AudioPath;
    final OldOffset = AudioOffsetUs;
    final OldAudioActive = AudioActive;
    try {
      await Source.StopRecording();
    } catch (_) {}
    try {
      await Source.StopAudio();
    } catch (_) {}
    Target = null;
    Actual = null;
    AudioPath = null;
    AudioOffsetUs = 0;
    AudioActive = false;
    if (OldTarget != null) EnqueueFinalize(OldTarget, OldActual, OldAudio, OldOffset, OldAudioActive);
    // Stop may have started while the old segment was closing. Then this roll
    // must not open a new segment: Stop closes whatever is still active.
    if (Stopping) return;
    await BeginSegment();
    if (Stopping) return;
    Segments++;
  }

  Future<void> Stop() {
    Stopping = true;
    Clock?.cancel();
    Clock = null;
    final Pending = StopTask;
    if (Pending != null) return Pending;
    final Task = StopCapture();
    StopTask = Task;
    return Task.whenComplete(() {
      if (identical(StopTask, Task)) StopTask = null;
    });
  }

  Future<void> StopCapture() async {
    final InFlight = Operation;
    if (InFlight != null) {
      try {
        await InFlight;
      } catch (_) {}
    }
    final OldTarget = Target;
    final OldActual = Actual;
    final OldAudio = AudioPath;
    final OldOffset = AudioOffsetUs;
    final OldAudioActive = AudioActive;
    Target = null;
    Actual = null;
    AudioPath = null;
    AudioOffsetUs = 0;
    AudioActive = false;
    try {
      if (OldTarget != null) {
        try {
          await Source.StopRecording();
        } catch (_) {}
        try {
          await Source.StopAudio();
        } catch (_) {}
        EnqueueFinalize(OldTarget, OldActual, OldAudio, OldOffset, OldAudioActive);
      }
      await Finalizes;
    } finally {
      Stopping = false;
    }
  }

  void EnqueueFinalize(String FinalTarget, String? SourcePath, String? Audio, int Offset, bool HadAudio) {
    Finalizes = Finalizes.then((_) => Finalize(FinalTarget, SourcePath, Audio, Offset, HadAudio)).catchError((Object Cause) {
      Error.value = CauseText(Cause);
    });
  }

  Future<void> Finalize(String FinalTarget, String? SourcePath, String? Audio, int Offset, bool HadAudio) async {
    final Video = SourcePath ?? FinalTarget;
    if (!File(Video).existsSync() && !File(FinalTarget).existsSync()) return;
    final Result = await Source.Finish(Video, HadAudio ? Audio : null, FinalTarget, AudioOffsetUs: Offset);
    if (Result == null || !File(Result).existsSync() || File(Result).lengthSync() == 0) {
      Error.value = '录像合流失败：$FinalTarget';
      return;
    }
    if (Result != FinalTarget) {
      Error.value = '录像导出失败，已保留原始文件';
      return;
    }
    if (HadAudio && Audio != null && File(Audio).existsSync()) {
      Error.value = '音频合流失败，已保留无音频视频';
      return;
    }
    if (Audio != null && File(Audio).existsSync() && Result == FinalTarget) {
      try {
        await File(Audio).delete();
      } catch (_) {}
    }
  }

  Future<void> Recover() async {
    final Folder = Directory(Directories.Cache);
    if (!Folder.existsSync()) return;
    for (final Item in Folder.listSync().whereType<File>()) {
      final Lower = Item.path.toLowerCase();
      if (!Lower.endsWith('.mov')) continue;
      final Name = Item.uri.pathSegments.last.replaceFirst(RegExp(r'[.]mov$', caseSensitive: false), '.mp4');
      final FinalTarget = '${Directories.Cache}${Platform.pathSeparator}$Name';
      await Finalize(FinalTarget, Item.path, null, 0, false);
    }
    for (final Item in Folder.listSync().whereType<File>()) {
      if (!Item.path.toLowerCase().endsWith('.m4a')) continue;
      final FinalTarget = Item.path.replaceFirst(RegExp(r'[.]m4a$', caseSensitive: false), '.mp4');
      if (!File(FinalTarget).existsSync()) continue;
      await Finalize(FinalTarget, FinalTarget, Item.path, 0, true);
    }
  }
}
