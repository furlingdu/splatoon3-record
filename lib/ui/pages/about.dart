import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../config/system.dart';
import '../../format/formats.dart';
import '../../media/capture/mobile/mobileMedia.dart';
import '../theme.dart';
import '../controls.dart';
import '../shell.dart';
import '../videoActions.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key, required this.Controller});

  final AppController Controller;

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    return PageBody(Children: <Widget>[
      const AppPageTitle('关于'),
      AboutCard(Children: <Widget>[
        Row(children: <Widget>[
          Image.asset('assets/images/appIcon.png', width: 72, height: 72),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text('Splatoon3 Record', style: AppTheme.Style(Size: 18, Weight: FontWeight.w600)),
              Text('Splatoon3Record Ver.${Controller.Version}', style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant)),
            ]),
          ),
        ]),
        Text('一款斯普拉遁3录制机，通过采集卡自动采集整局录像，并通过 QQBot 推送。', style: AppTheme.Style(Size: 14, Height: 1.7)),
        AppButton(Label: '保存日志反馈内容', OnPressed: () => SaveReport(context)),
      ]),
      AboutCard(Children: <Widget>[
        Row(children: <Widget>[
          ClipOval(child: Image.network('https://q2.qlogo.cn/headimg_dl?dst_uin=3648192311&spec=640', width: 64, height: 64, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Icon(Icons.person, size: 64))),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text('澪度', style: AppTheme.Style(Size: 18, Weight: FontWeight.w600)),
              Text('作者', style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant)),
            ]),
          ),
        ]),
        Text('斯普拉遁3录制机作者，梦想是把巨齿刮水刀打到十星！', style: AppTheme.Style(Size: 14, Height: 1.7)),
        Text('喜欢我的话，欢迎关注项目主页。', style: AppTheme.Style(Size: 14, Height: 1.7)),
        AppButton(Label: '项目主页', Kind: AppButtonKind.Tonal, StartIcon: Icons.link, OnPressed: () => Controller.OpenFile('https://github.com/furlingdu/splatoon3-record')),
      ]),
      AboutCard(Children: <Widget>[
        Row(children: <Widget>[
          ClipOval(child: Image.asset('assets/images/abxy.png', width: 64, height: 64, fit: BoxFit.cover)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text('ABXY', style: AppTheme.Style(Size: 18, Weight: FontWeight.w600)),
              Text('乐队', style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant)),
            ]),
          ),
        ]),
        Text('这是一支由四名成员组成的乐队，他们以朗朗上口的电子音乐和主唱脉子的歌声在音乐排行榜上掀起热潮。在演唱会上，他们让复古游戏机与音乐联动，并通过自身发光进行表演，这使得他们收获了很高的人气。收录的歌声使用了大量的后期修音，所以现场表演经常是对口型假唱。', style: AppTheme.Style(Size: 14, Height: 1.7)),
        Text('作者是ABXY小粉丝~~', style: AppTheme.Style(Size: 14, Height: 1.7)),
      ]),
      AboutCard(Children: <Widget>[
        Text('项目致谢', style: AppTheme.Style(Size: 18, Weight: FontWeight.w600)),
        Text('本项目的 NSO 登录与 SplatNet 3 数据接入参考了开源项目 Cypas/splatoon3-nso 的实现，在此致谢。', style: AppTheme.Style(Size: 14, Height: 1.7)),
        Text('NSO 登录 Token 加密依赖 samuelthomas2774/nxapi 所公开的 nxapi-znca-api 接口。请注意，当涉及到NSO登录时，你的id_token会被发送到nxapi-znca-api服务以获取必要的校验参数。id_token仅包含账号标识与有效期，不含密码，仅用于完成登录。', style: AppTheme.Style(Size: 14, Height: 1.7)),
        Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
          AppButton(Label: 'GitHub：furlingdu/splatoon3-record', Kind: AppButtonKind.Tonal, StartIcon: Icons.link, OnPressed: () => Controller.OpenFile('https://github.com/furlingdu/splatoon3-record')),
          AppButton(Label: 'GitHub：Cypas/splatoon3-nso', Kind: AppButtonKind.Tonal, StartIcon: Icons.link, OnPressed: () => Controller.OpenFile('https://github.com/Cypas/splatoon3-nso')),
          AppButton(Label: 'GitHub：samuelthomas2774/nxapi', Kind: AppButtonKind.Tonal, StartIcon: Icons.link, OnPressed: () => Controller.OpenFile('https://github.com/samuelthomas2774/nxapi')),
        ]),
      ]),
      AboutCard(Children: <Widget>[
        Text('为什么登录需要经过 nxapi-znca-api?', style: AppTheme.Style(Size: 18, Weight: FontWeight.w600)),
        Text('Nintendo 在登录服务的登录请求中要求携带一个由官方 NSO App 内置算法生成的校验参数，该算法无法在第三方应用中复现，因此登录时需要把 Nintendo 签发的 id_token 提交给公开的 nxapi-znca-api 服务换取这个参数。id_token 只包含账号标识与有效期，不含密码，仅用于完成登录。', style: AppTheme.Style(Size: 14, Height: 1.7)),
      ]),
    ]);
  }

  Future<void> SaveReport(BuildContext Context) async {
    final Status = Controller.Status;
    final Settings = Controller.SettingsValue;
    final Devices = Controller.Devices;
    final Videos = Devices.where((Item) => Item.Kind == 'video').toList();
    final Audios = Devices.where((Item) => Item.Kind == 'audio').toList();
    final Stats = Controller.Capture.Stats.value ?? const <String, dynamic>{};
    final Accounts = Controller.Accounts;
    final Records = Controller.Archive.Matches;
    final FFmpegVersion = await Controller.FFmpeg.Version();
    final Size = MediaQuery.sizeOf(Context);
    final Ratio = MediaQuery.devicePixelRatioOf(Context);
    final Insets = MediaQuery.paddingOf(Context);
    final Now = DateTime.now();
    final Offset = Now.timeZoneOffset;
    String NameOf(String Id) {
      if (Id.isEmpty) return '未选择';
      for (final Item in Devices) {
        if (Item.Id == Id) return '${Item.Name}（$Id）';
      }
      return Id;
    }

    String TimeText(int? Value) => Value == null ? '无' : Formats.DateTimeText(Value);
    final Lines = <String>[
      'Splatoon3 Record 反馈报告',
      '生成时间：${Now.toIso8601String()}',
      '',
      '===== 应用 =====',
      '应用版本：${Controller.Version}',
      'Flutter：3.47.8',
      'Dart：${Platform.version}',
      '系统：${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      '处理器核心：${Platform.numberOfProcessors}',
      '时区：${Now.timeZoneName}（${Offset.inMinutes >= 0 ? '+' : '-'}${(Offset.inMinutes.abs() ~/ 60).toString().padLeft(2, '0')}:${(Offset.inMinutes.abs() % 60).toString().padLeft(2, '0')}）',
      '屏幕：${Size.width.toStringAsFixed(0)}x${Size.height.toStringAsFixed(0)}，像素比 ${Ratio.toStringAsFixed(2)}',
      '安全区：上 ${Insets.top.toStringAsFixed(0)} / 下 ${Insets.bottom.toStringAsFixed(0)} / 左 ${Insets.left.toStringAsFixed(0)} / 右 ${Insets.right.toStringAsFixed(0)}',
      '界面类别：${Size.shortestSide >= 600 ? '平板' : '手机'}',
      '',
      '===== 采集 =====',
      '平台：${PlatformInfo.Windows ? 'Windows' : PlatformInfo.MacOS ? 'macOS' : PlatformInfo.Linux ? 'Linux' : PlatformInfo.IOS ? 'iOS' : PlatformInfo.Android ? 'Android' : Platform.operatingSystem}',
      '捕获方式：${Settings.CaptureMode == 'rtmp' ? 'RTMP' : '软件内捕获'}',
      '移动端采集来源：${Settings.MobileSource}',
      '视频设备数量：${Videos.length}',
      ...Videos.map((Item) => '  视频设备：${Item.Name}（${Item.Id}）'),
      '音频设备数量：${Audios.length}',
      ...Audios.map((Item) => '  音频设备：${Item.Name}（${Item.Id}）'),
      '已选视频设备：${NameOf(PlatformInfo.Mobile ? Settings.MobileDevice : Settings.VideoDevice)}',
      '已选音频设备：${NameOf(PlatformInfo.Mobile ? Settings.MobileAudioDevice : Settings.AudioDevice)}',
      '音频录制：${Settings.MobileAudio ? '开' : '关'}',
      '声音返听：${Settings.MonitorAudio ? '开' : '关'}',
      '设置分辨率：${Settings.Width}x${Settings.Height} @ ${Settings.Fps}fps',
      '实际分辨率：${Status?.Width ?? 0}x${Status?.Height ?? 0} @ ${Formats.Fps(Status?.Fps ?? 0)}',
      '采集像素格式：${Status?.PixelFormat ?? '未知'}',
      '录制编码：${Status?.Encoder ?? '未知'}',
      '编码器：${Status?.StreamEncoder ?? '未知'}',
      '硬件加速：${Status?.HwAccel ?? '未启用'}',
      if (!PlatformInfo.Mobile) '内置 FFmpeg：${FFmpegVersion.isEmpty ? '未知' : FFmpegVersion}',
      if (!PlatformInfo.Mobile) '编码器检测：${Controller.FFmpeg.EncoderNote ?? '正常'}',
      '录制质量：${Settings.Quality}',
      '画面方向：${Settings.MobileOrientation}',
      '垂直翻转：${Settings.FlipVertical ? '开' : '关'}',
      '',
      '===== 录制状态 =====',
      '录制状态：${Status?.RecordState ?? '未知'}',
      '录制错误：${Status?.RecordError ?? '无'}',
      '缓存分段：${Status?.Segments ?? 0}',
      '缓存开始：${TimeText(Status?.CacheStart)}',
      '缓存结束：${TimeText(Status?.CacheEnd)}',
      '采集帧率：${Stats['captureFps'] ?? 0}',
      '预览帧率：${Stats['previewFps'] ?? 0}',
      '预览延迟：${Stats['latency'] ?? 0}',
      '丢帧计数：${Stats['dropped'] ?? 0}',
      '队列积压：${Stats['queue'] ?? 0}',
      '音频录制状态：${Stats['audio'] == true ? '录制中' : '未录制'}',
      '音频错误：${Stats['audioError'] ?? '无'}',
      '',
      '===== Nintendo Switch Online =====',
      '状态：${Formats.BindingState(Status?.NSOState ?? 'unbound')}',
      '当前账户：${Status?.NSOCurrentNickname ?? '未选择'}',
      '失败原因：${Status?.NSOError ?? '无'}',
      '已绑定账户：${Accounts.length}',
      ...Accounts.map((Item) => '  ${Item.Nickname}：${Formats.BindingState(Item.State)}${Item.Error == null ? '' : '，${Item.Error}'}'),
      '',
      '===== QQBot =====',
      '状态：${Formats.BindingState(Status?.QQState ?? 'unbound')}',
      '绑定用户：${Status?.QQOwner != null ? '已绑定' : '未绑定'}',
      '错误：${Controller.QQError ?? '无'}',
      '二维码：${Status?.QrCode == null ? '无' : '已生成'}',
      '',
      '===== 归档与目录 =====',
      '对局数量：${Records.length}',
      '最新对局：${Records.isEmpty ? '无' : Formats.DateTimeText(Records.first.EndAt)}',
      '数据目录：${Controller.Directories.Root}',
      '缓存目录：${Controller.Directories.Cache}',
      '归档目录：${Controller.Directories.Videos}',
      '保存目录：${Settings.SaveDir.isEmpty ? '默认' : Settings.SaveDir}',
      '背景图片：${Settings.BackgroundPath.isEmpty ? '无' : Settings.BackgroundPath}',
      '',
      '===== 设置摘要 =====',
      '自动录制：${Settings.AutoRecord ? '开' : '关'}',
      '自动推送：${Settings.AutoPush ? '开' : '关'}',
      '开机启动：${Settings.AutoLaunch ? '开' : '关'}',
      '昵称打码：${Settings.BlurNickname ? '开' : '关'}',
      '轮询间隔：${Settings.PollSeconds} 秒',
      '检查更新：${Settings.UpdateCheck ? '开' : '关'}',
      '更新代理：${Settings.UpdateProxy ? '开' : '关'}',
      '主题色：${Settings.ThemeColor}',
      '背景暗度：${Settings.BackgroundDim}',
      'RTMP 端口：${Settings.RtmpPort}',
      'RTMP 输入：${Status?.RtmpInputUrl ?? '未启用'}',
      'RTMP 推流状态：${Status?.RtmpPushState ?? '未知'}',
    ];
    final Path = await Controller.Logs.Report(Lines.join('\n'));
    if (!Context.mounted) return;
    if (Path == null) {
      AppSnack.Show(Context, '日志反馈内容保存失败，请稍后重试。');
      return;
    }
    if (PlatformInfo.IOS) {
      var Saved = false;
      try {
        Saved = await MobileMedia.SaveFile(Path);
      } catch (Cause) {
        if (Context.mounted) AppSnack.Show(Context, '保存日志反馈内容失败：$Cause');
        return;
      }
      if (Context.mounted && Saved) AppSnack.Show(Context, '日志反馈内容已保存');
      return;
    }
    if (PlatformInfo.Mobile) {
      await ShareText(Context, Path, 'Splatoon3 Record 日志反馈');
      AppSnack.Show(Context, '请在系统分享面板中选择“存储到文件”保存 TXT 文件。');
      return;
    }
    await Controller.OpenPath(Path);
    AppSnack.Show(Context, '日志反馈内容已保存到 $Path');
  }
}

class AboutCard extends StatelessWidget {
  const AboutCard({super.key, required this.Children});

  final List<Widget> Children;

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      decoration: BoxDecoration(border: Border.all(color: Scheme.outlineVariant), borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 12, children: Children),
    );
  }
}












