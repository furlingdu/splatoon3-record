part of 'package:splatoon3record/app/controller.dart';

extension AppCaptureFlow on AppController {




  Future<void> DevicesRefresh() async {
    try {
      Devices = await Capture.Devices(Refresh: true);
    } catch (_) {
      Devices = <CaptureDevice>[];
    }
    final Videos = Devices.where((Item) => Item.Kind == 'video').toList();
    final Audios = Devices.where((Item) => Item.Kind == 'audio').toList();
    await Logs.App('devices video=${Videos.length} [${Videos.map((Item) => '${Item.Name}（${Item.Id}）').join('、')}] audio=${Audios.length} [${Audios.map((Item) => '${Item.Name}（${Item.Id}）').join('、')}]');
  }

  Future<void> NormalizeMobileSettings() async {
    if (!PlatformInfo.Mobile) return;
    final Default = PlatformInfo.IOS ? 'external' : 'uvc';
    var Next = SettingsValue;
    var Changed = false;
    if (Next.MobileSource != Default) {
      Next = Next.Copy(<String, dynamic>{'mobileSource': Default});
      Changed = true;
    }
    if (Next.MobileDevice.isNotEmpty && !Next.MobileDevice.startsWith('$Default:')) {
      Next = Next.Copy(<String, dynamic>{'mobileDevice': ''});
      Changed = true;
    }
    if (!Next.MobileAudio) {
      Next = Next.Copy(<String, dynamic>{'mobileAudio': true});
      Changed = true;
    }
    if (Changed) {
      await Configs.SaveSettings(Next);
      await Logs.App('mobile settings normalized source=${Next.MobileSource} device=${Next.MobileDevice} audio=${Next.MobileAudio}');
    }
  }

  CaptureDevice PreferredAudio(List<CaptureDevice> Items) {
    return Items.firstWhere(
      (Item) => RegExp('hdmi|line|capture|game|usb|uvc|采集|线路|audio', caseSensitive: false).hasMatch(Item.Name),
      orElse: () => Items.first,
    );
  }

  Future<void> EnsureMobileDevice() async {
    final Videos = Devices.where((Item) => Item.Kind == 'video').toList();
    final Audios = Devices.where((Item) => Item.Kind == 'audio').toList();
    var Next = SettingsValue;
    var Changed = false;
    final CurrentMissing = Next.MobileDevice.isNotEmpty && Videos.isNotEmpty && !Videos.any((Item) => Item.Id == Next.MobileDevice);
    if ((Next.MobileDevice.isEmpty || CurrentMissing) && Videos.isNotEmpty) {
      Next = Next.Copy(<String, dynamic>{'mobileDevice': Videos.first.Id});
      Changed = true;
    }
    if (Audios.isNotEmpty && !Audios.any((Item) => Item.Id == Next.MobileAudioDevice)) {
      Next = Next.Copy(<String, dynamic>{'mobileAudioDevice': PreferredAudio(Audios).Id});
      Changed = true;
    }
    if (Changed) {
      await Configs.SaveSettings(Next);
      await Logs.App('mobile device selected video=${Next.MobileDevice} audio=${Next.MobileAudioDevice}');
    }
  }

  Future<void> EnsureDevice() async {
    if (PlatformInfo.Mobile) {
      await EnsureMobileDevice();
      return;
    }
    final VideoDevices = Devices.where((Item) => Item.Kind == 'video').toList();
    final AudioDevices = Devices.where((Item) => Item.Kind == 'audio').toList();
    var Changed = false;
    var Next = SettingsValue;
    final VideoMissing = Next.VideoDevice.isEmpty || !VideoDevices.any((Item) => Item.Id == Next.VideoDevice);
    final VideoLegacy = RegExp(r'^[0-9a-f]{64}$').hasMatch(Next.VideoDevice);
    if (VideoMissing && VideoDevices.isNotEmpty) {
      if (Next.VideoDevice.isEmpty) {
        Next = Next.Copy(<String, dynamic>{'videoDevice': VideoDevices.first.Id});
        final Modes = await Capture.Modes(VideoDevices.first.Id).catchError((_) => <CaptureMode>[]);
        final Picked = PickMode(Next, Modes);
        if (Picked != null) {
          Next = Next.Copy(<String, dynamic>{'width': Picked.Width, 'height': Picked.Height, 'fps': Picked.MaxFps, 'captureFormat': Picked.Format});
        }
        Changed = true;
      } else if (VideoLegacy) {
        Next = Next.Copy(<String, dynamic>{'videoDevice': ''});
        Changed = true;
      }
    }
    if (Next.VideoDevice.isNotEmpty) {
      final Modes = await Capture.Modes(Next.VideoDevice).catchError((_) => <CaptureMode>[]);
      final Picked = PickMode(Next, Modes);
      if (Picked != null && (Picked.Width != Next.Width || Picked.Height != Next.Height || Picked.MaxFps != Next.Fps || Picked.Format != Next.CaptureFormat)) {
        Next = Next.Copy(<String, dynamic>{'width': Picked.Width, 'height': Picked.Height, 'fps': Picked.MaxFps, 'captureFormat': Picked.Format});
        Changed = true;
      }
    }
    if (Next.AudioDevice.isNotEmpty && !AudioDevices.any((Item) => Item.Id == Next.AudioDevice)) {
      Next = Next.Copy(<String, dynamic>{'audioDevice': ''});
      Changed = true;
    }
    if (Next.AudioDevice.isEmpty && AudioDevices.isNotEmpty) {
      Next = Next.Copy(<String, dynamic>{'audioDevice': PreferredAudio(AudioDevices).Id});
      Changed = true;
    }
    if (Changed) await Configs.SaveSettings(Next);
  }

