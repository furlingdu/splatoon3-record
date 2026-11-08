import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

enum NSOBackendState { Online, Offline }

class NSOBackendStatus {
  const NSOBackendStatus({
    required this.Url,
    required this.State,
    this.Version,
    this.LatencyMs = 0,
    this.Error,
  });

  final String Url;
  final NSOBackendState State;
  final String? Version;
  final int LatencyMs;
  final String? Error;

  bool get Online => State == NSOBackendState.Online;
}

class NSOBackendProbe {
  const NSOBackendProbe({this.Timeout = const Duration(seconds: 6)});

  final Duration Timeout;

  Future<NSOBackendStatus> Probe(String Server) async {
    final Base = Server.trim().replaceAll(RegExp(r'/+$'), '');
    final Started = DateTime.now();
    final Client = http.Client();
    try {
      final Response = await Client.get(
        Uri.parse('$Base/config'),
      ).timeout(Timeout);
      final Latency = DateTime.now().difference(Started).inMilliseconds;
      if (Response.statusCode < 200 || Response.statusCode >= 300) {
        return NSOBackendStatus(
          Url: Base,
          State: NSOBackendState.Offline,
          LatencyMs: Latency,
          Error: 'HTTP ${Response.statusCode}',
        );
      }
      Object? Data;
      try {
        Data = jsonDecode(Response.body);
      } on FormatException {
        return NSOBackendStatus(
          Url: Base,
          State: NSOBackendState.Offline,
          LatencyMs: Latency,
          Error: '响应不是有效 JSON',
        );
      }
      if (Data is! Map) {
        return NSOBackendStatus(
          Url: Base,
          State: NSOBackendState.Offline,
          LatencyMs: Latency,
          Error: '响应格式错误',
        );
      }
      final Version = '${Data['nso_version'] ?? ''}';
      return NSOBackendStatus(
        Url: Base,
        State: NSOBackendState.Online,
        Version: Version.isEmpty ? null : Version,
        LatencyMs: Latency,
      );
    } on TimeoutException {
      return NSOBackendStatus(
        Url: Base,
        State: NSOBackendState.Offline,
        LatencyMs: DateTime.now().difference(Started).inMilliseconds,
        Error: '请求超时（${Timeout.inSeconds} 秒）',
      );
    } catch (Cause) {
      return NSOBackendStatus(
        Url: Base,
        State: NSOBackendState.Offline,
        LatencyMs: DateTime.now().difference(Started).inMilliseconds,
        Error: _ErrorText(Cause),
      );
    } finally {
      Client.close();
    }
  }

  Future<NSOBackendStatus> ProbeAll(Iterable<String> Servers) async {
    final Urls = Servers.map(
      (Item) => Item.trim().replaceAll(RegExp(r'/+$'), ''),
    ).where((Item) => Item.isNotEmpty).toSet().toList();
    if (Urls.isEmpty)
      return const NSOBackendStatus(
        Url: '',
        State: NSOBackendState.Offline,
        Error: '未配置 znca 实例',
      );
    final Results = await Future.wait(Urls.map(Probe));
    return Results.firstWhere(
      (Item) => Item.Online,
      orElse: () => Results.first,
    );
  }

  String _ErrorText(Object Cause) {
    if (Cause is TimeoutException) return '请求超时（${Timeout.inSeconds} 秒）';
    final Text = '$Cause'.trim();
    if (Text.isEmpty) return '连接失败';
    return Text.length > 160 ? '${Text.substring(0, 160)}…' : Text;
  }
}
