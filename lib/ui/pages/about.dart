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
    final Text = <String>[
      'Splatoon3 Record 设备反馈信息',
      '应用版本：${Controller.Version}',
      'Flutter：3.47.8',
      'Dart：3.13.7',
      '系统：${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      '采集卡：${Controller.Devices.where((Item) => Item.Kind == 'video').map((Item) => Item.Name).join('、')}',
      '已选采集卡：${Status?.Settings.VideoDevice ?? '未选择'}',
      '视频设备：${Controller.Devices.where((Item) => Item.Kind == 'video').length}',
      '音频设备：${Controller.Devices.where((Item) => Item.Kind == 'audio').length}',
      '采集画面：${Status?.Width ?? 0}x${Status?.Height ?? 0} @ ${Formats.Fps(Status?.Fps ?? 0)}',
      '录制编码格式：${Status?.StreamEncoder ?? '未知'}',
      '录制质量：${Status?.Settings.Quality ?? '未知'}',
      '捕获方式：${Status?.Settings.CaptureMode == 'rtmp' ? 'RTMP' : '软件内捕获'}',
      'RTMP 输入：${Status?.RtmpInputUrl ?? '未启用'}',
      'RTMP 推流状态：${Status?.RtmpPushState ?? '未知'}',
    ].join('\n');
    final Path = await Controller.Logs.Report(Text);
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












