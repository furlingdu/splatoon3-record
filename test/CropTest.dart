import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:splatoon3record/domain/Models.dart';
import 'package:splatoon3record/media/capture/Service.dart';
import 'package:splatoon3record/media/ffmpeg/Service.dart';

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
    await Temp.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}







