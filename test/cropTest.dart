import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:splatoon3record/domain/models.dart';
import 'package:splatoon3record/media/capture/desktop.dart';
import 'package:splatoon3record/media/ffmpeg/ffmpegService.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Crop cache segments into a match video', () async {
    final Temp = await Directory.systemTemp.createTemp('s3r-crop-');
    final Directories = AppDirectories(Root: Temp.path);
    await Directories.Create();
    final FFmpeg = FFmpegService(Directories);
    final Capture = CaptureService(Directories, FFmpeg);
    final First = '${Directories.Cache}${Platform.pathSeparator}First.mp4';
    final Second = '${Directories.Cache}${Platform.pathSeparator}Second.mp4';
    for (final Path in <String>[First, Second]) {
      final Result = await FFmpeg.Run(<String>[
        '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=30',
        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
        '-t', '2', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', Path,
      ]);
      expect(Result.exitCode, 0);
    }
    final Records = <VideoRecord>[
      VideoRecord(FilePath: First, StartAt: 0, EndAt: 2000, Width: 320, Height: 240, Fps: 30, Encoder: 'libx264', HasAudio: true, Flip: false),
      VideoRecord(FilePath: Second, StartAt: 2000, EndAt: 4000, Width: 320, Height: 240, Fps: 30, Encoder: 'libx264', HasAudio: true, Flip: false),
    ];
    final Match = BattleMatch.FromMap(<String, dynamic>{'matchId': 'm1', 'kind': 'regular', 'startAt': 2000, 'endAt': 3000, 'duration': 1000});
    final Output = '${Directories.Videos}${Platform.pathSeparator}Match.mp4';
    final Path = await Capture.CropRecords(Match, Records, Output, RecordSettings());
    expect(Path, Output);
    expect(File(Output).existsSync(), true);
    expect(File(Output).lengthSync(), greaterThan(1000));
    final Probe = await FFmpeg.Run(<String>['-hide_banner', '-i', Output], Timeout: const Duration(seconds: 30));
    expect('${Probe.stderr}${Probe.stdout}', contains('Video: hevc'));
    expect('${Probe.stderr}${Probe.stdout}', contains('hvc1'));
    final Dump = await FFmpeg.Run(<String>['-hide_banner', '-loglevel', 'error', '-i', Output, '-map', '0:v:0', '-c', 'copy', '-f', 'framecrc', '-'], Timeout: const Duration(seconds: 30));
    final Timestamps = <int>[];
    for (final Line in '${Dump.stdout}'.split(RegExp(r'\r?\n'))) {
      if (Line.isEmpty || Line.startsWith('#')) continue;
      final Parts = Line.split(',');
      if (Parts.length < 3) continue;
      final Pts = int.tryParse(Parts[1].trim());
      if (Pts != null) Timestamps.add(Pts);
    }
    expect(Timestamps.length, greaterThan(1));
    final Deltas = <int>{for (var Index = 1; Index < Timestamps.length; Index++) Timestamps[Index] - Timestamps[Index - 1]};
    expect(Deltas.length, 1);
    expect(Deltas.first, greaterThan(0));
    await Temp.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}







