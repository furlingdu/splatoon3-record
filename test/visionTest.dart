import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:splatoon3record/media/nickname/detect.dart';
import 'package:splatoon3record/media/nickname/events.dart';

void main() {
  test('Decode end-to-end YOLO output and letterbox coordinates', () {
    final Output = <dynamic>[
      <dynamic>[
        <dynamic>[100.0, 380.0, 200.0, 480.0, 0.9, 3.0],
        <dynamic>[0.0, 0.0, 0.0, 0.0, 0.1, 0.0],
      ],
    ];
    final Boxes = DecodeDetections(Output, Width: 1280, Height: 720, InputSize: 1280, Confidence: 0.8);
    expect(Boxes.length, 1);
    expect(Boxes.first.Label, 3);
    expect(Boxes.first.Confidence, closeTo(0.9, 0.001));
    expect(Boxes.first.Left, closeTo(100 / 1280, 0.001));
    expect(Boxes.first.Top, closeTo(100 / 720, 0.001));
    expect(Boxes.first.Right, closeTo(200 / 1280, 0.001));
    expect(Boxes.first.Bottom, closeTo(200 / 720, 0.001));
  });

  test('Letterbox fills gray and preserves source aspect', () {
    final Rgba = Uint8List(640 * 360 * 4);
    for (var Index = 0; Index < 640 * 360; Index++) {
      Rgba[Index * 4] = 255;
      Rgba[Index * 4 + 3] = 255;
    }
    final Shot = BuildLetterbox(Rgba, 640, 360, 1280);
    expect(Shot.Scale, 2);
    expect(Shot.PadX, 0);
    expect(Shot.PadY, 280);
    expect(Shot.Blob[0], closeTo(114 / 255, 0.001));
    final Offset = (280 * 1280) * 3;
    expect(Shot.Blob[Offset], closeTo(1, 0.001));
  });

  test('Detection gate fires once and rearms after absence', () {
    final Gate = DetectionGate(RequiredHits: 2, CooldownMs: 1000, ReleaseMs: 1000);
    expect(Gate.Update(1000, true, 500), isNull);
    expect(Gate.Update(1500, true, 500), 1000);
    expect(Gate.Update(2000, true, 500), isNull);
    expect(Gate.Update(2500, false, 500), isNull);
    expect(Gate.Update(3000, false, 500), isNull);
    expect(Gate.Update(3500, true, 500), isNull);
    expect(Gate.Update(4000, true, 500), 3500);
  });

  test('Work timeline pairs detected start and end with NSO end', () {
    final Timeline = WorkTimeline();
    Timeline.Add(WorkEventKind.start, 1000, 0.9);
    Timeline.Add(WorkEventKind.end, 5000, 0.9);
    final Result = Timeline.Resolve(5100);
    expect(Result.StartAt, 1000);
    expect(Result.EndAt, 5000);
    expect(Result.Exact, true);
  });

  test('Work timeline detects when NSO time is the start', () {
    final Timeline = WorkTimeline();
    Timeline.Add(WorkEventKind.start, 1000, 0.9);
    Timeline.Add(WorkEventKind.end, 5000, 0.9);
    final Result = Timeline.Resolve(900);
    expect(Result.StartAt, 1000);
    expect(Result.EndAt, 5000);
    expect(Result.Exact, true);
  });

  test('Work timeline falls back when no events exist', () {
    final Timeline = WorkTimeline();
    final Result = Timeline.Resolve(1000000);
    expect(Result.EndAt, 1000000);
    expect(Result.StartAt, 400000);
    expect(Result.Exact, false);
  });
}
