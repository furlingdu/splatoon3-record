import 'dart:io';
import 'dart:math';

import '../../config/constants.dart';
import '../../domain/models.dart';
import '../ffmpeg/ffmpegService.dart';
import 'detector.dart';

class NicknameBlur {
  NicknameBlur(this.FFmpeg, this.Directories, this.Vision);

  final FFmpegService FFmpeg;
  final AppDirectories Directories;
  final SplatoonVision Vision;

  Future<String?> Blur(String Source, String Output) async {
    if (!File(Source).existsSync()) return null;
    final Probe = await FFmpeg.Run(<String>['-hide_banner', '-i', Source], Timeout: const Duration(seconds: 20));
    final Text = '${Probe.stderr}';
    final Clip = RegExp(r'Duration:\s*(\d+):(\d+):(\d+(?:[.]\d+)?)').firstMatch(Text);
    final Size = RegExp(r'Stream #0:0.*?(\d{2,5})x(\d{2,5})').firstMatch(Text);
    if (Clip == null || Size == null) return null;
    final Seconds = int.parse(Clip.group(1)!) * 3600 + int.parse(Clip.group(2)!) * 60 + double.parse(Clip.group(3)!);
    final Width = int.parse(Size.group(1)!);
    final Height = int.parse(Size.group(2)!);
    final SampleWidth = Width > 1280 ? 1280 : Width;
    final SampleHeight = (Height * SampleWidth / Width).round();
    final Boxes = <List<double>>[];
    try {
      for (var Index = 1; Index <= 6; Index++) {
        final At = Seconds * Index / 7;
        final Sample = '${Directories.Temp}${Platform.pathSeparator}detect-$Index.rgba';
        final Shot = await FFmpeg.Run(<String>[
          '-hide_banner', '-loglevel', 'error', '-y',
          '-ss', At.toStringAsFixed(2), '-i', Source, '-frames:v', '1',
          '-vf', 'scale=$SampleWidth:-2', '-pix_fmt', 'rgba', '-f', 'rawvideo', Sample,
        ], Timeout: const Duration(seconds: 30));
        if (Shot.exitCode != 0) continue;
        final Bytes = await File(Sample).readAsBytes();
        try {
          await File(Sample).delete();
        } catch (_) {}
        if (Bytes.isEmpty) continue;
        if (Bytes.length < SampleWidth * SampleHeight * 4) continue;
        final Found = await Vision.Detect(Bytes, SampleWidth, SampleHeight, Confidence: Config.NicknameConfidence);
        for (final Box in Found) {
          if (Box.Label != Config.PlayerNicknameLabel && Box.Label != Config.KillPlayerNicknameLabel) continue;
          Boxes.add(<double>[Box.Left * Width, Box.Top * Height, Box.Width * Width, Box.Height * Height]);
        }
      }
    } catch (_) {
    }
    if (Boxes.isEmpty) return null;
    final Mask = '${Directories.Temp}${Platform.pathSeparator}mask-${DateTime.now().microsecondsSinceEpoch}.png';
    final Filters = <String>['format=gray'];
    for (final Box in Boxes) {
      final X = max(0, (Box[0] - 4).round());
      final Y = max(0, (Box[1] - 4).round());
      final W = min(Width - X, (Box[2] + 8).round());
      final H = min(Height - Y, (Box[3] + 8).round());
      if (W <= 0 || H <= 0) continue;
      Filters.add('drawbox=x=$X:y=$Y:w=$W:h=$H:color=white:t=fill');
    }
    final MaskResult = await FFmpeg.Run(<String>[
      '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'lavfi', '-i', 'color=c=black:s=${Width}x$Height:d=1',
      '-vf', Filters.join(','), '-frames:v', '1', Mask,
    ], Timeout: const Duration(seconds: 30));
    if (MaskResult.exitCode != 0 || !File(Mask).existsSync()) return null;
    await Directory(File(Output).parent.path).create(recursive: true);
    final Primary = await FFmpeg.ArchiveEncoder(RecordSettings());
    for (var Attempt = 0; Attempt < 2; Attempt++) {
      final Encoder = Attempt == 0 ? Primary : 'libx265';
      final Args = <String>[
        '-hide_banner', '-loglevel', 'error', '-y',
        '-i', Source, '-loop', '1', '-i', Mask,
        '-filter_complex', '[0:v]split=2[base][blur];[blur]boxblur=20:2[soft];[1:v]format=gray[mask];[soft][mask]alphamerge[fg];[base][fg]overlay=shortest=1[out]',
        '-map', '[out]', '-map', '0:a:0?',
        ...FFmpeg.ArchiveVideoArgs(Encoder, 20), '-pix_fmt', 'yuv420p',
        '-fps_mode', 'cfr',
        '-c:a', 'copy', '-movflags', '+faststart', '-shortest', Output,
      ];
      final Result = await FFmpeg.Run(Args, Timeout: const Duration(minutes: 20));
      if (Result.exitCode == 0 && File(Output).existsSync()) {
        try {
          await File(Mask).delete();
        } catch (_) {}
        return Output;
      }
      try {
        await File(Output).delete();
      } catch (_) {}
      if (Encoder == 'libx265') break;
    }
    try {
      await File(Mask).delete();
    } catch (_) {}
    return null;
  }
}









