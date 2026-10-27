import 'package:flutter/widgets.dart';
import 'package:haishin_kit/haishin_kit.dart';

class MobileLiveService {
  final ValueNotifier<String> State = ValueNotifier<String>('idle');
  final ValueNotifier<String?> Error = ValueNotifier<String?>(null);

  MediaMixer? _Mixer;
  StreamSession? _Session;
  String? _Target;
  VideoSource? _Source;

  bool get Running => _Session != null;

  String? get Target => _Target;

  VideoSource? get Source => _Source;

  Future<List<VideoSource>> Sources() async {
    try {
      return await HaishinKitPlatformInterface.instance.videoSources;
    } catch (_) {
      return const <VideoSource>[];
    }
  }

  Future<void> Start(String Url, {String? VideoId, int Width = 1280, int Height = 720, int Fps = 30, int Bitrate = 4000000}) async {
    if (_Session != null) return;
    Error.value = null;
    State.value = 'starting';
    var Started = false;
    try {
      final List<VideoSource> Items = await Sources();
      if (Items.isEmpty) throw StateError('没有可用的摄像头');
      final Picked = Items.firstWhere((VideoSource Item) => Item.id == VideoId, orElse: () => Items.first);
      final Mixer = await MediaMixer.create(options: const MediaMixerOptions(captureSessionMode: CaptureSessionMode.multi));
      _Mixer = Mixer;
      await Mixer.attachAudio(0, AudioSource());
      await Mixer.attachVideo(0, Picked);
      Mixer.frameRate = Fps;
      await Mixer.startRunning();
      final Session = await StreamSession.create(Url, StreamSessionMode.publish);
      Session.videoSettings = VideoCodecSettings(width: Width, height: Height, bitrate: Bitrate, frameInterval: Fps);
      _Session = Session;
      _Target = Url;
      _Source = Picked;
      await Session.connect();
      Started = true;
      State.value = 'live';
    } catch (Cause) {
      Error.value = '$Cause';
      State.value = 'error';
      await Stop();
      State.value = 'error';
    }
    if (!Started && State.value != 'error') State.value = 'idle';
  }

  Future<void> Stop() async {
    final Session = _Session;
    _Session = null;
    if (Session != null) {
      try {
        await Session.close();
      } catch (_) {}
      try {
        await Session.dispose();
      } catch (_) {}
    }
    final Mixer = _Mixer;
    _Mixer = null;
    if (Mixer != null) {
      try {
        await Mixer.stopRunning();
      } catch (_) {}
      try {
        await Mixer.dispose();
      } catch (_) {}
    }
    _Target = null;
    if (State.value != 'error') State.value = 'idle';
  }

  Widget? BuildPreview() {
    final Session = _Session;
    if (Session == null) return null;
    return StreamSessionViewTexture(Session);
  }

  Future<void> Dispose() async {
    await Stop();
    State.dispose();
    Error.dispose();
  }
}
