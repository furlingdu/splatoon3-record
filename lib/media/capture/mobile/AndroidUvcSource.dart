import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';

import '../../../domain/Models.dart';
import 'AndroidAudio.dart';
import 'MobileCaptureSource.dart';

class AndroidUvcSource implements MobileCaptureSource {
  static const String SourcePrefix = 'uvc';

  final UvcCamera Camera = uvcCamera;
  final Map<int, List<UvcCameraMode>> ModeCache = <int, List<UvcCameraMode>>{};
  int TextureId = -1;
  int DeviceId = -1;
  String? Target;
  CaptureMode? Mode;
  UvcCameraMode? NativeMode;
  bool Active = false;
  bool AudioEnabled = false;
  String AudioDevice = '';
  int Quality = 22;
  bool Flip = false;

  @override
  String get Prefix => SourcePrefix;

  @override
  bool get Prepared => Active;

  @override
  Future<List<CaptureDevice>> Devices() async {
    if (!Active) ModeCache.clear();
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
  Future<MobileAudioClip?> StartAudio(String Path) async {
    if (!AudioEnabled) return null;
    final Items = await AndroidAudio.Devices();
    if (Items.isEmpty) return null;
    final Granted = await AndroidAudio.EnsurePermission();
    if (!Granted) throw StateError('未授权录音权限');
    return AndroidAudio.Start(Path, AudioDevice);
  }

  @override
  Future<void> StopAudio() async {
    await AndroidAudio.Stop();
  }

  @override
  Future<void> SetMonitor(bool Value) async {
    await AndroidAudio.SetMonitor(Value);
  }

  @override
  Future<int> MonotonicNs() async {
    return AndroidAudio.MonotonicNs();
  }

  @override
  Map<String, dynamic> Stats() {
    try {
      final Value = Camera.getStreamStats();
      final Dropped = Value.callbackLockDropCount +
          Value.decodeFailureCount +
          Value.staleFrameCount +
          Value.undersizedFrameCount +
          Value.invalidMjpegCount +
          Value.previewSurfaceFailureCount +
          Value.conversionFailureCount;
      return <String, dynamic>{
        'captureFps': Value.inputFps.round(),
        'previewFps': Value.deliveredFps.round(),
        'latency': Value.avgInterFrameGapMs.round(),
        'dropped': Dropped,
        'queue': Value.inputFrameCount > Value.deliveredFrameCount ? Value.inputFrameCount - Value.deliveredFrameCount : 0,
        'convertMs': 0,
        'audio': AudioEnabled,
      };
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  @override
  Future<List<CaptureMode>> Modes(String Id) async {
    final IdValue = int.tryParse(Id.split(':').last) ?? -1;
    if (IdValue < 0) return <CaptureMode>[];
    final Cached = ModeCache[IdValue];
    if (Cached != null && Cached.isNotEmpty) return MapModes(Cached);
    await OpenDevice(IdValue);
    try {
      final Items = Camera.supportedModes().where((Item) => Item.width > 0 && Item.height > 0 && Item.fps > 0).toList();
      if (Items.isEmpty) return <CaptureMode>[];
      ModeCache[IdValue] = List<UvcCameraMode>.of(Items);
      return MapModes(Items);
    } finally {
      await CloseDevice();
    }
  }

  List<CaptureMode> MapModes(List<UvcCameraMode> Items) {
    return Items.map((UvcCameraMode Item) {
      final Format = Item.formatName.toLowerCase();
      return CaptureMode(Format: Format, Width: Item.width, Height: Item.height, MinFps: Item.fps, MaxFps: Item.fps);
    }).toList();
  }

  int ModeScore(UvcCameraMode Item, CaptureMode Requested) {
    final Format = Item.formatName.toLowerCase();
    final FormatPenalty = Format == Requested.Format ? 0 : 4;
    final ResolutionPenalty = (Item.width - Requested.Width).abs() + (Item.height - Requested.Height).abs();
    final FpsPenalty = (Item.fps - Requested.MaxFps).abs();
    return FormatPenalty + ResolutionPenalty * 4 + FpsPenalty * 16;
  }

  UvcCameraMode PickNative(List<UvcCameraMode> Items, CaptureMode Requested) {
    var Best = Items.first;
    var BestScore = ModeScore(Best, Requested);
    for (final Item in Items.skip(1)) {
      final Score = ModeScore(Item, Requested);
      if (Score < BestScore) {
        Best = Item;
        BestScore = Score;
      }
    }
    return Best;
  }

  List<UvcCameraMode> OrderedCandidates(List<UvcCameraMode> Items, CaptureMode Requested) {
    final Sorted = List<UvcCameraMode>.of(Items);
    Sorted.sort((Left, Right) => ModeScore(Left, Requested).compareTo(ModeScore(Right, Requested)));
    return Sorted;
  }

  Future<void> OpenDevice(int Id) async {
    if (Camera.openedDeviceId == Id) return;
    if (Camera.openedDeviceId != null) await Camera.closeUsbDevice();
    await Camera.openUsbDevice(Id);
    DeviceId = Id;
  }

  Future<void> CloseDevice() async {
    if (Camera.openedDeviceId == null) {
      DeviceId = -1;
      return;
    }
    try {
      await Camera.closeUsbDevice();
    } catch (_) {}
    DeviceId = -1;
  }

  @override
  Future<CaptureMode> Prepare(CaptureDevice Device, CaptureMode Requested, RecordSettings Value) async {
    await Release();
    AudioEnabled = Value.MobileAudio;
    AudioDevice = Value.MobileAudioDevice;
    Quality = Value.Quality;
    Flip = Value.FlipVertical;
    final IdValue = int.tryParse(Device.Id.split(':').last) ?? -1;
    if (IdValue < 0) throw StateError('未找到采集卡');
    await OpenDevice(IdValue);
    try {
      final Items = ModeCache[IdValue] ?? Camera.supportedModes().where((Item) => Item.width > 0 && Item.height > 0 && Item.fps > 0).toList();
      if (Items.isEmpty) throw StateError('采集卡没有可用格式');
      ModeCache[IdValue] = List<UvcCameraMode>.of(Items);
      final Texture = await Camera.createPreviewTexture();
      TextureId = Texture;
      UvcPreviewStartResult? Started;
      Object? LastError;
      final Candidates = OrderedCandidates(Items, Requested);
      for (final Candidate in Candidates.take(4)) {
        try {
          final Result = await Camera.startPreview(Candidate);
          if (Result.success) {
            Started = Result;
            break;
          }
          LastError = Result.lastError ?? '采集卡预览启动失败';
        } catch (Cause) {
          LastError = Cause;
        }
      }
      if (Started == null) throw StateError('${LastError ?? '采集卡预览启动失败'}');
      await Camera.attachPreviewTexture(Texture, width: Started.mode.width, height: Started.mode.height);
      NativeMode = Started.mode;
      Mode = CaptureMode(
        Format: Started.mode.formatName.toLowerCase(),
        Width: Started.mode.width,
        Height: Started.mode.height,
        MinFps: Started.mode.fps,
        MaxFps: Started.mode.fps,
      );
      Active = true;
      return Mode!;
    } catch (Cause) {
      await Release();
      rethrow;
    }
  }

  @override
  Future<String> StartRecording(String Path) async {
    if (!Active || Mode == null) throw StateError('采集卡未就绪');
    Target = Path;
    try {
      Camera.startVideoRecording(
        Path,
        bitrateBps: MobileBitrate(Mode!, Quality),
        transform: UvcPreviewTransform(flipVertical: Flip),
      );
    } catch (Cause) {
      Target = null;
      rethrow;
    }
    return Path;
  }

  @override
  Future<String?> StopRecording() async {
    final Path = Target;
    Target = null;
    if (!Camera.isRecording) return Path;
    try {
      Camera.stopVideoRecording();
    } catch (_) {}
    return Path;
  }

  @override
  Future<String?> Finish(String Video, String? Audio, String Target, {int AudioOffsetUs = 0}) async {
    if (Audio == null || !File(Audio).existsSync()) return Video;
    final Temp = '$Target.mux.mp4';
    final Ok = await AndroidAudio.Mux(Video: Video, Audio: Audio, Output: Temp, AudioOffsetUs: AudioOffsetUs);
    if (!Ok || !File(Temp).existsSync()) {
      try {
        if (File(Temp).existsSync()) await File(Temp).delete();
      } catch (_) {}
      return File(Video).existsSync() ? Video : null;
    }
    try {
      if (File(Target).existsSync()) await File(Target).delete();
      await File(Temp).rename(Target);
      await File(Audio).delete();
      return Target;
    } catch (_) {
      return File(Video).existsSync() ? Video : null;
    }
  }

  @override
  Future<void> Release() async {
    Active = false;
    Target = null;
    NativeMode = null;
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
    await CloseDevice();
  }

  @override
  Widget BuildPreview() {
    if (TextureId < 0) return const SizedBox.shrink();
    return Texture(textureId: TextureId, filterQuality: FilterQuality.low);
  }
}
