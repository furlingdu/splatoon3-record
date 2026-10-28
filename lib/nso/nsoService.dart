import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../config/constants.dart';

class NSOAuthRequest {
  const NSOAuthRequest({required this.Url, required this.State, required this.Verifier});

  final String Url;
  final String State;
  final String Verifier;
}

class NSOSession {
  NSOSession({
    required this.Session,
    required this.GToken,
    required this.BulletToken,
    required this.NaId,
    required this.CoralUserId,
    required this.Language,
    required this.Country,
    required this.Version,
    required this.ExpiresAt,
    this.Nickname = '',
  });

  String Session;
  String GToken;
  String BulletToken;
  String NaId;
  String CoralUserId;
  String Language;
  String Country;
  String Version;
  int ExpiresAt;
  String Nickname;
}

class NSOService {
  NSOService({String? Server}) : Servers = (<String>[if (Server != null) Server, Config.NSOFServer, Config.NSOFServerAlternative]).toSet().toList();

  final List<String> Servers;
  String? _LastServer;
  static const String ClientId = Config.NSOClientId;
  static const String AuthClientId = Config.NSOAuthClientId;
  static const String AuthServer = Config.NSOAuthServer;
  static const String FServer = Config.NSOFServer;
  static const String Coral = Config.NSOCoral;
  static const String SplatNet = Config.NSOSplatNet;
  static const String AppVersion = Config.NSOAppVersion;
  static const String ZncaVersion = Config.NSOZncaVersion;
  static const String ClientVersion = Config.NSOClientVersion;
  static const int WebServiceId = Config.NSOWebServiceId;
  static const String LatestQuery = Config.NSOLatestQuery;
  static const String DetailQuery = Config.NSODetailQuery;

  String? _AccessToken;
  int _AccessExpires = 0;

  void RestoreAuth(String Token, int ExpiresAt) {
    _AccessToken = Token;
    _AccessExpires = ExpiresAt;
  }

  String? get CachedAuth => _AccessToken;
  int get CachedAuthExpires => _AccessExpires;

  NSOAuthRequest BeginAuth() {
    final RandomValue = Random.secure();
    final State = _B64(List<int>.generate(36, (_) => RandomValue.nextInt(256)));
    final Verifier = _B64(List<int>.generate(32, (_) => RandomValue.nextInt(256)));
    final Challenge = _B64(sha256.convert(utf8.encode(Verifier)).bytes);
    final Url = Uri.https('accounts.nintendo.com', '/connect/1.0.0/authorize', <String, String>{
      'state': State,
      'redirect_uri': 'npf$ClientId://auth',
      'client_id': ClientId,
      'scope': 'openid user user.birthday user.screenName',
      'response_type': 'session_token_code',
      'session_token_code_challenge': Challenge,
      'session_token_code_challenge_method': 'S256',
      'theme': 'login_form',
    }).toString();
    return NSOAuthRequest(Url: Url, State: State, Verifier: Verifier);
  }

  Future<String> Exchange(String Code, String Verifier) async {
    final Data = await _PostForm('https://accounts.nintendo.com/connect/1.0.0/api/session_token', <String, String>{
      'client_id': ClientId,
      'session_token_code': Code,
      'session_token_code_verifier': Verifier,
    });
    final Token = '${Data['session_token'] ?? ''}';
    if (Token.isEmpty) throw StateError('Nintendo 登录授权失败');
    return Token;
  }

