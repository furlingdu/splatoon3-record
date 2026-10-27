import 'package:flutter/widgets.dart';
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';

import '../../../domain/Models.dart';
import 'AndroidAudio.dart';
import 'MobileCaptureSource.dart';

class AndroidUvcSource implements MobileCaptureSource {
  static const String SourcePrefix = 'uvc';

  final UvcCamera Camera = uvcCamera;
  int TextureId = -1;
  int DeviceId = -1;
  String? Target;
  CaptureMode? Mode;
  bool Active = false;
  bool AudioEnabled = false;
  String AudioDevice = '';

  @override
  String get Prefix => SourcePrefix;

  @override
  bool get Prepared => Active;

  @override
  Future<List<CaptureDevice>> Devices() async {
    final Items = await Camera.listUsbDevices();
    return Items.map((UvcUsbDevice Item) {
      final Name = Item.productName.isNotEmpty ? Item.productName : Item.deviceName.isNotEmpty ? Item.deviceName : 'USB 采集卡';
      return CaptureDevice(Id: '$Prefix:${Item.deviceId}', Name: Name, Kind: 'video');
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
    final IdValue = int.tryParse(Id.split(':').last) ?? -1;
    if (IdValue < 0) return <CaptureMode>[];
    await Camera.openUsbDevice(IdValue);
    final Items = Camera.supportedModes();
    final Result = <CaptureMode>[];
    for (final UvcCameraMode Item in Items) {
      if (Item.width <= 0 || Item.height <= 0 || Item.fps <= 0) continue;
      if (Result.any((CaptureMode Value) => Value.Width == Item.width && Value.Height == Item.height && Value.MaxFps == Item.fps)) continue;
      Result.add(CaptureMode(Format: 'uvc', Width: Item.width, Height: Item.height, MinFps: Item.fps, MaxFps: Item.fps));
    }
    return Result;
  }

  UvcCameraMode PickMode(List<UvcCameraMode> Items, CaptureMode Requested) {
    UvcCameraMode? Best;
    var BestScore = 1 << 30;
    for (final UvcCameraMode Item in Items) {
      if (Item.width <= 0 || Item.height <= 0) continue;
      final Score = (Item.width - Requested.Width).abs() + (Item.height - Requested.Height).abs() + (Item.fps - Requested.MaxFps).abs() * 8;
      if (Score < BestScore) {
        BestScore = Score;
        Best = Item;
      }
    }
    return Best ?? Items.first;
  }

  @override
  Future<CaptureMode> Prepare(CaptureDevice Device, CaptureMode Requested, RecordSettings Value) async {
    await Release();
    AudioEnabled = Value.MobileAudio;
    AudioDevice = Value.MobileAudioDevice;
    final IdValue = int.tryParse(Device.Id.split(':').last) ?? -1;
    if (IdValue < 0) throw StateError('未找到采集卡');
    await Camera.openUsbDevice(IdValue);
    final Items = Camera.supportedModes();
    if (Items.isEmpty) throw StateError('采集卡没有可用格式');
    final Picked = PickMode(Items, Requested);
    final Start = await Camera.startPreview(Picked);
    if (!Start.success) throw StateError(Start.lastError ?? '采集卡预览启动失败');
    TextureId = await Camera.createPreviewTexture();
    await Camera.attachPreviewTexture(TextureId, width: Picked.width, height: Picked.height);
    DeviceId = IdValue;
    Mode = CaptureMode(Format: 'uvc', Width: Picked.width, Height: Picked.height, MinFps: Picked.fps, MaxFps: Picked.fps);
    Active = true;
    return Mode!;
  }

  @override
  Future<String> StartRecording(String Path) async {
    if (!Active) throw StateError('采集卡未就绪');
    Target = Path;
    Camera.startVideoRecording(Path, bitrateBps: MobileBitrate(Mode ?? CaptureMode(Format: 'uvc', Width: 1920, Height: 1080, MinFps: 30, MaxFps: 30), 22));
    return Path;
  }

  @override
  Future<String?> StopRecording() async {
    final Path = Target;
    Target = null;
    if (!Camera.isRecording) return Path;
    Camera.stopVideoRecording();
    return Path;
  }

  @override
  Future<void> Release() async {
    Active = false;
    Target = null;
    try {
      if (Camera.isRecording) Camera.stopVideoRecording();
    } catch (_) {}
    try {
      await Camera.stopPreview();
    } catch (_) {}
    if (TextureId >= 0) {
      try {
        await Camera.disposePreviewTexture(TextureId);
      } catch (_) {}
      TextureId = -1;
    }
    try {
      await Camera.closeUsbDevice();
    } catch (_) {}
    DeviceId = -1;
  }

  @override
  Widget BuildPreview() {
    if (TextureId < 0) return const SizedBox.shrink();
    return Texture(textureId: TextureId, filterQuality: FilterQuality.low);
  }
}
