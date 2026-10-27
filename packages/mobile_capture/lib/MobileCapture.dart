import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MobileCaptureDevice {
  const MobileCaptureDevice({required this.Id, required this.Name, required this.External});

  final String Id;
  final String Name;
  final bool External;

  static MobileCaptureDevice FromMap(Map<dynamic, dynamic> Data) {
    return MobileCaptureDevice(
      Id: '${Data['id'] ?? ''}',
      Name: '${Data['name'] ?? ''}',
      External: Data['external'] == true,
    );
  }
}

class MobileCaptureMode {
  const MobileCaptureMode({required this.Width, required this.Height, required this.Fps});

  final int Width;
  final int Height;
  final int Fps;

  static MobileCaptureMode FromMap(Map<dynamic, dynamic> Data) {
    return MobileCaptureMode(
      Width: (Data['width'] as num?)?.toInt() ?? 0,
      Height: (Data['height'] as num?)?.toInt() ?? 0,
      Fps: (Data['fps'] as num?)?.toInt() ?? 0,
    );
  }
}

class MobileCaptureException implements Exception {
  const MobileCaptureException(this.Message);

  final String Message;

  @override
  String toString() => Message;
}

abstract final class MobileCapture {
  static const MethodChannel Channel = MethodChannel('splatoon3record/mobile_capture');
  static const EventChannel Events = EventChannel('splatoon3record/mobile_capture/events');

  static Future<List<MobileCaptureDevice>> Enumerate() async {
    final Raw = await Channel.invokeMethod<List<dynamic>>('Enumerate') ?? <dynamic>[];
    return Raw.whereType<Map>().map(MobileCaptureDevice.FromMap).where((Item) => Item.Id.isNotEmpty).toList();
  }

  static Future<List<MobileCaptureMode>> Modes(String Device) async {
    final Raw = await Channel.invokeMethod<List<dynamic>>('Modes', <String, dynamic>{'device': Device}) ?? <dynamic>[];
    return Raw.whereType<Map>().map(MobileCaptureMode.FromMap).where((Item) => Item.Width > 0 && Item.Height > 0).toList();
  }

  static Future<MobileCaptureMode> Prepare({
    required String Device,
    required int Width,
    required int Height,
    required int Fps,
    required bool Audio,
  }) async {
    final Raw = await Channel.invokeMethod<Map<dynamic, dynamic>>('Prepare', <String, dynamic>{
      'device': Device,
      'width': Width,
      'height': Height,
      'fps': Fps,
      'audio': Audio,
    });
    if (Raw == null) throw const MobileCaptureException('无法打开采集设备');
    return MobileCaptureMode.FromMap(Raw);
  }

  static Future<void> Start(String Path) async {
    await Channel.invokeMethod<void>('Start', <String, dynamic>{'path': Path});
  }

  static Future<String?> Stop() async {
    return Channel.invokeMethod<String>('Stop');
  }

  static Future<void> Dispose() async {
    await Channel.invokeMethod<void>('Dispose');
  }

  static Widget Preview() {
    return const UiKitView(viewType: 'splatoon3record/capture_preview');
  }
}
