import 'package:flutter_test/flutter_test.dart';
import 'package:splatoon3record/app/SetupGating.dart';
import 'package:splatoon3record/domain/Models.dart';
import 'package:splatoon3record/media/capture/mobile/MobileModes.dart';

CaptureMode Mode(int Width, int Height, int Fps, String Format) {
  return CaptureMode(Format: Format, Width: Width, Height: Height, MinFps: Fps, MaxFps: Fps);
}

NSOAccount Account(String State) {
  return NSOAccount(
    Id: State,
    Nickname: State,
    Session: 'session',
    Token: NSOToken(BulletToken: '', GToken: '', Language: 'zh-CN', Country: 'CN', UserAgent: '', ExpiresAt: 0),
    AddedAt: 0,
    State: State,
  );
}

void main() {
  test('Mobile modes list actual resolutions and frame rates', () {
    final Items = <CaptureMode>[
      Mode(1920, 1080, 30, 'yuy2'),
      Mode(1920, 1080, 60, 'mjpeg'),
      Mode(1280, 720, 60, 'mjpeg'),
      Mode(1280, 720, 60, 'yuy2'),
    ];
    expect(MobileModes.Resolutions(Items), <String>['1920x1080', '1280x720']);
    expect(MobileModes.FpsList(Items, 1920, 1080), <int>[60, 30]);
    expect(MobileModes.FpsList(Items, 1280, 720), <int>[60]);
  });

  test('Mobile mode pick prefers actual frame rate and format', () {
    final Items = <CaptureMode>[
      Mode(1920, 1080, 30, 'yuy2'),
      Mode(1920, 1080, 60, 'yuy2'),
      Mode(1920, 1080, 60, 'mjpeg'),
      Mode(1280, 720, 60, 'mjpeg'),
    ];
    final Picked = MobileModes.Pick(Items, 1920, 1080, 60);
    expect(Picked, isNotNull);
    expect(Picked!.Width, 1920);
    expect(Picked.MaxFps, 60);
    expect(Picked.Format, 'mjpeg');
    expect(MobileModes.Pick(Items, 1366, 768, 60), isNull);
  });

  test('Mobile best mode respects display refresh preference', () {
    final Items = <CaptureMode>[
      Mode(3840, 2160, 30, 'mjpeg'),
      Mode(1920, 1080, 60, 'mjpeg'),
      Mode(1920, 1080, 120, 'mjpeg'),
      Mode(1280, 720, 120, 'mjpeg'),
    ];
    final Pick60 = MobileModes.Best(Items, PreferredFps: 60);
    expect(Pick60, isNotNull);
    expect(Pick60!.Width, 1920);
    expect(Pick60.MaxFps, 60);
    final Pick120 = MobileModes.Best(Items, PreferredFps: 120);
    expect(Pick120, isNotNull);
    expect(Pick120!.MaxFps, 120);
    expect(MobileModes.Contains(Items, 1920, 1080, 120), true);
    expect(MobileModes.Contains(Items, 1920, 1080, 90), false);
  });

  test('Setup gating needs NSO and QQBot connectivity', () {
    expect(SetupGating.NSOReady(<NSOAccount>[Account('expired')]), false);
    expect(SetupGating.NSOReady(<NSOAccount>[Account('expired'), Account('connected')]), true);
    expect(SetupGating.QQReady('connecting', true), false);
    expect(SetupGating.QQReady('connected', false), false);
    expect(SetupGating.QQReady('connected', true), true);
    final Items = <CaptureMode>[Mode(1920, 1080, 60, 'mjpeg')];
    expect(SetupGating.ModeReady(Items, 1920, 1080, 60), true);
    expect(SetupGating.ModeReady(Items, 1920, 1080, 30), false);
    expect(SetupGating.DeviceReady('uvc:1', Items, 1920, 1080, 60), true);
    expect(SetupGating.DeviceReady('', Items, 1920, 1080, 60), false);
  });
}
