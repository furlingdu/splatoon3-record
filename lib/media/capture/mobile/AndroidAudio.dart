import 'package:flutter/services.dart';

import '../../../domain/Models.dart';

class AndroidAudio {
  static const MethodChannel Channel = MethodChannel('splatoon3record/mobile_audio');

  static Future<List<CaptureDevice>> Devices() async {
    final Raw = await Channel.invokeMethod<List<dynamic>>('Devices') ?? <dynamic>[];
    return Raw.whereType<Map>().map((Map Item) {
      return CaptureDevice(Id: 'audio:${Item['id'] ?? ''}', Name: '${Item['name'] ?? ''}', Kind: 'audio');
    }).where((Item) => Item.Id != 'audio:').toList();
  }

  static Future<void> Start(String Path, String DeviceId) async {
    final Id = DeviceId.contains(':') ? DeviceId.split(':').last : DeviceId;
    await Channel.invokeMethod<void>('Start', <String, dynamic>{'path': Path, 'device': Id});
  }

  static Future<String?> Stop() async {
    return Channel.invokeMethod<String>('Stop');
  }
}
