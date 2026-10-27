import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:haishin_kit/haishin_kit.dart';

import '../../app/AppController.dart';
import '../../config/PlatformInfo.dart';
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
    if (PlatformInfo.Mobile) return MobileLiveView(Controller: widget.Controller);
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













class MobileLiveView extends StatefulWidget {
  const MobileLiveView({super.key, required this.Controller});

  final AppController Controller;

  @override
  State<MobileLiveView> createState() => MobileLiveViewState();
}

class MobileLiveViewState extends State<MobileLiveView> {
  List<VideoSource> Sources = <VideoSource>[];
  String Source = '';
  bool Busy = false;

  @override
  void initState() {
    super.initState();
    Load();
  }

  Future<void> Load() async {
    final Items = await widget.Controller.MobileLive.Sources();
    if (!mounted) return;
    setState(() {
      Sources = Items;
      if (Source.isEmpty && Items.isNotEmpty) Source = Items.first.id;
    });
  }

  Future<void> Toggle(bool Value) async {
    if (Busy) return;
    setState(() => Busy = true);
    try {
      if (Value) {
        await widget.Controller.StartMobileLive(VideoId: Source);
      } else {
        await widget.Controller.StopMobileLive();
      }
    } finally {
      if (mounted) setState(() => Busy = false);
    }
  }

  Future<void> Save(Map<String, dynamic> Part) async {
    await widget.Controller.SaveSettings(widget.Controller.SettingsValue.Copy(Part));
  }

  @override
  Widget build(BuildContext context) {
    final Live = widget.Controller.MobileLive;
    final Settings = widget.Controller.SettingsValue;
    final Scheme = Theme.of(context).colorScheme;
    return PageBody(
      Children: <Widget>[
        const AppPageTitle('直播'),
        ValueListenableBuilder<String>(
          valueListenable: Live.State,
          builder: (Context, State, _) {
            final Preview = Live.BuildPreview();
            return AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(12)),
                clipBehavior: Clip.antiAlias,
                child: Preview ??
                    Center(
                      child: Text(
                        State == 'starting' ? '正在连接…' : State == 'live' ? '直播中' : '未开始直播',
                        style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant),
                      ),
                    ),
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        ValueListenableBuilder<String>(
          valueListenable: Live.State,
          builder: (Context, State, _) {
            final TextValue = State == 'live' ? '直播中' : State == 'starting' ? '连接中' : State == 'error' ? '推流失败' : '未直播';
            return Text('状态：$TextValue', style: AppTheme.Style(Size: 14, ColorValue: State == 'error' ? Scheme.error : Scheme.onSurfaceVariant));
          },
        ),
        ValueListenableBuilder<String?>(
          valueListenable: Live.Error,
          builder: (Context, Error, _) {
            if (Error == null || Error.isEmpty) return const SizedBox.shrink();
            return Padding(padding: const EdgeInsets.only(top: 6), child: Text(Error, style: AppTheme.Style(Size: 13, ColorValue: Scheme.error)));
          },
        ),
        const AppSectionTitle('推流设置'),
        AppSelect<String>(
          Label: '摄像头',
          Value: Source,
          Items: <String>['', ...Sources.map((Item) => Item.id)],
          Display: (Value) => Value.isEmpty ? '默认摄像头' : Sources.firstWhere((VideoSource Item) => Item.id == Value, orElse: () => const VideoSource(id: '', name: '默认摄像头')).name ?? Value,
          OnChanged: (Value) => setState(() => Source = Value),
        ),
        AppTextField(Label: 'RTMP 推流地址', Value: Settings.RtmpPushUrl, Placeholder: 'rtmp://example.com/live', Enabled: Live.State.value != 'live', OnChanged: (Value) => Save(<String, dynamic>{'rtmpPushUrl': Value})),
        AppTextField(Label: '推流码', Value: Settings.RtmpPushKey, Placeholder: '留空则直接使用上方地址', Enabled: Live.State.value != 'live', OnChanged: (Value) => Save(<String, dynamic>{'rtmpPushKey': Value})),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: <Widget>[
            AppButton(Label: Busy ? '处理中…' : '开始直播', Enabled: !Busy && Live.State.value != 'live' && Live.State.value != 'starting', OnPressed: () => Toggle(true)),
            AppButton(Label: '停止直播', Kind: AppButtonKind.Outlined, Enabled: !Busy && Live.State.value != 'idle', OnPressed: () => Toggle(false)),
          ],
        ),
        const AppHint('移动端直播使用系统摄像头，iPadOS 识别到的外接相机也会出现在列表；开始直播会先停止缓存录制，推流地址与推流码会保存到设置。'),
      ],
    );
  }
}