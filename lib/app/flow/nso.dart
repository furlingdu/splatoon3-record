part of 'package:splatoon3record/app/controller.dart';

extension AppNSOFlow on AppController {
  Future<void> LoadLegacy() async {
    Legacy = await LegacySecret.Load(Directories);
    if (Legacy == null) return;
    Accounts = LegacySecret.Accounts(Legacy!);
    CurrentNSOId = LegacySecret.Current(Legacy!);
    if (CurrentNSOId == null && Accounts.isNotEmpty) CurrentNSOId = Accounts.first.Id;
  }

  String? NSOName() {
    for (final Account in Accounts) {
      if (Account.Id == CurrentNSOId) return Account.Nickname;
    }
    return null;
  }

  Future<void> StartNSOLogin([String? AccountId]) async {
    if (AuthBusy) return;
    if (AccountId == null) {
      await BeginNSOAuth();
      return;
    }
    final Matches = Accounts.where((Item) => Item.Id == AccountId);
    if (Matches.isEmpty) return;
    await NSORefresh(Matches.first);
    StartNSOPoll();
  }

  Future<void> BeginNSOAuth() async {
    if (AuthBusy) return;
    AuthBusy = true;
    Notify();
    try {
      LastAuthState = null;
      PendingAuth = NSO.BeginAuth();
      final Data = Map<String, dynamic>.from(Vault.Data);
      Data['nsoAuth'] = <String, dynamic>{'url': PendingAuth!.Url, 'state': PendingAuth!.State, 'verifier': PendingAuth!.Verifier, 'at': DateTime.now().millisecondsSinceEpoch};
      await Vault.Save(Data);
      if (PlatformInfo.Mobile) {
        Notice = '登录链接已生成，请在浏览器中完成 Nintendo 登录';
        return;
      }
      final Ok = await launchUrl(Uri.parse(PendingAuth!.Url), mode: LaunchMode.externalApplication);
      Notice = Ok ? '请在浏览器中完成 Nintendo 登录' : '无法打开 Nintendo 登录页面';
    } catch (Cause) {
      Notice = '$Cause';
    } finally {
      AuthBusy = false;
      Notify();
    }
  }

  Future<void> OpenAuth() async {
    final Auth = PendingAuth;
    if (Auth == null) {
      Notice = '请先获取 Nintendo 登录链接';
      Notify();
      return;
    }
    try {
      final Ok = await launchUrl(Uri.parse(Auth.Url), mode: LaunchMode.externalApplication);
      Notice = Ok ? '请在浏览器中完成 Nintendo 登录' : '无法打开 Nintendo 登录页面';
    } catch (Cause) {
      Notice = '$Cause';
    }
    Notify();
  }

  Future<void> SubmitAuth(String Value) async {
    final Text = Value.trim();
    if (Text.isEmpty) {
      Notice = '请粘贴 Nintendo 登录回调链接';
      Notify();
      return;
    }
    final Callback = NSOAuthCallback.ParseInput(Text);
    if (Callback == null) {
      Notice = '未识别 Nintendo 登录回调链接';
      Notify();
      return;
    }
    await Logs.Login('nso callback input length=${Text.length} code=${Callback.Code.isNotEmpty} error=${Callback.Error.isNotEmpty}');
    await CompleteNSOAuth(Callback);
  }

  Future<void> HandleNSOLink(Uri Link) async {
    final Callback = NSOAuthCallback.Parse(Link);
    if (Callback == null) return;
    await Logs.Login('nso callback fragment=${Link.fragment.isNotEmpty} query=${Link.query.isNotEmpty} code=${Callback.Code.isNotEmpty} error=${Callback.Error.isNotEmpty}');
    await CompleteNSOAuth(Callback);
  }

