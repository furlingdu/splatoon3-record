import 'dart:async';
import 'dart:io';

import '../../../config/Config.dart';
import '../../../domain/Models.dart';
import '../../ffmpeg/Service.dart';
import 'MobileCaptureSource.dart';

class MobileRecorder {
  MobileRecorder(this.Source, this.Directories, this.FFmpeg);

  final MobileCaptureSource Source;
  final AppDirectories Directories;
  final FFmpegService FFmpeg;

  Timer? Clock;
  String? Target;
  String? Actual;
  String? AudioPath;
  bool Busy = false;
  int Segments = 0;

  String NextPath([DateTime? Now]) {
    final Base = Now ?? DateTime.now();
    for (var Index = 0; Index < 120; Index++) {
      final At = Base.add(Duration(seconds: Index));
      final Stamp = '${At.year.toString().padLeft(4, '0')}${At.month.toString().padLeft(2, '0')}${At.day.toString().padLeft(2, '0')}'
          '-${At.hour.toString().padLeft(2, '0')}${At.minute.toString().padLeft(2, '0')}${At.second.toString().padLeft(2, '0')}';
      final Path = '${Directories.Cache}${Platform.pathSeparator}Cache-$Stamp.mp4';
      final Mov = Path.replaceFirst(RegExp(r'[.]mp4$'), '.mov');
      if (!File(Path).existsSync() && !File(Mov).existsSync()) return Path;
    }
    throw StateError('缓存文件名冲突');
  }

  Future<void> Start() async {
    Target = NextPath();
    AudioPath = await Source.StartAudio('${Target!}.wav');
    try {
      Actual = await Source.StartRecording(Target!);
    } catch (_) {
      await Source.StopAudio();
      AudioPath = null;
      rethrow;
    }
    Segments = 1;
    Clock?.cancel();
    Clock = Timer.periodic(const Duration(seconds: Config.SegmentSeconds), (_) => Roll());
  }

  Future<void> Roll() async {
    if (Busy || Target == null) return;
    Busy = true;
    try {
      final OldTarget = Target;
      final OldActual = Actual;
      final OldAudio = AudioPath;
      await Source.StopRecording();
      await Source.StopAudio();
      await Finalize(OldTarget, OldActual, OldAudio);
      Target = NextPath();
      AudioPath = await Source.StartAudio('${Target!}.wav');
      Actual = await Source.StartRecording(Target!);
      Segments++;
    } finally {
      Busy = false;
    }
  }

  Future<void> Stop() async {
    Clock?.cancel();
    Clock = null;
    final OldTarget = Target;
    final OldActual = Actual;
    final OldAudio = AudioPath;
    Target = null;
    Actual = null;
    AudioPath = null;
    if (OldTarget == null) return;
    await Source.StopRecording();
    await Source.StopAudio();
    await Finalize(OldTarget, OldActual, OldAudio);
  }

  Future<void> Finalize(String? Target, String? Actual, [String? Audio]) async {
    if (Target == null) return;
    final Source = Actual ?? Target;
    if (!File(Source).existsSync()) return;
    var Video = Source;
    if (Video.toLowerCase().endsWith('.mov')) {
      final Out = await FFmpeg.Run(<String>['-hide_banner', '-loglevel', 'error', '-y', '-i', Video, '-c', 'copy', '-movflags', '+faststart', Target], Timeout: const Duration(minutes: 3));
      if (Out.exitCode != 0 || !File(Target).existsSync()) return;
      try {
        await File(Video).delete();
      } catch (_) {}
      Video = Target;
    }
    if (Audio == null || !File(Audio).existsSync()) return;
    final Temp = '$Target.mux.mp4';
    final Out = await FFmpeg.Run(<String>[
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-i',
      Video,
      '-i',
      Audio,
      '-c:v',
      'copy',
      '-c:a',
      'aac',
      '-b:a',
      '192k',
      '-shortest',
      Temp,
    ], Timeout: const Duration(minutes: 3));
    if (Out.exitCode != 0 || !File(Temp).existsSync()) return;
    try {
      await File(Audio).delete();
    } catch (_) {}
    if (Video != Target) {
      try {
        await File(Video).delete();
      } catch (_) {}
    }
    try {
      if (File(Target).existsSync()) await File(Target).delete();
      await File(Temp).rename(Target);
    } catch (_) {}
  }

  Future<void> Recover() async {
    final Folder = Directory(Directories.Cache);
    if (!Folder.existsSync()) return;
    for (final Item in Folder.listSync().whereType<File>().where((File Item) => Item.path.toLowerCase().endsWith('.mov'))) {
      final Name = Item.uri.pathSegments.last.replaceFirst(RegExp(r'[.]mov$', caseSensitive: false), '.mp4');
      final Target = '${Directories.Cache}${Platform.pathSeparator}$Name';
      await Finalize(Target, Item.path);
    }
  }
}
