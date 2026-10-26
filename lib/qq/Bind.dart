import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../config/Config.dart';

class QQBind {
  QQBind({this.OnQr, this.OnState, this.OnSuccess});

  final void Function(String Url)? OnQr;
  final void Function(String State)? OnState;
  final void Function(String AppId, String Secret)? OnSuccess;

  static const String Host = Config.QQHost;
  Timer? _Timer;
  bool _Busy = false;

  Future<void> Start() async {
    await Stop();
    OnState?.call('connecting');
    try {
      final Key = Base64Encoder().convert(List<int>.generate(32, (_) => Random.secure().nextInt(256)));
      final Task = await _Post('https://$Host/lite/create_bind_task', <String, dynamic>{'key': Key});
      final TaskId = '${Task['data']?['task_id'] ?? ''}';
      if (TaskId.isEmpty) throw StateError('create_bind_task: missing task_id');
      final Url = 'https://$Host/qqbot/openclaw/connect.html?task_id=${Uri.encodeComponent(TaskId)}&source=${Uri.encodeComponent('Splatoon3Record')}&_wv=2';
      OnQr?.call(Url);
      _Busy = true;
      _Timer = Timer.periodic(const Duration(seconds: 2), (_) => Poll(TaskId, Key));
    } catch (Cause) {
      OnState?.call('error');
      throw StateError('获取绑定任务失败：$Cause');
    }
  }

  Future<void> Poll(String TaskId, String Key) async {
    if (!_Busy) return;
    try {
      final Result = await _Post('https://$Host/lite/poll_bind_result', <String, dynamic>{'task_id': TaskId});
      final Data = Result['data'] is Map ? Result['data'] as Map : const <String, dynamic>{};
      final Status = Data['status'] is num ? (Data['status'] as num).toInt() : 0;
      if (Status == 2) {
        _Busy = false;
        _Timer?.cancel();
        _Timer = null;
        final Secret = await _Decrypt('${Data['bot_encrypt_secret'] ?? ''}', Key);
        OnQr?.call('');
        OnSuccess?.call('${Data['bot_appid'] ?? ''}', Secret);
        OnState?.call('connected');
        return;
      }
      if (Status == 3) {
        await Start();
      }
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _Post(String Url, Map<String, dynamic> Body) async {
    final Response = await http.post(Uri.parse(Url), headers: <String, String>{'Content-Type': 'application/json', 'Accept': 'application/json'}, body: jsonEncode(Body)).timeout(const Duration(seconds: 10));
    if (Response.statusCode != 200) throw StateError('HTTP ${Response.statusCode}');
    final Value = jsonDecode(Response.body);
    if (Value is! Map<String, dynamic>) throw StateError('响应格式错误');
    if (Value['retcode'] != 0) throw StateError('${Value['msg'] ?? 'request failed'}');
    return Value;
  }

  Future<String> _Decrypt(String Encoded, String Key) async {
    final KeyBytes = base64Decode(Key);
    final Bytes = base64Decode(Encoded);
    final Nonce = Bytes.sublist(0, 12);
    final Tag = Bytes.sublist(Bytes.length - 16);
    final Cipher = Bytes.sublist(12, Bytes.length - 16);
    final Clear = await AesGcm.with256bits().decrypt(SecretBox(Cipher, nonce: Nonce, mac: Mac(Tag)), secretKey: SecretKey(KeyBytes));
    return utf8.decode(Clear);
  }

  Future<void> Stop() async {
    _Busy = false;
    _Timer?.cancel();
    _Timer = null;
  }
}










