import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_capture/mobileCapture.dart';

import '../../config/constants.dart';
import '../../config/system.dart';
import '../../domain/models.dart';
import '../ffmpeg/ffmpegService.dart';
import 'contract.dart';
import 'clip.dart';
import 'mobile/androidUvc.dart';
import 'mobile/iosCapture.dart';
import 'mobile/source.dart';
import 'mobile/modes.dart';
import 'mobile/recorder.dart';

export 'mobile/mobileMedia.dart';

class MobileCaptureService implements CapturePlatform {
  MobileCaptureService(this.Directories, this.FFmpeg, {List<MobileCaptureSource>? Sources})
      : Sources = Sources ?? (PlatformInfo.IOS ? <MobileCaptureSource>[IosCaptureSource()] : <MobileCaptureSource>[AndroidUvcSource()]) {
    if (PlatformInfo.IOS) {
      Events = MobileCapture.Events.receiveBroadcastStream().listen(HandleEvent, onError: (Object Error) => OnLog?.call('采集事件监听失败：$Error'));
    }
  }

  final AppDirectories Directories;
  final FFmpegService FFmpeg;
  final List<MobileCaptureSource> Sources;
  StreamSubscription<dynamic>? Events;
  void Function(String Message)? OnLog;
  RecordSettings? LastSettings;
  bool Stopping = false;
  bool Recovered = false;
  bool AutoRecover = false;
  bool PendingIdle = false;
  bool RecordingStarted = false;
  int RunVersion = 0;
  Future<void>? StopTask;

  void HandleEvent(dynamic Value) {
    if (Value is! Map) return;
    final Type = '${Value['type'] ?? ''}';
    final Text = '${Value['value'] ?? ''}'.trim();
    if (Text.isEmpty) return;
    if (Type == 'state') {
      OnLog?.call('采集状态：$Text');
      if (Text == 'recording') {
        if (Starting || Running) {
          RecordingStarted = true;
          PendingIdle = false;
        }
      } else if (Text == 'idle') {
        // Preparation can release an old session, and segment rollover stops
        // the writer deliberately. Only recover an active, unexpected stop.
        if (!RecordingStarted || Stopping || Recorder?.Busy == true) return;
        RecordingStarted = false;
        if (_State.value == 'recording') {
          final Value = LastSettings;
          if (!Recovered && Value != null) {
            Recovered = true;
            _State.value = 'idle';
            OnLog?.call('录制意外中断，正在自动恢复');
            unawaited(ResumeRecording(Value));
          } else {
            _State.value = 'error';
            _Error.value = '录制意外中断，请检查采集卡连接与存储空间后点击重试采集';
          }
        } else if (_State.value == 'starting' && !Stopping) {
          PendingIdle = true;
        }
      }
      return;
    }
    OnLog?.call(Text);
  }

  Future<void> ResumeRecording(RecordSettings Value) async {
    final Version = RunVersion;
    await Future<void>.delayed(const Duration(seconds: 1));
    if (Version != RunVersion || Stopping || _State.value != 'idle') return;
    AutoRecover = true;
    try {
      await Start(Value);
    } finally {
      AutoRecover = false;
    }
  }

  final ValueNotifier<String?> _Error = ValueNotifier<String?>(null);
  final ValueNotifier<String> _State = ValueNotifier<String>('idle');
  final ValueNotifier<VideoRecord?> _LatestRecord = ValueNotifier<VideoRecord?>(null);
  final ValueNotifier<String?> _MonitorError = ValueNotifier<String?>(null);
  final ValueNotifier<bool> _MonitorActive = ValueNotifier<bool>(false);
  final ValueNotifier<int?> _PreviewTexture = ValueNotifier<int?>(null);
  final ValueNotifier<bool> _PreviewActive = ValueNotifier<bool>(false);
  final ValueNotifier<Map<String, dynamic>?> _Stats = ValueNotifier<Map<String, dynamic>?>(null);

  MobileCaptureSource? Active;
  MobileRecorder? Recorder;
  CaptureMode? Mode;
  Timer? StatsClock;
  Timer? DeviceClock;
  Timer? SweepClock;
  String? ActiveDeviceId;
  int DeviceMisses = 0;
  int Segments = 0;

  @override
  ValueNotifier<String?> get Error => _Error;

  @override
  ValueNotifier<String> get State => _State;

  @override
  ValueNotifier<VideoRecord?> get LatestRecord => _LatestRecord;

  @override
  ValueNotifier<String?> get MonitorError => _MonitorError;

  @override
  ValueNotifier<bool> get MonitorActive => _MonitorActive;

