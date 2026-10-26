import 'package:flutter/material.dart';

import '../../app/AppController.dart';
import '../../config/PlatformInfo.dart';
import '../../format/Formats.dart';
import '../AppTheme.dart';
import '../Controls.dart';
import '../Shell.dart';

class StatusPage extends StatelessWidget {
  const StatusPage({super.key, required this.Controller});

  final AppController Controller;

  @override
  Widget build(BuildContext context) {
    final Status = Controller.Status;
    if (Status == null) return const SizedBox.shrink();
    final Scheme = Theme.of(context).colorScheme;
    final Recent = Status.RecentMatches;
    final Mobile = PlatformInfo.Mobile;
    return PageBody(
      Children: <Widget>[
        const AppPageTitle('状态'),
        if (Mobile) const AppHint('移动端提供账号同步、对局与相册；采集、编码与录制请在桌面端完成。'),
        if (!Mobile) CapturePreview(Controller: Controller),
        if (!Mobile) const SizedBox(height: 20),
        if (!Mobile) ...<Widget>[
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              AppButton(
                Label: Controller.Busy && Status.RecordState == 'starting' ? '正在开始…' : '开始录制',
                Enabled: !Controller.Busy && Status.RecordState != 'recording' && Status.RecordState != 'starting',
                OnPressed: () => Controller.StartRecord(),
              ),
              AppButton(
                Label: Controller.Busy && Status.RecordState == 'recording' ? '正在停止…' : '停止录制',
                Kind: AppButtonKind.Outlined,
                Enabled: !Controller.Busy && Status.RecordState != 'idle',
                OnPressed: () => Controller.StopRecord(),
              ),
              AppButton(
                Label: '打开预览窗口',
                Enabled: Status.Width > 0 && Status.RecordError == null && Status.Settings.CaptureMode != 'rtmp',
                OnPressed: () async {
                  final Opened = await Controller.OpenPreviewWindow();
                  if (!Opened && context.mounted) await ShowPreviewDialog(context, Controller);
                },
              ),
              if (Status.RecordError != null)
                AppButton(Label: '重试采集', Kind: AppButtonKind.Text, OnPressed: () => Controller.RetryRecord()),
              if (Status.Settings.CaptureMode != 'rtmp')
                Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                  Text('声音返听', style: AppTheme.Style(Size: 15)),
                  const SizedBox(width: 4),
                  AppSwitch(
                    Value: Status.Settings.MonitorAudio,
                    Enabled: Status.HasAudio,
                    OnChanged: (Value) => Controller.SetMonitor(Value),
                  ),
                  if (!Status.HasAudio)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text('未启用音频', style: AppTheme.Style(Size: 13, ColorValue: Scheme.onSurfaceVariant).copyWith(fontStyle: FontStyle.italic)),
                    ),
                ]),
            ],
          ),
          if (Status.RecordState == 'recording')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('正在录制对局中……', style: AppTheme.Style(Size: 13, ColorValue: Scheme.primary)),
            ),
          if (Controller.Busy && Status.RecordState == 'recording')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('正在停止录制并保存分段……', style: AppTheme.Style(Size: 13, ColorValue: Scheme.primary)),
            ),
          const AppSectionTitle('录制'),
          StatusGrid(
            Children: <Widget>[
              AppStatusItem(Label: '采集方式', Value: Text(Status.Settings.CaptureMode == 'rtmp' ? 'RTMP' : '软件内捕获')),
              AppStatusItem(Label: '分辨率', Value: AppStatusText(Status.Width > 0 ? Formats.Resolution(Status.Width, Status.Height) : '未收到画面')),
              AppStatusItem(Label: '帧率', Value: AppStatusText(Status.Fps > 0 ? Formats.Fps(Status.Fps) : '未收到画面')),
              AppStatusItem(Label: '采集画面格式', Value: AppStatusText(Status.Settings.CaptureMode == 'rtmp' ? 'RTMP / MP4' : Status.PixelFormat)),
              AppStatusItem(Label: '录制格式', Value: AppStatusText(Status.Settings.CaptureMode == 'rtmp' ? 'video/mp4' : Formats.FileFormat(Status.StreamFormat ?? ''))),
              AppStatusItem(Label: '录制编码', Value: AppStatusText(Status.Encoder.isEmpty ? '-' : Status.Encoder)),
              AppStatusItem(Label: '硬件加速', Value: AppStatusText(Status.HwAccel == null ? '未启用' : '${Status.HwAccel} 硬件解码')),
              AppStatusItem(Label: '编码器', Value: AppStatusText(Status.StreamEncoder ?? '-')),
              ValueListenableBuilder<Map<String, dynamic>?>(
                valueListenable: Controller.Capture.Stats,
                builder: (Context, Stats, _) {
                  final Value = Stats == null
                      ? '等待画面'
                      : '采集 ${Stats['captureFps'] ?? 0} fps · 预览 ${Stats['previewFps'] ?? 0} fps · ${Stats['latency'] ?? 0} ms';
                  return AppStatusItem(Label: '实时链路', Value: AppStatusText(Value));
                },
              ),
              if (Status.RecordError != null) AppStatusItem(Label: '错误信息', Value: AppStatusText(Status.RecordError!)),
            ],
          ),
          if (Status.Width > 0 && Status.Width != Status.Settings.Width)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('采集卡未接受设置页的分辨率，当前输出 ${Formats.Resolution(Status.Width, Status.Height)}', style: AppTheme.Style(Size: 13, ColorValue: Scheme.error)),
            ),
          if (Status.Fps > 0 && (Status.Fps - Status.Settings.Fps).abs() > 0.5)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('采集卡未接受设置页的帧率，当前输出 ${Formats.Fps(Status.Fps)}', style: AppTheme.Style(Size: 13, ColorValue: Scheme.error)),
            ),
          if (Status.Encoder == 'libx264' && Status.Width * Status.Height * Status.Fps >= 3840 * 2160 * 30)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('当前档位没有硬件编码，录制会丢帧，建议改用有硬编的档位', style: AppTheme.Style(Size: 13, ColorValue: Scheme.error)),
            ),
        ],
        const AppSectionTitle('连接'),
        StatusGrid(
          Children: <Widget>[
            AppStatusItem(Label: 'NSO 登录', Value: AppStatusText(Formats.MatchState(Status.NSOState))),
            AppStatusItem(Label: '当前账户', Value: AppStatusText(Status.NSOCurrentNickname ?? '未选择')),
            AppStatusItem(Label: '已绑定账户', Value: AppStatusText('${Status.NSOAccounts.length} 个')),
            if (Status.NSOState == 'error' && Status.NSOError != null) AppStatusItem(Label: '失败原因', Value: AppStatusText(Status.NSOError!)),
            AppStatusItem(Label: 'QQBot 连接', Value: AppStatusText(Formats.MatchState(Status.QQState))),
            AppStatusItem(Label: '自动推送', Value: AppStatusText(Status.Settings.AutoPush ? '已开启' : '已关闭')),
          ],
        ),
        if (Status.NSOState == 'connecting')
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: AppLinearProgress(Indeterminate: true),
          ),
        const AppSectionTitle('最近对局'),
        if (Recent.isEmpty)
          AppEmpty(Status.NSOState == 'unbound' ? '暂未登录NSO，无法获取数据' : '正在获取 NSO 对局数据')
        else
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              children: Recent.map((Match) {
                final State = Controller.Status?.Processing.contains(Match.Key) == true
                    ? '正在保存'
                    : Match.VideoPath != null
                        ? '已归档'
                        : Match.SkipReason != null
                            ? '账户冲突'
                            : '未录制';
                return AppStatusItem(
                  Label: '${Match.AccountNickname == null ? '' : '${Match.AccountNickname} · '}${Formats.Kind(Match.Kind)}',
                  Value: AppStatusText('${Formats.Rule(Match.Rule)} · ${Formats.DateTimeText(Match.EndAt)} · ${Formats.Duration(Match.Duration)} · ${Match.IsDisconnected ? '掉线' : Formats.Result(Match.Result)} · $State'),
                );
              }).toList(),
            ),
          ),
      ],
    );
  }
}

