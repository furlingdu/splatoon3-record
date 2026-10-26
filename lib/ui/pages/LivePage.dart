import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/AppController.dart';
import '../../format/Formats.dart';
import '../AppTheme.dart';
import '../Controls.dart';
import 'StatusPage.dart';
import '../Shell.dart';

class LivePage extends StatefulWidget {
  const LivePage({super.key, required this.Controller});

  final AppController Controller;

  @override
  State<LivePage> createState() => LivePageState();
}

class LivePageState extends State<LivePage> {
  bool Live = false;
  bool Blur = false;

  @override
  void initState() {
    super.initState();
    Blur = widget.Controller.SettingsValue.BlurNickname;
  }

  @override
  Widget build(BuildContext context) {
    final Status = widget.Controller.Status;
    final Settings = widget.Controller.SettingsValue;
    final Target = widget.Controller.PushTarget(Settings.RtmpPushUrl, Settings.RtmpPushKey);
    final CopyMode = Settings.CaptureMode == 'rtmp' && !Blur;
    final Scheme = Theme.of(context).colorScheme;
    return PageBody(
      Children: <Widget>[
        const AppPageTitle('直播'),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(Settings.CaptureMode == 'rtmp' ? 'RTMP 输入画面' : '采集画面', style: AppTheme.Style(Size: 13, ColorValue: Scheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            CapturePreview(Controller: widget.Controller),
          ])),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text('直播画面', style: AppTheme.Style(Size: 13, ColorValue: Scheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            CapturePreview(Controller: widget.Controller),
          ])),
        ]),
        const AppSectionTitle('直播与打码'),
        AppFormSwitch(
          Label: '开启直播',
          Note: '开启后，将画面推流至下方填写的 RTMP 地址。RTMP 捕获且未开启昵称自动打码时，输入画面与音轨直接无损转发；开启打码后推送本地处理后的画面。',
          Value: Live,
          OnChanged: (Value) => ToggleLive(Value),
        ),
        if (Status?.RtmpPushState == 'starting')
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('正在连接推流服务……', style: AppTheme.Style(Size: 13, ColorValue: Scheme.onSurfaceVariant)),
          ),
        if (Settings.CaptureMode == 'rtmp' && Status?.RtmpState != 'live')
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('等待 OBS 等推流端向本机 RTMP 输入推流。', style: AppTheme.Style(Size: 13, ColorValue: Scheme.onSurfaceVariant)),
          ),
        AppTextField(Label: 'RTMP 推流地址', Value: Settings.RtmpPushUrl, Placeholder: 'rtmp://example.com/live', Enabled: !Live, OnChanged: (Value) => Save(<String, dynamic>{'rtmpPushUrl': Value})),
        AppTextField(Label: '推流码', Value: Settings.RtmpPushKey, Placeholder: '留空则直接使用上方地址', Enabled: !Live, OnChanged: (Value) => Save(<String, dynamic>{'rtmpPushKey': Value})),
        AppFormSwitch(
          Label: '昵称自动打码',
          Note: '开启按钮后，将在本地进行画面后处理。对画面中展示的昵称进行模糊打码处理。适用于直播用户。\n由于实时检测存在一定的性能需求，推荐搭载了独立显卡的用户进行使用。',
          Value: Blur,
          Enabled: !Live,
          OnChanged: (Value) {
            setState(() => Blur = Value);
            Save(<String, dynamic>{'blurNickname': Value});
          },
        ),
        const AppSectionTitle('RTMP 输入'),
        StatusGrid(Children: <Widget>[
          if (Settings.CaptureMode == 'rtmp')
            AppStatusItem(
              Label: '输入地址',
              Value: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                Flexible(child: AppStatusText(Status?.RtmpInputUrl ?? '等待 RTMP 服务启动')),
                if ((Status?.RtmpInputUrl ?? '').isNotEmpty)
                  AppIconButton(Glyph: Icons.copy, Tooltip: '复制', OnPressed: () => Copy(Status!.RtmpInputUrl!, 'RTMP 输入地址已复制')),
              ]),
            ),
          AppStatusItem(Label: '推流目标', Value: AppStatusText(Target.isEmpty ? '未设置' : Target)),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            Settings.CaptureMode == 'rtmp' && !Blur
                ? '昵称打码未开启，RTMP 输入画面与音轨直接无损转发。'
                : Settings.CaptureMode == 'rtmp'
                    ? '昵称打码已开启，直播推送处理后的画面。'
                    : '软件内捕获模式下，直播推送本地编码后的画面。',
            style: AppTheme.Style(Size: 13, ColorValue: Scheme.onSurfaceVariant),
          ),
        ),
        const AppSectionTitle('直播状态'),
        StatusGrid(Children: <Widget>[
          AppStatusItem(Label: '直播状态', Value: AppStatusText(Formats.PushState(Status?.RtmpPushState ?? 'idle'))),
          AppStatusItem(Label: '转发方式', Value: AppStatusText(Live ? (CopyMode ? '无损转发（不转码）' : '打码后重新编码') : '未直播')),
          AppStatusItem(Label: '编码器', Value: AppStatusText(Live ? (CopyMode ? '未转码（直接转发）' : Status?.StreamEncoder ?? '等待编码') : '未直播')),
          AppStatusItem(Label: '直播码率', Value: AppStatusText(Live ? (CopyMode ? '跟随输入' : '等待连接') : '未直播')),
          AppStatusItem(Label: '推理设备', Value: AppStatusText(Blur ? 'ONNX Runtime' : '未开启打码')),
          AppStatusItem(Label: '打码目标', Value: AppStatusText(Blur ? '实时检测' : '未开启')),
          AppStatusItem(Label: '画面帧率', Value: AppStatusText(Status != null && Status.Fps > 0 ? Formats.Fps(Status.Fps) : '未运行')),
          AppStatusItem(Label: '推理帧率', Value: AppStatusText(Blur ? '实时' : '未开启')),
          if ((Status?.RtmpPushError ?? '').isNotEmpty) AppStatusItem(Label: '直播错误', Value: AppStatusText(Status!.RtmpPushError!)),
        ]),
        if (Status?.RtmpPushState == 'error')
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('直播推流已中断，请检查推流地址与推流码后重新开始直播', style: AppTheme.Style(Size: 13, ColorValue: Scheme.error)),
          ),
        if (Status?.RtmpPushError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(Status!.RtmpPushError!, style: AppTheme.Style(Size: 13, ColorValue: Scheme.error)),
          ),
      ],
    );
  }

  Future<void> ToggleLive(bool Value) async {
    if (Value) {
      await widget.Controller.StartLive();
      setState(() => Live = widget.Controller.Capture.LiveTarget != null);
    } else {
      await widget.Controller.StopLive();
      setState(() => Live = false);
    }
  }

  Future<void> Save(Map<String, dynamic> Part) async {
    await widget.Controller.SaveSettings(widget.Controller.SettingsValue.Copy(Part));
  }

  Future<void> Copy(String Text, String Message) async {
    await Clipboard.setData(ClipboardData(text: Text));
    if (mounted) AppSnack.Show(context, Message);
  }
}












