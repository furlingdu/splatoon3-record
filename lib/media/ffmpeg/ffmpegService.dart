import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../config/constants.dart';
import '../../config/system.dart';
import '../../domain/models.dart';
import 'runner.dart';

const Utf8Codec OutputEncoding = Utf8Codec(allowMalformed: true);

class FFmpegService {
  FFmpegService(this.Directories);

  final AppDirectories Directories;
  String? _Path;
  String? _Encoder;
  String? _EncoderNote;
  String? _ArchiveEncoder;
  String? _ArchiveNote;
  String? _EncoderText;
  String? _Version;
  String? _PlayPath;
  Future<String>? _Extracting;
  Future<String>? _PlayExtracting;
  final Map<String, String?> _EncoderStates = <String, String?>{};
  List<CaptureDevice> _Devices = <CaptureDevice>[];
  final Map<String, List<CaptureMode>> _Modes = <String, List<CaptureMode>>{};

  String? get EncoderNote => _EncoderNote;
  String? get ArchiveNote => _ArchiveNote;

  Future<String> Version() async {
    if (PlatformInfo.Mobile) return '';
    final Cached = _Version;
    if (Cached != null) return Cached;
    try {
      final Out = await Run(<String>['-hide_banner', '-version'], Timeout: const Duration(seconds: 8));
      final Line = '${Out.stdout}${Out.stderr}'.split(RegExp(r'\r?\n')).firstWhere((Item) => Item.trim().isNotEmpty, orElse: () => '');
      _Version = Line.split(' Copyright').first.replaceFirst('ffmpeg version ', '').trim();
    } catch (_) {
      return '';
    }
    return _Version ?? '';
  }

  Future<String> Ensure() {
    if (PlatformInfo.Mobile) return Future<String>.value('');
    final Cached = _Path;
    if (Cached != null && (Cached == 'ffmpeg' || File(Cached).existsSync())) return Future<String>.value(Cached);
    final Pending = _Extracting;
    if (Pending != null) return Pending;
    final Task = _Extract();
    _Extracting = Task;
    return Task.whenComplete(() {
      if (identical(_Extracting, Task)) _Extracting = null;
    });
  }

