import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:splatoon3record/nso/backend.dart';
import 'package:splatoon3record/nso/nsoService.dart';

void main() {
  final Servers = <HttpServer>[];

  Future<HttpServer> Serve(Future<void> Function(HttpRequest) Handler) async {
    final Server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Servers.add(Server);
    Server.listen((Request) => Handler(Request));
    return Server;
  }

  tearDown(() async {
    for (final Server in Servers) {
      await Server.close(force: true);
    }
    Servers.clear();
  });

  test('probe reports online version and latency', () async {
    final Server = await Serve((Request) async {
      Request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(<String, String>{'nso_version': '3.6.0'}));
      await Request.response.close();
    });
    final Status = await const NSOBackendProbe(
      Timeout: Duration(seconds: 2),
    ).Probe('http://127.0.0.1:${Server.port}/');
    expect(Status.Online, true);
    expect(Status.Version, '3.6.0');
    expect(Status.Url, 'http://127.0.0.1:${Server.port}');
    expect(Status.LatencyMs >= 0, true);
    expect(Status.Error, isNull);
  });

  test('probe keeps HTTP failure detail', () async {
    final Server = await Serve((Request) async {
      Request.response.statusCode = HttpStatus.serviceUnavailable;
      await Request.response.close();
    });
    final Status = await const NSOBackendProbe(
      Timeout: Duration(seconds: 2),
    ).Probe('http://127.0.0.1:${Server.port}');
    expect(Status.Online, false);
    expect(Status.Error, contains('503'));
  });

  test('probe times out instead of hanging on a stalled response', () async {
    final Server = await Serve((Request) async {
      try {
        Request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write('{"nso_version":');
        await Request.response.flush();
      } catch (_) {}
    });
    final Started = DateTime.now();
    final Status = await const NSOBackendProbe(
      Timeout: Duration(milliseconds: 250),
    ).Probe('http://127.0.0.1:${Server.port}');
    expect(Status.Online, false);
    expect(Status.Error, contains('超时'));
    expect(DateTime.now().difference(Started).inMilliseconds, lessThan(3000));
  });

  test('probe all prefers an online fallback', () async {
    final Down = await Serve((Request) async {
      Request.response.statusCode = HttpStatus.serviceUnavailable;
      await Request.response.close();
    });
    final Up = await Serve((Request) async {
      Request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(<String, String>{'nso_version': '3.6.0'}));
      await Request.response.close();
    });
    final Status = await const NSOBackendProbe(Timeout: Duration(seconds: 2))
        .ProbeAll(<String>[
          'http://127.0.0.1:${Down.port}',
          'http://127.0.0.1:${Up.port}',
        ]);
    expect(Status.Online, true);
    expect(Status.Url, 'http://127.0.0.1:${Up.port}');
  });

  test('timeout errors are human readable', () {
    expect(NSOService.ErrorText(TimeoutException('slow')), '网络请求超时，请检查网络后重试');
    expect(NSOService.ErrorText(StateError('Nintendo 登录失败')), 'Nintendo 登录失败');
  });
}
