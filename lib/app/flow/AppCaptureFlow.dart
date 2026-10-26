part of 'package:splatoon3record/app/AppController.dart';

extension AppCaptureFlow on AppController {




  Future<void> DevicesRefresh() async {
    try {
      Devices = await Capture.Devices(Refresh: true);
    } catch (_) {
      Devices = <CaptureDevice>[];
    }
  }

  Future<void> EnsureDevice() async {
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
      final Preferred = AudioDevices.firstWhere(
        (Item) => RegExp('hdmi|line|capture|game|采集|线路', caseSensitive: false).hasMatch(Item.Name),
        orElse: () => AudioDevices.first,
      );
      Next = Next.Copy(<String, dynamic>{'audioDevice': Preferred.Id});
      Changed = true;
    }
    if (Changed) await Configs.SaveSettings(Next);
  }

  String? HardwareName(String? Encoder) {
    if (Encoder == null) return null;
    if (Encoder.contains('nvenc')) return 'NVIDIA';
    if (Encoder.contains('qsv')) return 'Intel';
    if (Encoder.contains('amf')) return 'AMD';
    return '软件';
  }

  Future<void> StartPreview() async {
    PreviewStopping = false;
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
    try {
      await Capture.Start(SettingsValue);
      Notice = Capture.Error.value ?? '已开始录制';
      if (Capture.Error.value == null) await StartPreview();
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
    try {
      await StopPreview();
      await Capture.Stop();
      await Capture.Records();
      Notice = '已停止录制';
    } finally {
      Busy = false;
      PushStatus();
    }
  }

  Future<void> RetryRecord() async {
    await StopPreview();
    await Capture.Stop();
    await StartRecord();
  }

  Future<void> StartLive() async {
    final Target = PushTarget(SettingsValue.RtmpPushUrl, SettingsValue.RtmpPushKey);
    if (Target.isEmpty) {
      Notice = '请先填写 RTMP 推流地址';
      Notify();
      return;
    }
    await Capture.Start(SettingsValue, LiveUrl: Target);
    Notice = Capture.Error.value ?? '已开始直播';
    if (Capture.Error.value == null) await StartPreview();
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
        Previous.RtmpStreamKey != Value.RtmpStreamKey;
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
    PushStatus();
  }

  Future<void> SetMonitor(bool Value) async {
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










