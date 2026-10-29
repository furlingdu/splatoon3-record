import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../app/gating.dart';
import '../../config/constants.dart';
import '../../config/system.dart';
import '../../domain/models.dart';
import '../../format/formats.dart';
import '../../media/capture/mobile/modes.dart';
import '../theme.dart';
import '../controls.dart';
import '../nsoLogin.dart';

class SetupPage extends StatefulWidget {
  const SetupPage({super.key, required this.Controller});

  final AppController Controller;

  @override
  State<SetupPage> createState() => SetupPageState();
}

class SetupPageState extends State<SetupPage> {
  static const List<String> Steps = <String>['选择采集设备', '绑定 Nintendo 账号', '绑定 QQBot'];
  int Step = 0;
  late String VideoDevice;
  late String AudioDevice;
  late int Width;
  late int Height;
  late int Fps;
  late String MobileDevice;
  late String MobileOrientation;
  List<CaptureMode> Modes = <CaptureMode>[];
  bool ModesLoading = false;
  bool DevicesLoading = false;
  String? ModesError;
  bool LastNSO = false;
  bool LastQQ = false;

  @override
  void initState() {
    super.initState();
    final Settings = widget.Controller.SettingsValue;
    VideoDevice = Settings.VideoDevice;
    AudioDevice = Settings.AudioDevice;
    Width = Settings.Width;
    Height = Settings.Height;
    Fps = Settings.Fps;
    MobileDevice = Settings.MobileDevice;
    MobileOrientation = Settings.MobileOrientation;
    LastNSO = widget.Controller.NSOReady;
    LastQQ = widget.Controller.QQReady;
    widget.Controller.addListener(FollowLogin);
    if (PlatformInfo.Mobile && MobileDevice.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => LoadMobileModes());
    }
  }

  @override
  void dispose() {
    widget.Controller.removeListener(FollowLogin);
    super.dispose();
  }

  void FollowLogin() {
    if (!mounted) return;
    final NSO = widget.Controller.NSOReady;
    final QQ = widget.Controller.QQReady;
    final NSOChanged = NSO && !LastNSO;
    final QQChanged = QQ && !LastQQ;
    LastNSO = NSO;
    LastQQ = QQ;
    if (NSOChanged && Step == 1) {
      setState(() => Step = 2);
      return;
    }
    if (QQChanged && Step == Steps.length - 1) unawaited(widget.Controller.FinishSetup());
  }

  Future<void> LoadMobileModes() async {
    if (!mounted || MobileDevice.isEmpty) return;
    setState(() {
      ModesLoading = true;
      ModesError = null;
    });
    try {
      final Items = await widget.Controller.Capture.Modes(MobileDevice);
      if (!mounted) return;
      final Current = MobileModes.Pick(Items, Width, Height, Fps);
      final Refresh = View.of(context).display.refreshRate.round();
      final Best = Current ?? MobileModes.Best(Items, PreferredWidth: Width, PreferredHeight: Height, PreferredFps: Refresh > 0 ? Refresh : Fps);
      setState(() {
        Modes = Items;
        ModesLoading = false;
        if (Best != null) {
          Width = Best.Width;
          Height = Best.Height;
          Fps = Best.MaxFps;
        }
        if (Items.isEmpty) ModesError = '未读取到采集卡档位，请检查 USB 连接后刷新';
      });
    } catch (Cause) {
      if (!mounted) return;
      setState(() {
        Modes = <CaptureMode>[];
        ModesLoading = false;
        ModesError = '$Cause';
      });
    }
  }

  Future<void> RefreshMobileDevices() async {
    if (DevicesLoading) return;
    setState(() => DevicesLoading = true);
    await widget.Controller.DevicesRefresh();
    await widget.Controller.EnsureDevice();
    if (!mounted) return;
    final Selected = widget.Controller.SettingsValue.MobileDevice;
    setState(() {
      MobileDevice = Selected;
      Modes = <CaptureMode>[];
      ModesError = null;
      DevicesLoading = false;
    });
    if (MobileDevice.isNotEmpty) await LoadMobileModes();
  }

  Future<void> SelectMobileDevice(String Value) async {
    setState(() {
      MobileDevice = Value;
      Modes = <CaptureMode>[];
      ModesError = null;
    });
    if (Value.isNotEmpty) await LoadMobileModes();
  }

  void SelectResolution(String Value) {
    final Parts = Value.split('x');
    final NextWidth = int.tryParse(Parts.first) ?? Width;
    final NextHeight = int.tryParse(Parts.length > 1 ? Parts[1] : '') ?? Height;
    final NextFps = MobileModes.FpsList(Modes, NextWidth, NextHeight);
    setState(() {
      Width = NextWidth;
      Height = NextHeight;
      if (!NextFps.contains(Fps) && NextFps.isNotEmpty) Fps = NextFps.first;
    });
  }

  List<CaptureDevice> MobileVideoDevices() {
    return widget.Controller.Devices.where((Item) => Item.Kind == 'video').toList();
  }

  String MobileDeviceName(List<CaptureDevice> Items, String Value) {
    if (Value.isEmpty) return '未选择';
    for (final Item in Items) {
      if (Item.Id == Value) return Item.Name;
    }
    return Value;
  }

  bool ModeReady() {
    return MobileDevice.isNotEmpty && Modes.isNotEmpty && SetupGating.ModeReady(Modes, Width, Height, Fps);
  }

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    final Mobile = PlatformInfo.Mobile;
    final Total = Steps.length;
    final Video = widget.Controller.Devices.where((Item) => Item.Kind == 'video').toList();
    final Audio = widget.Controller.Devices.where((Item) => Item.Kind == 'audio').toList();
    final MobileVideo = MobileVideoDevices();
    final Resolutions = MobileModes.Resolutions(Modes);
    final FpsItems = MobileModes.FpsList(Modes, Width, Height);
    return Material(
      color: Colors.transparent,
      child: Stack(children: <Widget>[
        const Positioned.fill(child: SetupBackground()),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                MediaQuery.sizeOf(context).width < 640 ? 20 : 32,
                MediaQuery.paddingOf(context).top + 24,
                MediaQuery.sizeOf(context).width < 640 ? 20 : 32,
                40 + MediaQuery.paddingOf(context).bottom,
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
                Row(children: <Widget>[
                  Image.asset('assets/images/appIcon.png', width: 56, height: 56),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                      Text('Splatoon3 Record', style: AppTheme.Style(Size: 18, Weight: FontWeight.w600)),
                      Text('步骤 ${Step + 1} / $Total：${Steps[Step]}', style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 20),
                AppLinearProgress(Value: (Step + 1) / Total),
                const SizedBox(height: 24),
                if (Step == 0 && Mobile) ...<Widget>[
                  const AppSectionTitle('选择采集设备'),
                  Row(crossAxisAlignment: CrossAxisAlignment.center, children: <Widget>[
                    Expanded(
                      child: AppSelect<String>(
                        Label: 'USB 采集卡',
                        Value: MobileDevice,
                        Items: <String>['', ...MobileVideo.map((Item) => Item.Id)],
                        Display: (Value) => MobileDeviceName(MobileVideo, Value),
                        OnChanged: SelectMobileDevice,
                      ),
                    ),
                    AppIconButton(Glyph: Icons.refresh, OnPressed: RefreshMobileDevices),
                  ]),
                  if (DevicesLoading) const Padding(padding: EdgeInsets.only(bottom: 8), child: AppLinearProgress(Indeterminate: true)),
                  if (ModesLoading) const Padding(padding: EdgeInsets.only(bottom: 8), child: AppLinearProgress(Indeterminate: true)),
                  if (MobileVideo.isEmpty) AppHint(PlatformInfo.IOS ? '未检测到 USB 采集卡。需要 iPadOS 17 或更高版本，并连接支持 UVC 的采集设备。' : '未检测到 USB 采集卡。请通过 USB OTG 连接采集卡后点击刷新。'),
                  if (Modes.isNotEmpty) ...<Widget>[
                    AppSelect<String>(
                      Label: '录制分辨率',
                      Value: '${Width}x$Height',
                      Items: Resolutions,
                      Display: (Value) => Formats.Resolution(int.tryParse(Value.split('x').first) ?? 0, int.tryParse(Value.split('x').last) ?? 0),
                      OnChanged: SelectResolution,
                    ),
                    AppSelect<int>(
                      Label: '录制帧率',
                      Value: Fps,
                      Items: FpsItems,
                      Display: (Value) => '$Value fps',
                      OnChanged: (Value) => setState(() => Fps = Value),
                    ),
                    if (PlatformInfo.IOS)
                      AppSelect<String>(
                        Label: '画面方向',
                        Value: MobileOrientation,
                        Items: const <String>['auto', 'landscape', 'portrait', 'landscapeFlipped', 'portraitFlipped'],
                        Display: Formats.OrientationName,
                        OnChanged: (Value) => setState(() => MobileOrientation = Value),
                      ),
                  ],
                  if (ModesError != null) AppHint(ModesError!, Error: true),
                  const SizedBox(height: 8),
                  AppButton(
                    Label: '下一步',
                    Enabled: ModeReady(),
                    OnPressed: () async {
                      await Save(<String, dynamic>{
                        'mobileSource': PlatformInfo.IOS ? 'external' : 'uvc',
                        'mobileDevice': MobileDevice,
                        'width': Width,
                        'height': Height,
                        'fps': Fps,
                        'mobileOrientation': MobileOrientation,
                      });
                      setState(() => Step = 1);
                    },
                  ),
                ],
                if (Step == 0 && !Mobile) ...<Widget>[
                  const AppSectionTitle('选择采集卡设备'),
                  AppSelect<String>(
                    Label: '摄像头 / 采集卡',
                    Value: VideoDevice,
                    Items: <String>['', ...Video.map((Item) => Item.Id)],
                    Display: (Value) => Value.isEmpty ? '未选择' : Video.firstWhere((Item) => Item.Id == Value, orElse: () => CaptureDevice(Id: Value, Name: Value, Kind: 'video')).Name,
                    OnChanged: (Value) => setState(() => VideoDevice = Value),
                  ),
                  const SizedBox(height: 12),
                  AppSelect<String>(
                    Label: '音频录制设备',
                    Value: AudioDevice,
                    Items: <String>['', ...Audio.map((Item) => Item.Id)],
                    Display: (Value) => Value.isEmpty ? '不录制音频' : Audio.firstWhere((Item) => Item.Id == Value, orElse: () => CaptureDevice(Id: Value, Name: Value, Kind: 'audio')).Name,
                    OnChanged: (Value) => setState(() => AudioDevice = Value),
                  ),
                  const SizedBox(height: 12),
                  Row(children: <Widget>[
                    Expanded(child: AppTextField(Label: '录制分辨率', Value: '$Width x $Height', ReadOnly: true)),
                    const SizedBox(width: 12),
                    Expanded(child: AppTextField(Label: '录制帧率', Value: '$Fps fps', ReadOnly: true)),
                  ]),
                  AppFormSwitch(Label: '垂直翻转画面', Value: widget.Controller.SettingsValue.FlipVertical, OnChanged: (Value) => Save(<String, dynamic>{'flipVertical': Value})),
                  const SizedBox(height: 16),
                  AppButton(Label: '下一步', OnPressed: () async {
                    await Save(<String, dynamic>{'videoDevice': VideoDevice, 'audioDevice': AudioDevice});
                    setState(() => Step = 1);
                  }),
                ],
                if (Step == 1) ...<Widget>[
                  const AppSectionTitle('绑定 Nintendo 账号'),
                  const SizedBox(height: 8),
                  NSOLoginPanel(Controller: widget.Controller),
                  const SizedBox(height: 16),
                  StatusBox(Label: '当前状态', Value: Formats.BindingState(widget.Controller.Status?.NSOState ?? 'unbound')),
                  StatusBox(Label: '已绑定账户', Value: '${widget.Controller.Status?.NSOAccounts.length ?? 0} 个'),
                  const SizedBox(height: 24),
                  Row(children: <Widget>[
                    if (Step > 0) ...<Widget>[
                      AppButton(Label: '上一步', Kind: AppButtonKind.Text, OnPressed: () => setState(() => Step = Step - 1)),
                      const SizedBox(width: 12),
                    ],
                    AppButton(Label: '下一步', Enabled: !Mobile || widget.Controller.NSOReady, OnPressed: () => setState(() => Step = Step + 1)),
                  ]),
                ],
                if (Step == Total - 1) ...<Widget>[
                  const AppSectionTitle('绑定 QQBot'),
                  Text('绑定后可将对局录像推送到你的 QQ。点击按钮获取二维码，使用创建机器人的 QQ 扫码授权，并在机器人私聊窗口发送 /bind 完成绑定。', style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant, Height: 1.6)),
                  const SizedBox(height: 16),
                  AppButton(Label: '获取绑定机器人二维码', Enabled: !widget.Controller.QQBusy && widget.Controller.QQState != 'connecting' && widget.Controller.QQState != 'connected', OnPressed: () => widget.Controller.StartQQLogin()),
                  if (widget.Controller.QQBusy) const Padding(padding: EdgeInsets.only(top: 8), child: AppLinearProgress(Indeterminate: true)),
                  if (widget.Controller.Status?.QrCode != null) ...<Widget>[
                    const SizedBox(height: 16),
                    Center(child: QrView(Data: widget.Controller.Status!.QrCode!)),
                  ],
                  const SizedBox(height: 16),
                  StatusBox(Label: '当前状态', Value: Formats.BindingState(widget.Controller.Status?.QQState ?? 'unbound')),
                  StatusBox(Label: '推送用户', Value: widget.Controller.Status?.QQOwner == null ? '未绑定' : '已绑定'),
                  const SizedBox(height: 24),
                  Row(children: <Widget>[
                    AppButton(Label: '上一步', Kind: AppButtonKind.Text, OnPressed: () => setState(() => Step = Step - 1)),
                    const SizedBox(width: 12),
                    AppButton(Label: '完成并进入应用', Enabled: widget.Controller.QQReady, OnPressed: () => widget.Controller.FinishSetup()),
                  ]),
                ],
                const SizedBox(height: 24),
                if (!Mobile)
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Opacity(
                      opacity: 0.5,
                      child: Image.asset('assets/images/character.png', height: 240, fit: BoxFit.contain),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  Future<void> Save(Map<String, dynamic> Part) async {
    await widget.Controller.SaveSettings(widget.Controller.SettingsValue.Copy(Part));
    setState(() {});
  }
}

class StatusBox extends StatelessWidget {
  const StatusBox({super.key, required this.Label, required this.Value});

  final String Label;
  final String Value;

  @override
  Widget build(BuildContext context) {
    return AppStatusItem(Label: Label, Value: AppStatusText(Value));
  }
}

class SetupBackground extends StatelessWidget {
  const SetupBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xff1b1b1f),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Image.asset(Config.BackgroundPath, fit: BoxFit.cover),
          Container(color: Colors.black.withValues(alpha: 0.55)),
        ],
      ),
    );
  }
}
