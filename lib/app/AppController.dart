import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'ExternalLinkBus.dart';
import 'SetupGating.dart';

import '../config/Config.dart';
import '../config/PlatformInfo.dart';
import '../domain/Models.dart';
import '../domain/UpdateInfo.dart';
import '../format/Formats.dart';
import '../media/capture/CaptureBridge.dart';
import '../media/capture/CapturePlatform.dart';
import '../media/capture/MobileService.dart';
import '../media/capture/Service.dart';
import '../media/ffmpeg/Service.dart';
import '../media/nickname/Blur.dart';
import '../nso/Battle.dart';
import '../nso/NSOAuthCallback.dart';
import '../nso/Service.dart';
import '../store/LegacySecret.dart';
import '../store/SecretStore.dart';
import '../store/Stores.dart';
import '../qq/Bind.dart';
import '../qq/Bot.dart';

part 'flow/AppNSOFlow.dart';
part 'flow/AppQQFlow.dart';
part 'flow/AppMatchFlow.dart';
part 'flow/AppCaptureFlow.dart';
part 'flow/AppUpdateFlow.dart';
part 'flow/AppPlatformFlow.dart';

class AppController extends ChangeNotifier {
  late AppDirectories Directories;
  late EnvStore Env;
  late ConfigStore Configs;
  late LogStore Logs;
  late ArchiveStore Archive;
  late FFmpegService FFmpeg;
  late CapturePlatform Capture;
  late NicknameBlur Blur;
  late SecretStore Vault;
  AppStatus? Status;
  List<CaptureDevice> Devices = <CaptureDevice>[];
  String Page = 'status';
  String Version = '3.0.0';
  bool Ready = false;
  bool Busy = false;
  bool CaptureAborting = false;
  String? Notice;
  String? LastNotice;
  Timer? Clock;
  int LastWidth = 0;
  int LastHeight = 0;
  (int, int?, int?)? _CacheRange;
  int _CacheRangeTick = 0;
  Map<String, dynamic>? Legacy;
  List<NSOAccount> Accounts = <NSOAccount>[];
  String? CurrentNSOId;
  bool PreviewReady = false;
  String? PreviewMessage;
  bool PreviewStopping = false;
  QQBind? QQBindRef;
  QQBot? QQBotRef;
  String QQState = 'unbound';
  String? QrCode;
  String? QQError;
  String? QQAppId;
  String? QQSecret;
  final NSOService NSO = NSOService();
  final Map<String, NSOSession> NSOSessions = <String, NSOSession>{};
  Timer? NSOClock;
  bool NSOBusy = false;
  String? NSOErrorText;
  NSOAuthRequest? PendingAuth;
  bool AuthBusy = false;
  String? LastAuthState;
  StreamSubscription<Uri>? LinkSub;

  AppConfig get CurrentConfig => Configs.Current;
  RecordSettings get SettingsValue => Configs.Current.Settings;
  List<BattleMatch> get Matches => Archive.Matches;
  bool get NSOReady => SetupGating.NSOReady(Accounts);
  bool get QQReady => SetupGating.QQReady(QQState, Configs.Current.QQOwner != null);
  bool get MobileSetupReady => !PlatformInfo.Mobile || (NSOReady && QQReady);
  String? get PreviewError => Capture.Error.value;
  int? get PreviewTextureId => Capture.PreviewTexture.value;