  @override
  ValueNotifier<int?> get PreviewTexture => _PreviewTexture;

  @override
  ValueNotifier<bool> get PreviewActive => _PreviewActive;

  @override
  ValueNotifier<Map<String, dynamic>?> get Stats => _Stats;

  @override
  bool get Running => _State.value == 'recording';

  @override
  bool get Starting => _State.value == 'starting';

  @override
  String? get EncoderName {
    if (Active == null) return null;
    return PlatformInfo.IOS ? 'h264_videotoolbox' : 'h264_mediacodec';
  }

  @override
  String? get LiveTarget => null;

  @override
  int get ActualWidth => Mode?.Width ?? 0;

  @override
  int get ActualHeight => Mode?.Height ?? 0;

  @override
  int get ActualFps => Mode?.MaxFps ?? 0;

  @override
  String get ActualFormat => (Mode?.Format ?? '').toUpperCase();

  MobileCaptureSource? SourceFor(RecordSettings Value) {
    final Device = Value.MobileDevice;
    if (Device.contains(':')) {
      final Prefix = Device.split(':').first;
      for (final Item in Sources) {
        if (Item.Prefix == Prefix) return Item;
      }
    }
    return Sources.isEmpty ? null : Sources.first;
  }

  @override
  Future<List<CaptureDevice>> Devices({bool Refresh = false}) async {
    final Result = <CaptureDevice>[];
    for (final Source in Sources) {
      try {
        Result.addAll(await Source.Devices());
      } catch (_) {}
      try {
        Result.addAll(await Source.AudioDevices());
      } catch (_) {}
    }
    final Seen = <String>{};
    return Result.where((CaptureDevice Item) => Seen.add(Item.Id)).toList();
  }

  @override
  Future<List<CaptureMode>> Modes(String Device) async {
    if (!Device.contains(':')) return <CaptureMode>[];
    final Prefix = Device.split(':').first;
    for (final Source in Sources) {
      if (Source.Prefix != Prefix) continue;
      try {
        return await Source.Modes(Device);
      } catch (_) {
        return <CaptureMode>[];
      }
    }
    return <CaptureMode>[];
  }

  CaptureMode? Pick(List<CaptureMode> Items, RecordSettings Value) {
    if (Items.isEmpty) return null;
    return MobileModes.Pick(Items, Value.Width, Value.Height, Value.Fps) ??
        MobileModes.Best(Items, PreferredWidth: Value.Width, PreferredHeight: Value.Height, PreferredFps: Value.Fps);
  }

