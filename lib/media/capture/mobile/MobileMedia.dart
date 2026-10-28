import 'package:flutter/services.dart';

abstract final class MobileMedia {
  static const MethodChannel Channel = MethodChannel('splatoon3record/mobile_media');

  static Future<bool> SaveVideo(String Path) async {
    return await Channel.invokeMethod<bool>('SaveVideo', <String, dynamic>{'path': Path}) ?? false;
  }
}
