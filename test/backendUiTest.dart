import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splatoon3record/app/controller.dart';
import 'package:splatoon3record/nso/backend.dart';
import 'package:splatoon3record/ui/nsoBackend.dart';

void main() {
  testWidgets('backend bar renders online and offline states', (tester) async {
    final Online = AppController()
      ..NSOBackend = const NSOBackendStatus(
        Url: 'https://znca.example.test/api/znca',
        State: NSOBackendState.Online,
        Version: '3.6.0',
        LatencyMs: 42,
      );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NSOBackendBar(Controller: Online)),
      ),
    );
    expect(find.textContaining('znca 校验服务可用'), findsOneWidget);
    expect(find.textContaining('NSO 3.6.0'), findsOneWidget);

    final Offline = AppController()
      ..NSOBackend = const NSOBackendStatus(
        Url: 'https://znca.example.test/api/znca',
        State: NSOBackendState.Offline,
        Error: 'HTTP 503',
      );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NSOBackendBar(Controller: Offline)),
      ),
    );
    expect(find.textContaining('znca 校验服务不可用'), findsOneWidget);
    expect(find.textContaining('HTTP 503'), findsOneWidget);
  });
}
