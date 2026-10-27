import 'package:flutter/services.dart';

class UvcLive {
  static const MethodChannel Channel = MethodChannel('splatoon3record/uvc_live');
  static const EventChannel Events = EventChannel('splatoon3record/uvc_live/events');

  static Stream<Map<String, dynamic>> get Updates {
    return Events.receiveBroadcastStream().map((dynamic Value) => Map<String, dynamic>.from(Value as Map));
  }

  static Future<String?> Start({required String Url, required int Width, required int Height, required int Fps, required int Bitrate}) async {
    try {
      await Channel.invokeMethod<void>('Start', <String, dynamic>{
        'url': Url,
        'width': Width,
        'height': Height,
        'fps': Fps,
        'bitrate': Bitrate,
      });
      return null;
    } catch (Failure) {
      return '$Failure';
    }
  }

  static Future<void> Stop() async {
    try {
      await Channel.invokeMethod<void>('Stop');
    } catch (_) {}
  }
}
