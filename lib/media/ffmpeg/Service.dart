import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../config/Config.dart';
import '../../config/PlatformInfo.dart';
import '../../domain/Models.dart';
import 'MediaRunner.dart';

const Utf8Codec OutputEncoding = Utf8Codec(allowMalformed: true);

class FFmpegService {
  FFmpegService(this.Directories);

  final AppDirectories Directories;
  String? _Path;
  String? _Encoder;
  String? _PlayPath;
  List<CaptureDevice> _Devices = <CaptureDevice>[];
  final Map<String, List<CaptureMode>> _Modes = <String, List<CaptureMode>>{};

  Future<String> Ensure() async {
    if (PlatformInfo.Mobile) return '';
    if (_Path != null && (_Path == 'ffmpeg' || File(_Path!).existsSync())) return _Path!;
    final Asset = Platform.isWindows ? Config.FFmpegAsset : Config.FFmpegAssetUnix;
    final Name = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    try {
      final Data = await rootBundle.load(Asset);
      if (Data.lengthInBytes > 1000000) {
        final Target = '${Directories.Cache}${Platform.pathSeparator}Tools${Platform.pathSeparator}$Name';
        final FileRef = File(Target);
        if (!FileRef.existsSync() || FileRef.lengthSync() != Data.lengthInBytes) {
          await FileRef.parent.create(recursive: true);
          await FileRef.writeAsBytes(Data.buffer.asUint8List(Data.offsetInBytes, Data.lengthInBytes), flush: true);
          if (!Platform.isWindows) await Process.run('chmod', <String>['755', Target]);
        }
        _Path = Target;
        return Target;
      }
    } catch (_) {}
    if (!Platform.isWindows) {
      final Probe = await Process.run('ffmpeg', <String>['-version'], stdoutEncoding: OutputEncoding, stderrEncoding: OutputEncoding);
      if (Probe.exitCode != 0) throw StateError('未找到 ffmpeg，请先安装并加入 PATH');
      _Path = 'ffmpeg';
      return _Path!;
    }
    throw StateError('未找到 ffmpeg');
  }

  Future<ProcessResult> Run(List<String> Args, {Duration Timeout = const Duration(seconds: 20)}) async {
    if (PlatformInfo.Mobile) return KitMediaRunner.Run(Args, Timeout);
    final Exe = await Ensure();
    final Task = Process.run(Exe, Args, stdoutEncoding: OutputEncoding, stderrEncoding: OutputEncoding);
    return Task.timeout(Timeout, onTimeout: () => ProcessResult(0, -1, '', 'timeout'));
  }

  Future<bool> Thumbnail(String Video, String Output) async {
    if (!File(Video).existsSync()) return false;
    final Out = await Run(<String>['-hide_banner', '-loglevel', 'error', '-y', '-ss', '1', '-i', Video, '-frames:v', '1', '-vf', 'scale=480:-2', '-q:v', '4', Output], Timeout: const Duration(seconds: 40));
    return Out.exitCode == 0 && File(Output).existsSync();
  }

  Future<String> EnsureFFplay() async {
    if (_PlayPath != null && File(_PlayPath!).existsSync()) return _PlayPath!;
    if (!Platform.isWindows) throw StateError('声音返听暂不支持当前平台');
    final Target = '${Directories.Cache}${Platform.pathSeparator}Tools${Platform.pathSeparator}ffplay.exe';
    final FileRef = File(Target);
    if (!FileRef.existsSync() || FileRef.lengthSync() < 1000000) {
      await FileRef.parent.create(recursive: true);
      final Data = await rootBundle.load(Config.FFplayAsset);
      await FileRef.writeAsBytes(Data.buffer.asUint8List(Data.offsetInBytes, Data.lengthInBytes), flush: true);
    }
    _PlayPath = Target;
    return Target;
  }

