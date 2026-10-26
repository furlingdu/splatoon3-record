import 'dart:io';

import '../../config/Config.dart';
import '../../domain/Models.dart';
import '../ffmpeg/Service.dart';

class CaptureArguments {
  static List<String> Native({
    required RecordSettings Value,
    required FFmpegService FFmpeg,
    required AppDirectories Directories,
    required String Encoder,
    required int Width,
    required int Height,
    required int Fps,
    required String RateText,
    required String? LiveTarget,
    required bool Record,
    required String? MaskPipe,
  }) {
    final HasAudio = Value.AudioDevice.isNotEmpty;
    final VideoIndex = HasAudio ? 1 : 0;
    final MaskIndex = HasAudio ? 2 : 1;
    final Live = LiveTarget != null && LiveTarget.isNotEmpty;
    final Blur = Live && MaskPipe != null && Value.BlurNickname;
    final Args = <String>['-hide_banner', '-loglevel', 'warning', '-progress', 'pipe:2', '-stats_period', '1', '-nostdin', '-y'];
    if (HasAudio) {
      Args.addAll(<String>['-use_wallclock_as_timestamps', '1', '-rtbufsize', '4M', '-audio_buffer_size', '50', '-f', 'dshow', '-i', 'audio=${Value.AudioDevice}']);
    }
    Args.addAll(<String>[
      '-use_wallclock_as_timestamps', '1',
      '-f', 'rawvideo',
      '-pixel_format', 'nv12',
      '-video_size', '${Width}x$Height',
      '-framerate', RateText,
      '-i', 'pipe:0',
    ]);
    if (Blur) {
      Args.addAll(<String>[
        '-use_wallclock_as_timestamps', '1',
        '-f', 'rawvideo',
        '-pixel_format', 'gray',
        '-video_size', '${Config.MaskWidth}x${Config.MaskHeight}',
        '-framerate', '${Config.MaskFps}',
        '-i', MaskPipe,
      ]);
    }
    String RecordMap = '$VideoIndex:v:0';
    if (Blur) {
      final Filter = StringBuffer();
      if (Record) {
        Filter.write('[$VideoIndex:v]split=2[rec][live0];');
      }
      Filter.write('[${Record ? 'live0' : '$VideoIndex:v'}]scale=${Config.PreviewWidth}:${Config.PreviewHeight}:force_original_aspect_ratio=decrease,'
          'pad=${Config.PreviewWidth}:${Config.PreviewHeight}:(ow-iw)/2:(oh-ih)/2[base];'
          '[base]split=2[b1][b2];[b2]boxblur=20:2[soft];'
          '[$MaskIndex:v]fps=${Config.PreviewFps},scale=${Config.PreviewWidth}:${Config.PreviewHeight},format=gray[mask];'
          '[soft][mask]alphamerge[fg];[b1][fg]overlay=shortest=1,format=yuv420p[live]');
      Args.addAll(<String>['-filter_complex', Filter.toString()]);
      if (Record) RecordMap = '[rec]';
    }
    if (Record) {
      AddRecordOutput(
        Args,
        FFmpeg: FFmpeg,
        Directories: Directories,
        Encoder: Encoder,
        VideoMap: RecordMap,
        AudioMap: HasAudio ? '0:a:0?' : null,
        Fps: Fps,
        RateText: RateText,
        Quality: Value.Quality,
      );
    }
    if (Live) {
      Args.addAll(<String>['-map', Blur ? '[live]' : '$VideoIndex:v:0']);
      if (HasAudio) Args.addAll(<String>['-map', '0:a:0?']);
      if (!HasAudio) Args.addAll(<String>['-an']);
      if (!Blur) {
        Args.addAll(<String>[
          '-vf', 'scale=${Config.PreviewWidth}:${Config.PreviewHeight}:force_original_aspect_ratio=decrease,'
              'pad=${Config.PreviewWidth}:${Config.PreviewHeight}:(ow-iw)/2:(oh-ih)/2,format=yuv420p',
          '-r', '${Config.PreviewFps}',
        ]);
      }
      Args.addAll(<String>[
        '-c:v', LiveEncoder(Encoder),
        ...LiveRateArgs(Encoder),
        '-g', '${Config.PreviewFps * 2}',
        '-keyint_min', '${Config.PreviewFps * 2}',
      ]);
      if (HasAudio) Args.addAll(AudioArgs());
      Args.addAll(<String>['-f', 'flv', LiveTarget]);
    }
    return Args;
  }

