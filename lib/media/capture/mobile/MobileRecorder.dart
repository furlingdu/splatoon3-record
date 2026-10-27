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
    Actual = await Source.StartRecording(Target!);
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
      await Source.StopRecording();
      await Finalize(OldTarget, OldActual);
      Target = NextPath();
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
    Target = null;
    Actual = null;
    if (OldTarget == null) return;
    await Source.StopRecording();
    await Finalize(OldTarget, OldActual);
  }

  Future<void> Finalize(String? Target, String? Actual) async {
    if (Target == null) return;
    final Source = Actual ?? Target;
    if (!File(Source).existsSync()) return;
    if (!Source.toLowerCase().endsWith('.mov')) return;
    final Out = await FFmpeg.Run(<String>['-hide_banner', '-loglevel', 'error', '-y', '-i', Source, '-c', 'copy', '-movflags', '+faststart', Target], Timeout: const Duration(minutes: 3));
    if (Out.exitCode == 0 && File(Target).existsSync()) {
      try {
        await File(Source).delete();
      } catch (_) {}
    }
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
