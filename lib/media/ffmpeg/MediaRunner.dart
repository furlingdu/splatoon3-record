import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';

class KitMediaRunner {
  static Future<ProcessResult> Run(List<String> Args, Duration Timeout) async {
    final Done = Completer<ProcessResult>();
    final Session = await FFmpegKit.executeWithArgumentsAsync(Args, (FFmpegSession Value) async {
      final Code = await Value.getReturnCode();
      final Output = await Value.getOutput() ?? '';
      final Exit = ReturnCode.isSuccess(Code) ? 0 : (Code?.getValue() ?? -1);
      if (!Done.isCompleted) Done.complete(ProcessResult(0, Exit, '', Output));
    });
    try {
      return await Done.future.timeout(Timeout);
    } on TimeoutException {
      await FFmpegKit.cancel(Session.getSessionId());
      if (!Done.isCompleted) Done.complete(ProcessResult(0, -1, '', 'timeout'));
      return Done.future;
    }
  }
}
