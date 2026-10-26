import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/AppController.dart';
import '../../config/PlatformInfo.dart';
import '../../domain/Models.dart';
import '../../format/Formats.dart';
import '../AppTheme.dart';
import '../Controls.dart';
import '../Shell.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.Controller});

  final AppController Controller;

  @override
  State<SettingsPage> createState() => SettingsPageState();
}

class SettingsPageState extends State<SettingsPage> {
  late RecordSettings Draft;
  List<CaptureMode> Modes = <CaptureMode>[];
  bool LoadingDevices = false;
  bool Picking = false;
  final TextEditingController SaveDir = TextEditingController();
  final TextEditingController RtmpPort = TextEditingController();
  final TextEditingController RtmpKey = TextEditingController();
  final TextEditingController PushUrl = TextEditingController();
  final TextEditingController PushKey = TextEditingController();

  @override
  void initState() {
    super.initState();
    Draft = widget.Controller.SettingsValue;
    SaveDir.text = Draft.SaveDir;
    RtmpPort.text = '${Draft.RtmpPort}';
    RtmpKey.text = Draft.RtmpStreamKey;
    PushUrl.text = Draft.RtmpPushUrl;
    PushKey.text = Draft.RtmpPushKey;
    LoadModes();
  }

  Future<void> LoadModes() async {
    if (Draft.VideoDevice.isEmpty) return;
    final List = await widget.Controller.Capture.Modes(Draft.VideoDevice).catchError((_) => <CaptureMode>[]);
    if (!mounted) return;
    setState(() => Modes = List);
  }

  @override
  void dispose() {
    SaveDir.dispose();
    RtmpPort.dispose();
    RtmpKey.dispose();
    PushUrl.dispose();
    PushKey.dispose();
    super.dispose();
  }

  Future<void> Update(RecordSettings Next, {bool Save = true}) async {
    setState(() => Draft = Next);
    if (Save) await widget.Controller.SaveSettings(Next);
  }

  Future<void> ChooseBackground() async {
    if (Picking) return;
    setState(() => Picking = true);
    try {
      await widget.Controller.PickBackground();
      if (!mounted) return;
      setState(() => Draft = widget.Controller.SettingsValue);
    } finally {
      if (mounted) setState(() => Picking = false);
    }
  }