  Future<List<CaptureDevice>> Devices({bool Refresh = false}) async {
    if (_Devices.isNotEmpty && !Refresh) return _Devices;
    final List<CaptureDevice> Result = <CaptureDevice>[];
    if (Platform.isWindows) {
      final Out = await Run(<String>['-hide_banner', '-list_devices', 'true', '-f', 'dshow', '-i', 'dummy']);
      final Lines = '${Out.stderr}'.split(RegExp(r'\r?\n'));
      final VideoNames = <String>{};
      final AudioNames = <String>{};
      for (final Line in Lines) {
        final Match = RegExp(r'"([^"]+)" \((video|audio)\)').firstMatch(Line);
        if (Match == null) continue;
        final Name = Match.group(1)!;
        final Kind = Match.group(2)!;
        if (Kind == 'video' && VideoNames.add(Name)) {
          Result.add(CaptureDevice(Id: Name, Name: Name, Kind: 'video'));
        }
        if (Kind == 'audio' && AudioNames.add(Name)) {
          Result.add(CaptureDevice(Id: Name, Name: Name, Kind: 'audio'));
        }
      }
    } else if (Platform.isMacOS) {
      final Out = await Run(<String>['-hide_banner', '-f', 'avfoundation', '-list_devices', 'true', '-i', '']);
      final Lines = '${Out.stderr}'.split(RegExp(r'\r?\n'));
      for (final Line in Lines) {
        final Match = RegExp(r'\[(\d+)\] (.+)').firstMatch(Line);
        if (Match == null) continue;
        final Index = Match.group(1)!;
        final Name = Match.group(2)!.trim();
        if (Name.toLowerCase().contains('audio')) {
          Result.add(CaptureDevice(Id: Index, Name: Name, Kind: 'audio'));
        } else if (!Name.toLowerCase().contains('capture screen') && !Name.startsWith('AVFoundation')) {
          Result.add(CaptureDevice(Id: Index, Name: Name, Kind: 'video'));
        }
      }
    } else {
      List<FileSystemEntity> Nodes;
      try {
        Nodes = Directory('/dev').listSync().where((Item) => Item.path.startsWith('/dev/video')).toList();
      } catch (_) {
        Nodes = <FileSystemEntity>[];
      }
      for (final Node in Nodes) {
        final Path = Node.path;
        final NameMatch = RegExp(r'video(\d+)$').firstMatch(Path);
        if (NameMatch == null) continue;
        Result.add(CaptureDevice(Id: Path, Name: 'Video ${NameMatch.group(1)}', Kind: 'video'));
      }
      for (final Entry in <String>['default', 'pulse']) {
        Result.add(CaptureDevice(Id: Entry, Name: Entry == 'default' ? '默认音频' : 'PulseAudio', Kind: 'audio'));
      }
    }
    _Devices = Result;
    return Result;
  }

