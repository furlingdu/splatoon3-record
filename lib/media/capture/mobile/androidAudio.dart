import 'package:flutter/services.dart';

import '../../../domain/models.dart';
import 'source.dart';

class AndroidAudio {
  static const MethodChannel Channel = MethodChannel('splatoon3record/mobile_audio');

  static Future<List<CaptureDevice>> Devices() async {
    final Raw = await Channel.invokeMethod<List<dynamic>>('Devices') ?? <dynamic>[];
    return Raw.whereType<Map>().map((Map Item) {
      return CaptureDevice(Id: 'audio:${Item['id'] ?? ''}', Name: '${Item['name'] ?? ''}', Kind: 'audio');
    }).where((Item) => Item.Id != 'audio:').toList();
  }

  static Future<bool> EnsurePermission() async {
    return await Channel.invokeMethod<bool>('EnsurePermission') ?? false;
  }

  static Future<MobileAudioClip?> Start(String Path, String DeviceId) async {
    final Id = DeviceId.contains(':') ? DeviceId.split(':').last : DeviceId;
    final Raw = await Channel.invokeMethod<Map<dynamic, dynamic>>('Start', <String, dynamic>{'path': Path, 'device': Id});
    if (Raw == null) return null;
    return MobileAudioClip(Path: '${Raw['path'] ?? Path}', StartNs: (Raw['startNs'] as num?)?.toInt() ?? 0);
  }

  static Future<String?> Stop() async {
    return Channel.invokeMethod<String>('Stop');
  }

  static Future<bool> Monitor(bool Value) async {
    return await Channel.invokeMethod<bool>('SetMonitor', <String, dynamic>{'enabled': Value}) ?? false;
  }

  static Future<int> MonotonicNs() async {
    return await Channel.invokeMethod<int>('MonotonicNs') ?? 0;
  }

  static Future<bool> Mux({required String Video, required String Audio, required String Output, required int AudioOffsetUs}) async {
    return await Channel.invokeMethod<bool>('Mux', <String, dynamic>{
      'video': Video,
      'audio': Audio,
      'output': Output,
      'audioOffsetUs': AudioOffsetUs,
    }) ?? false;
  }
}
