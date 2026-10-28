import 'package:flutter/material.dart';

import '../../domain/models.dart';
import 'desktop.dart';

abstract interface class CapturePlatform {
  ValueNotifier<String?> get Error;
  ValueNotifier<String> get State;
  ValueNotifier<VideoRecord?> get LatestRecord;
  ValueNotifier<String?> get MonitorError;
  ValueNotifier<bool> get MonitorActive;
  ValueNotifier<int?> get PreviewTexture;
  ValueNotifier<bool> get PreviewActive;
  ValueNotifier<Map<String, dynamic>?> get Stats;

  bool get Running;
  bool get Starting;
  String? get EncoderName;
  String? get LiveTarget;
  int get ActualWidth;
  int get ActualHeight;
  int get ActualFps;
  String get ActualFormat;

  Future<List<CaptureDevice>> Devices({bool Refresh = false});
  Future<List<CaptureMode>> Modes(String Device);
  Future<void> Start(RecordSettings Value, {String? LiveUrl, bool Record = true});
  Future<void> Stop({bool Fast = false});
  Future<List<VideoRecord>> Records();
  Future<String?> Crop(BattleMatch Match, String Output, RecordSettings Value);
  Widget? BuildPreview(BuildContext Context);
  Future<void> StartMonitor(RecordSettings Value);
  Future<void> StopMonitor();
  Future<void> Dispose();
}

class DesktopCaptureAdapter implements CapturePlatform {
  DesktopCaptureAdapter(this.Inner);

  final CaptureService Inner;

  @override
  ValueNotifier<String?> get Error => Inner.Error;

  @override
  ValueNotifier<String> get State => Inner.State;

  @override
  ValueNotifier<VideoRecord?> get LatestRecord => Inner.LatestRecord;

  @override
  ValueNotifier<String?> get MonitorError => Inner.MonitorError;

  @override
  ValueNotifier<bool> get MonitorActive => Inner.MonitorActive;

  @override
  ValueNotifier<int?> get PreviewTexture => Inner.PreviewTexture;

  @override
  ValueNotifier<bool> get PreviewActive => Inner.PreviewActive;

  @override
  ValueNotifier<Map<String, dynamic>?> get Stats => Inner.Stats;

  @override
  bool get Running => Inner.Running;

  @override
  bool get Starting => Inner.Starting;

  @override
  String? get EncoderName => Inner.EncoderName;

  @override
  String? get LiveTarget => Inner.LiveTarget;

  @override
  int get ActualWidth => Inner.ActualWidth;

  @override
  int get ActualHeight => Inner.ActualHeight;

  @override
  int get ActualFps => Inner.ActualFps;

  @override
  String get ActualFormat => Inner.ActualFormat;

  @override
  Future<List<CaptureDevice>> Devices({bool Refresh = false}) => Inner.Devices(Refresh: Refresh);

  @override
  Future<List<CaptureMode>> Modes(String Device) => Inner.Modes(Device);

  @override
  Future<void> Start(RecordSettings Value, {String? LiveUrl, bool Record = true}) => Inner.Start(Value, LiveUrl: LiveUrl, Record: Record);

  @override
  Future<void> Stop({bool Fast = false}) => Inner.Stop(Fast: Fast);

  @override
  Future<List<VideoRecord>> Records() => Inner.Records();

  @override
  Future<String?> Crop(BattleMatch Match, String Output, RecordSettings Value) => Inner.Crop(Match, Output, Value);

  @override
  Widget? BuildPreview(BuildContext Context) {
    final Id = Inner.PreviewTexture.value;
    if (Id == null) return null;
    return Texture(textureId: Id, filterQuality: FilterQuality.low);
  }

  @override
  Future<void> StartMonitor(RecordSettings Value) => Inner.StartMonitor(Value);

  @override
  Future<void> StopMonitor() => Inner.StopMonitor();

  @override
  Future<void> Dispose() => Inner.Dispose();
}