  Future<NSOSession> Login(String SessionToken) async {
    final Session = NSOSession(Session: SessionToken, GToken: '', BulletToken: '', NaId: '', CoralUserId: '', Language: 'en-GB', Country: 'JP', Version: AppVersion, ExpiresAt: 0);
    final Na = await _PostForm('https://accounts.nintendo.com/connect/1.0.0/api/token', <String, String>{
      'client_id': ClientId,
      'session_token': SessionToken,
      'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer-session-token',
    });
    final IdToken = '${Na['id_token'] ?? ''}';
    if (IdToken.isEmpty) throw StateError('Nintendo 登录已过期');
    final Me = await _GetJson('https://api.accounts.nintendo.com/2.0.0/users/me', <String, String>{'Authorization': 'Bearer ${Na['access_token']}'});
    Session.NaId = '${Me['id'] ?? ''}';
    Session.Nickname = '${Me['nickname'] ?? 'Nintendo 账号'}';
    Session.Language = '${Me['language'] ?? 'en-GB'}';
    Session.Country = '${Me['country'] ?? 'JP'}';
    final Parameter = <String, dynamic>{
      'naIdToken': IdToken,
      'language': Session.Language,
      'timestamp': 0,
      'requestId': '',
      'f': '',
    };
    final F = await _F(idToken: IdToken, NaId: Session.NaId, EncryptUrl: '$Coral/v4/Account/Login', Parameter: Parameter);
    final Login = await _EncryptedCoral('/v4/Account/Login', F, null);
    if (Login['status'] != 0) throw StateError('${Login['errorMessage'] ?? 'NSO 登录失败'}');
    final Result = Login['result'] is Map ? Login['result'] as Map : const <String, dynamic>{};
    final Credential = Result['webApiServerCredential'] is Map ? Result['webApiServerCredential'] as Map : const <String, dynamic>{};
    Session.GToken = '${Credential['accessToken'] ?? ''}';
    Session.CoralUserId = '${Result['user'] is Map ? (Result['user'] as Map)['id'] ?? '' : ''}';
    final Expires = (Credential['expiresIn'] as num?)?.toInt() ?? 7200;
    Session.ExpiresAt = DateTime.now().millisecondsSinceEpoch + Expires * 1000;
    final WebParameter = <String, dynamic>{
      'id': WebServiceId,
      'registrationToken': '',
      'f': '',
      'requestId': '',
      'timestamp': 0,
    };
    final WebF = await _F(idToken: Session.GToken, Token: Session.GToken, NaId: Session.NaId, CoralUserId: Session.CoralUserId, Hash: 2, EncryptUrl: '$Coral/v4/Game/GetWebServiceToken', Parameter: WebParameter);
    final Web = await _EncryptedCoral('/v4/Game/GetWebServiceToken', WebF, Session.GToken);
    if (Web['status'] != 0) throw StateError('${Web['errorMessage'] ?? '获取游戏令牌失败'}');
    final WebToken = Web['result'] is Map ? (Web['result'] as Map)['accessToken'] : null;
    if (WebToken is! String || WebToken.isEmpty) throw StateError('游戏令牌为空');
    final Client = http.Client();
    final Root = await Client.get(
      Uri.parse('$SplatNet/?lang=${Session.Language}&na_country=${Session.Country}&na_lang=${Session.Language}'),
      headers: <String, String>{
        'x-gamewebtoken': WebToken,
        'x-appplatform': 'android',
        'x-appcolorscheme': 'DARK',
        'X-Requested-With': 'com.nintendo.znca',
        'User-Agent': 'Mozilla/5.0 (Linux; Android 8.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/58.0.3029.125 Mobile Safari/537.36',
      },
    ).timeout(const Duration(seconds: 30));
    final Version = Root.headers['x-be-version'] ?? AppVersion;
    Session.Version = Version;
    final Cookie = Root.headers['set-cookie'] ?? '';
    final Bullet = await Client.post(
      Uri.parse('$SplatNet/api/bullet_tokens'),
      headers: <String, String>{
        'X-GameWebToken': WebToken,
        'Content-Type': 'application/json',
        'Accept': '*/*',
        'X-Web-View-Ver': Version,
        'X-NaCountry': Session.Country,
        'Accept-Language': Session.Language,
        'X-Requested-With': 'XMLHttpRequest',
        if (Cookie.isNotEmpty) 'Cookie': Cookie,
        'User-Agent': 'Mozilla/5.0 (Linux; Android 8.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/58.0.3029.125 Mobile Safari/537.36',
      },
      body: '',
    ).timeout(const Duration(seconds: 30));
    Client.close();
    if (Bullet.statusCode != 201) throw StateError('SplatNet 令牌获取失败：HTTP ${Bullet.statusCode} ${Bullet.body}');
    final BulletData = jsonDecode(Bullet.body);
    Session.BulletToken = BulletData is Map ? '${BulletData['bulletToken'] ?? ''}' : '';
    if (Session.BulletToken.isEmpty) throw StateError('SplatNet 令牌为空');
    return Session;
  }