  String? HardwareName(String? Encoder) {
    if (Encoder == null) return null;
    if (Encoder.contains('nvenc')) return 'NVIDIA';
    if (Encoder.contains('qsv')) return 'Intel';
    if (Encoder.contains('amf')) return 'AMD';
    if (Encoder.endsWith('_mf')) return 'Media Foundation';
    if (Encoder.endsWith('_videotoolbox')) return 'VideoToolbox';
    if (Encoder.endsWith('_mediacodec')) return 'MediaCodec';
    return '软件';
  }

  Future<void> StartPreview() async {
    PreviewStopping = false;
    if (PlatformInfo.Mobile) {
      PreviewReady = Capture.PreviewActive.value;
      PreviewMessage = PreviewReady ? null : (Capture.Error.value ?? '正在打开采集设备');
      Notify();
      return;
    }
    if (SettingsValue.CaptureMode == 'rtmp' || !CaptureBridge.Supported) {
      PreviewReady = false;
      PreviewMessage = SettingsValue.CaptureMode == 'rtmp' ? 'RTMP 采集模式不提供本地画面预览' : '当前平台暂不提供原生画面预览';
      Notify();
      return;
    }
    final Texture = Capture.PreviewTexture.value;
    final Active = Capture.PreviewActive.value;
    if (Texture == null || Texture < 0) {
      PreviewReady = false;
      PreviewMessage = Capture.Error.value ?? '预览纹理不可用';
      Notify();
      return;
    }
    PreviewReady = Active;
    PreviewMessage = Active ? null : '正在打开采集设备';
    Notify();
  }

  Future<void> StopPreview() async {
    PreviewStopping = true;
    PreviewReady = false;
    PreviewMessage = null;
    Notify();
  }

  Future<void> StartRecord() async {
    if (Busy) return;
    Busy = true;
    Notice = '正在开始录制…';
    Notify();
    await Logs.App('record start mode=${SettingsValue.CaptureMode} device=${PlatformInfo.Mobile ? SettingsValue.MobileDevice : SettingsValue.VideoDevice} audio=${SettingsValue.MobileAudio ? 'on' : 'off'} audioDevice=${PlatformInfo.Mobile ? SettingsValue.MobileAudioDevice : SettingsValue.AudioDevice} monitor=${SettingsValue.MonitorAudio} ${SettingsValue.Width}x${SettingsValue.Height}@${SettingsValue.Fps}');
    try {
      await Capture.Start(SettingsValue);
      final EncoderName = Capture.EncoderName;
      final EncoderNote = EncoderName == 'h264_mf' || EncoderName == 'h264_videotoolbox' ? null : FFmpeg.EncoderNote;
      Notice = Capture.Error.value ?? EncoderNote ?? '已开始录制';
      if (EncoderNote != null && SettingsValue.Encoder != 'software') await Logs.App('encoder fallback $EncoderNote');
      await Logs.App('record start result=${Capture.Error.value ?? 'ok'} encoder=${Capture.EncoderName} actual=${Capture.ActualWidth}x${Capture.ActualHeight}@${Capture.ActualFps}');
      if (Capture.Error.value == null) {
        if (PlatformInfo.Mobile) {
          final Next = SettingsValue.Copy(<String, dynamic>{
            'width': Capture.ActualWidth,
            'height': Capture.ActualHeight,
            'fps': Capture.ActualFps,
          });
          if (Next.Width != SettingsValue.Width || Next.Height != SettingsValue.Height || Next.Fps != SettingsValue.Fps) {
            await SaveSettingsSilent(Next);
          }
        }
        await StartPreview();
      } else if (Capture.PreviewTexture.value != null) {
        await StartPreview();
      }
      await SyncVision();
    } finally {
      Busy = false;
      PushStatus();
    }
  }

  Future<void> StopRecord() async {
    if (Busy) return;
    Busy = true;
    Notice = '正在停止录制并保存分段…';
    Notify();
    await Logs.App('record stop');
    try {
      await StopPreview();
      await Capture.Stop();
      await Capture.Records();
      Notice = '已停止录制';
      await StopVision();
    } finally {
      Busy = false;
      PushStatus();
    }
  }

