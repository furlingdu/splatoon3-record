import 'dart:io';

import 'package:flutter/services.dart';

import '../../domain/models.dart';
import 'contract.dart';

class CaptureBridge {
  static const MethodChannel Channel = MethodChannel('splatoon3record/capture');
  static const EventChannel Events = EventChannel('splatoon3record/capture/events');

  static bool get Supported => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static Future<List<CaptureDevice>> Enumerate() async {
    final Raw = await Channel.invokeMethod<List<dynamic>>('Enumerate') ?? <dynamic>[];
    return Raw.whereType<Map>().map((Item) {
      final Data = Map<String, dynamic>.from(Item);
      return CaptureDevice(
        Id: '${Data['id'] ?? ''}',
        Name: '${Data['name'] ?? ''}',
        Kind: '${Data['kind'] ?? 'video'}',
      );
    }).where((Item) => Item.Id.isNotEmpty).toList();
  }

  static Future<List<CaptureMode>> Modes(String Device) async {
    final Raw = await Channel.invokeMethod<List<dynamic>>('Modes', <String, dynamic>{'device': Device}) ?? <dynamic>[];
    return Raw.whereType<Map>().map((Item) {
      final Data = Map<String, dynamic>.from(Item);
      return CaptureMode(
        Format: '${Data['format'] ?? 'nv12'}',
        Width: (Data['width'] as num?)?.toInt() ?? 0,
        Height: (Data['height'] as num?)?.toInt() ?? 0,
        MinFps: (Data['fps'] as num?)?.toInt() ?? 0,
        MaxFps: (Data['fps'] as num?)?.toInt() ?? 0,
      );
    }).where((Item) => Item.Width > 0 && Item.Height > 0).toList();
  }

  static Future<CapturePrepared> Prepare(RecordSettings Value, {String? AudioFifo}) async {
    final Raw = await Channel.invokeMethod<Map<dynamic, dynamic>>('Prepare', <String, dynamic>{
      'device': Value.VideoDevice,
      'width': Value.Width,
      'height': Value.Height,
      'fps': Value.Fps,
      'format': Value.CaptureFormat,
      'audioDevice': Value.AudioDevice,
      'audioFifo': AudioFifo ?? '',
    });
    final Data = Map<String, dynamic>.from(Raw ?? <dynamic, dynamic>{});
    return CapturePrepared(
      Width: (Data['width'] as num?)?.toInt() ?? Value.Width,
      Height: (Data['height'] as num?)?.toInt() ?? Value.Height,
      Fps: (Data['fps'] as num?)?.toInt() ?? Value.Fps,
      FpsNumerator: (Data['fpsNum'] as num?)?.toInt() ?? Value.Fps,
      FpsDenominator: (Data['fpsDen'] as num?)?.toInt() ?? 1,
      Format: '${Data['format'] ?? 'nv12'}',
      AudioFifo: '${Data['audioFifo'] ?? AudioFifo ?? ''}',
    );
  }

  static Future<void> Start(
    String Exe,
    List<String> Args,
    double Fps,
    bool Writer, {
    bool Native = false,
    String Directory = '',
    String AudioDevice = '',
    int Quality = 28,
    int SegmentSeconds = 600,
    bool Audio = false,
    bool Monitor = false,
    int MonitorDelayMs = 30,
  }) async {
    await Channel.invokeMethod<void>('Start', <String, dynamic>{
      'exe': Exe,
      'args': Args,
      'fps': Fps,
      'writer': Writer,
      'native': Native,
      'directory': Directory,
      'audioDevice': AudioDevice,
      'quality': Quality,
      'segmentSeconds': SegmentSeconds,
      'audio': Audio,
      'monitor': Monitor,
      'monitorDelayMs': MonitorDelayMs,
    });
  }

  static Future<void> Monitor({required bool Enabled}) async {
    await Channel.invokeMethod<void>('Monitor', <String, dynamic>{'enabled': Enabled});
  }

  static Future<void> Theme(int Color) async {
    await Channel.invokeMethod<void>('Theme', <String, dynamic>{'color': Color});
  }

  static Future<void> Stop({bool Fast = false}) async {
    await Channel.invokeMethod<void>('Stop', <String, dynamic>{'fast': Fast});
  }

  static Future<int> PreviewTexture() async {
    return await Channel.invokeMethod<int>('PreviewTexture') ?? -1;
  }

  static Future<Map<String, dynamic>> PreviewState() async {
    final Raw = await Channel.invokeMethod<Map<dynamic, dynamic>>('PreviewState');
    return Map<String, dynamic>.from(Raw ?? <dynamic, dynamic>{});
  }

  static Future<Uint8List?> Snapshot() async {
    return await Channel.invokeMethod<Uint8List>('Snapshot');
  }

  static Future<void> Vision(bool Enabled) async {
    await Channel.invokeMethod<void>('Vision', <String, dynamic>{'enabled': Enabled});
  }

  static Future<CaptureFrame?> VisionSnapshot() async {
    final Raw = await Channel.invokeMethod<Map<dynamic, dynamic>>('VisionSnapshot');
    if (Raw == null) return null;
    final Data = Map<String, dynamic>.from(Raw);
    final Bytes = Data['bytes'];
    if (Bytes is! Uint8List || Bytes.isEmpty) return null;
    final Width = (Data['width'] as num?)?.toInt() ?? 0;
    final Height = (Data['height'] as num?)?.toInt() ?? 0;
    if (Width <= 0 || Height <= 0 || Bytes.length < Width * Height * 4) return null;
    return CaptureFrame(Width: Width, Height: Height, Rgba: Bytes);
  }

  static Future<void> Mask(Uint8List Value) async {
    await Channel.invokeMethod<void>('Mask', Value);
  }

  static Future<String?> OpenMaskPipe() async {
    return await Channel.invokeMethod<String>('OpenMaskPipe');
  }

  static Future<void> CloseMaskPipe() async {
    await Channel.invokeMethod<void>('CloseMaskPipe');
  }
}

class CapturePrepared {
  const CapturePrepared({
    required this.Width,
    required this.Height,
    required this.Fps,
    required this.FpsNumerator,
    required this.FpsDenominator,
    required this.Format,
    this.AudioFifo = '',
  });

  final int Width;
  final int Height;
  final int Fps;
  final int FpsNumerator;
  final int FpsDenominator;
  final String Format;
  final String AudioFifo;

  bool get HasAudio => AudioFifo.isNotEmpty;

  double get Rate => FpsDenominator > 0 ? FpsNumerator / FpsDenominator : Fps.toDouble();

  String get RateText => FpsDenominator > 1 ? '$FpsNumerator/$FpsDenominator' : '$FpsNumerator';
}