  Future<List<CaptureMode>> Modes(String VideoDevice) async {
    final Cached = _Modes[VideoDevice];
    if (Cached != null) return Cached;
    final List<CaptureMode> Result = <CaptureMode>[];
    if (Platform.isWindows) {
      final Out = await Run(<String>['-hide_banner', '-list_options', 'true', '-f', 'dshow', '-i', 'video=$VideoDevice'], Timeout: const Duration(seconds: 15));
      for (final Line in '${Out.stderr}'.split(RegExp(r'\r?\n'))) {
        final Match = RegExp(r'pixel_format=(\w+)\s+min s=(\d+)x(\d+) fps=([\d.]+) max s=(\d+)x(\d+) fps=([\d.]+)').firstMatch(Line);
        if (Match == null) continue;
        final RawFormat = Match.group(1)!.toLowerCase();
        final Format = RawFormat == 'yuyv422' || RawFormat == 'yuy2'
            ? 'yuy2'
            : RawFormat == 'mjpeg'
                ? 'mjpeg'
                : RawFormat == 'nv12'
                    ? 'nv12'
                    : '';
        if (Format.isEmpty) continue;
        final MinFps = double.tryParse(Match.group(4)!)?.round() ?? 1;
        final MaxFps = double.tryParse(Match.group(7)!)?.round() ?? MinFps;
        for (final Fps in <int>{MinFps, MaxFps, if (MinFps <= 60 && MaxFps >= 60) 60}.where((Item) => Item > 0)) {
          for (final Size in <List<int>>[
            <int>[int.parse(Match.group(2)!), int.parse(Match.group(3)!)],
            <int>[int.parse(Match.group(5)!), int.parse(Match.group(6)!)],
          ]) {
            if (Result.any((Item) => Item.Format == Format && Item.Width == Size[0] && Item.Height == Size[1] && Item.MaxFps >= Fps)) continue;
            Result.add(CaptureMode(Format: Format, Width: Size[0], Height: Size[1], MinFps: MinFps, MaxFps: Fps));
          }
        }
      }
      final FullHdModes = Result.where((Item) => Item.Width == 1920 && Item.Height == 1080).toList();
      final MjpegFps = FullHdModes.map((Item) => Item.MaxFps).toSet().toList()..sort();
      for (final Fps in MjpegFps) {
        if (!Result.any((Item) => Item.Format == 'mjpeg' && Item.Width == 1920 && Item.Height == 1080 && Item.MaxFps == Fps)) {
          Result.add(CaptureMode(Format: 'mjpeg', Width: 1920, Height: 1080, MinFps: Fps, MaxFps: Fps));
        }
      }
    }
    _Modes[VideoDevice] = Result;
    return Result;
  }

  CaptureMode? PickMode(RecordSettings Value, List<CaptureMode> Available) {
    if (Available.isEmpty) return null;
    final Matching = Available.where((Item) => Item.Format == Value.CaptureFormat).toList();
    final PoolBase = Matching.isEmpty ? Available : Matching;
    final Exact = PoolBase.where((Item) => Item.Width == Value.Width && Item.Height == Value.Height).toList();
    final Pool = Exact.isNotEmpty ? Exact : (PoolBase.toList()..sort((Left, Right) => (Left.Width * Left.Height - Value.Width * Value.Height).abs().compareTo((Right.Width * Right.Height - Value.Width * Value.Height).abs())));
    final Best = Pool.where((Item) => Item.MaxFps == Value.Fps).toList();
    if (Best.isNotEmpty) return Best.first;
    final AtLeast = Pool.where((Item) => Item.MaxFps >= Value.Fps).toList();
    return AtLeast.isNotEmpty ? AtLeast.first : Pool.first;
  }

  Future<String> Encoder(RecordSettings Value) async {
    if (Value.Encoder == 'software' && !PlatformInfo.Mobile) return 'libx264';
    if (_Encoder != null && Value.Encoder == 'auto') return _Encoder!;
    final Out = await Run(<String>['-hide_banner', '-encoders'], Timeout: const Duration(seconds: 30));
    final Text = '${Out.stdout}${Out.stderr}';
    final Candidate = PlatformInfo.IOS
        ? <String>[Config.VideoToolbox, 'libx264']
        : PlatformInfo.Android
            ? <String>[Config.MediaCodec, 'libx264']
            : Value.Encoder == 'nvidia'
                ? <String>['h264_nvenc', 'libx264']
                : Value.Encoder == 'amd'
                    ? <String>['h264_amf', 'libx264']
                    : Value.Encoder == 'intel'
                        ? <String>['h264_qsv', 'libx264']
                        : <String>['h264_nvenc', 'h264_qsv', 'h264_amf', 'libx264'];
    for (final Name in Candidate) {
      if (Text.contains(Name)) {
        _Encoder = Name;
        return Name;
      }
    }
    _Encoder = 'libx264';
    return 'libx264';
  }

