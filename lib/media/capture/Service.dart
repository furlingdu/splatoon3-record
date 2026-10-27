import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../config/Config.dart';
import '../../config/PlatformInfo.dart';
import '../../domain/Models.dart';
import '../ffmpeg/Service.dart';
import '../nickname/Detector.dart';
import 'CaptureArguments.dart';
import 'CaptureBridge.dart';

class CaptureService {
  CaptureService(this.Directories, this.FFmpeg) {
    _Events = CaptureBridge.Events.receiveBroadcastStream().listen(_OnEvent, onError: (Object Cause) {
      unawaited(Log('capture events $Cause'));
    });
  }

  final AppDirectories Directories;
  final FFmpegService FFmpeg;
  final ValueNotifier<String?> Error = ValueNotifier<String?>(null);
  final ValueNotifier<String> State = ValueNotifier<String>('idle');
  final ValueNotifier<VideoRecord?> LatestRecord = ValueNotifier<VideoRecord?>(null);
  final ValueNotifier<String?> MonitorError = ValueNotifier<String?>(null);
  final ValueNotifier<bool> MonitorActive = ValueNotifier<bool>(false);
  final ValueNotifier<int?> PreviewTexture = ValueNotifier<int?>(null);
  final ValueNotifier<bool> PreviewActive = ValueNotifier<bool>(false);
  final ValueNotifier<Map<String, dynamic>?> Stats = ValueNotifier<Map<String, dynamic>?>(null);

  late final StreamSubscription<dynamic> _Events;
  Process? _Process;
  Process? _MonitorProcess;
  RecordSettings? _Active;
  String? _Encoder;
  String? _LiveUrl;
  String _StderrTail = '';
  Timer? _Sweep;
  bool _Stopping = false;
  Completer<void>? _Ready;
  Timer? _MaskTimer;
  NicknameDetector? _Detector;
  final List<int> _RawFrames = <int>[];
  bool _MaskBusy = false;
  Uint8List? _MaskFrame;
  final StringBuffer _LogBuffer = StringBuffer();
  Timer? _LogTimer;
  bool _LogBusy = false;
  Completer<void>? _RecordWaiter;
  Completer<void>? _IdleWaiter;
  bool _NativeRunning = false;
  bool _FallbackBlur = false;
  bool _MaskPipeOpen = false;
  CapturePrepared? _Prepared;
  Timer? _NativeMaskTimer;
  int _LastStatsLog = 0;

  bool get Running => State.value == 'recording';
  bool get Starting => State.value == 'starting';
  String? get EncoderName => _Encoder;
  String? get LiveTarget => _LiveUrl;
  int get ActualWidth => _Prepared?.Width ?? _Active?.Width ?? 1920;
  int get ActualHeight => _Prepared?.Height ?? _Active?.Height ?? 1080;
  int get ActualFps => _Prepared?.Fps ?? _Active?.Fps ?? 60;
  String get ActualFormat => _Prepared?.Format.toUpperCase() ?? _Active?.CaptureFormat.toUpperCase() ?? 'NV12';

  Future<List<CaptureDevice>> Devices({bool Refresh = false}) async {
    if (CaptureBridge.Supported) {
      try {
        return await CaptureBridge.Enumerate();
      } catch (_) {
        return <CaptureDevice>[];
      }
    }
    return FFmpeg.Devices(Refresh: Refresh);
  }

  Future<List<CaptureMode>> Modes(String Device) async {
    if (CaptureBridge.Supported) {
      try {
        return await CaptureBridge.Modes(Device);
      } catch (_) {
        return <CaptureMode>[];
      }
    }
    return FFmpeg.Modes(Device);
  }

