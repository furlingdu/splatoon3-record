import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../config/PlatformInfo.dart';
import '../../domain/Models.dart';
import '../ffmpeg/Service.dart';
import 'CapturePlatform.dart';
import 'ClipBuilder.dart';
import 'mobile/AndroidCameraSource.dart';
import 'mobile/AndroidUvcSource.dart';
import 'mobile/IosCaptureSource.dart';
import 'mobile/MobileCaptureSource.dart';
import 'mobile/MobileRecorder.dart';

class MobileCaptureService implements CapturePlatform {
  MobileCaptureService(this.Directories, this.FFmpeg)
      : Sources = PlatformInfo.IOS
            ? <MobileCaptureSource>[IosCaptureSource()]
            : <MobileCaptureSource>[AndroidCameraSource(), AndroidUvcSource()];

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
  String? get EncoderName => null;

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
    final Prefix = Device.contains(':') ? Device.split(':').first : Value.MobileSource;
    for (final Item in Sources) {
      if (Item.Prefix == Prefix) return Item;
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
    }
    return Result;
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

  CaptureMode Pick(List<CaptureMode> Items, RecordSettings Value) {
    final Exact = Items.where((Item) => Item.Width == Value.Width && Item.Height == Value.Height).toList();
    final Pool = Exact.isNotEmpty ? Exact : Items;
    final Fps = Pool.where((Item) => Item.MaxFps >= Value.Fps).toList()..sort((Left, Right) => Left.MaxFps.compareTo(Right.MaxFps));
    if (Fps.isNotEmpty) return Fps.first;
    final Sorted = Pool.toList()..sort((Left, Right) => Right.MaxFps.compareTo(Left.MaxFps));
    return Sorted.first;
  }

  @override
  Future<void> Start(RecordSettings Value, {String? LiveUrl, bool Record = true}) async {
    if (Running || Starting) return;
    await Stop(Fast: true);
    _Error.value = null;
    _State.value = 'starting';
    try {
      final Source = SourceFor(Value);
      if (Source == null) throw StateError('没有可用的采集来源');
      final List<CaptureDevice> Items = await Source.Devices();
      if (Items.isEmpty) throw StateError('没有可用的采集设备');
      final Device = Items.firstWhere((Item) => Item.Id == Value.MobileDevice, orElse: () => Items.first);
      final List<CaptureMode> Formats = await Source.Modes(Device.Id);
      if (Formats.isEmpty) throw StateError('没有可用的采集格式');
      final Picked = Pick(Formats, Value);
      final Ready = await Source.Prepare(Device, Picked, Value);
      Active = Source;
      Mode = Ready;
      final Engine = MobileRecorder(Source, Directories, FFmpeg);
      Recorder = Engine;
      await Engine.Start();
      Segments = Engine.Segments;
      _State.value = 'recording';
      _PreviewActive.value = true;
      _LatestRecord.value = null;
      StatsClock?.cancel();
      StatsClock = Timer.periodic(const Duration(seconds: 2), (_) => PushStats());
      PushStats();
    } catch (Cause) {
      await Stop(Fast: true);
      _State.value = 'error';
      _Error.value = '$Cause';
    }
  }

  void PushStats() {
    final Engine = Recorder;
    _Stats.value = <String, dynamic>{
      'captureFps': ActualFps,
      'previewFps': ActualFps,
      'latency': 0,
      'dropped': 0,
      'written': Segments,
      'queue': 0,
      'convertMs': 0,
      'segments': Engine?.Segments ?? 0,
    };
  }

  @override
  Future<void> Stop({bool Fast = false}) async {
    StatsClock?.cancel();
    StatsClock = null;
    final Engine = Recorder;
    Recorder = null;
    if (Engine != null) {
      try {
        await Engine.Stop();
      } catch (_) {}
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
        HasAudio: false,
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
  Future<void> StartMonitor(RecordSettings Value) async {}

  @override
  Future<void> StopMonitor() async {}

  Future<void> Recover() async {
    final Engine = MobileRecorder(Sources.first, Directories, FFmpeg);
    await Engine.Recover();
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
