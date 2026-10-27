import 'package:flutter/widgets.dart';
import 'package:mobile_capture/MobileCapture.dart';

import '../../../domain/Models.dart';
import 'MobileCaptureSource.dart';

class IosCaptureSource implements MobileCaptureSource {
  static const String SourcePrefix = 'external';

  bool Ready = false;
  String? Target;

  @override
  String get Prefix => SourcePrefix;

  @override
  bool get Prepared => Ready;

  @override
  Future<List<CaptureDevice>> Devices() async {
    final Items = await MobileCapture.Enumerate();
    return Items.map((MobileCaptureDevice Item) {
      final Name = Item.External ? '${Item.Name} · 外接' : '${Item.Name} · 内置';
      return CaptureDevice(Id: '$Prefix:${Item.Id}', Name: Name, Kind: 'video');
    }).toList();
  }

  @override
  Future<List<CaptureDevice>> AudioDevices() async {
    final Items = await MobileCapture.EnumerateAudio();
    return Items.map((MobileCaptureDevice Item) {
      final Name = Item.External ? '${Item.Name} · USB' : '${Item.Name} · 内置';
      return CaptureDevice(Id: 'audio:${Item.Id}', Name: Name, Kind: 'audio');
    }).toList();
  }

  @override
  bool get HasSeparateAudio => false;

  @override
  Future<String?> StartAudio(String Path) async {
    return null;
  }

  @override
  Future<void> StopAudio() async {}

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
    );
    Ready = true;
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
    await MobileCapture.Dispose();
  }

  @override
  Widget BuildPreview() {
    return MobileCapture.Preview();
  }
}
