import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';

import '../../../domain/Models.dart';
import 'AndroidAudio.dart';
import 'MobileCaptureSource.dart';

class AndroidCameraSource implements MobileCaptureSource {
  static const String SourcePrefix = 'camera';

  final List<CameraDescription> Descriptions = <CameraDescription>[];
  CameraController? ControllerRef;
  String? Target;
  int Index = -1;
  bool AudioEnabled = false;
  String AudioDevice = '';

  @override
  String get Prefix => SourcePrefix;

  @override
  bool get Prepared => ControllerRef != null && ControllerRef!.value.isInitialized;

  @override
  Future<List<CaptureDevice>> Devices() async {
    Descriptions
      ..clear()
      ..addAll(await availableCameras());
    return List<CameraDescription>.generate(Descriptions.length, (int Value) => Descriptions[Value]).asMap().entries.map((MapEntry<int, CameraDescription> Entry) {
      final Item = Entry.value;
      final Facing = Item.lensDirection == CameraLensDirection.front
          ? '前置'
          : Item.lensDirection == CameraLensDirection.back
              ? '后置'
              : '外接';
      return CaptureDevice(Id: '$Prefix:${Entry.key}', Name: '${Item.name} · $Facing', Kind: 'video');
    }).toList();
  }

  @override
  Future<List<CaptureDevice>> AudioDevices() async {
    return AndroidAudio.Devices();
  }

  @override
  bool get HasSeparateAudio => true;

  @override
  Future<String?> StartAudio(String Path) async {
    if (!AudioEnabled) return null;
    await AndroidAudio.Start(Path, AudioDevice);
    return Path;
  }

  @override
  Future<void> StopAudio() async {
    await AndroidAudio.Stop();
  }

  @override
  Future<List<CaptureMode>> Modes(String Id) async {
    return <CaptureMode>[
      CaptureMode(Format: 'camera', Width: 1920, Height: 1080, MinFps: 30, MaxFps: 30),
      CaptureMode(Format: 'camera', Width: 1280, Height: 720, MinFps: 60, MaxFps: 60),
      CaptureMode(Format: 'camera', Width: 1280, Height: 720, MinFps: 30, MaxFps: 30),
      CaptureMode(Format: 'camera', Width: 854, Height: 480, MinFps: 30, MaxFps: 30),
    ];
  }

  @override
  Future<CaptureMode> Prepare(CaptureDevice Device, CaptureMode Mode, RecordSettings Value) async {
    await Release();
    AudioEnabled = Value.MobileAudio;
    AudioDevice = Value.MobileAudioDevice;
    final Position = int.tryParse(Device.Id.split(':').last) ?? -1;
    if (Position < 0 || Position >= Descriptions.length) throw StateError('未找到相机');
    final Preset = Mode.Height >= 1080 ? ResolutionPreset.veryHigh : Mode.Height >= 720 ? ResolutionPreset.high : ResolutionPreset.medium;
    final Bitrate = MobileBitrate(Mode, Value.Quality);
    CameraController? Controller = CameraController(Descriptions[Position], Preset, enableAudio: false, fps: Mode.MaxFps, videoBitrate: Bitrate);
    try {
      await Controller.initialize();
    } catch (_) {
      await Controller.dispose();
      Controller = CameraController(Descriptions[Position], Preset, enableAudio: false, videoBitrate: Bitrate);
      await Controller.initialize();
    }
    ControllerRef = Controller;
    Index = Position;
    final Preview = Controller.value.previewSize;
    if (Preview != null && Preview.width > 0) {
      return CaptureMode(Format: Mode.Format, Width: Preview.height.round(), Height: Preview.width.round(), MinFps: Mode.MinFps, MaxFps: Mode.MaxFps);
    }
    return Mode;
  }

  @override
  Future<String> StartRecording(String Path) async {
    final Controller = ControllerRef;
    if (Controller == null || !Controller.value.isInitialized) throw StateError('相机未就绪');
    Target = Path;
    await Controller.startVideoRecording();
    return Path;
  }

  @override
  Future<String?> StopRecording() async {
    final Controller = ControllerRef;
    final Output = Target;
    if (Controller == null || !Controller.value.isRecordingVideo) return null;
    final FileRef = await Controller.stopVideoRecording();
    if (Output == null) return FileRef.path;
    try {
      final Moved = await File(FileRef.path).rename(Output);
      return Moved.path;
    } catch (_) {
      return FileRef.path;
    }
  }

  @override
  Future<void> Release() async {
    final Controller = ControllerRef;
    ControllerRef = null;
    Target = null;
    if (Controller != null) {
      try {
        await Controller.dispose();
      } catch (_) {}
    }
  }

  @override
  Widget BuildPreview() {
    final Controller = ControllerRef;
    if (Controller == null || !Controller.value.isInitialized) return const SizedBox.shrink();
    return CameraPreview(Controller);
  }
}