  Future<void> Boot() async {
    Directories = PathStore.Open();
    await Directories.Create();
    Env = EnvStore(Directories);
    Configs = ConfigStore(Directories, Env);
    Logs = LogStore(Directories);
    Archive = ArchiveStore(Directories);
    FFmpeg = FFmpegService(Directories);
    Capture = PlatformInfo.Mobile ? MobileCaptureService(Directories, FFmpeg) : DesktopCaptureAdapter(CaptureService(Directories, FFmpeg));
    Blur = NicknameBlur(FFmpeg, Directories);
    Vault = SecretStore(Directories);
    await Vault.Load();
    final Package = await PackageInfo.fromPlatform();
    Version = Package.version;
    await Logs.App('app start');
    await Configs.Load();
    await Archive.Load();
    await MigrateHandled();
    await LoadLegacy();
    await LoadVaultAccounts();
    if (Vault.Data['nsoAuthToken'] is Map) {
      final Auth = Map<String, dynamic>.from(Vault.Data['nsoAuthToken'] as Map);
      if ((Auth['expiresAt'] as num?)?.toInt() != null && (Auth['expiresAt'] as num).toInt() > DateTime.now().millisecondsSinceEpoch) {
        NSO.RestoreAuth('${Auth['token'] ?? ''}', (Auth['expiresAt'] as num).toInt());
      }
    }
    await RegisterProtocol();
    LinkSub = ExternalLinkBus.Controller.stream.listen(HandleNSOLink);
    try {
      final Links = AppLinks();
      Links.uriLinkStream.listen(HandleNSOLink);
      final Initial = await Links.getInitialLink();
      if (Initial != null) unawaited(HandleNSOLink(Initial));
    } catch (_) {}
    if (ExternalLinkBus.Pending != null) unawaited(HandleNSOLink(ExternalLinkBus.Pending!));
    QQAppId = Vault.Text('qqAppId') ?? (Legacy?['qqAppId'] is String ? Legacy!['qqAppId'] as String : null);
    QQSecret = Vault.Text('qqSecret') ?? (Legacy?['qqSecret'] is String ? Legacy!['qqSecret'] as String : null);
    Capture.State.addListener(CaptureChanged);
    Capture.Error.addListener(CaptureChanged);
    if (PlatformInfo.Desktop) {
      await DevicesRefresh();
      await EnsureDevice();
    } else {
      await DevicesRefresh();
      await NormalizeMobileSettings();
      final Mobile = Capture as MobileCaptureService;
      await EnsureDevice();
      await Mobile.Recover();
    }
    await ApplyAutoLaunch();
    Clock = Timer.periodic(const Duration(seconds: 2), (_) => PushStatus());
    Ready = true;
    Page = Configs.Current.SetupDone ? 'status' : 'setup';
    PushStatus();
    if (QQAppId != null && QQSecret != null) {
      unawaited(StartQQBot(QQAppId!, QQSecret!));
    }
    unawaited(NSOConnect());
    unawaited(GenerateThumbs());
    unawaited(ArchiveCached());
    if (Configs.Current.SetupDone && Configs.Current.Settings.AutoRecord) {
      unawaited(StartRecord());
    }
    if (Configs.Current.SetupDone && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      unawaited(WarmPreviewWindow());
    }
  }






  CaptureMode? PickMode(RecordSettings Value, List<CaptureMode> Available) => FFmpeg.PickMode(Value, Available);

  void CaptureChanged() {
    _CacheRangeTick = 0;
    final ErrorText = Capture.Error.value;
    if (ErrorText != null && ErrorText.isNotEmpty) {
      Notice = ErrorText;
      if (Capture.Running || Capture.Starting) unawaited(Abort(ErrorText));
    }
    PushStatus();
  }

  Future<void> Abort(String Text) async {
    if (CaptureAborting) return;
    CaptureAborting = true;
    try {
      await Capture.Stop(Fast: true);
      await Capture.Records();
      Notice = '采集设备已断开，录制已停止：$Text';
    } catch (_) {
      Notice = '采集设备已断开，录制已停止';
    } finally {
      CaptureAborting = false;
      PushStatus();
    }
  }