  Future<String> _Extract() async {
    final Asset = Platform.isWindows ? Config.FFmpegAsset : Config.FFmpegAssetUnix;
    final Name = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    final Target = '${Directories.Cache}${Platform.pathSeparator}Tools${Platform.pathSeparator}$Name';
    try {
      final Data = await rootBundle.load(Asset);
      if (Data.lengthInBytes > 1000000) {
        final FileRef = File(Target);
        if (!FileRef.existsSync() || FileRef.lengthSync() != Data.lengthInBytes) {
          await FileRef.parent.create(recursive: true);
          final Temp = File('$Target.$pid.tmp');
          try {
            await Temp.writeAsBytes(Data.buffer.asUint8List(Data.offsetInBytes, Data.lengthInBytes), flush: true);
            await Temp.rename(Target);
          } catch (_) {
            try {
              await Temp.delete();
            } catch (_) {}
          }
          if (!Platform.isWindows) await Process.run('chmod', <String>['755', Target]);
        }
        if (File(Target).existsSync()) {
          _Path = Target;
          return Target;
        }
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

  Future<String> EnsureFFplay() {
    final Cached = _PlayPath;
    if (Cached != null && File(Cached).existsSync()) return Future<String>.value(Cached);
    if (!Platform.isWindows) return Future<String>.error(StateError('声音返听暂不支持当前平台'));
    final Pending = _PlayExtracting;
    if (Pending != null) return Pending;
    final Task = _ExtractPlay();
    _PlayExtracting = Task;
    return Task.whenComplete(() {
      if (identical(_PlayExtracting, Task)) _PlayExtracting = null;
    });
  }

  Future<String> _ExtractPlay() async {
    final Target = '${Directories.Cache}${Platform.pathSeparator}Tools${Platform.pathSeparator}ffplay.exe';
    final FileRef = File(Target);
    if (!FileRef.existsSync() || FileRef.lengthSync() < 1000000) {
      await FileRef.parent.create(recursive: true);
      final Data = await rootBundle.load(Config.FFplayAsset);
      final Temp = File('$Target.$pid.tmp');
      try {
        await Temp.writeAsBytes(Data.buffer.asUint8List(Data.offsetInBytes, Data.lengthInBytes), flush: true);
        await Temp.rename(Target);
      } catch (_) {
        try {
          await Temp.delete();
        } catch (_) {}
      }
      if (!FileRef.existsSync()) throw StateError('无法解压 ffplay');
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
    if (Value.Encoder == 'software' && !PlatformInfo.Mobile) {
      _EncoderNote = null;
      return 'libx264';
    }
    if (_Encoder != null && Value.Encoder == 'auto') return _Encoder!;
    final Text = await _Encoders();
    final Rejected = <String>[];
    for (final Name in EncoderOrder(Value)) {
      if (!Text.contains(Name)) continue;
      if (!PlatformInfo.Mobile && !await Probe(Name)) {
        final Reason = _EncoderStates[Name];
        Rejected.add(Reason == null ? EncoderLabel(Name) : '${EncoderLabel(Name)}（$Reason）');
        continue;
      }
      _Encoder = Name;
      _EncoderNote = Rejected.isEmpty ? null : '${Rejected.join('、')}不可用，已改用${EncoderLabel(Name)}';
      return Name;
    }
    _Encoder = 'libx264';
    _EncoderNote = Rejected.isEmpty ? null : '${Rejected.join('、')}不可用，已改用软件编码';
    return 'libx264';
  }

  Future<String> ArchiveEncoder(RecordSettings Value) async {
    final Cached = _ArchiveEncoder;
    if (Cached != null) return Cached;
    final Text = await _Encoders();
    final Rejected = <String>[];
    for (final Name in ArchiveEncoderOrder(Value)) {
      if (!Text.contains(Name)) {
        Rejected.add('${EncoderLabel(Name)}（捆绑 FFmpeg 未包含）');
        continue;
      }
      if (!PlatformInfo.Mobile && !await Probe(Name)) {
        final Reason = _EncoderStates[Name];
        Rejected.add(Reason == null ? EncoderLabel(Name) : '${EncoderLabel(Name)}（$Reason）');
        continue;
      }
      _ArchiveEncoder = Name;
      _ArchiveNote = Rejected.isEmpty ? null : '${Rejected.join('、')}不可用，已改用${EncoderLabel(Name)}';
      return Name;
    }
    _ArchiveEncoder = 'libx265';
    _ArchiveNote = Rejected.isEmpty ? null : '${Rejected.join('、')}不可用，已改用软件编码';
    return 'libx265';
  }

  Future<String> _Encoders() async {
    final Cached = _EncoderText;
    if (Cached != null) return Cached;
    final Out = await Run(<String>['-hide_banner', '-encoders'], Timeout: const Duration(seconds: 30));
    final Text = '${Out.stdout}${Out.stderr}';
    if (Text.isNotEmpty) _EncoderText = Text;
    return Text;
  }

  static List<String> EncoderOrder(RecordSettings Value) {
    if (PlatformInfo.IOS) return <String>[Config.VideoToolbox, 'libx264'];
    if (PlatformInfo.Android) return <String>[Config.MediaCodec, 'libx264'];
    if (Value.Encoder == 'nvidia') return <String>['h264_nvenc', 'libx264'];
    if (Value.Encoder == 'amd') return <String>['h264_amf', 'libx264'];
    if (Value.Encoder == 'intel') return <String>['h264_qsv', 'libx264'];
    return <String>['h264_nvenc', 'h264_qsv', 'h264_amf', 'libx264'];
  }

  static List<String> ArchiveEncoderOrder(RecordSettings Value) {
    if (PlatformInfo.IOS) return <String>['hevc_videotoolbox', 'libx265'];
    if (PlatformInfo.Android) return <String>['hevc_mediacodec', 'libx265'];
    if (PlatformInfo.MacOS) return <String>['hevc_videotoolbox', 'libx265'];
    if (Value.Encoder == 'nvidia') return <String>['hevc_nvenc', 'libx265'];
    if (Value.Encoder == 'amd') return <String>['hevc_amf', 'libx265'];
    if (Value.Encoder == 'intel') return <String>['hevc_qsv', 'libx265'];
    return <String>['hevc_nvenc', 'hevc_qsv', 'hevc_amf', 'libx265'];
  }

  Future<bool> Probe(String Name) async {
    if (_EncoderStates.containsKey(Name)) return _EncoderStates[Name] == null;
    final Out = await Run(<String>[
      '-hide_banner', '-nostdin', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'color=c=black:s=256x256:r=30:d=0.2',
      '-c:v', Name, '-pix_fmt', 'yuv420p', '-f', 'null', '-',
    ], Timeout: const Duration(seconds: 8));
    if (Out.exitCode == 0) {
      _EncoderStates[Name] = null;
      return true;
    }
    final Hint = EncoderHint('${Out.stderr}${Out.stdout}');
    _EncoderStates[Name] = Out.stderr == 'timeout' ? '编码器初始化超时' : (Hint.isEmpty ? '编码器初始化失败' : Hint);
    return false;
  }

  static String EncoderLabel(String Name) {
    if (Name.contains('nvenc')) return 'NVIDIA NVENC';
    if (Name.contains('qsv')) return 'Intel QSV';
    if (Name.contains('amf')) return 'AMD AMF';
    if (Name.contains('videotoolbox')) return 'VideoToolbox';
    if (Name.contains('mediacodec')) return 'MediaCodec';
    return '软件编码';
  }

  static String EncoderHint(String Text) {
    final Lower = Text.toLowerCase();
    final Driver = RegExp(r'minimum required nvidia driver for nvenc is ([\d.]+)').firstMatch(Lower);
    if (Lower.contains('nvenc api version') || Lower.contains('required nvenc') || Lower.contains('minimum required nvidia driver')) {
      return Driver == null ? 'NVIDIA 驱动版本过低，需要更新显卡驱动' : 'NVIDIA 驱动版本过低，需要 ${Driver.group(1)} 或更新版本';
    }
    if (Lower.contains('cannot load nvcuda') || Lower.contains('no capable devices') || Lower.contains('nvenc is not supported')) {
      return '未检测到支持 NVENC 的 NVIDIA 显卡';
    }
    if (Lower.contains('no free encoding sessions') || Lower.contains('openencodesessionex failed')) {
      return '硬件编码会话已满，请关闭其他录制或直播软件';
    }
    if (Lower.contains('mfx session') || Lower.contains('mfx') || Lower.contains('qsv')) {
      return 'Intel QSV 硬件编码不可用，请更新核显驱动';
    }
    if (Lower.contains('amf') || Lower.contains('createcomponent')) {
      return 'AMD AMF 硬件编码不可用，请更新显卡驱动';
    }
    if (Lower.contains('unknown encoder')) return '当前 FFmpeg 未包含该编码器';
    if (Lower.contains('error while opening encoder') || Lower.contains('could not open encoder') || Lower.contains('error initializing')) {
      return '编码器初始化失败';
    }
    return '';
  }

  List<String> QualityArgs(String Encoder, int Quality) {
    final Q = '$Quality';
    if (Encoder == Config.VideoToolbox || Encoder == Config.MediaCodec) {
      final Bitrate = Quality >= 28 ? 6000 : Quality >= 22 ? 10000 : 16000;
      return <String>['-b:v', '${Bitrate}k', '-maxrate', '${Bitrate}k', '-bufsize', '${Bitrate * 2}k'];
    }
    if (Encoder == 'hevc_videotoolbox' || Encoder == 'hevc_mediacodec') {
      final Bitrate = Quality >= 28 ? 8000 : Quality >= 22 ? 14000 : 24000;
      return <String>['-b:v', '${Bitrate}k', '-maxrate', '${Bitrate}k', '-bufsize', '${Bitrate * 2}k'];
    }
    if (Encoder == 'h264_nvenc') return <String>['-preset', 'p1', '-rc', 'constqp', '-qp', Q];
    if (Encoder == 'hevc_nvenc') return <String>['-preset', 'p4', '-tune', 'hq', '-rc', 'constqp', '-qp', Q];
    if (Encoder == 'h264_qsv') return <String>['-preset', 'medium', '-global_quality', Q];
    if (Encoder == 'hevc_qsv') return <String>['-preset', 'medium', '-global_quality', Q];
    if (Encoder == 'h264_amf') return <String>['-quality', 'quality', '-rc', 'cqp', '-qp_i', Q, '-qp_p', Q, '-qp_b', Q];
    if (Encoder == 'hevc_amf') return <String>['-quality', 'quality', '-rc', 'cqp', '-qp_i', Q, '-qp_p', Q, '-qp_b', Q];
    if (Encoder == 'libx264') return <String>['-preset', 'veryfast', '-crf', Q, '-profile:v', 'high'];
    if (Encoder == 'libx265') {
      final Threads = (Platform.numberOfProcessors ~/ 2).clamp(2, 8).toInt();
      return <String>['-preset', 'veryfast', '-crf', Q, '-threads', '$Threads', '-x265-params', 'log-level=error'];
    }
    return <String>['-preset', 'veryfast', '-crf', Q];
  }

  List<String> ArchiveVideoArgs(String Encoder, int Quality) {
    return <String>['-c:v', Encoder, ...QualityArgs(Encoder, Quality), '-tag:v', 'hvc1'];
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















