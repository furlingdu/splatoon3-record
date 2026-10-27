import 'package:flutter/widgets.dart';

import '../../../domain/Models.dart';

abstract class MobileCaptureSource {
  String get Prefix;

  Future<List<CaptureDevice>> Devices();

  Future<List<CaptureDevice>> AudioDevices() async {
    return <CaptureDevice>[];
  }

  bool get HasSeparateAudio => false;

  Future<String?> StartAudio(String Path) async {
    return null;
  }

  Future<void> StopAudio() async {}

  Future<List<CaptureMode>> Modes(String Id);

  Future<CaptureMode> Prepare(CaptureDevice Device, CaptureMode Mode, RecordSettings Value);

  Future<String> StartRecording(String Path);

  Future<String?> StopRecording();

  Future<void> Release();

  Widget BuildPreview();

  bool get Prepared;
}

int MobileBitrate(CaptureMode Mode, int Quality) {
  final Area = Mode.Width * Mode.Height;
  final Base = Area >= 1920 * 1080 ? 16 : Area >= 1280 * 720 ? 8 : 4;
  final Scale = Quality >= 28 ? 0.5 : Quality >= 22 ? 0.75 : 1.0;
  final FpsScale = Mode.MaxFps >= 50 ? 1.0 : 0.7;
  return (Base * 1000 * 1000 * Scale * FpsScale).round();
}