  Future<void> CompleteNSOAuth(NSOAuthCallback Callback) async {
    if (AuthBusy) return;
    if (Callback.State.isNotEmpty && Callback.State == LastAuthState) return;
    final Auth = PendingAuth;
    if (Auth == null) {
      Notice = 'Nintendo 登录会话已过期，请重新登录';
      Notify();
      return;
    }
    if (Callback.Error.isNotEmpty) {
      Notice = 'Nintendo 登录失败：${Callback.Error}';
      Notify();
      return;
    }
    if (Callback.State != Auth.State || Callback.Code.isEmpty) {
      Notice = 'Nintendo 登录回调无效';
      Notify();
      return;
    }
    AuthBusy = true;
    Notice = '正在完成 Nintendo 登录…';
    Notify();
    try {
      final Token = await NSO.Exchange(Callback.Code, Auth.Verifier);
      final Session = await NSO.Login(Token);
      final Existing = Accounts.where((Item) => Item.Id == Session.NaId).toList();
      if (Existing.isEmpty && Accounts.length >= Config.MaxNSOAccounts) throw StateError('最多绑定 5 个 NSO 账户');
      final Account = Existing.isEmpty
          ? NSOAccount(Id: Session.NaId, Nickname: Session.Nickname, Session: Token, Token: NSOToken(BulletToken: Session.BulletToken, GToken: Session.GToken, Language: Session.Language, Country: Session.Country, UserAgent: Config.UserAgent, ExpiresAt: Session.ExpiresAt), AddedAt: DateTime.now().millisecondsSinceEpoch)
          : Existing.first;
      Account.Session = Token;
      Account.Nickname = Session.Nickname;
      Account.Token = NSOToken(BulletToken: Session.BulletToken, GToken: Session.GToken, Language: Session.Language, Country: Session.Country, UserAgent: Config.UserAgent, ExpiresAt: Session.ExpiresAt);
      Account.State = 'connected';
      Account.Error = null;
      Account.LastRefreshAt = DateTime.now().millisecondsSinceEpoch;
      if (Existing.isEmpty) Accounts.add(Account);
      NSOSessions[Account.Id] = Session;
      CurrentNSOId = Account.Id;
      LastAuthState = Auth.State;
      PendingAuth = null;
      NSOErrorText = null;
      final Data = Map<String, dynamic>.from(Vault.Data);
      Data.remove('nsoAuth');
      final Sessions = Data['nsoSessions'] is Map ? Map<String, dynamic>.from(Data['nsoSessions'] as Map) : <String, dynamic>{};
      Sessions[Account.Id] = <String, dynamic>{
        'gToken': Session.GToken,
        'bulletToken': Session.BulletToken,
        'naId': Session.NaId,
        'coralUserId': Session.CoralUserId,
        'language': Session.Language,
        'country': Session.Country,
        'version': Session.Version,
        'expiresAt': Session.ExpiresAt,
        'nickname': Session.Nickname,
      };
      Data['nsoSessions'] = Sessions;
      if (NSO.CachedAuth != null) Data['nsoAuthToken'] = <String, dynamic>{'token': NSO.CachedAuth, 'expiresAt': NSO.CachedAuthExpires};
      await Vault.Save(Data);
      await SaveVaultAccounts();
      Notice = 'Nintendo 登录成功';
      StartNSOPoll();
      PushStatus();
    } catch (Cause) {
      NSOErrorText = '$Cause';
      Notice = 'Nintendo 登录失败：$Cause';
    } finally {
      AuthBusy = false;
      Notify();
    }
  }