  Future<void> ResetBackground() async {
    if (Picking) return;
    setState(() => Picking = true);
    try {
      await widget.Controller.ResetBackground();
      if (!mounted) return;
      setState(() => Draft = widget.Controller.SettingsValue);
    } finally {
      if (mounted) setState(() => Picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    final Video = widget.Controller.Devices.where((Item) => Item.Kind == 'video').toList();
    final Audio = widget.Controller.Devices.where((Item) => Item.Kind == 'audio').toList();
    final FormatModes = Modes.where((Item) => Item.Format == Draft.CaptureFormat).toList();
    final Resolutions = <String>{
      ...FormatModes.map((Item) => '${Item.Width}x${Item.Height}'),
      if (FormatModes.isEmpty) '${Draft.Width}x${Draft.Height}',
    }.toList()
      ..sort((Left, Right) {
        final A = Left.split('x').map(int.tryParse).whereType<int>().fold<int>(1, (Value, Item) => Value * Item);
        final B = Right.split('x').map(int.tryParse).whereType<int>().fold<int>(1, (Value, Item) => Value * Item);
        return B.compareTo(A);
      });
    final FpsList = <int>{
      ...FormatModes.where((Item) => Item.Width == Draft.Width && Item.Height == Draft.Height).map((Item) => Item.MaxFps),
      if (FormatModes.isEmpty) Draft.Fps,
    }.toList()
      ..sort();
    final FormatList = <String>{
      ...Modes.map((Item) => Item.Format),
      Draft.CaptureFormat,
    }.toList();
    return PageBody(Children: <Widget>[
      const AppPageTitle('设置'),
      if (PlatformInfo.Mobile) const AppHint('移动端不提供采集与编码设置，录制相关选项在桌面端调整。'),
      if (!PlatformInfo.Mobile)
        AppSelect<String>(
          Label: '捕获方式',
          Value: Draft.CaptureMode,
          Items: const <String>['internal', 'rtmp'],
          Display: (Value) => Value == 'rtmp' ? 'RTMP' : '软件内捕获',
          OnChanged: (Value) => Update(Draft.Copy(<String, dynamic>{'captureMode': Value})),
        ),
      if (!PlatformInfo.Mobile) const AppHint('RTMP 模式仅接收 RTMP 画面与原始音轨，请在 OBS 等推流端配置分辨率与帧率。'),
      if (!PlatformInfo.Mobile && Draft.CaptureMode == 'rtmp') ...<Widget>[
        const AppSectionTitle('RTMP 采集'),
        AppTextField(Label: 'RTMP 服务器', Value: widget.Controller.Status?.RtmpServerUrl ?? '', ReadOnly: true, Placeholder: '等待主进程启动 RTMP 服务', OnIcon: Icons.copy, OnIconTap: () => Copy(widget.Controller.Status?.RtmpServerUrl ?? '', 'RTMP 服务器地址已复制')),
        AppHint('OBS 的服务器填该地址，流密钥填下方密钥。'),
        Row(children: <Widget>[
          Expanded(child: AppTextField(Label: 'RTMP 监听端口', Controller: RtmpPort, OnChanged: (Value) => Update(Draft.Copy(<String, dynamic>{'rtmpPort': int.tryParse(Value)?.clamp(1024, 65535) ?? Draft.RtmpPort})))),
          const SizedBox(width: 12),
          Expanded(child: AppTextField(Label: '流密钥', Controller: RtmpKey, OnIcon: Icons.copy, OnIconTap: () => Copy(Draft.RtmpStreamKey, 'RTMP 流密钥已复制'), OnChanged: (Value) => Update(Draft.Copy(<String, dynamic>{'rtmpStreamKey': Value})))),
        ]),
        AppHint('直播推流地址与推流码请在直播页填写。'),
        const AppSectionTitle('RTMP 状态'),
        StatusGrid(Children: <Widget>[
          AppStatusItem(Label: '输入状态', Value: AppStatusText(Formats.RtmpState(widget.Controller.Status?.RtmpState ?? 'idle'))),
          AppStatusItem(Label: '输入画面', Value: AppStatusText(widget.Controller.Status?.RtmpWidth == 0 ? '等待推流' : '${widget.Controller.Status?.RtmpWidth}x${widget.Controller.Status?.RtmpHeight} @ ${widget.Controller.Status?.RtmpFps} fps')),
          AppStatusItem(Label: '音频', Value: AppStatusText(widget.Controller.Status?.HasAudio == true ? '跟随 RTMP 输入' : '无音频')),
          AppStatusItem(Label: '硬件解码', Value: AppStatusText(widget.Controller.Status?.HwAccel ?? '未启动')),
          AppStatusItem(Label: '录制编码', Value: AppStatusText(widget.Controller.Status?.Encoder ?? '未启动')),
          if (widget.Controller.Status?.RtmpError != null) AppStatusItem(Label: '错误信息', Value: AppStatusText(widget.Controller.Status!.RtmpError!)),
        ]),
      ] else if (!PlatformInfo.Mobile) ...<Widget>[
        const AppSectionTitle('采集设备'),
        AppSelect<String>(
          Label: '摄像头 / 采集卡',
          Value: Draft.VideoDevice,
          Items: <String>['', ...Video.map((Item) => Item.Id)],
          Display: (Value) => Value.isEmpty ? '未选择' : Video.firstWhere((Item) => Item.Id == Value, orElse: () => CaptureDevice(Id: Value, Name: Value, Kind: 'video')).Name,
          OnChanged: (Value) => SelectVideo(Value),
        ),
        AppHint('选择采集卡'),
        AppSelect<String>(
          Label: '采集画面格式',
          Value: Draft.CaptureFormat,
          Items: FormatList,
          Display: FormatName,
          OnChanged: (Value) => ChangeFormat(Value),
        ),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
          Expanded(
            child: AppSelect<String>(
              Label: '音频录制设备',
              Value: Draft.AudioDevice,
              Items: <String>['', ...Audio.map((Item) => Item.Id)],
              Display: (Value) => Value.isEmpty ? '不录制音频' : Audio.firstWhere((Item) => Item.Id == Value, orElse: () => CaptureDevice(Id: Value, Name: Value, Kind: 'audio')).Name,
              OnChanged: (Value) => Update(Draft.Copy(<String, dynamic>{'audioDevice': Value})),
            ),
          ),
          const SizedBox(width: 8),
          AppIconButton(Glyph: Icons.refresh, OnPressed: () async {
            setState(() => LoadingDevices = true);
            await widget.Controller.DevicesRefresh();
            await LoadModes();
            if (mounted) setState(() => LoadingDevices = false);
          }),
        ]),
        if (LoadingDevices) const Padding(padding: EdgeInsets.only(bottom: 8), child: AppLinearProgress(Indeterminate: true)),
        AppHint('选择音频输入'),
        AppFormSwitch(Label: '电脑声音录制', Note: '开启后，将同时捕获电脑输出声音并录制。', Value: Draft.DesktopAudio, OnChanged: (Value) => Update(Draft.Copy(<String, dynamic>{'desktopAudio': Value}))),
        AppFormSwitch(Label: '麦克风声音录制', Note: '开启后，将同时捕获麦克风输出声音并录制。', Value: Draft.MicAudio, OnChanged: (Value) => Update(Draft.Copy(<String, dynamic>{'micAudio': Value}))),
        if (Draft.MicAudio)
          AppSelect<String>(
            Label: '麦克风设备',
            Value: Draft.MicDevice,
            Items: <String>['', ...Audio.map((Item) => Item.Id)],
            Display: (Value) => Value.isEmpty ? '未选择' : Audio.firstWhere((Item) => Item.Id == Value, orElse: () => CaptureDevice(Id: Value, Name: Value, Kind: 'audio')).Name,
            OnChanged: (Value) => Update(Draft.Copy(<String, dynamic>{'micDevice': Value})),
          ),
        const AppSectionTitle('画质与编码'),
        Row(children: <Widget>[
          Expanded(
            child: AppSelect<String>(
              Label: '录制分辨率',
              Value: '${Draft.Width}x${Draft.Height}',
              Items: Resolutions,
              Display: (Value) {
                final Parts = Value.split('x');
                return Formats.Resolution(int.tryParse(Parts[0]) ?? 0, int.tryParse(Parts.length > 1 ? Parts[1] : '0') ?? 0);
              },
              OnChanged: (Value) {
                final Parts = Value.split('x');
                final Width = int.tryParse(Parts[0]) ?? Draft.Width;
                final Height = int.tryParse(Parts.length > 1 ? Parts[1] : '0') ?? Draft.Height;
                final Supported = FormatModes.where((Item) => Item.Width == Width && Item.Height == Height).map((Item) => Item.MaxFps).toList()..sort();
                Update(Draft.Copy(<String, dynamic>{'width': Width, 'height': Height, if (Supported.isNotEmpty) 'fps': Supported.last}));
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: AppSelect<int>(
              Label: '录制帧率',
              Value: Draft.Fps,
              Items: FpsList,
              Display: (Value) => '$Value fps',
              OnChanged: (Value) => Update(Draft.Copy(<String, dynamic>{'fps': Value})),
            ),
          ),
        ]),
        if (widget.Controller.Status != null && widget.Controller.Status!.Width > 0 && widget.Controller.Status!.Width != Draft.Width)
          AppHint('采集卡未接受该分辨率，当前输出 ${Formats.Resolution(widget.Controller.Status!.Width, widget.Controller.Status!.Height)}'),
        if (widget.Controller.Status != null && widget.Controller.Status!.Fps > 0 && (widget.Controller.Status!.Fps - Draft.Fps).abs() > 0.5)
          AppHint('采集卡未接受设置页的帧率，当前输出 ${Formats.Fps(widget.Controller.Status!.Fps)}'),
        AppHint('${Draft.Width}x${Draft.Height} @ ${Draft.Fps}fps：${Draft.Width * Draft.Height * Draft.Fps >= 3840 * 2160 * 30 ? '建议开启硬件编码，软件编码可能掉帧。' : '当前档位可正常录制。'}'),
        AppFormSwitch(Label: '垂直翻转画面', Note: '画面上下颠倒时开启', Value: Draft.FlipVertical, OnChanged: (Value) => Update(Draft.Copy(<String, dynamic>{'flipVertical': Value}))),
        AppSelect<String>(
          Label: '编码器',
          Value: Draft.Encoder,
          Items: const <String>['auto', 'nvidia', 'amd', 'intel', 'software'],
          Display: (Value) => const <String, String>{'auto': '自动选择', 'nvidia': 'NVIDIA NVENC', 'amd': 'AMD AMF', 'intel': 'Intel QSV', 'software': '软件编码'}[Value] ?? Value,
          OnChanged: (Value) => Update(Draft.Copy(<String, dynamic>{'encoder': Value})),
        ),
        AppHint(const <String, String>{
          'auto': '',
          'nvidia': '使用 NVIDIA 显卡的 NVENC 硬件编码。',
          'amd': '使用 AMD 显卡的 AMF 硬件编码。',
          'intel': '使用 Intel 核显的 QSV 硬件编码。',
          'software': '使用 CPU 软件编码，画质上限最高但 CPU 占用大。',
        }[Draft.Encoder] ?? ''),
        AppSelect<int>(
          Label: '录制质量',
          Value: Draft.Quality,
          Items: QualityTiers,
          Display: (Value) => const <int, String>{18: '高质量、存储占用大', 22: '普通质量、存储占用适中', 28: '低质量、存储占用小'}[Value] ?? '$Value',
          OnChanged: (Value) => Update(Draft.Copy(<String, dynamic>{'quality': Value})),
        ),
        AppHint('CQP 数值越低画质越高，录制文件体积随画面复杂度变化。'),
      ],
      const AppSectionTitle('存储与运行'),
      if (!PlatformInfo.Mobile) ...<Widget>[
        AppTextField(Label: '视频保存目录', Controller: SaveDir, ReadOnly: true, Placeholder: '默认保存到 ~/.splatoon3record/videos', OnIcon: Icons.folder, OnIconTap: () async {
          await widget.Controller.PickFolder();
          if (!mounted) return;
          setState(() => SaveDir.text = widget.Controller.SettingsValue.SaveDir);
        }),
        AppHint('裁剪完成的对局录像保存到该目录。'),
      ],
      AppFormSwitch(Label: '自动推送录像', Note: '对局裁剪完成后由 QQBot 私聊推送', Value: Draft.AutoPush, OnChanged: (Value) => Update(Draft.Copy(<String, dynamic>{'autoPush': Value}))),
      if (!PlatformInfo.Mobile) ...<Widget>[
        AppFormSwitch(Label: '启动时自动录制', Note: '应用打开后立即开始缓存采集画面；RTMP 模式下收到推流即开始录制', Value: Draft.AutoRecord, OnChanged: (Value) => Update(Draft.Copy(<String, dynamic>{'autoRecord': Value}))),
        AppFormSwitch(Label: '开机自启动', Note: '开机后自动运行 Splatoon3 Record', Value: Draft.AutoLaunch, OnChanged: (Value) => Update(Draft.Copy(<String, dynamic>{'autoLaunch': Value}))),
      ],
      const AppSectionTitle('外观'),
      Text('背景图片', style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurface)),
      AppHint(Draft.BackgroundPath.isEmpty ? '正在使用默认背景和吉祥物。' : '正在使用自定义背景，吉祥物已自动隐藏。'),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: AppButton(Label: Picking ? '正在选择…' : '更换背景', Full: true, Enabled: !Picking, OnPressed: ChooseBackground),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: AppButton(Label: '恢复默认背景', Kind: AppButtonKind.Outlined, Full: true, Enabled: !Picking && Draft.BackgroundPath.isNotEmpty, OnPressed: ResetBackground),
      ),
      const SizedBox(height: 12),
      Row(children: <Widget>[
        Text('背景压黑', style: AppTheme.Style(Size: 14)),
        const Spacer(),
        Text('${Draft.BackgroundDim}%', style: AppTheme.Style(Size: 14, Weight: FontWeight.w500)),
      ]),
      Slider(
        value: Draft.BackgroundDim.toDouble(),
        min: 0,
        max: 100,
        divisions: 20,
        onChanged: Draft.BackgroundPath.isEmpty ? null : (Value) => Update(Draft.Copy(<String, dynamic>{'backgroundDim': Value.round()}), Save: false),
        onChangeEnd: (Value) => Update(Draft.Copy(<String, dynamic>{'backgroundDim': Value.round()})),
      ),
      AppHint('数值越高背景越暗，能避免背景图案影响文字阅读。'),
      Row(children: <Widget>[
        Container(width: 34, height: 34, decoration: BoxDecoration(color: AppTheme.ParseColor(Draft.ThemeColor), borderRadius: BorderRadius.circular(10), border: Border.all(color: Scheme.outlineVariant))),
        const SizedBox(width: 12),
        Text(Draft.ThemeColor, style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant)),
      ]),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: AppButton(Label: '打开色板', Kind: AppButtonKind.Outlined, Full: true, OnPressed: () => OpenPalette()),
      ),
      const SizedBox(height: 24),
    ]);
  }

  Future<void> SelectVideo(String Device) async {
    final Available = await widget.Controller.FFmpeg.Modes(Device).catchError((_) => <CaptureMode>[]);
    final PreferredFormat = Available.any((Item) => Item.Format == Draft.CaptureFormat)
        ? Draft.CaptureFormat
        : (Available.isEmpty ? Draft.CaptureFormat : Available.first.Format);
    final Candidates = Available.where((Item) => Item.Format == PreferredFormat).toList();
    final Pick = BestMode(Candidates);
    final Next = Draft.Copy(<String, dynamic>{
      'videoDevice': Device,
      if (Pick != null) 'captureFormat': Pick.Format,
      if (Pick != null) 'width': Pick.Width,
      if (Pick != null) 'height': Pick.Height,
      if (Pick != null) 'fps': Pick.MaxFps,
    });
    setState(() => Modes = Available);
    await Update(Next);
  }

  CaptureMode? BestMode(List<CaptureMode> Items) {
    if (Items.isEmpty) return null;
    final FullHd = Items.where((Item) => Item.Width == 1920 && Item.Height == 1080).toList();
    final Pool = FullHd.isEmpty ? Items : FullHd;
    return Pool.reduce((Left, Right) => Left.MaxFps >= Right.MaxFps ? Left : Right);
  }

  Future<void> ChangeFormat(String Value) async {
    final Candidates = Modes.where((Item) => Item.Format == Value).toList();
    final Pick = BestMode(Candidates);
    await Update(Draft.Copy(<String, dynamic>{
      'captureFormat': Value,
      if (Pick != null) 'width': Pick.Width,
      if (Pick != null) 'height': Pick.Height,
      if (Pick != null) 'fps': Pick.MaxFps,
    }));
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (Context) => AppDialog(
        Title: '需要重启应用',
        Description: '采集格式已切换为 ${FormatName(Value)}，请重启应用程序。',
        Content: const SizedBox.shrink(),
        Actions: <Widget>[
          AppButton(Label: '稍后重启', Kind: AppButtonKind.Text, OnPressed: () => Navigator.of(Context).pop()),
          AppButton(Label: '立即重启', OnPressed: () => widget.Controller.Relaunch()),
        ],
      ),
    );
  }

  String FormatName(String Value) => Value == 'yuy2' ? 'YUY2' : Value == 'mjpeg' ? 'MJPEG' : 'NV12';

  Future<void> Copy(String Text, String Message) async {
    if (Text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: Text));
    if (mounted) AppSnack.Show(context, Message);
  }

  Future<void> OpenPalette() async {
    var Picked = Draft.ThemeColor;
    final Result = await showDialog<String>(
      context: context,
      builder: (Context) => StatefulBuilder(builder: (Context, SetLocal) {
        return AppDialog(
          Title: '选择主题颜色',
          Content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
            Wrap(spacing: 12, runSpacing: 12, children: ThemeColors.map((Color) => AppColorDot(ColorValue: AppTheme.ParseColor(Color), Active: Picked == Color, OnTap: () => SetLocal(() => Picked = Color))).toList()),
            const SizedBox(height: 16),
            AppTextField(Label: '自定义颜色', Value: Picked, Placeholder: '#4285f4', OnChanged: (Value) {
              if (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(Value)) SetLocal(() => Picked = Value.toLowerCase());
            }),
          ]),
          Actions: <Widget>[
            AppButton(Label: '取消', Kind: AppButtonKind.Text, OnPressed: () => Navigator.of(Context).pop()),
            AppButton(Label: '确定', OnPressed: () => Navigator.of(Context).pop(Picked)),
          ],
        );
      }),
    );
    if (Result != null) await Update(Draft.Copy(<String, dynamic>{'themeColor': Result}));
  }
}













