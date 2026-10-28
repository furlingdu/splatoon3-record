import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:mobile_capture/MobileCapture.dart';

import '../../../domain/Models.dart';
import 'MobileCaptureSource.dart';

class IosCaptureSource implements MobileCaptureSource {
  static const String SourcePrefix = 'external';

  bool Ready = false;
  String? Target;
  int PreviewVersion = 0;

  @override
  String get Prefix => SourcePrefix;

  @override
  bool get Prepared => Ready;

  @override
  Future<List<CaptureDevice>> Devices() async {
    final Items = (await MobileCapture.Enumerate()).where((Item) => Item.External).toList();
    return Items.map((MobileCaptureDevice Item) {
      return CaptureDevice(Id: '$Prefix:${Item.Id}', Name: Item.Name, Kind: 'video');
    }).toList();
  }

  @override
  Future<List<CaptureDevice>> AudioDevices() async {
    final Items = await MobileCapture.EnumerateAudio();
    return Items.where((MobileCaptureDevice Item) => Item.External).map((MobileCaptureDevice Item) {
      return CaptureDevice(Id: 'audio:${Item.Id}', Name: Item.Name, Kind: 'audio');
    }).toList();
  }

  @override
  bool get HasSeparateAudio => false;

  @override
  Future<MobileAudioClip?> StartAudio(String Path) async {
    return null;
  }

  @override
  Future<void> StopAudio() async {}

  @override
  Future<void> Monitor(bool Value) async {
    await MobileCapture.Monitor(Value);
  }

  @override
  Future<int> MonotonicNs() async {
    return DateTime.now().microsecondsSinceEpoch * 1000;
  }

  @override
  Map<String, dynamic> Stats() {
    return const <String, dynamic>{};
  }

  @override
  Future<String?> Finish(String Video, String? Audio, String Target, {int AudioOffsetUs = 0}) async {
    if (Video == Target) return Target;
    final Exported = await MobileCapture.Export(Video, Target);
    if (Exported && File(Target).existsSync()) {
      try {
        await File(Video).delete();
      } catch (_) {}
      return Target;
    }
    return File(Video).existsSync() ? Video : null;
  }

  @override
  Future<List<CaptureMode>> Modes(String Id) async {
    final Items = await MobileCapture.Modes(Id.split(':').last);
    return Items.map((MobileCaptureMode Item) => CaptureMode(Format: 'avfoundation', Width: Item.Width, Height: Item.Height, MinFps: Item.Fps, MaxFps: Item.Fps)).toList();
  }

  @override
  Future<CaptureMode> Prepare(CaptureDevice Device, CaptureMode Mode, RecordSettings Value) async {
    await Release();
    final Result = await MobileCapture.Prepare(
      Device: Device.Id.split(':').last,
      Width: Mode.Width,
      Height: Mode.Height,
      Fps: Mode.MaxFps,
      Audio: Value.MobileAudio,
      AudioDevice: Value.MobileAudioDevice.contains(':') ? Value.MobileAudioDevice.split(':').last : Value.MobileAudioDevice,
      Orientation: Value.MobileOrientation,
    );
    Ready = true;
    PreviewVersion++;
    return CaptureMode(Format: Mode.Format, Width: Result.Width, Height: Result.Height, MinFps: Result.Fps, MaxFps: Result.Fps);
  }

  @override
  Future<String> StartRecording(String Path) async {
    final TargetPath = Path.replaceFirst(RegExp(r'[.]mp4$'), '.mov');
    Target = TargetPath;
    await MobileCapture.Start(TargetPath);
    return TargetPath;
  }

  @override
  Future<String?> StopRecording() async {
    final Path = await MobileCapture.Stop();
    return Path ?? Target;
  }

  @override
  Future<void> Release() async {
    Ready = false;
    Target = null;
    PreviewVersion++;
    await MobileCapture.Dispose();
  }

  @override
  Widget BuildPreview() {
    return MobileCapture.Preview(Key: ValueKey<int>(PreviewVersion));
  }
}