  Future<Map<String, dynamic>> Latest(NSOSession Session) => _Query(Session, LatestQuery, <String, dynamic>{});
  Future<Map<String, dynamic>> Detail(NSOSession Session, String Id) => _Query(Session, DetailQuery, <String, dynamic>{'vsResultId': Id});

  Future<Map<String, dynamic>> _Query(NSOSession Session, String Hash, Map<String, dynamic> Variables) async {
    final Response = await http.post(
      Uri.parse('$SplatNet/api/graphql'),
      headers: <String, String>{
        'Authorization': 'Bearer ${Session.BulletToken}',
        'Content-Type': 'application/json',
        'Accept': '*/*',
        'Accept-Language': Session.Language,
        'X-Web-View-Ver': Session.Version,
        'X-NaCountry': Session.Country,
        'X-Requested-With': 'com.nintendo.znca',
        'Cookie': '_gtoken=${Session.GToken}; _dnt=1',
        'Origin': SplatNet,
        'Referer': '$SplatNet/?lang=${Session.Language}&na_country=${Session.Country}&na_lang=${Session.Language}',
        'User-Agent': 'Mozilla/5.0 (Linux; Android 14; Pixel 7a) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.230 Mobile Safari/537.36',
      },
      body: jsonEncode(<String, dynamic>{
        'variables': Variables,
        'extensions': <String, dynamic>{
          'persistedQuery': <String, dynamic>{'version': 1, 'sha256Hash': Hash},
        },
      }),
    ).timeout(const Duration(seconds: 30));
    if (Response.body.isEmpty) throw StateError('SplatNet 空响应：HTTP ${Response.statusCode} hash=$Hash');
    final Data = jsonDecode(Response.body);
    if (Data is! Map<String, dynamic>) throw StateError('SplatNet 响应格式错误');
    if (Response.statusCode != 200) throw StateError('SplatNet 请求失败：HTTP ${Response.statusCode}');
    if (Data['errors'] is List) throw StateError('SplatNet 数据请求失败');
    return Data;
  }

  Future<Map<String, dynamic>> _F({required String idToken, required String NaId, String? Token, String? CoralUserId, int Hash = 1, String? EncryptUrl, Map<String, dynamic>? Parameter}) async {
    final Body = <String, dynamic>{'hash_method': Hash, 'token': Token ?? idToken, 'na_id': NaId};
    if (CoralUserId != null && CoralUserId.isNotEmpty) Body['coral_user_id'] = CoralUserId;
    if (EncryptUrl != null && Parameter != null) Body['encrypt_token_request'] = <String, dynamic>{'url': EncryptUrl, 'parameter': Parameter};
    Object? Last;
    for (final Server in Servers) {
      try {
        final Data = await _PostJson('$Server/f', Body, <String, String>{
          'Authorization': 'Bearer ${await _AuthToken()}',
          'Content-Type': 'application/json',
          'X-znca-Platform': 'Android',
          'X-znca-Version': ZncaVersion,
          'X-znca-Client-Version': ClientVersion,
          'User-Agent': Config.UserAgent,
        });
        _LastServer = Server;
        return Data;
      } catch (Cause) {
        Last = Cause;
      }
    }
    throw StateError('$Last');
  }

  Future<Map<String, dynamic>> _EncryptedCoral(String Path, Map<String, dynamic> FData, String? Token) async {
    final Encrypted = '${FData['encrypted_token_request'] ?? ''}';
    if (Encrypted.isEmpty) throw StateError('请求加密失败');
    final Response = await http.post(
      Uri.parse('$Coral$Path'),
      headers: <String, String>{
        'Content-Type': 'application/octet-stream',
        'Accept': 'application/octet-stream,application/json',
        'X-Platform': 'Android',
        'X-ProductVersion': ZncaVersion,
        'User-Agent': 'com.nintendo.znca/$ZncaVersion(Android/12)',
        if (Token != null) 'Authorization': 'Bearer $Token',
      },
      body: base64Decode(Encrypted),
    ).timeout(const Duration(seconds: 30));
    if (Response.bodyBytes.isEmpty) throw StateError('NSO 响应为空');
    if (Response.bodyBytes[0] == 0x7b) {
      final Direct = jsonDecode(latin1.decode(Response.bodyBytes));
      if (Direct is Map<String, dynamic>) return Direct;
    }
    Object? Last;
    final Order = <String>[if (_LastServer != null) _LastServer!, ...Servers].toSet().toList();
    for (final Server in Order) {
      try {
        final Decrypted = await _PostJson('$Server/decrypt-response', <String, dynamic>{'data': base64Encode(Response.bodyBytes)}, <String, String>{
          'Authorization': 'Bearer ${await _AuthToken()}',
          'Content-Type': 'application/json',
          'X-znca-Platform': 'Android',
          'X-znca-Version': ZncaVersion,
          'X-znca-Client-Version': ClientVersion,
          'Accept': 'application/json',
        });
        final Text = '${Decrypted['data'] ?? ''}';
        final Data = jsonDecode(Text);
        if (Data is! Map<String, dynamic>) throw StateError('NSO 解密响应格式错误');
        return Data;
      } catch (Cause) {
        Last = Cause;
      }
    }
    throw StateError('$Last');
  }

