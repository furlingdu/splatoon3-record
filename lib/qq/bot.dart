import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../config/constants.dart';
import 'package:web_socket_channel/io.dart';

class QQBot {
  QQBot({this.OnState, this.OnMessage});

  final void Function(String State)? OnState;
  final void Function(String OpenId, String Content)? OnMessage;
  IOWebSocketChannel? _Socket;
  Timer? _Heartbeat;
  String? _Token;
  String? _OpenId;
  int? _Sequence;
  bool _Stopped = false;

  Future<void> Start(String AppId, String Secret) async {
    await Stop();
    _Stopped = false;
    OnState?.call('connecting');
    try {
      _Token = await _AccessToken(AppId, Secret);
      final Gateway = await _Gateway(_Token!);
      final Socket = IOWebSocketChannel.connect(Uri.parse(Gateway));
      _Socket = Socket;
      Socket.stream.listen(Receive, onError: (_) => OnState?.call('error'), onDone: () {
        if (!_Stopped) OnState?.call('error');
      });
    } catch (_) {
      OnState?.call('error');
    }
  }

  Future<String> _AccessToken(String AppId, String Secret) async {
    final Response = await http.post(
      Uri.parse(Config.QQTokenUrl),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{'appId': AppId, 'clientSecret': Secret}),
    ).timeout(const Duration(seconds: 15));
    final Data = jsonDecode(Response.body);
    if (Data is! Map || Data['access_token'] is! String) throw StateError('QQ Token 获取失败');
    return Data['access_token'] as String;
  }

  Future<String> _Gateway(String Token) async {
    final Response = await http.get(
      Uri.parse('${Config.QQApi}/gateway'),
      headers: <String, String>{'Authorization': 'QQBot $Token'},
    ).timeout(const Duration(seconds: 15));
    final Data = jsonDecode(Response.body);
    if (Data is! Map || Data['url'] is! String) throw StateError('QQ Gateway 获取失败');
    return Data['url'] as String;
  }

  void Receive(dynamic Raw) {
    final Data = jsonDecode('$Raw');
    if (Data is! Map) return;
    final Op = Data['op'];
    if (Data['s'] is int) _Sequence = Data['s'] as int;
    if (Op == 10) {
      final Interval = Data['d'] is Map && Data['d']['heartbeat_interval'] is num ? (Data['d']['heartbeat_interval'] as num).toInt() : 30000;
      _Socket?.sink.add(jsonEncode(<String, dynamic>{
        'op': 2,
        'd': <String, dynamic>{'token': 'QQBot $_Token', 'intents': (1 << 25) | (1 << 12)},
      }));
      _Heartbeat?.cancel();
      _Heartbeat = Timer.periodic(Duration(milliseconds: Interval), (_) {
        _Socket?.sink.add(jsonEncode(<String, dynamic>{'op': 1, 'd': _Sequence}));
      });
      return;
    }
    if (Op == 0 && Data['t'] == 'READY') {
      OnState?.call('connected');
      return;
    }
    if (Op == 0 && Data['t'] == 'C2C_MESSAGE_CREATE' && Data['d'] is Map) {
      final Event = Data['d'] as Map;
      final Author = Event['author'] is Map ? Event['author'] as Map : const <String, dynamic>{};
      final Id = '${Author['user_openid'] ?? ''}';
      final Content = '${Event['content'] ?? ''}';
      if (Id.isNotEmpty) {
        _OpenId = Id;
        OnMessage?.call(Id, Content);
      }
      return;
    }
    if (Op == 7 || Op == 9) {
      OnState?.call('error');
    }
  }

  Future<void> SendText(String OpenId, String Text) async {
    final Token = _Token;
    if (Token == null) return;
    await http.post(
      Uri.parse('${Config.QQApi}/v2/users/$OpenId/messages'),
      headers: <String, String>{'Authorization': 'QQBot $Token', 'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{'content': Text, 'msg_type': 0}),
    ).timeout(const Duration(seconds: 30));
  }

  Future<void> SendMarkdown(String OpenId, String Text) async {
    final Token = _Token;
    if (Token == null) return;
    await http.post(
      Uri.parse('${Config.QQApi}/v2/users/$OpenId/messages'),
      headers: <String, String>{'Authorization': 'QQBot $Token', 'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{
        'markdown': <String, dynamic>{'content': Text},
        'msg_type': 2,
      }),
    ).timeout(const Duration(seconds: 30));
  }

  String? get OpenId => _OpenId;

  Future<void> SendVideo(String OpenId, String Path) async {
    final Token = _Token;
    if (Token == null) return;
    final FileRef = File(Path);
    if (!FileRef.existsSync()) throw StateError('录像文件不存在');
    final Bytes = await FileRef.readAsBytes();
    final Info = Bytes.length > 5 * 1024 * 1024 ? await UploadChunked(OpenId, FileRef, Bytes) : await UploadSmall(OpenId, Bytes);
    await http.post(
      Uri.parse('${Config.QQApi}/v2/users/$OpenId/messages'),
      headers: <String, String>{'Authorization': 'QQBot $Token', 'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{'msg_type': 7, 'media': <String, String>{'file_info': Info}, 'msg_seq': 1}),
    ).timeout(const Duration(seconds: 60));
  }

  Future<String> UploadSmall(String OpenId, List<int> Bytes) async {
    final Data = await ApiPost('/v2/users/$OpenId/files', <String, dynamic>{'file_type': 2, 'srv_send_msg': false, 'file_data': base64Encode(Bytes)});
    final Info = Data['file_info'];
    if (Info is! String || Info.isEmpty) throw StateError('录像上传失败');
    return Info;
  }

  Future<String> UploadChunked(String OpenId, File FileRef, List<int> Bytes) async {
    final Md5 = md5.convert(Bytes).toString();
    final Sha1 = sha1.convert(Bytes).toString();
    final Md5Part = md5.convert(Bytes.sublist(0, Bytes.length > 10002432 ? 10002432 : Bytes.length)).toString();
    final Prepare = await ApiPost('/v2/users/$OpenId/upload_prepare', <String, dynamic>{
      'file_type': 2,
      'file_name': FileRef.uri.pathSegments.last,
      'file_size': Bytes.length,
      'md5': Md5,
      'sha1': Sha1,
      'md5_10m': Md5Part,
    });
    final UploadId = '${Prepare['upload_id'] ?? ''}';
    final Parts = Prepare['parts'] is List ? Prepare['parts'] as List : const <dynamic>[];
    final Block = Prepare['block_size'] is num ? (Prepare['block_size'] as num).toInt() : 0;
    if (UploadId.isEmpty || Parts.isEmpty || Block <= 0) throw StateError('录像分片上传初始化失败');
    for (final Item in Parts) {
      if (Item is! Map) continue;
      final Index = Item['index'] is num ? (Item['index'] as num).toInt() : Item['part_num'] is num ? (Item['part_num'] as num).toInt() : 0;
      final Url = '${Item['presigned_url'] ?? Item['url'] ?? ''}';
      if (Index <= 0 || Url.isEmpty) continue;
      final Offset = (Index - 1) * Block;
      final Length = (Bytes.length - Offset).clamp(0, Block).toInt();
      if (Length <= 0) continue;
      final Chunk = Bytes.sublist(Offset, Offset + Length);
      final Put = await http.put(Uri.parse(Url), headers: <String, String>{'Content-Length': '$Length'}, body: Chunk).timeout(const Duration(minutes: 5));
      if (Put.statusCode < 200 || Put.statusCode >= 300) throw StateError('分片 $Index 上传失败：HTTP ${Put.statusCode}');
      await ApiPost('/v2/users/$OpenId/upload_part_finish', <String, dynamic>{
        'upload_id': UploadId,
        'part_index': Index,
        'block_size': Length,
        'md5': md5.convert(Chunk).toString(),
      });
    }
    final Done = await ApiPost('/v2/users/$OpenId/files', <String, dynamic>{'upload_id': UploadId});
    final Info = Done['file_info'];
    if (Info is! String || Info.isEmpty) throw StateError('录像上传完成失败');
    return Info;
  }

  Future<Map<String, dynamic>> ApiPost(String Path, Map<String, dynamic> Body) async {
    final Token = _Token;
    if (Token == null) throw StateError('QQBot 未连接');
    final Response = await http.post(
      Uri.parse('${Config.QQApi}$Path'),
      headers: <String, String>{'Authorization': 'QQBot $Token', 'Content-Type': 'application/json'},
      body: jsonEncode(Body),
    ).timeout(const Duration(minutes: 5));
    final Data = jsonDecode(Response.body);
    if (Data is! Map<String, dynamic>) throw StateError('QQBot 响应格式错误');
    if (Response.statusCode < 200 || Response.statusCode >= 300) throw StateError('${Data['message'] ?? 'QQBot 请求失败：HTTP ${Response.statusCode}'}');
    return Data;
  }

  Future<void> Stop() async {
    _Stopped = true;
    _Heartbeat?.cancel();
    _Heartbeat = null;
    try {
      await _Socket?.sink.close().timeout(const Duration(seconds: 1));
    } catch (_) {}
    _Socket = null;
    _Token = null;
  }
}













