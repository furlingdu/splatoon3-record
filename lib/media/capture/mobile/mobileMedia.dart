import 'package:flutter/services.dart';

abstract final class MobileMedia {
  static const MethodChannel Channel = MethodChannel('splatoon3record/mobile_media');

  static Future<bool> SaveVideo(String Path) async {
    return await Channel.invokeMethod<bool>('SaveVideo', <String, dynamic>{'path': Path}) ?? false;
  }

  static Future<String?> PickImage() async {
    return Channel.invokeMethod<String>('PickImage');
  }

  static Future<bool> SaveFile(String Path) async {
    return await Channel.invokeMethod<bool>('SaveFile', <String, dynamic>{'path': Path}) ?? false;
  }

  static Future<void> KeepAwake(bool Enabled) async {
    try {
      await Channel.invokeMethod<void>('KeepAwake', <String, dynamic>{'enabled': Enabled});
    } catch (_) {}
  }
}