  Future<void> LoadVaultAccounts() async {
    if (Vault.Data['nsoAuth'] is Map) {
      final Auth = Map<String, dynamic>.from(Vault.Data['nsoAuth'] as Map);
      final At = (Auth['at'] as num?)?.toInt() ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - At < 900000) {
        PendingAuth = NSOAuthRequest(Url: '${Auth['url'] ?? ''}', State: '${Auth['state'] ?? ''}', Verifier: '${Auth['verifier'] ?? ''}');
      }
    }
    if (Vault.Data['nsoAccounts'] is! List) return;
    final Items = Vault.Data['nsoAccounts'] as List;
    for (final Item in Items) {
      if (Item is! Map) continue;
      final Account = NSOAccount.FromMap(Map<String, dynamic>.from(Item));
      if (Account.Id.isEmpty || Account.Session.isEmpty) continue;
      final Index = Accounts.indexWhere((Value) => Value.Id == Account.Id);
      if (Index >= 0) Accounts[Index] = Account; else Accounts.add(Account);
    }
    if (CurrentNSOId == null && Accounts.isNotEmpty) CurrentNSOId = Accounts.first.Id;
  }

  Future<void> SaveVaultAccounts() async {
    final Data = Map<String, dynamic>.from(Vault.Data);
    Data['nsoAccounts'] = Accounts.map((Item) => Item.ToMap()).toList();
    await Vault.Save(Data);
  }

  Future<void> NSOConnect() async {
    if (Accounts.isEmpty) return;
    for (final Account in Accounts) {
      final Cached = Vault.Data['nsoSessions'] is Map && (Vault.Data['nsoSessions'] as Map)[Account.Id] is Map
          ? Map<String, dynamic>.from((Vault.Data['nsoSessions'] as Map)[Account.Id] as Map)
          : null;
      if (Cached != null && (Cached['expiresAt'] as num?)?.toInt() != null && (Cached['expiresAt'] as num).toInt() > DateTime.now().millisecondsSinceEpoch + 300000 && '${Cached['bulletToken'] ?? ''}'.isNotEmpty) {
        final Session = NSOSession(
          Session: Account.Session,
          GToken: '${Cached['gToken'] ?? ''}',
          BulletToken: '${Cached['bulletToken'] ?? ''}',
          NaId: '${Cached['naId'] ?? ''}',
          CoralUserId: '${Cached['coralUserId'] ?? ''}',
          Language: '${Cached['language'] ?? 'en-GB'}',
          Country: '${Cached['country'] ?? 'JP'}',
          Version: '${Cached['version'] ?? NSOService.AppVersion}',
          ExpiresAt: (Cached['expiresAt'] as num).toInt(),
          Nickname: '${Cached['nickname'] ?? Account.Nickname}',
        );
        NSOSessions[Account.Id] = Session;
        Account.State = 'connected';
        Account.Error = null;
        if (CurrentNSOId == null) CurrentNSOId = Account.Id;
        continue;
      }
      if (Account.Session.isEmpty) continue;
      await NSORefresh(Account);
    }
    StartNSOPoll();
    PushStatus();
  }

  Future<void> NSORefresh(NSOAccount Account) async {
    if (Account.State == 'connecting') return;
    Account.State = 'connecting';
    NSOErrorText = null;
    Notify();
    try {
      final Session = await NSO.Login(Account.Session);
      NSOSessions[Account.Id] = Session;
      Account.Token = NSOToken(BulletToken: Session.BulletToken, GToken: Session.GToken, Language: Session.Language, Country: Session.Country, UserAgent: Config.UserAgent, ExpiresAt: Session.ExpiresAt);
      Account.State = 'connected';
      Account.Error = null;
      NSOErrorText = null;
      Account.LastRefreshAt = DateTime.now().millisecondsSinceEpoch;
      if (CurrentNSOId == null) CurrentNSOId = Account.Id;
      final Data = Map<String, dynamic>.from(Vault.Data);
      final Sessions = Data['nsoSessions'] is Map ? Map<String, dynamic>.from(Data['nsoSessions'] as Map) : <String, dynamic>{};
      Sessions[Account.Id] = <String, dynamic>{
        'gToken': Session.GToken,
        'bulletToken': Session.BulletToken,
        'naId': Session.NaId,
        'coralUserId': Session.CoralUserId,
        'language': Session.Language,
        'country': Session.Country,
        'version': Session.Version,
        'expiresAt': Session.ExpiresAt,
        'nickname': Session.Nickname,
      };
      Data['nsoSessions'] = Sessions;
      if (NSO.CachedAuth != null) Data['nsoAuthToken'] = <String, dynamic>{'token': NSO.CachedAuth, 'expiresAt': NSO.CachedAuthExpires};
      await Vault.Save(Data);
      if (Session.Nickname.isNotEmpty) Account.Nickname = Session.Nickname;
      await SaveVaultAccounts();
    } catch (Cause) {
      Account.State = 'error';
      Account.Error = '$Cause';
      NSOErrorText = '$Cause';
      NSOSessions.remove(Account.Id);
    }
    PushStatus();
  }

  void StartNSOPoll() {
    NSOClock?.cancel();
    if (NSOSessions.isEmpty) {
      if (Accounts.any((Item) => Item.State != 'connected' && Item.Session.isNotEmpty)) {
        NSOClock = Timer(const Duration(minutes: Config.NSORetryMinutes), () {
          unawaited(NSOConnect());
        });
      }
      return;
    }
    NSOClock = Timer.periodic(const Duration(seconds: Config.NSOPollSeconds), (_) => PollNSO());
    unawaited(PollNSO());
  }

  Future<void> PollNSO() async {
    if (NSOBusy || NSOSessions.isEmpty) return;
    NSOBusy = true;
    try {
      for (final Account in Accounts) {
        final Session = NSOSessions[Account.Id];
        if (Session == null || Account.State != 'connected') continue;
        try {
          final Latest = await NSO.Latest(Session);
          final Data = Latest['data'] is Map ? Latest['data'] as Map : const <String, dynamic>{};
          final History = Data['latestBattleHistories'] is Map ? Data['latestBattleHistories'] as Map : const <String, dynamic>{};
          final Groups = History['historyGroups'] is Map ? History['historyGroups'] as Map : const <String, dynamic>{};
          final Nodes = Groups['nodes'] is List ? Groups['nodes'] as List : const <dynamic>[];
          var Added = 0;
          for (final Group in Nodes) {
            if (Group is! Map) continue;
            final Details = Group['historyDetails'] is Map ? Group['historyDetails'] as Map : const <String, dynamic>{};
            final Items = Details['nodes'] is List ? Details['nodes'] as List : const <dynamic>[];
            for (final Item in Items) {
              if (Item is! Map || Added >= 8) continue;
              final Id = '${Item['id'] ?? ''}';
              if (Id.isEmpty || Archive.Matches.any((Match) => Match.MatchId == Id)) continue;
              final Detail = await NSO.Detail(Session, Id);
              final Match = NSOBattle.FromDetail(Detail, Account.Id, Account.Nickname);
              if (Match == null || !Match.TimeExact || Match.Duration <= 0) continue;
              Archive.Matches.insert(0, Match);
              await Archive.Save(Match);
              Account.LastMatchAt = Match.EndAt;
              Added++;
              if (CanCrop(Match)) await ArchiveMatch(Match);
            }
          }
          if (Added > 0) PushStatus();
        } catch (Cause) {
          if ('$Cause'.contains('9403') || '$Cause'.contains('9404') || '$Cause'.contains('登录已过期') || '$Cause'.contains('HTTP 401')) {
            await NSORefresh(Account);
          }
        }
      }
    } finally {
      NSOBusy = false;
    }
  }

  Future<void> SelectNSOAccount(String Id) async {
    if (!Accounts.any((Item) => Item.Id == Id)) return;
    CurrentNSOId = Id;
    PushStatus();
  }

  Future<void> DeleteNSOAccount(String Id) async {
    if (Accounts.length <= 1) return;
    Accounts.removeWhere((Item) => Item.Id == Id);
    if (CurrentNSOId == Id) CurrentNSOId = Accounts.isEmpty ? null : Accounts.first.Id;
    NSOSessions.remove(Id);
    final Data = Map<String, dynamic>.from(Vault.Data);
    Data['nsoAccounts'] = Accounts.map((Item) => Item.ToMap()).toList();
    if (Data['nsoSessions'] is Map) {
      final Sessions = Map<String, dynamic>.from(Data['nsoSessions'] as Map);
      Sessions.remove(Id);
      Data['nsoSessions'] = Sessions;
    }
    await Vault.Save(Data);
    PushStatus();
  }

}