  Future<void> PushStatus() async {
    if (!Ready) return;
    final Recent = Archive.Matches.take(8).toList();
    final State = Capture.State.value;
    final Cache = CacheRange();
    final Settings = SettingsValue;
    final HasAudio = PlatformInfo.Mobile ? Settings.MobileAudio && Devices.any((Item) => Item.Kind == 'audio') : Settings.AudioDevice.isNotEmpty;
    Status = AppStatus(
      RecordState: State == 'recording' ? 'recording' : State == 'starting' ? 'starting' : State == 'error' ? 'error' : 'idle',
      RecordError: Capture.Error.value,
      Width: State == 'recording' || State == 'starting' ? Capture.ActualWidth : LastWidth,
      Height: State == 'recording' || State == 'starting' ? Capture.ActualHeight : LastHeight,
      Fps: State == 'recording' || State == 'starting' ? Capture.ActualFps : 0,
      Format: State == 'recording' || State == 'starting' ? 'video/mp4' : '',
      PixelFormat: State == 'recording' || State == 'starting' ? Capture.ActualFormat : Settings.CaptureFormat.toUpperCase(),
      Encoder: Capture.EncoderName ?? '',
      HasAudio: HasAudio,
      Audio: HasAudio ? 'ok' : null,
      AudioSource: PlatformInfo.Mobile ? (HasAudio ? 'USB 音频' : null) : (HasAudio ? '采集卡音频' : null),
      Segments: Cache.$1,
      CacheStart: Cache.$2,
      CacheEnd: Cache.$3,
      NSOState: Accounts.isEmpty ? 'unbound' : Accounts.any((Item) => Item.State == 'connected') ? 'connected' : Accounts.any((Item) => Item.State == 'connecting') ? 'connecting' : 'expired',
      NSOError: NSOErrorText,
      NSOAccounts: Accounts,
      NSOCurrentId: CurrentNSOId,
      NSOCurrentNickname: NSOName(),
      QQState: QQState == 'connected' && Configs.Current.QQOwner == null ? 'connecting' : QQState,
      QQOwner: Configs.Current.QQOwner,
      QrCode: QrCode,
      SetupDone: Configs.Current.SetupDone,
      RecentMatches: Recent,
      LatestMatch: Recent.isEmpty ? null : Recent.first,
      Settings: Settings,
      RtmpState: Settings.CaptureMode == 'rtmp' ? (State == 'recording' ? 'live' : 'listening') : 'idle',
      RtmpError: null,
      RtmpWidth: 0,
      RtmpHeight: 0,
      RtmpFps: 0,
      RtmpPushState: Capture.LiveTarget == null ? 'idle' : 'live',
      RtmpPushMode: Capture.LiveTarget == null ? null : 'encode',
      RtmpPushError: null,
      HwAccel: HardwareName(Capture.EncoderName),
      StreamEncoder: Capture.EncoderName,
      StreamFormat: 'video/mp4',
      RtmpInputUrl: Settings.CaptureMode == 'rtmp' ? 'rtmp://127.0.0.1:${Settings.RtmpPort}/live/${Settings.RtmpStreamKey}' : null,
      RtmpServerUrl: Settings.CaptureMode == 'rtmp' ? 'rtmp://127.0.0.1:${Settings.RtmpPort}/live' : null,
      PushState: 'idle',
      PushError: null,
      Processing: <String>{},
      Devices: Devices,
      Country: 'CN',
      PlatformName: Platform.operatingSystem,
      PlatformVersion: Platform.operatingSystemVersion,
    );
    notifyListeners();
  }



  (int, int?, int?) CacheRange() {
    final Now = DateTime.now().millisecondsSinceEpoch;
    if (_CacheRange != null && Now - _CacheRangeTick < 5000) return _CacheRange!;
    final Folder = Directory(Directories.Cache);
    if (!Folder.existsSync()) {
      _CacheRange = (0, null, null);
      _CacheRangeTick = Now;
      return _CacheRange!;
    }
    final Files = Folder.listSync().whereType<File>().where((Item) => RegExp(r'Cache-\d{8}-\d{6}\.mp4$').hasMatch(Item.path)).toList()
      ..sort((Left, Right) => Left.path.compareTo(Right.path));
    if (Files.isEmpty) {
      _CacheRange = (0, null, null);
      _CacheRangeTick = Now;
      return _CacheRange!;
    }
    int? Start;
    for (final Item in Files) {
      final Match = RegExp(r'Cache-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})\.mp4$').firstMatch(Item.path);
      if (Match == null) continue;
      Start ??= DateTime(
        int.parse(Match.group(1)!),
        int.parse(Match.group(2)!),
        int.parse(Match.group(3)!),
        int.parse(Match.group(4)!),
        int.parse(Match.group(5)!),
        int.parse(Match.group(6)!),
      ).millisecondsSinceEpoch;
    }
    _CacheRange = (Files.length, Start, Files.last.lastModifiedSync().millisecondsSinceEpoch);
    _CacheRangeTick = Now;
    return _CacheRange!;
  }












  void Navigate(String Value) {
    if (PlatformInfo.Mobile && (Value == 'live' || Value == 'update')) return;
    Page = Value;
    notifyListeners();
  }

  void ClearNotice() {
    Notice = null;
    notifyListeners();
  }










































  void Notify() => notifyListeners();

  void ShowNotice(String Text) {
    Notice = Text;
    notifyListeners();
  }

  String KindName(String Value) => Formats.Kind(Value);

  @override
  void dispose() {
    Clock?.cancel();
    NSOClock?.cancel();
    LinkSub?.cancel();
    unawaited(Capture.Dispose());
    if (Ready) {
      Capture.State.removeListener(CaptureChanged);
      Capture.Error.removeListener(CaptureChanged);
    }
    super.dispose();
  }
}






