class CapturePreview extends StatelessWidget {
  const CapturePreview({super.key, required this.Controller, this.Height = 0});

  final AppController Controller;
  final double Height;

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (Context, Constraints) {
      final Width = Constraints.maxWidth;
      final BoxHeight = Height > 0 ? Height : Width * 9 / 16;
      return Container(
        height: BoxHeight,
        width: double.infinity,
        decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: Controller.PreviewReady && Controller.PreviewTextureId != null
            ? Transform.flip(
                flipY: Controller.SettingsValue.FlipVertical,
                child: Texture(textureId: Controller.PreviewTextureId!, filterQuality: FilterQuality.low),
              )
            : Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    Controller.SettingsValue.CaptureMode == 'rtmp'
                        ? 'RTMP 采集模式不提供本地画面预览'
                        : Controller.PreviewError != null
                            ? Controller.PreviewError!
                            : Controller.PreviewMessage != null
                                ? Controller.PreviewMessage!
                                : Controller.SettingsValue.VideoDevice.isEmpty
                                    ? '未选择采集设备，请到设置页选择采集卡'
                                    : Controller.Capture.State.value == 'starting'
                                        ? '正在打开采集设备'
                                        : '尚未开始录制，点击“开始录制”后可预览',
                    textAlign: TextAlign.center,
                    style: AppTheme.Style(Size: 15, ColorValue: Scheme.onSurfaceVariant, Height: 1.6),
                  ),
                ),
              ),
      );
    });
  }
}

Future<void> ShowPreviewDialog(BuildContext Context, AppController Controller) async {
  await showDialog<void>(
    context: Context,
    barrierColor: Colors.black87,
    builder: (Context) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: Colors.black,
      child: SizedBox(
        width: 960,
        height: 540,
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: ListenableBuilder(
                listenable: Controller,
                builder: (Context, _) => CapturePreview(Controller: Controller, Height: 540),
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: AppIconButton(Glyph: Icons.close, OnPressed: () => Navigator.of(Context).pop()),
            ),
          ],
        ),
      ),
    ),
  );
}