  Future<void> RetryRecord() async {
    await Logs.App('record retry');
    await StopPreview();
    await Capture.Stop();
    await StartRecord();
  }

  Future<void> StartLive() async {
    if (PlatformInfo.Mobile) {
      Notice = '移动端不支持直播';
      Notify();
      return;
    }
    final Target = PushTarget(SettingsValue.RtmpPushUrl, SettingsValue.RtmpPushKey);
    if (Target.isEmpty) {
      Notice = '请先填写 RTMP 推流地址';
      Notify();
      return;
    }
    await Capture.Start(SettingsValue, LiveUrl: Target);
    Notice = Capture.Error.value ?? '已开始直播';
    if (Capture.Error.value == null) await StartPreview();
    await SyncVision();
    PushStatus();
  }

  Future<void> StopLive() async {
    await StopPreview();
    await Capture.Stop();
    if (SettingsValue.AutoRecord) {
      await Capture.Start(SettingsValue);
      if (Capture.Error.value == null) await StartPreview();
    }
    Notice = '已停止直播';
    await SyncVision();
    PushStatus();
  }

  String PushTarget(String Url, String Key) {
    if (Url.isEmpty) return '';
    return Key.isEmpty ? Url : '${Url.replaceAll(RegExp(r'/+$'), '')}/$Key';
  }

  Future<void> SaveSettings(RecordSettings Value) async {
    final Previous = SettingsValue;
    final DeviceChanged = Previous.VideoDevice != Value.VideoDevice ||
        Previous.AudioDevice != Value.AudioDevice ||
        Previous.CaptureMode != Value.CaptureMode ||
        Previous.CaptureFormat != Value.CaptureFormat ||
        Previous.Width != Value.Width ||
        Previous.Height != Value.Height ||
        Previous.Fps != Value.Fps ||
        Previous.RtmpPort != Value.RtmpPort ||
        Previous.RtmpStreamKey != Value.RtmpStreamKey ||
        (PlatformInfo.Mobile &&
            (Previous.MobileDevice != Value.MobileDevice ||
                Previous.MobileAudio != Value.MobileAudio ||
                Previous.MobileAudioDevice != Value.MobileAudioDevice ||
                Previous.MobileOrientation != Value.MobileOrientation ||
                Previous.FlipVertical != Value.FlipVertical));
    if (DeviceChanged) {
      await Logs.App('settings change mode=${Value.CaptureMode} video=${Value.VideoDevice} audio=${Value.AudioDevice} mobile=${Value.MobileDevice} mobileAudio=${Value.MobileAudio} mobileAudioDevice=${Value.MobileAudioDevice} ${Value.Width}x${Value.Height}@${Value.Fps}');
    }
    await Configs.SaveSettings(Value);
    await ApplyAutoLaunch();
    if (Value.MonitorAudio && Capture.State.value == 'recording') {
      await Capture.StartMonitor(Value);
    } else if (!Value.MonitorAudio) {
      await Capture.StopMonitor();
    }
    final Live = Capture.LiveTarget;
    if (DeviceChanged) {
      await StopPreview();
      await Capture.Stop();
      if (Live != null) {
        await Capture.Start(Value, LiveUrl: Live);
        if (Capture.Error.value == null) await StartPreview();
      } else if (Value.AutoRecord) {
        await StartRecord();
      }
    } else if (Value.AutoRecord && !Capture.Running && !Capture.Starting) {
      await StartRecord();
    } else if (!Value.AutoRecord && Capture.Running && Live == null) {
      await StopRecord();
    }
    await SyncVision();
    PushStatus();
  }

  Future<void> ToggleMonitor(bool Value) async {
    await Logs.App('monitor ${Value ? 'on' : 'off'}');
    final Next = SettingsValue.Copy(<String, dynamic>{'monitorAudio': Value});
    await SaveSettings(Next);
  }

  Future<void> SaveSettingsSilent(RecordSettings Value) async {
    await Configs.SaveSettings(Value);
    PushStatus();
  }

  Future<bool> OpenPreviewWindow() async {
    try {
      final Client = await Socket.connect(InternetAddress.loopbackIPv4, Config.PreviewInstancePort, timeout: const Duration(milliseconds: 500));
      Client.write('SHOW');
      await Client.flush();
      await Client.close();
      return true;
    } catch (_) {}
    try {
      await Process.start(Platform.resolvedExecutable, <String>['--preview'], mode: ProcessStartMode.detached);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> WarmPreviewWindow() async {
    try {
      final Client = await Socket.connect(InternetAddress.loopbackIPv4, Config.PreviewInstancePort, timeout: const Duration(milliseconds: 200));
      Client.destroy();
      return;
    } catch (_) {}
    try {
      await Process.start(Platform.resolvedExecutable, <String>['--preview', '--hidden'], mode: ProcessStartMode.detached);
    } catch (_) {}
  }

}