  @override
  Future<void> Start(RecordSettings Value, {String? LiveUrl, bool Record = true}) async {
    if (Running || Starting) return;
    if (LiveUrl != null && LiveUrl.isNotEmpty) {
      _Error.value = '移动端不支持直播';
      return;
    }
    final Cleanup = Stop(Fast: true);
    final Version = RunVersion;
    await Cleanup;
    if (Version != RunVersion) return;
    unawaited(SweepCache());
    _Error.value = null;
    _State.value = 'starting';
    LastSettings = Value;
    PendingIdle = false;
    RecordingStarted = false;
    if (!AutoRecover) Recovered = false;
    OnLog?.call('移动端开始采集 source=${Value.MobileSource} device=${Value.MobileDevice} audio=${Value.MobileAudio} audioDevice=${Value.MobileAudioDevice} monitor=${Value.MonitorAudio} ${Value.Width}x${Value.Height}@${Value.Fps}');
    final Source = SourceFor(Value);
    if (Source == null) {
      _State.value = 'error';
      _Error.value = '没有可用的采集来源';
      return;
    }
    Active = Source;
    try {
      final List<CaptureDevice> Items = await Source.Devices();
      if (Version != RunVersion) return;
      if (Items.isEmpty) throw StateError('没有检测到 USB 采集卡');
      final Device = Items.firstWhere((Item) => Item.Id == Value.MobileDevice, orElse: () => Items.first);
      final List<CaptureMode> Formats = await Source.Modes(Device.Id);
      if (Version != RunVersion) return;
      if (Formats.isEmpty) throw StateError('采集卡没有报告可用档位');
      final Picked = Pick(Formats, Value);
      if (Picked == null) throw StateError('采集卡没有可用档位');
      final Ready = await Source.Prepare(Device, Picked, Value);
      if (Version != RunVersion) return;
      Mode = Ready;
      OnLog?.call('移动端采集就绪 device=${Device.Id} ${Ready.Width}x${Ready.Height}@${Ready.MaxFps} audio=${Value.MobileAudio}');
      final Engine = MobileRecorder(Source, Directories, Value.MobileAudio);
      Recorder = Engine;
      Engine.Error.addListener(RecorderChanged);
      await Engine.Start();
      if (Version != RunVersion) return;
      if (Value.MonitorAudio) await Engine.Monitor(true);
      if (Version != RunVersion) return;
      Segments = Engine.Segments;
      RecordingStarted = !PendingIdle;
      _State.value = 'recording';
      if (PendingIdle) {
        PendingIdle = false;
        OnLog?.call('录制启动后立即中断');
        _State.value = 'idle';
        if (!Recovered) {
          Recovered = true;
          unawaited(ResumeRecording(Value));
        } else {
          _State.value = 'error';
          _Error.value = '录制意外中断，请检查采集卡连接与存储空间后点击重试采集';
        }
        return;
      }
      _PreviewActive.value = true;
      _LatestRecord.value = null;
      ActiveDeviceId = Device.Id;
      DeviceMisses = 0;
      DeviceClock?.cancel();
      DeviceClock = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(Check()));
      StatsClock?.cancel();
      StatsClock = Timer.periodic(const Duration(seconds: 2), (_) => PushStats());
      SweepClock?.cancel();
      SweepClock = Timer.periodic(const Duration(minutes: 5), (_) => unawaited(SweepCache()));
      PushStats();
    } catch (Cause) {
      if (Version != RunVersion) return;
      OnLog?.call('移动端采集失败：$Cause');
      await Stop(Fast: true);
      _State.value = 'error';
      _Error.value = CauseText(Cause);
    }
  }

  void RecorderChanged() {
    final Value = Recorder?.Error.value;
    if (Value == null || Value.isEmpty) return;
    _Error.value = Value;
    _State.value = 'error';
    StatsClock?.cancel();
    StatsClock = null;
    _Stats.value = <String, dynamic>{'error': Value};
  }

  Future<void> Check() async {
    final Source = Active;
    final Id = ActiveDeviceId;
    if (Source == null || Id == null || _State.value != 'recording') return;
    try {
      final Items = await Source.Devices();
      if (_State.value != 'recording') return;
      if (Items.any((Item) => Item.Id == Id)) {
        DeviceMisses = 0;
        return;
      }
      DeviceMisses++;
      if (DeviceMisses < 2) return;
      OnLog?.call('采集设备断开：$Id');
      _Error.value = '采集设备已断开，录制已停止';
      _State.value = 'error';
    } catch (_) {}
  }

  void PushStats() {
    final Engine = Recorder;
    final Source = Active;
    final Dynamic = Source?.Stats() ?? const <String, dynamic>{};
    final CaptureFps = (Dynamic['captureFps'] as num?)?.toInt() ?? 0;
    final PreviewFps = (Dynamic['previewFps'] as num?)?.toInt() ?? 0;
    final Base = <String, dynamic>{
      'captureFps': CaptureFps > 0 ? CaptureFps : ActualFps,
      'previewFps': PreviewFps > 0 ? PreviewFps : ActualFps,
      'latency': Dynamic['latency'] ?? 0,
      'dropped': Dynamic['dropped'] ?? 0,
      'written': Segments,
      'queue': Dynamic['queue'] ?? 0,
      'convertMs': 0,
      'segments': Engine?.Segments ?? 0,
      'audio': Engine?.AudioActive ?? false,
      'audioError': Engine?.AudioError,
    };
    _Stats.value = Base;
  }

  @override
  Future<void> Stop({bool Fast = false}) {
    RunVersion++;
    Stopping = true;
    PendingIdle = false;
    RecordingStarted = false;
    final Pending = StopTask;
    if (Pending != null) return Pending;
    final Task = StopCapture();
    StopTask = Task;
    return Task.whenComplete(() {
      if (identical(StopTask, Task)) StopTask = null;
    });
  }

  Future<void> StopCapture() async {
    OnLog?.call('移动端停止采集 state=${_State.value}');
    DeviceClock?.cancel();
    DeviceClock = null;
    ActiveDeviceId = null;
    DeviceMisses = 0;
    StatsClock?.cancel();
    StatsClock = null;
    SweepClock?.cancel();
    SweepClock = null;
    final Engine = Recorder;
    Recorder = null;
    if (Engine != null) {
      Engine.Error.removeListener(RecorderChanged);
      try {
        await Engine.Stop();
      } catch (_) {}
      Engine.Error.dispose();
    }
    final Source = Active;
    Active = null;
    if (Source != null) {
      try {
        await Source.Release();
      } catch (_) {}
    }
    _PreviewActive.value = false;
    _Stats.value = null;
    _State.value = 'idle';
    Stopping = false;
  }

  /// Mobile capture never had a cache sweep, so abandoned segments piled up and
  /// could fill the device. Recording then failed with "Cannot Record".
  Future<void> SweepCache() async {
    final Folder = Directory(Directories.Cache);
    final Cutoff = DateTime.now().millisecondsSinceEpoch - Config.CacheKeepMs;
    var Removed = 0;
    try {
      if (!await Folder.exists()) return;
      await for (final Item in Folder.list()) {
        if (Item is! File) continue;
        final Lower = Item.path.toLowerCase();
        if (!Lower.endsWith('.mov') && !Lower.endsWith('.mp4') && !Lower.endsWith('.m4a')) continue;
        final Engine = Recorder;
        if (Engine != null && <String?>[Engine.Target, Engine.Actual, Engine.AudioPath].contains(Item.path)) continue;
        try {
          if ((await Item.stat()).modified.millisecondsSinceEpoch > Cutoff) continue;
          await Item.delete();
          Removed++;
        } catch (_) {}
      }
    } catch (_) {}
    if (Removed > 0) OnLog?.call('清理过期缓存 $Removed 个');
  }

  @override
  Future<List<VideoRecord>> Records() async {
    final Result = <VideoRecord>[];
    final Folder = Directory(Directories.Cache);
    if (!Folder.existsSync()) return Result;
    final Files = Folder.listSync().whereType<File>().where((Item) => RegExp(r'Cache-\d{8}-\d{6}\.mp4$').hasMatch(Item.path)).toList()..sort((Left, Right) => Left.path.compareTo(Right.path));
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
      final NextMatch = Index + 1 < Files.length ? RegExp(r'Cache-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})\.mp4$').firstMatch(Files[Index + 1].path) : null;
      final Next = NextMatch == null
          ? null
          : DateTime(
              int.parse(NextMatch.group(1)!),
              int.parse(NextMatch.group(2)!),
              int.parse(NextMatch.group(3)!),
              int.parse(NextMatch.group(4)!),
              int.parse(NextMatch.group(5)!),
              int.parse(NextMatch.group(6)!),
            ).millisecondsSinceEpoch;
      final End = Next ?? FileRef.lastModifiedSync().millisecondsSinceEpoch;
      Result.add(VideoRecord(
        FilePath: FileRef.path,
        StartAt: Start,
        EndAt: End,
        Width: ActualWidth,
        Height: ActualHeight,
        Fps: ActualFps,
        Encoder: 'hardware',
        HasAudio: true,
        Flip: false,
      ));
    }
    if (Result.isNotEmpty) _LatestRecord.value = Result.last;
    return Result;
  }

  @override
  Future<String?> Crop(BattleMatch Match, String Output, RecordSettings Value, {int LeadMs = 15000, int TailMs = 30000}) async {
    final Cache = await Records();
    return ClipBuilder.Build(Match, Cache, Output, Value, FFmpeg, Directories, LeadMs: LeadMs, TailMs: TailMs);
  }

  @override
  Widget? BuildPreview(BuildContext Context) {
    final Source = Active;
    if (Source == null) return null;
    return Source.BuildPreview();
  }

  @override
  Future<void> StartMonitor(RecordSettings Value) async {
    await Recorder?.Monitor(true);
  }

  @override
  Future<void> StopMonitor() async {
    await Recorder?.Monitor(false);
  }

  Future<void> Recover() async {
    final Engine = MobileRecorder(Sources.first, Directories, false);
    await Engine.Recover();
    Engine.Error.dispose();
  }

  @override
  Future<void> SetVision(bool Enabled) async {}

  @override
  Future<CaptureFrame?> VisionSnapshot() async {
    final Source = Active;
    if (Source == null || !Source.Prepared) return null;
    final Frame = await Source.Snapshot();
    if (Frame == null || Frame.Width <= 0 || Frame.Height <= 0 || Frame.Rgba.isEmpty) return null;
    return CaptureFrame(Width: Frame.Width, Height: Frame.Height, Rgba: Frame.Rgba);
  }

  @override
  Future<void> Dispose() async {
    await Stop(Fast: true);
    await Events?.cancel();
    _Error.dispose();
    _State.dispose();
    _LatestRecord.dispose();
    _MonitorError.dispose();
    _MonitorActive.dispose();
    _PreviewTexture.dispose();
    _PreviewActive.dispose();
    _Stats.dispose();
  }
}
