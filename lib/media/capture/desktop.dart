import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../config/constants.dart';
import '../../config/system.dart';
import '../../domain/models.dart';
import '../ffmpeg/ffmpegService.dart';
import 'arguments.dart';
import 'bridge.dart';
import 'contract.dart';

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
  final List<String> _LogTail = <String>[];
  String? _EncoderFault;
  String? _StartError;
  bool _Starting = false;
  Timer? _Sweep;
  bool _Stopping = false;
  Completer<void>? _Ready;
  Timer? _MaskTimer;
  final List<int> _RawFrames = <int>[];
  bool _MaskBusy = false;
  Uint8List? _MaskFrame;
  int _LastMaskFrameAt = 0;
  bool _VisionEnabled = false;
  Future<Uint8List?> Function(Uint8List Rgba, int Width, int Height)? OnMaskFrame;
  final StringBuffer _LogBuffer = StringBuffer();
  Timer? _LogTimer;
  bool _LogBusy = false;
  Completer<void>? _RecordWaiter;
  Completer<void>? _IdleWaiter;
  bool _NativeRunning = false;
  bool _NativeRecorder = false;
  bool _FallbackBlur = false;
  bool _MaskPipeOpen = false;
  CapturePrepared? _Prepared;
  String? _AudioFifo;
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
    if (Value.CaptureMode == 'rtmp' || !CaptureBridge.Supported) {
      await Stop();
      _StartState(Value, LiveUrl);
      await _StartFallback(Value, LiveUrl: LiveUrl, Record: Record);
      return;
    }
    var Use = Value;
    _Starting = true;
    try {
      for (var Attempt = 0; Attempt < 2; Attempt++) {
        await Stop();
        _StartState(Use, LiveUrl);
        try {
          await _StartNative(Use, LiveUrl: LiveUrl, Record: Record);
          return;
        } catch (Cause) {
          final Text = _StartError ?? _CauseText(Cause);
          var Fault = _EncoderFault;
          if (Fault == null && Attempt == 0 && _RecordWaiter != null && Use.Encoder != 'software') {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            final Late = FFmpegService.EncoderHint(_LogTail.join('\n'));
            if (Late.isNotEmpty) Fault = Late;
          }
          if (Attempt == 0 && Fault != null && _RecordWaiter != null && Use.Encoder != 'software') {
            await Log('capture retry software encoder $Fault');
            Use = Use.Copy(<String, dynamic>{'encoder': 'software'});
            continue;
          }
          if (Fault != null && _NativeRunning && _Prepared != null) {
            final Texture = await CaptureBridge.PreviewTexture();
            PreviewTexture.value = Texture >= 0 ? Texture : null;
            PreviewActive.value = Texture >= 0;
            State.value = 'error';
            Error.value = Text;
            await Log('capture preview kept $Text');
            return;
          }
          await Stop();
          State.value = 'error';
          Error.value = Text;
          await Log('capture start failed $Text');
          return;
        }
      }
    } finally {
      _Starting = false;
    }
  }

  void _StartState(RecordSettings Value, String? LiveUrl) {
    _Active = Value;
    _Prepared = null;
    _LiveUrl = LiveUrl;
    _StderrTail = '';
    _EncoderFault = null;
    _StartError = null;
    _LogTail.clear();
    Error.value = null;
    State.value = 'starting';
  }

  String _CauseText(Object Cause) {
    if (Cause is StateError) return Cause.message;
    if (Cause is TimeoutException) return '采集启动超时，请检查采集卡是否被其他程序占用';
    if (Cause is PlatformException) return '${Cause.message ?? Cause.code}';
    return '$Cause';
  }

  Future<void> _StartNative(RecordSettings Value, {String? LiveUrl, bool Record = true}) async {
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
    final Live = LiveUrl != null && LiveUrl.isNotEmpty;
    final Native = (PlatformInfo.Windows || PlatformInfo.MacOS) && Record && !Live;
    String? Fifo;
    if (!Native && !PlatformInfo.Windows && !PlatformInfo.MacOS && Use.AudioDevice.isNotEmpty) {
      Fifo = '${Directories.Temp}${Platform.pathSeparator}audio-${DateTime.now().microsecondsSinceEpoch}.pcm';
    }
    final Prepared = await CaptureBridge.Prepare(Use, AudioFifo: Fifo);
    _Prepared = Prepared;
    _AudioFifo = Prepared.AudioFifo;
    final Writer = Record || Live;
    final Blur = Live && Use.BlurNickname;
    String? MaskPipe;
    if (Blur) {
      MaskPipe = await CaptureBridge.OpenMaskPipe();
      if (MaskPipe == null || MaskPipe.isEmpty) throw StateError('无法创建直播打码通道');
      _MaskPipeOpen = true;
    }
    _RecordWaiter = Completer<void>();
    _NativeRecorder = Native;
    if (Native) {
      _Encoder = PlatformInfo.MacOS ? 'h264_videotoolbox' : 'h264_mf';
      await CaptureBridge.Start(
        '',
        const <String>[],
        Prepared.Rate,
        true,
        Native: true,
        Directory: Directories.Cache,
        AudioDevice: Use.AudioDevice,
        Quality: Use.Quality,
        SegmentSeconds: Config.SegmentSeconds,
        Audio: Use.AudioDevice.isNotEmpty,
        Monitor: Use.MonitorAudio,
        MonitorDelayMs: Config.MonitorDelayMs,
      );
    } else {
      final Encoder = await FFmpeg.Encoder(Use);
      _Encoder = Encoder;
      final Exe = await FFmpeg.Ensure();
      final Args = PlatformInfo.Windows
          ? CaptureArguments.Native(
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
            )
          : PlatformInfo.MacOS
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
                  AudioFifo: Prepared.AudioFifo,
                )
              : CaptureArguments.Linux(
                  Value: Use,
                  FFmpeg: FFmpeg,
                  Directories: Directories,
                  Encoder: Encoder,
                  Width: Prepared.Width,
                  Height: Prepared.Height,
                  Fps: Prepared.Fps,
                  RateText: Prepared.RateText,
                  Record: Record,
                  AudioFifo: Prepared.AudioFifo,
                );
      await CaptureBridge.Start(Exe, Args, Prepared.Rate, Writer);
    }
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
  }

  Future<void> Stop({bool Fast = false}) async {
    final Fifo = _AudioFifo;
    _AudioFifo = null;
    final FallbackBlur = _FallbackBlur;
    _FallbackBlur = false;
    if (_VisionEnabled) {
      _VisionEnabled = false;
      if (CaptureBridge.Supported) {
        try {
          await CaptureBridge.Vision(false);
        } catch (_) {}
      }
    }
    _MaskTimer?.cancel();
    _MaskTimer = null;
    _RawFrames.clear();
    _MaskBusy = false;
    _MaskFrame = null;
    _LastMaskFrameAt = 0;
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
    if (Fifo != null && Fifo.isNotEmpty) {
      try {
        await File(Fifo).delete();
      } catch (_) {}
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
    _NativeRecorder = false;
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
        final Reason = Detail.isEmpty ? '采集进程退出 $Code' : Detail.last;
        final Hint = FFmpegService.EncoderHint(_StderrTail);
        Error.value = Hint.isEmpty ? Reason : '$Reason（$Hint）';
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
        PreviewActive.value = true;
        if (!_Starting) State.value = 'recording';
        if (_RecordWaiter != null && !_RecordWaiter!.isCompleted) _RecordWaiter!.complete();
      } else if (Value == 'idle') {
        if (_IdleWaiter != null && !_IdleWaiter!.isCompleted) _IdleWaiter!.complete();
        if (!_Starting) {
          State.value = 'idle';
          PreviewActive.value = false;
        }
      } else if (Value == 'starting') {
        if (!_Starting && State.value != 'error') State.value = 'starting';
      } else if (Value == 'error') {
        if (!_Starting) State.value = 'error';
        if (_RecordWaiter != null && !_RecordWaiter!.isCompleted) _RecordWaiter!.completeError(StateError(_StartError ?? Error.value ?? '采集失败'));
      }
      return;
    }
    if (Type == 'error') {
      final Raw = '${Data['text'] ?? '采集失败'}';
      final Hint = FFmpegService.EncoderHint(_LogTail.join('\n'));
      final Text = Hint.isEmpty ? Raw : '$Raw（$Hint）';
      if (Hint.isNotEmpty) _EncoderFault = Hint;
      if (_Starting) {
        _StartError = Text;
        if (_RecordWaiter != null && !_RecordWaiter!.isCompleted) _RecordWaiter!.completeError(StateError(Text));
        if (_IdleWaiter != null && !_IdleWaiter!.isCompleted) _IdleWaiter!.complete();
        unawaited(Log('capture error $Text'));
        return;
      }
      Error.value = Text;
      State.value = 'error';
      if (_RecordWaiter != null && !_RecordWaiter!.isCompleted) _RecordWaiter!.completeError(StateError(Text));
      if (_IdleWaiter != null && !_IdleWaiter!.isCompleted) _IdleWaiter!.complete();
      unawaited(Log('capture error $Text'));
      return;
    }
    if (Type == 'log') {
      final Text = '${Data['text'] ?? ''}';
      AppendLog('$Text\n');
      _PushTail(Text);
      return;
    }
    if (Type == 'stats') {
      Stats.value = Data;
      final Now = DateTime.now().millisecondsSinceEpoch;
      if (Now - _LastStatsLog >= 5000) {
        _LastStatsLog = Now;
        unawaited(Log('capture stats ${Data['captureFps']}fps preview=${Data['previewFps']}fps ${Data['previewWidth'] ?? 0}x${Data['previewHeight'] ?? 0} convert=${Data['convertMs']}ms latency=${Data['latency']}ms dropped=${Data['dropped']} written=${Data['written']} dup=${Data['duplicated']} write=${Data['writeMs']}ms queue=${Data['queue']}'));
      }
    }
  }

  void StartNativeMask() {
    _MaskFrame = Uint8List(Config.MaskWidth * Config.MaskHeight);
    StartMaskClock();
  }

  void StartMaskClock() {
    _MaskTimer?.cancel();
    _MaskTimer = Timer.periodic(const Duration(milliseconds: 200), (_) => unawaited(SendMask()));
  }

  Future<void> SendMask() async {
    final Mask = _MaskFrame;
    if (Mask == null) return;
    if (_NativeRecorder && CaptureBridge.Supported) {
      try {
        await CaptureBridge.Mask(Mask);
      } catch (_) {}
      return;
    }
    final ProcessRef = _Process;
    if (ProcessRef == null) return;
    try {
      ProcessRef.stdin.add(Mask);
    } catch (_) {}
  }

  void UpdateMask(Uint8List Mask) {
    if (Mask.length != Config.MaskWidth * Config.MaskHeight) return;
    _MaskFrame = Mask;
  }

  void StartMask(Process ProcessRef) {
    _MaskFrame = Uint8List(Config.MaskWidth * Config.MaskHeight);
    StartMaskClock();
    ProcessRef.stdout.listen((Data) {
      _RawFrames.addAll(Data);
      final FrameSize = Config.MaskWidth * Config.MaskHeight * 4;
      if (_RawFrames.length > FrameSize * 3) _RawFrames.removeRange(0, _RawFrames.length - FrameSize);
      while (_RawFrames.length >= FrameSize) {
        final Frame = Uint8List.fromList(_RawFrames.sublist(0, FrameSize));
        _RawFrames.removeRange(0, FrameSize);
        if (_MaskBusy) continue;
        final Now = DateTime.now().millisecondsSinceEpoch;
        if (Now - _LastMaskFrameAt < Config.DetectIntervalMs) continue;
        final Callback = OnMaskFrame;
        if (Callback == null) continue;
        _LastMaskFrameAt = Now;
        _MaskBusy = true;
        Callback(Frame, Config.MaskWidth, Config.MaskHeight).then((Mask) {
          if (Mask != null && Mask.length == Config.MaskWidth * Config.MaskHeight) _MaskFrame = Mask;
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

  void _PushTail(String Text) {
    for (final Line in Text.split(RegExp(r'\r?\n'))) {
      final Trimmed = Line.trim();
      if (Trimmed.isEmpty) continue;
      if (RegExp(r'^[a-z_0-9]+=').hasMatch(Trimmed)) continue;
      _LogTail.add(Trimmed);
    }
    while (_LogTail.length > 30) {
      _LogTail.removeAt(0);
    }
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

  Future<void> SetVision(bool Enabled) async {
    _VisionEnabled = Enabled;
    if (!CaptureBridge.Supported) return;
    try {
      await CaptureBridge.Vision(Enabled);
    } catch (_) {}
  }

  Future<CaptureFrame?> VisionSnapshot() async {
    if (!_VisionEnabled || !CaptureBridge.Supported) return null;
    try {
      return await CaptureBridge.VisionSnapshot();
    } catch (_) {
      return null;
    }
  }

  Future<String?> Crop(BattleMatch Match, String Output, RecordSettings Value, {int LeadMs = Config.ClipLeadMs, int TailMs = Config.ClipTailMs}) async {
    final Cache = await Records();
    return CropRecords(Match, Cache, Output, Value, LeadMs: LeadMs, TailMs: TailMs);
  }

  Future<String?> CropRecords(BattleMatch Match, List<VideoRecord> Cache, String Output, RecordSettings Value, {int LeadMs = Config.ClipLeadMs, int TailMs = Config.ClipTailMs}) async {
    final Start = Match.StartAt - LeadMs;
    final End = Match.EndAt + TailMs;
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
      final Primary = await FFmpeg.ArchiveEncoder(Value);
      final Note = FFmpeg.ArchiveNote;
      final Fps = Selected.first.Fps > 0 ? Selected.first.Fps : Value.Fps;
      await Log('archive encoder=$Primary${Note == null ? '' : ' $Note'} fps=$Fps');
      await Directory(File(Output).parent.path).create(recursive: true);
      for (var Attempt = 0; Attempt < 2; Attempt++) {
        final Encoder = Attempt == 0 ? Primary : 'libx265';
        final Args = <String>[
          '-hide_banner', '-loglevel', 'error', '-y',
          '-f', 'concat', '-safe', '0', '-i', Temp,
          '-ss', Offset.toStringAsFixed(3),
          '-t', Span.toStringAsFixed(3),
          '-map', '0:v:0?',
          ...(Selected.any((Item) => Item.HasAudio) ? <String>['-map', '0:a:0?', '-c:a', 'aac', '-b:a', '${Config.AudioBitrate}'] : <String>['-an']),
          ...FFmpeg.ArchiveVideoArgs(Encoder, Value.Quality),
          '-r', '$Fps',
          '-fps_mode', 'cfr',
          '-movflags', '+faststart',
          Output,
        ];
        final Result = await FFmpeg.Run(Args, Timeout: const Duration(minutes: 10));
        if (Result.exitCode == 0 && File(Output).existsSync()) return Output;
        try {
          await File(Output).delete();
        } catch (_) {}
        final Detail = '${Result.stderr}${Result.stdout}'.trim();
        await Log('archive failed encoder=$Encoder ${Detail.length > 500 ? Detail.substring(Detail.length - 500) : Detail}');
        if (Encoder == 'libx265') break;
      }
      return null;
    } finally {
      try {
        await File(Temp).delete();
      } catch (_) {}
    }
  }

  Future<void> StartMonitor(RecordSettings Value) async {
    await StopMonitor();
    if (Value.AudioDevice.isEmpty) return;
    if (!Platform.isWindows && !Platform.isMacOS) return;
    if (_NativeRecorder && CaptureBridge.Supported) {
      try {
        await CaptureBridge.Monitor(Enabled: true);
        MonitorActive.value = true;
        MonitorError.value = null;
      } catch (Cause) {
        MonitorActive.value = false;
        MonitorError.value = '$Cause';
      }
      return;
    }
    if (!Platform.isWindows) return;
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
    if (_NativeRecorder && CaptureBridge.Supported) {
      try {
        await CaptureBridge.Monitor(Enabled: false);
      } catch (_) {}
    }
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
    final Cutoff = DateTime.now().millisecondsSinceEpoch - Config.CacheKeepMs;
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