  List<String> QualityArgs(String Encoder, int Quality) {
    final Q = '$Quality';
    if (Encoder == Config.VideoToolbox || Encoder == Config.MediaCodec) {
      final Bitrate = Quality >= 28 ? 6000 : Quality >= 22 ? 10000 : 16000;
      return <String>['-b:v', '${Bitrate}k', '-maxrate', '${Bitrate}k', '-bufsize', '${Bitrate * 2}k'];
    }
    if (Encoder == 'h264_nvenc' || Encoder == 'hevc_nvenc') return <String>['-preset', 'p1', '-rc', 'constqp', '-qp', Q];
    if (Encoder == 'h264_qsv' || Encoder == 'hevc_qsv') return <String>['-preset', 'medium', '-global_quality', Q];
    if (Encoder == 'h264_amf' || Encoder == 'hevc_amf') return <String>['-quality', 'quality', '-rc', 'cqp', '-qp_i', Q, '-qp_p', Q, '-qp_b', Q];
    if (Encoder == 'libx264') return <String>['-preset', 'veryfast', '-crf', Q, '-profile:v', 'high'];
    return <String>['-preset', 'veryfast', '-crf', Q];
  }

  List<String> InputArgs(RecordSettings Value) {
    final List<String> Args = <String>[];
    if (Value.CaptureMode == 'rtmp') {
      Args.addAll(<String>[
        '-fflags', 'nobuffer',
        '-flags', 'low_delay',
        '-rw_timeout', '5000000',
        '-i', 'rtmp://127.0.0.1:${Value.RtmpPort}/live/${Value.RtmpStreamKey}',
      ]);
      return Args;
    }
    if (Value.VideoDevice.isEmpty) throw StateError('未选择采集设备');
    if (Platform.isWindows) {
      Args.addAll(<String>[
        '-rtbufsize', Config.CaptureBuffer,
        '-fflags', 'nobuffer',
        '-flags', 'low_delay',
        '-f', 'dshow',
        '-video_size', '${Value.Width}x${Value.Height}',
        '-framerate', '${Value.Fps}',
      ]);
      if (Value.CaptureFormat == 'mjpeg') {
        Args.addAll(<String>['-vcodec', 'mjpeg', '-i', 'video=${Value.VideoDevice}']);
      } else {
        final PixelFormat = Value.CaptureFormat == 'yuy2' ? 'yuyv422' : 'nv12';
        Args.addAll(<String>['-pixel_format', PixelFormat, '-i', 'video=${Value.VideoDevice}']);
      }
      if (Value.AudioDevice.isNotEmpty) {
        Args.addAll(<String>['-rtbufsize', '4M', '-f', 'dshow', '-i', 'audio=${Value.AudioDevice}']);
      }
      if (Value.MicAudio && Value.MicDevice.isNotEmpty) {
        Args.addAll(<String>['-rtbufsize', '4M', '-f', 'dshow', '-i', 'audio=${Value.MicDevice}']);
      }
    } else if (Platform.isMacOS) {
      Args.addAll(<String>['-f', 'avfoundation', '-framerate', '${Value.Fps}', '-i', '${Value.VideoDevice}:${Value.AudioDevice.isEmpty ? 'none' : Value.AudioDevice}']);
    } else {
      Args.addAll(<String>['-f', 'v4l2', '-input_format', Value.CaptureFormat == 'yuy2' ? 'yuyv422' : Value.CaptureFormat == 'mjpeg' ? 'mjpeg' : 'nv12', '-video_size', '${Value.Width}x${Value.Height}', '-framerate', '${Value.Fps}', '-i', Value.VideoDevice]);
      if (Value.AudioDevice.isNotEmpty) {
        Args.addAll(<String>['-f', 'pulse', '-i', '${Value.AudioDevice}']);
      }
    }
    return Args;
  }

  String SegmentPattern() => '${Directories.Cache}${Platform.pathSeparator}Cache-%Y%m%d-%H%M%S.mp4';
}