  Future<String> _AuthToken() async {
    if (_AccessToken != null && _AccessExpires > DateTime.now().millisecondsSinceEpoch + 60000) return _AccessToken!;
    final Header = _B64(utf8.encode(jsonEncode(<String, String>{'alg': 'HS256', 'typ': 'JWT'})));
    final Now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final Payload = _B64(utf8.encode(jsonEncode(<String, dynamic>{
      'typ': 'client_assertion',
      'iss': AuthClientId,
      'aud': AuthServer,
      'exp': Now + 300,
      'iat': Now,
      'nxapi': _B64(List<int>.filled(22, 0)),
    })));
    final Signing = '$Header.$Payload';
    final Signature = _B64(Hmac(sha256, List<int>.filled(32, 0)).convert(utf8.encode(Signing)).bytes);
    final Data = await _PostForm('$AuthServer/api/oauth/token', <String, String>{
      'grant_type': 'client_credentials',
      'scope': 'ca:gf ca:er ca:dr',
      'client_assertion_type': 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
      'client_assertion': '$Signing.$Signature',
    });
    _AccessToken = '${Data['access_token'] ?? ''}';
    if (_AccessToken!.isEmpty) throw StateError('NSO 授权失败');
    final Expires = (Data['expires_in'] as num?)?.toInt() ?? 1200;
    _AccessExpires = DateTime.now().millisecondsSinceEpoch + Expires * 1000;
    return _AccessToken!;
  }

  Future<Map<String, dynamic>> _PostJson(String Url, Map<String, dynamic> Body, Map<String, String> Headers) async {
    final Response = await http.post(Uri.parse(Url), headers: Headers, body: jsonEncode(Body)).timeout(const Duration(seconds: 30));
    final Data = jsonDecode(Response.body);
    if (Data is! Map<String, dynamic>) throw StateError('响应格式错误');
    if (Response.statusCode < 200 || Response.statusCode >= 300) throw StateError('$Url: ${Data['error_description'] ?? Data['errorMessage'] ?? '请求失败：HTTP ${Response.statusCode}'}');
    return Data;
  }

  Future<Map<String, dynamic>> _PostForm(String Url, Map<String, String> Body) async {
    final Response = await http.post(Uri.parse(Url), headers: <String, String>{'Content-Type': 'application/x-www-form-urlencoded'}, body: Body).timeout(const Duration(seconds: 30));
    final Data = jsonDecode(Response.body);
    if (Data is! Map<String, dynamic>) throw StateError('响应格式错误');
    if (Response.statusCode < 200 || Response.statusCode >= 300) throw StateError('${Data['error_description'] ?? Data['errorMessage'] ?? '请求失败：HTTP ${Response.statusCode}'}');
    return Data;
  }

  Future<Map<String, dynamic>> _GetJson(String Url, Map<String, String> Headers) async {
    final Response = await http.get(Uri.parse(Url), headers: Headers).timeout(const Duration(seconds: 30));
    final Data = jsonDecode(Response.body);
    if (Data is! Map<String, dynamic>) throw StateError('响应格式错误');
    if (Response.statusCode != 200) throw StateError('请求失败：HTTP ${Response.statusCode}');
    return Data;
  }

  String _B64(List<int> Data) => base64Url.encode(Data).replaceAll('=', '');
}













