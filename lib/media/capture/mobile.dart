import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

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

class MobileCaptureService implements CapturePlatform {
  MobileCaptureService(this.Directories, this.FFmpeg)
      : Sources = PlatformInfo.IOS ? <MobileCaptureSource>[IosCaptureSource()] : <MobileCaptureSource>[AndroidUvcSource()];

  final AppDirectories Directories;
  final FFmpegService FFmpeg;
  final List<MobileCaptureSource> Sources;

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
    await Stop(Fast: true);
    _Error.value = null;
    _State.value = 'starting';
    final Source = SourceFor(Value);
    if (Source == null) {
      _State.value = 'error';
      _Error.value = '没有可用的采集来源';
      return;
    }
    Active = Source;
    try {
      final List<CaptureDevice> Items = await Source.Devices();
      if (Items.isEmpty) throw StateError('没有检测到 USB 采集卡');
      final Device = Items.firstWhere((Item) => Item.Id == Value.MobileDevice, orElse: () => Items.first);
      final List<CaptureMode> Formats = await Source.Modes(Device.Id);
      if (Formats.isEmpty) throw StateError('采集卡没有报告可用档位');
      final Picked = Pick(Formats, Value);
      if (Picked == null) throw StateError('采集卡没有可用档位');
      final Ready = await Source.Prepare(Device, Picked, Value);
      Mode = Ready;
      final Engine = MobileRecorder(Source, Directories, Value.MobileAudio);
      Recorder = Engine;
      Engine.Error.addListener(RecorderChanged);
      await Engine.Start();
      if (Value.MonitorAudio) await Engine.Monitor(true);
      Segments = Engine.Segments;
      _State.value = 'recording';
      _PreviewActive.value = true;
      _LatestRecord.value = null;
      ActiveDeviceId = Device.Id;
      DeviceMisses = 0;
      DeviceClock?.cancel();
      DeviceClock = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(Check()));
      StatsClock?.cancel();
      StatsClock = Timer.periodic(const Duration(seconds: 2), (_) => PushStats());
      PushStats();
    } catch (Cause) {
      await Stop(Fast: true);
      _State.value = 'error';
      _Error.value = '$Cause';
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
  Future<void> Stop({bool Fast = false}) async {
    DeviceClock?.cancel();
    DeviceClock = null;
    ActiveDeviceId = null;
    DeviceMisses = 0;
    StatsClock?.cancel();
    StatsClock = null;
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
  Future<String?> Crop(BattleMatch Match, String Output, RecordSettings Value) async {
    final Cache = await Records();
    return ClipBuilder.Build(Match, Cache, Output, Value, FFmpeg, Directories);
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
  Future<void> Dispose() async {
    await Stop(Fast: true);
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
