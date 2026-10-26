import 'dart:io';

abstract final class PlatformInfo {
  static bool get Windows => Platform.isWindows;
  static bool get MacOS => Platform.isMacOS;
  static bool get Linux => Platform.isLinux;
  static bool get Android => Platform.isAndroid;
  static bool get IOS => Platform.isIOS;
  static bool get Mobile => Platform.isAndroid || Platform.isIOS;
  static bool get Desktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  static bool get Capture => Platform.isWindows;
  static bool get Record => Desktop;
  static bool get Live => Desktop;
  static bool get Update => Desktop;
  static bool get Preview => Desktop;
}