  Future<void> Start(RecordSettings Value, {String? LiveUrl, bool Record = true}) async {
    await Stop();
    _Active = Value;
    _Prepared = null;
    _LiveUrl = LiveUrl;
    _StderrTail = '';
    Error.value = null;
    State.value = 'starting';
    if (Value.CaptureMode == 'rtmp' || !CaptureBridge.Supported) {
      await _StartFallback(Value, LiveUrl: LiveUrl, Record: Record);
      return;
    }
    try {
      final Devices = await this.Devices();
      if (Value.VideoDevice.isEmpty) throw StateError('未选择采集设备');
      if (!Devices.any((Item) => Item.Kind == 'video' && Item.Id == Value.VideoDevice)) {
        throw StateError('未找到所选采集设备，请到设置页重新选择');
      }
      var Use = Value;
      if (Use.AudioDevice.isNotEmpty && !Devices.any((Item) => Item.Kind == 'audio' && Item.Id == Use.AudioDevice)) {
        Use = Use.Copy(<String, dynamic>{'audioDevice': ''});
      }
      _Active = Use;
      final Encoder = await FFmpeg.Encoder(Use);
      _Encoder = Encoder;
      final Exe = await FFmpeg.Ensure();
      final Prepared = await CaptureBridge.Prepare(Use);
      _Prepared = Prepared;
      final Live = LiveUrl != null && LiveUrl.isNotEmpty;
      final Writer = Record || Live;
      final Blur = Live && Use.BlurNickname;
      String? MaskPipe;
      if (Blur) {
        MaskPipe = await CaptureBridge.OpenMaskPipe();
        if (MaskPipe == null || MaskPipe.isEmpty) throw StateError('无法创建直播打码通道');
        _MaskPipeOpen = true;
      }
      final Args = PlatformInfo.MacOS
          ? CaptureArguments.Mac(
              Value: Use,
              FFmpeg: FFmpeg,
              Directories: Directories,
              Encoder: Encoder,
              Width: Prepared.Width,
              Height: Prepared.Height,
              Fps: Prepared.Fps,
              RateText: Prepared.RateText,
              Record: Record,
            )
          : CaptureArguments.Native(
              Value: Use,
              FFmpeg: FFmpeg,
              Directories: Directories,
              Encoder: Encoder,
              Width: Prepared.Width,
              Height: Prepared.Height,
              Fps: Prepared.Fps,
              RateText: Prepared.RateText,
              LiveTarget: Live ? LiveUrl : null,
              Record: Record,
              MaskPipe: MaskPipe,
            );
      _RecordWaiter = Completer<void>();
      await CaptureBridge.Start(Exe, Args, Prepared.Rate, Writer);
      _NativeRunning = true;
      await _RecordWaiter!.future.timeout(const Duration(seconds: 15));
      PrepareLog();
      _LogTimer?.cancel();
      _LogTimer = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(FlushLog()));
      final Texture = await CaptureBridge.PreviewTexture();
      PreviewTexture.value = Texture >= 0 ? Texture : null;
      PreviewActive.value = Texture >= 0;
      State.value = 'recording';
      LatestRecord.value = null;
      if (Blur) StartNativeMask();
      if (Use.MonitorAudio) await StartMonitor(Use);
    } catch (Cause) {
      final Text = Cause is StateError
          ? Cause.message
          : Cause is TimeoutException
              ? '采集启动超时，请检查采集卡是否被其他程序占用'
              : Cause is PlatformException
                  ? '${Cause.message ?? Cause.code}'
                  : '$Cause';
      await Stop();
      State.value = 'error';
      Error.value = Text;
      await Log('capture start failed $Text');
    }
  }

  Future<void> Stop({bool Fast = false}) async {
    final FallbackBlur = _FallbackBlur;
    _FallbackBlur = false;
    _NativeMaskTimer?.cancel();
    _NativeMaskTimer = null;
    _MaskTimer?.cancel();
    _MaskTimer = null;
    _RawFrames.clear();
    _Detector?.Release();
    _Detector = null;
    _MaskBusy = false;
    await StopMonitor();
    _LogTimer?.cancel();
    _LogTimer = null;
    await FlushLog();
    if (_NativeRunning) {
      _IdleWaiter = Completer<void>();
      try {
        await CaptureBridge.Stop(Fast: Fast);
        await _IdleWaiter!.future.timeout(Duration(seconds: Fast ? 3 : 7));
      } catch (_) {}
      _NativeRunning = false;
    }
    if (_MaskPipeOpen) {
      try {
        await CaptureBridge.CloseMaskPipe();
      } catch (_) {}
      _MaskPipeOpen = false;
    }
    await FlushLog();
    final ProcessRef = _Process;
    _Process = null;
    _Stopping = true;
    _Sweep?.cancel();
    _Sweep = null;
    if (ProcessRef != null) {
      if (FallbackBlur || Fast) {
        ProcessRef.kill();
      } else {
        try {
          ProcessRef.stdin.write('q');
          await ProcessRef.stdin.flush();
        } catch (_) {}
        try {
          await ProcessRef.exitCode.timeout(const Duration(seconds: 4));
        } catch (_) {
          ProcessRef.kill();
        }
      }
    }
    if (_RecordWaiter != null && !_RecordWaiter!.isCompleted) _RecordWaiter!.completeError(StateError('采集已停止'));
    _RecordWaiter = null;
    _IdleWaiter = null;
    State.value = 'idle';
    PreviewActive.value = false;
    _LiveUrl = null;
    _Ready = null;
  }

  Future<void> _StartFallback(RecordSettings Value, {String? LiveUrl, required bool Record}) async {
    try {
      final Encoder = await FFmpeg.Encoder(Value);
      _Encoder = Encoder;
      final Exe = await FFmpeg.Ensure();
      final Args = CaptureArguments.Fallback(
        Value: Value,
        FFmpeg: FFmpeg,
        Directories: Directories,
        Encoder: Encoder,
        LiveTarget: LiveUrl,
        Record: Record,
      );
      final Blur = LiveUrl != null && LiveUrl.isNotEmpty && Value.BlurNickname;
      final ProcessRef = await Process.start(Exe, Args, runInShell: false);
      PrepareLog();
      AppendLog('ARGS ${Args.join(' ')}\n');
      _LogTimer?.cancel();
      _LogTimer = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(FlushLog()));
      _Process = ProcessRef;
      _Stopping = false;
      _FallbackBlur = Blur;
      _Ready = Completer<void>();
      if (Blur) StartMask(ProcessRef);
      ProcessRef.stderr.transform(OutputEncoding.decoder).listen((Text) {
        AppendLog(Text);
        _StderrTail = '${_StderrTail}$Text';
        if (_StderrTail.length > 8000) _StderrTail = _StderrTail.substring(_StderrTail.length - 8000);
        if (Text.contains('frame=') || Text.contains('Opening')) {
          if (State.value == 'starting') State.value = 'recording';
          if (_Ready != null && !_Ready!.isCompleted) _Ready!.complete();
        }
        final Lower = Text.toLowerCase();
        if (Lower.contains('failed to update header')) return;
        if (Lower.contains('error') || Lower.contains('failed') || Lower.contains('could not') || Lower.contains('invalid')) {
          Error.value = Text.trim().split(RegExp(r'\r?\n')).lastWhere((Line) => Line.trim().isNotEmpty, orElse: () => Text.trim());
        }
      });
      ProcessRef.exitCode.then((Code) {
        if (_Stopping || _Process != ProcessRef) return;
        _Process = null;
        State.value = 'error';
        final Detail = _StderrTail.trim().split(RegExp(r'\r?\n')).where((Line) => Line.trim().isNotEmpty).toList();
        Error.value = Detail.isEmpty ? '采集进程退出 $Code' : Detail.last;
        if (_Ready != null && !_Ready!.isCompleted) _Ready!.completeError(StateError(Error.value ?? '采集失败'));
      });
      _Sweep?.cancel();
      _Sweep = Timer.periodic(const Duration(seconds: 60), (_) => Sweep());
      final Ready = _Ready!;
      await Ready.future.timeout(const Duration(seconds: 15), onTimeout: () {
        if (State.value == 'starting') State.value = 'recording';
      });
      State.value = 'recording';
      LatestRecord.value = null;
      if (Value.MonitorAudio) await StartMonitor(Value);
    } catch (Cause) {
      final Text = Cause is StateError ? Cause.message : '$Cause';
      await Stop();
      State.value = 'error';
      Error.value = Text;
    }
  }

  void _OnEvent(dynamic Raw) {
    if (Raw is! Map) return;
    final Data = Map<String, dynamic>.from(Raw);
    final Type = '${Data['type'] ?? ''}';
    if (Type == 'state') {
      final Value = '${Data['value'] ?? ''}';
      if (Value == 'recording') {
        State.value = 'recording';
        PreviewActive.value = true;
        if (_RecordWaiter != null && !_RecordWaiter!.isCompleted) _RecordWaiter!.complete();
      } else if (Value == 'idle') {
        State.value = 'idle';
        PreviewActive.value = false;
        if (_IdleWaiter != null && !_IdleWaiter!.isCompleted) _IdleWaiter!.complete();
      } else if (Value == 'starting') {
        if (State.value != 'error') State.value = 'starting';
      } else if (Value == 'error') {
        State.value = 'error';
        if (_RecordWaiter != null && !_RecordWaiter!.isCompleted) _RecordWaiter!.completeError(StateError(Error.value ?? '采集失败'));
      }
      return;
    }
    if (Type == 'error') {
      final Text = '${Data['text'] ?? '采集失败'}';
      Error.value = Text;
      State.value = 'error';
      if (_RecordWaiter != null && !_RecordWaiter!.isCompleted) _RecordWaiter!.completeError(StateError(Text));
      if (_IdleWaiter != null && !_IdleWaiter!.isCompleted) _IdleWaiter!.complete();
      unawaited(Log('capture error $Text'));
      return;
    }
    if (Type == 'log') {
      AppendLog('${Data['text'] ?? ''}\n');
      return;
    }
    if (Type == 'stats') {
      Stats.value = Data;
      final Now = DateTime.now().millisecondsSinceEpoch;
      if (Now - _LastStatsLog >= 5000) {
        _LastStatsLog = Now;
        unawaited(Log('capture stats ${Data['captureFps']}fps preview=${Data['previewFps']}fps convert=${Data['convertMs']}ms latency=${Data['latency']}ms dropped=${Data['dropped']} written=${Data['written']} dup=${Data['duplicated']} write=${Data['writeMs']}ms queue=${Data['queue']}'));
      }
    }
  }

  void StartNativeMask() {
    _Detector = NicknameDetector();
    _NativeMaskTimer?.cancel();
    _NativeMaskTimer = Timer.periodic(const Duration(milliseconds: 200), (_) => unawaited(NativeMaskTick()));
  }

  Future<void> NativeMaskTick() async {
    if (_MaskBusy || _Detector == null) return;
    _MaskBusy = true;
    try {
      final Frame = await CaptureBridge.Snapshot();
      if (Frame == null || Frame.length < Config.MaskWidth * Config.MaskHeight * 4) return;
      final Boxes = await _Detector!.Detect(Frame, Config.MaskWidth, Config.MaskHeight);
      final Mask = Uint8List(Config.MaskWidth * Config.MaskHeight);
      for (final Box in Boxes) {
        final Left = (Box.Left - 3).round().clamp(0, Config.MaskWidth - 1).toInt();
        final Top = (Box.Top - 3).round().clamp(0, Config.MaskHeight - 1).toInt();
        final Right = (Box.Left + Box.Width + 3).round().clamp(Left + 1, Config.MaskWidth).toInt();
        final Bottom = (Box.Top + Box.Height + 3).round().clamp(Top + 1, Config.MaskHeight).toInt();
        for (var Y = Top; Y < Bottom; Y++) {
          Mask.fillRange(Y * Config.MaskWidth + Left, Y * Config.MaskWidth + Right, 255);
        }
      }
      await CaptureBridge.Mask(Mask);
    } catch (_) {
    } finally {
      _MaskBusy = false;
    }
  }

  void StartMask(Process ProcessRef) {
    _Detector = NicknameDetector();
    _MaskFrame = Uint8List(Config.MaskWidth * Config.MaskHeight);
    _MaskTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final Mask = _MaskFrame;
      if (Mask == null) return;
      try {
        ProcessRef.stdin.add(Mask);
      } catch (_) {}
    });
    ProcessRef.stdout.listen((Data) {
      _RawFrames.addAll(Data);
      final FrameSize = Config.MaskWidth * Config.MaskHeight * 4;
      if (_RawFrames.length > FrameSize * 3) _RawFrames.removeRange(0, _RawFrames.length - FrameSize);
      while (_RawFrames.length >= FrameSize) {
        final Frame = Uint8List.fromList(_RawFrames.sublist(0, FrameSize));
        _RawFrames.removeRange(0, FrameSize);
        if (_MaskBusy) continue;
        _MaskBusy = true;
        _Detector?.Detect(Frame, Config.MaskWidth, Config.MaskHeight).then((Boxes) {
          final Mask = Uint8List(Config.MaskWidth * Config.MaskHeight);
          for (final Box in Boxes) {
            final Left = (Box.Left - 3).round().clamp(0, Config.MaskWidth - 1).toInt();
            final Top = (Box.Top - 3).round().clamp(0, Config.MaskHeight - 1).toInt();
            final Right = (Box.Left + Box.Width + 3).round().clamp(Left + 1, Config.MaskWidth).toInt();
            final Bottom = (Box.Top + Box.Height + 3).round().clamp(Top + 1, Config.MaskHeight).toInt();
            for (var Y = Top; Y < Bottom; Y++) {
              Mask.fillRange(Y * Config.MaskWidth + Left, Y * Config.MaskWidth + Right, 255);
            }
          }
          _MaskFrame = Mask;
        }).catchError((_) {}).whenComplete(() => _MaskBusy = false);
      }
    });
  }

  void PrepareLog() {
    final FileRef = File('${Directories.Logs}${Platform.pathSeparator}capture.log');
    try {
      Directory(Directories.Logs).createSync(recursive: true);
      if (FileRef.existsSync() && FileRef.lengthSync() > 8 * 1024 * 1024) FileRef.writeAsStringSync('');
    } catch (_) {}
  }

  void AppendLog(String Text) {
    if (_LogBuffer.length > 256 * 1024) return;
    _LogBuffer.write(Text);
  }

  Future<void> FlushLog() async {
    if (_LogBusy || _LogBuffer.isEmpty) return;
    _LogBusy = true;
    final Text = _LogBuffer.toString();
    _LogBuffer.clear();
    try {
      await File('${Directories.Logs}${Platform.pathSeparator}capture.log').writeAsString(Text, mode: FileMode.append);
    } catch (_) {}
    _LogBusy = false;
  }

  Future<void> Log(String Text) async {
    AppendLog('${DateTime.now().toIso8601String()} $Text\n');
    await FlushLog();
  }

  Future<String?> Crop(BattleMatch Match, String Output, RecordSettings Value) async {
    final Cache = await Records();
    return CropRecords(Match, Cache, Output, Value);
  }

  Future<String?> CropRecords(BattleMatch Match, List<VideoRecord> Cache, String Output, RecordSettings Value) async {
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
      return Result.exitCode == 0 && File(Output).existsSync() ? Output : null;
    } finally {
      try {
        await File(Temp).delete();
      } catch (_) {}
    }
  }

  Future<void> StartMonitor(RecordSettings Value) async {
    await StopMonitor();
    if (!Platform.isWindows || Value.AudioDevice.isEmpty) return;
    try {
      final Exe = await FFmpeg.EnsureFFplay();
      final Args = <String>['-nodisp', '-autoexit', '-loglevel', 'error', '-fflags', 'nobuffer'];
      if (Value.CaptureMode == 'rtmp') {
        Args.addAll(<String>['-i', 'rtmp://127.0.0.1:${Value.RtmpPort}/live/${Value.RtmpStreamKey}']);
      } else {
        Args.addAll(<String>['-f', 'dshow', '-i', 'audio=${Value.AudioDevice}']);
      }
      final Monitor = await Process.start(Exe, Args, runInShell: false);
      _MonitorProcess = Monitor;
      MonitorActive.value = true;
      MonitorError.value = null;
      Monitor.stderr.transform(OutputEncoding.decoder).listen((Text) {
        final Line = Text.trim();
        if (Line.isNotEmpty) MonitorError.value = Line;
      });
      Monitor.exitCode.then((Code) {
        if (_MonitorProcess != Monitor) return;
        _MonitorProcess = null;
        MonitorActive.value = false;
        if (Code != 0) MonitorError.value = '声音返听进程退出 $Code';
      });
    } catch (Cause) {
      MonitorActive.value = false;
      MonitorError.value = '$Cause';
    }
  }

  Future<void> StopMonitor() async {
    final Monitor = _MonitorProcess;
    _MonitorProcess = null;
    MonitorActive.value = false;
    if (Monitor == null) return;
    try {
      Monitor.kill();
    } catch (_) {}
  }

  Future<List<VideoRecord>> Records() async {
    final List<VideoRecord> Result = <VideoRecord>[];
    final Folder = Directory(Directories.Cache);
    if (!Folder.existsSync()) return Result;
    final Files = Folder.listSync().whereType<File>().where((Item) => RegExp(r'Cache-\d{8}-\d{6}\.mp4$').hasMatch(Item.path)).toList()
      ..sort((Left, Right) => Left.path.compareTo(Right.path));
    for (var Index = 0; Index < Files.length; Index++) {
      final FileRef = Files[Index];
      final Match = RegExp(r'Cache-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})\.mp4$').firstMatch(FileRef.path);
      if (Match == null) continue;
      final Start = DateTime(
        int.parse(Match.group(1)!),
        int.parse(Match.group(2)!),
        int.parse(Match.group(3)!),
        int.parse(Match.group(4)!),
        int.parse(Match.group(5)!),
        int.parse(Match.group(6)!),
      ).millisecondsSinceEpoch;
      final NextStart = Index + 1 < Files.length
          ? RegExp(r'Cache-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})\.mp4$').firstMatch(Files[Index + 1].path)
          : null;
      final Next = NextStart == null
          ? null
          : DateTime(
              int.parse(NextStart.group(1)!),
              int.parse(NextStart.group(2)!),
              int.parse(NextStart.group(3)!),
              int.parse(NextStart.group(4)!),
              int.parse(NextStart.group(5)!),
              int.parse(NextStart.group(6)!),
            ).millisecondsSinceEpoch;
      final End = Next ?? FileRef.lastModifiedSync().millisecondsSinceEpoch;
      Result.add(VideoRecord(
        FilePath: FileRef.path,
        StartAt: Start,
        EndAt: End,
        Width: _Prepared?.Width ?? _Active?.Width ?? 1920,
        Height: _Prepared?.Height ?? _Active?.Height ?? 1080,
        Fps: _Prepared?.Fps ?? _Active?.Fps ?? 60,
        Encoder: _Encoder ?? '',
        HasAudio: (_Active?.AudioDevice.isNotEmpty ?? false),
        Flip: _Active?.FlipVertical ?? false,
      ));
    }
    if (Result.isNotEmpty) LatestRecord.value = Result.last;
    return Result;
  }

  Future<void> Sweep() async {
    final Cache = await Records();
    final Cutoff = DateTime.now().millisecondsSinceEpoch - 10 * 60 * 1000;
    for (final Record in Cache) {
      if (Record.EndAt < Cutoff) {
        try {
          await File(Record.FilePath).delete();
        } catch (_) {}
      }
    }
  }

  Future<void> Dispose() async {
    await Stop(Fast: true);
    await _Events.cancel();
    Error.dispose();
    State.dispose();
    LatestRecord.dispose();
    PreviewTexture.dispose();
    PreviewActive.dispose();
    Stats.dispose();
  }
}
