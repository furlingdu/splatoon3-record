import 'dart:io';

import '../../config/Config.dart';
import '../../domain/Models.dart';
import '../ffmpeg/Service.dart';

abstract final class ClipBuilder {
  static Future<String?> Build(BattleMatch Match, List<VideoRecord> Cache, String Output, RecordSettings Value, FFmpegService FFmpeg, AppDirectories Directories) async {
    final Start = Match.StartAt - Config.ClipLeadMs;
    final End = Match.EndAt + Config.ClipTailMs;
    final Selected = Cache.where((Item) => Item.EndAt > Start && Item.StartAt < End).toList()..sort((Left, Right) => Left.StartAt.compareTo(Right.StartAt));
    if (Selected.isEmpty) return null;
    final First = Selected.first;
    final Last = Selected.last;
    final Offset = (Start - First.StartAt).clamp(0, 1 << 31) / 1000;
    final Span = ((End.clamp(First.StartAt, Last.EndAt) - Start.clamp(First.StartAt, Last.EndAt)) / 1000).clamp(0.1, 86400.0);
    final Temp = '${Directories.Temp}${Platform.pathSeparator}crop-${DateTime.now().microsecondsSinceEpoch}.txt';
    final Lines = Selected.map((Item) => "file '${Item.FilePath.replaceAll('\\', '/').replaceAll("'", "'\\''")}'").join('\n');
    await File(Temp).writeAsString('$Lines\n');
    try {
      final Encoder = await FFmpeg.Encoder(Value);
      final Args = <String>[
        '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'concat', '-safe', '0', '-i', Temp,
        '-ss', Offset.toStringAsFixed(3),
        '-t', Span.toStringAsFixed(3),
        '-map', '0:v:0?',
        ...(Selected.any((Item) => Item.HasAudio) ? <String>['-map', '0:a:0?', '-c:a', 'aac', '-b:a', '${Config.AudioBitrate}'] : <String>['-an']),
        '-c:v', Encoder,
        ...FFmpeg.QualityArgs(Encoder, Value.Quality),
        '-movflags', '+faststart',
        Output,
      ];
      await Directory(File(Output).parent.path).create(recursive: true);
      final Result = await FFmpeg.Run(Args, Timeout: const Duration(minutes: 10));
      return Result.exitCode == 0 && File(Output).existsSync() && File(Output).lengthSync() > 0 ? Output : null;
    } finally {
      try {
        await File(Temp).delete();
      } catch (_) {}
    }
  }
}
