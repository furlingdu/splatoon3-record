import 'package:flutter/material.dart';

import '../../app/AppController.dart';
import '../../config/Config.dart';
import '../../domain/Models.dart';
import '../../format/Formats.dart';
import '../AppTheme.dart';
import '../Controls.dart';

class SetupPage extends StatefulWidget {
  const SetupPage({super.key, required this.Controller});

  final AppController Controller;

  @override
  State<SetupPage> createState() => SetupPageState();
}

class SetupPageState extends State<SetupPage> {
  int Step = 0;
  late String VideoDevice;
  late String AudioDevice;
  late int Width;
  late int Height;
  late int Fps;

  @override
  void initState() {
    super.initState();
    final Settings = widget.Controller.SettingsValue;
    VideoDevice = Settings.VideoDevice;
    AudioDevice = Settings.AudioDevice;
    Width = Settings.Width;
    Height = Settings.Height;
    Fps = Settings.Fps;
  }

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    final Video = widget.Controller.Devices.where((Item) => Item.Kind == 'video').toList();
    final Audio = widget.Controller.Devices.where((Item) => Item.Kind == 'audio').toList();
    return Material(
      color: Colors.transparent,
      child: Stack(children: <Widget>[
        const Positioned.fill(child: SetupBackground()),
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(32, 28, 32, 40),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
              Row(children: <Widget>[
                Image.asset('assets/images/AppIcon.png', width: 56, height: 56),
                const SizedBox(width: 16),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Text('Splatoon3 Record', style: AppTheme.Style(Size: 18, Weight: FontWeight.w600)),
                  Text('初始设置 · 步骤 ${Step + 1} / 3：${const <String>['选择采集卡设备', '绑定 Nintendo 账号', '绑定 QQBot'][Step]}', style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant)),
                ]),
              ]),
              const SizedBox(height: 20),
              AppLinearProgress(Value: (Step + 1) / 3),
              const SizedBox(height: 24),
              if (Step == 0) ...<Widget>[
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
                const SizedBox(height: 8),
                AppButton(Label: '下一步', OnPressed: () async {
                  await Save(<String, dynamic>{'videoDevice': VideoDevice, 'audioDevice': AudioDevice});
                  setState(() => Step = 1);
                }),
              ],
              if (Step == 1) ...<Widget>[
                const AppSectionTitle('绑定 Nintendo 账号'),
                const SizedBox(height: 8),
                Text('点击下方按钮登录 Nintendo 账号并授权鱿鱼圈 3 数据读取，登录成功后应用才能检测对局结果。每次登录前都会自动清除登录窗口的 cookies。', style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant, Height: 1.6)),
                const SizedBox(height: 16),
                AppButton(Label: '登录 Nintendo 账号', OnPressed: () => widget.Controller.StartNSOLogin()),
                const SizedBox(height: 16),
                StatusBox(Label: '当前状态', Value: Formats.BindingState(widget.Controller.Status?.NSOState ?? 'unbound')),
                StatusBox(Label: '已绑定账户', Value: '${widget.Controller.Status?.NSOAccounts.length ?? 0} 个'),
                const SizedBox(height: 24),
                Row(children: <Widget>[
                  AppButton(Label: '上一步', Kind: AppButtonKind.Text, OnPressed: () => setState(() => Step = 0)),
                  const SizedBox(width: 12),
                  AppButton(Label: '下一步', OnPressed: () => setState(() => Step = 2)),
                ]),
              ],
              if (Step == 2) ...<Widget>[
                const AppSectionTitle('绑定 QQBot'),
                Text('绑定后可将对局录像推送到你的 QQ。点击按钮获取二维码，并使用创建机器人的 QQ 扫码授权。', style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant, Height: 1.6)),
                const SizedBox(height: 16),
                AppButton(Label: '获取绑定机器人二维码', OnPressed: () => widget.Controller.StartQQLogin()),
                if (widget.Controller.Status?.QrCode != null) ...<Widget>[
                  const SizedBox(height: 16),
                  Center(child: QrView(Data: widget.Controller.Status!.QrCode!)),
                ],
                const SizedBox(height: 16),
                StatusBox(Label: '当前状态', Value: Formats.BindingState(widget.Controller.Status?.QQState ?? 'unbound')),
                StatusBox(Label: '推送用户', Value: widget.Controller.Status?.QQOwner == null ? '未绑定' : '已绑定'),
                const SizedBox(height: 24),
                Row(children: <Widget>[
                  AppButton(Label: '上一步', Kind: AppButtonKind.Text, OnPressed: () => setState(() => Step = 1)),
                  const SizedBox(width: 12),
                  AppButton(Label: '完成并进入应用', OnPressed: () => widget.Controller.FinishSetup()),
                ]),
              ],
              const SizedBox(height: 24),
              Align(
                alignment: Alignment.bottomRight,
                child: Opacity(
                  opacity: 0.5,
                  child: Image.asset('assets/images/Character.png', height: 240, fit: BoxFit.contain),
                ),
              ),
            ]),
          ),
        ),
        ),
      ],
    ),
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