  static List<String> Fallback({
    required RecordSettings Value,
    required FFmpegService FFmpeg,
    required AppDirectories Directories,
    required String Encoder,
    required String? LiveTarget,
    required bool Record,
  }) {
    final Rtmp = Value.CaptureMode == 'rtmp';
    final CombinedAudio = Platform.isMacOS && !Rtmp;
    final HasAudio = Rtmp || Value.AudioDevice.isNotEmpty;
    final Live = LiveTarget != null && LiveTarget.isNotEmpty;
    final Blur = Live && Value.BlurNickname;
    final Args = <String>['-hide_banner', '-loglevel', 'warning', '-progress', 'pipe:2', '-stats_period', '1', '-y'];
    if (!Blur) Args.add('-nostdin');
    if (Rtmp) {
      Args.addAll(<String>[
        '-fflags', 'nobuffer',
        '-flags', 'low_delay',
        '-rw_timeout', '5000000',
        '-i', 'rtmp://127.0.0.1:${Value.RtmpPort}/live/${Value.RtmpStreamKey}',
      ]);
    } else {
      Args.addAll(FFmpeg.InputArgs(Value));
    }
    final MaskIndex = Rtmp || CombinedAudio ? 1 : (HasAudio ? 2 : 1);
    if (Blur) {
      Args.addAll(<String>[
        '-f', 'rawvideo',
        '-pixel_format', 'gray',
        '-video_size', '${Config.MaskWidth}x${Config.MaskHeight}',
        '-framerate', '${Config.MaskFps}',
        '-i', 'pipe:0',
        '-map', '0:v:0',
        '-vf', 'scale=${Config.MaskWidth}:${Config.MaskHeight}',
        '-r', '10',
        '-pix_fmt', 'rgba',
        '-f', 'rawvideo',
        'pipe:1',
      ]);
      final Filter = '[0:v]scale=${Config.PreviewWidth}:${Config.PreviewHeight}:force_original_aspect_ratio=decrease,'
          'pad=${Config.PreviewWidth}:${Config.PreviewHeight}:(ow-iw)/2:(oh-ih)/2[base];'
          '[base]split=2[b1][b2];[b2]boxblur=20:2[soft];'
          '[$MaskIndex:v]fps=${Config.PreviewFps},scale=${Config.PreviewWidth}:${Config.PreviewHeight},format=gray[mask];'
          '[soft][mask]alphamerge[fg];[b1][fg]overlay=shortest=1,format=yuv420p[live]';
      Args.addAll(<String>['-filter_complex', Filter]);
    }
    if (Record) {
      AddRecordOutput(
        Args,
        FFmpeg: FFmpeg,
        Directories: Directories,
        Encoder: Encoder,
        VideoMap: '0:v:0',
        AudioMap: HasAudio ? (Rtmp || CombinedAudio ? '0:a:0?' : '1:a:0?') : null,
        Fps: Value.Fps,
        RateText: '${Value.Fps}',
        Quality: Value.Quality,
      );
    }
    if (Live) {
      if (Rtmp && !Blur) {
        Args.addAll(<String>['-map', '0:v:0', '-map', '0:a:0?', '-c', 'copy', '-f', 'flv', LiveTarget]);
      } else {
        Args.addAll(<String>['-map', Blur ? '[live]' : '0:v:0']);
        if (HasAudio) Args.addAll(<String>['-map', Rtmp || CombinedAudio ? '0:a:0?' : '1:a:0?']);
        if (!HasAudio) Args.addAll(<String>['-an']);
        if (!Blur) {
          Args.addAll(<String>[
            '-vf', 'scale=${Config.PreviewWidth}:${Config.PreviewHeight}:force_original_aspect_ratio=decrease,'
                'pad=${Config.PreviewWidth}:${Config.PreviewHeight}:(ow-iw)/2:(oh-ih)/2,format=yuv420p',
            '-r', '${Config.PreviewFps}',
          ]);
        }
        Args.addAll(<String>[
          '-c:v', LiveEncoder(Encoder),
          ...LiveRateArgs(Encoder),
          '-g', '${Config.PreviewFps * 2}',
          '-keyint_min', '${Config.PreviewFps * 2}',
        ]);
        if (HasAudio) Args.addAll(AudioArgs());
        Args.addAll(<String>['-f', 'flv', LiveTarget]);
      }
    }
    return Args;
  }

  static void AddRecordOutput(
    List<String> Args, {
    required FFmpegService FFmpeg,
    required AppDirectories Directories,
    required String Encoder,
    required String VideoMap,
    required String? AudioMap,
    required int Fps,
    required String RateText,
    required int Quality,
  }) {
    Args.addAll(<String>['-map', VideoMap]);
    if (AudioMap != null) {
      Args.addAll(<String>['-map', AudioMap]);
    } else {
      Args.addAll(<String>['-an']);
    }
    Args.addAll(<String>[
      '-c:v', Encoder,
      ...FFmpeg.QualityArgs(Encoder, Quality),
      '-pix_fmt', 'yuv420p',
      '-g', '${Fps * 2}',
      '-keyint_min', '${Fps * 2}',
      '-r', RateText,
      '-fps_mode', 'cfr',
    ]);
    if (AudioMap != null) Args.addAll(AudioArgs());
    Args.addAll(<String>[
      '-f', 'segment',
      '-segment_time', '600',
      '-segment_format', 'mp4',
      '-segment_format_options', 'movflags=+frag_keyframe+empty_moov+default_base_moof',
      '-reset_timestamps', '1',
      '-strftime', '1',
      '${Directories.Cache}${Platform.pathSeparator}Cache-%Y%m%d-%H%M%S.mp4',
    ]);
  }

  static List<String> AudioArgs() => <String>['-c:a', 'aac', '-b:a', '${Config.AudioBitrate}', '-ar', '${Config.AudioSampleRate}', '-ac', '${Config.AudioChannels}'];

  static String LiveEncoder(String Encoder) {
    if (Encoder.contains('nvenc')) return 'h264_nvenc';
    if (Encoder.contains('qsv')) return 'h264_qsv';
    if (Encoder.contains('amf')) return 'h264_amf';
    return 'libx264';
  }

  static List<String> LiveRateArgs(String Encoder) {
    if (Encoder.contains('nvenc')) {
      return <String>['-preset', 'p1', '-tune', 'ull', '-rc', 'constqp', '-qp', '20', '-bf', '0', '-rc-lookahead', '0', '-delay', '0', '-zerolatency', '1'];
    }
    if (Encoder.contains('qsv')) {
      return <String>['-preset', 'veryfast', '-global_quality', '20', '-bf', '0'];
    }
    if (Encoder.contains('amf')) {
      return <String>['-quality', 'speed', '-rc', 'cqp', '-qp_i', '20', '-qp_p', '20', '-qp_b', '20', '-bf', '0'];
    }
    return <String>['-preset', 'ultrafast', '-tune', 'zerolatency', '-crf', '20', '-bf', '0'];
  }
}
