import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../../domain/models.dart';

class MobileSnapshot {
  const MobileSnapshot({required this.Width, required this.Height, required this.Rgba});

  final int Width;
  final int Height;
  final Uint8List Rgba;
}

class MobileAudioClip {
  const MobileAudioClip({required this.Path, required this.StartNs});

  final String Path;
  final int StartNs;
}

abstract class MobileCaptureSource {
  String get Prefix;

  Future<List<CaptureDevice>> Devices();

  Future<List<CaptureDevice>> AudioDevices() async {
    return <CaptureDevice>[];
  }

  bool get HasSeparateAudio => false;

  Future<MobileAudioClip?> StartAudio(String Path) async {
    return null;
  }

  Future<void> StopAudio() async {}

  Future<void> Monitor(bool Value) async {}

  Future<int> MonotonicNs() async {
    return DateTime.now().microsecondsSinceEpoch * 1000;
  }

  Map<String, dynamic> Stats() {
    return const <String, dynamic>{};
  }

  Future<String?> Finish(String Video, String? Audio, String Target, {int AudioOffsetUs = 0}) async {
    if (Video == Target) return Target;
    try {
      if (File(Target).existsSync()) await File(Target).delete();
      await File(Video).rename(Target);
      return Target;
    } catch (_) {
      return null;
    }
  }

  Future<List<CaptureMode>> Modes(String Id);

  Future<CaptureMode> Prepare(CaptureDevice Device, CaptureMode Mode, RecordSettings Value);

  Future<String> StartRecording(String Path);

  Future<String?> StopRecording();

  Future<MobileSnapshot?> Snapshot() async {
    return null;
  }

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
