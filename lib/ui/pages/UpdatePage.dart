import 'package:flutter/material.dart';

import '../../app/AppController.dart';
import '../../domain/UpdateInfo.dart';
import '../AppTheme.dart';
import '../Controls.dart';
import '../Shell.dart';

class UpdatePage extends StatefulWidget {
  const UpdatePage({super.key, required this.Controller});

  final AppController Controller;

  @override
  State<UpdatePage> createState() => UpdatePageState();
}

class UpdatePageState extends State<UpdatePage> {
  UpdateInfo Info = const UpdateInfo();
  String Phase = 'idle';
  String? Error;
  double Progress = 0;
  int Received = 0;
  int Total = 0;
  String DownloadPath = '';

  @override
  void initState() {
    super.initState();
    Check();
  }

  Future<void> Check() async {
    setState(() {
      Phase = 'checking';
      Error = null;
    });
    try {
      final Result = await widget.Controller.UpdateCheck();
      if (!mounted) return;
      setState(() {
        Info = Result;
        Phase = Result.Available ? 'available' : 'idle';
      });
      if (Result.Available) await Download();
    } catch (Cause) {
      if (!mounted) return;
      setState(() {
        Phase = 'error';
        Error = '$Cause';
      });
    }
  }

  Future<void> Download() async {
    if (!Info.Available) return;
    setState(() {
      Phase = 'downloading';
      Progress = 0;
    });
    try {
      final Path = await widget.Controller.DownloadUpdate(Info, (Value, Received, Total) {
        if (!mounted) return;
        setState(() {
          Progress = Value;
          this.Received = Received;
          this.Total = Total;
        });
      });
      if (!mounted) return;
      setState(() {
        DownloadPath = Path;
        Phase = 'ready';
      });
    } catch (Cause) {
      if (!mounted) return;
      setState(() {
        Phase = 'error';
        Error = '$Cause';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    final Settings = widget.Controller.SettingsValue;
    final Available = Info.Available;
    final Hint = Phase == 'checking'
        ? '正在检查 GitHub 上的最新发行版…'
        : Phase == 'downloading'
            ? '正在下载 ${Info.Tag} 安装包'
            : Phase == 'error'
                ? Error ?? '更新失败，请稍后重试'
                : Phase == 'ready'
                    ? '安装包已下载完成，点击立即安装后会退出应用并启动安装程序'
                    : Available
                        ? '正在准备下载更新包…'
                        : '已是最新版本';
    return PageBody(Children: <Widget>[
      const AppPageTitle('更新'),
      Container(
        decoration: BoxDecoration(border: Border.all(color: Scheme.outlineVariant), borderRadius: BorderRadius.circular(16)),
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(Available ? '发现新版本 ${Info.Tag}' : '当前版本 ${widget.Controller.Version}', style: AppTheme.Style(Size: 18, Weight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(Hint, style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant)),
          if (Phase == 'downloading' || Phase == 'ready') ...<Widget>[
            const SizedBox(height: 12),
            AppLinearProgress(Value: Phase == 'ready' ? 1 : Progress),
            const SizedBox(height: 6),
            Text(Phase == 'ready' ? '下载完成，${SizeText(Total)}' : '已下载 ${(Progress * 100).round()}%，${SizeText(Received)} / ${SizeText(Total)}', style: AppTheme.Style(Size: 13, ColorValue: Scheme.onSurfaceVariant)),
          ],
          if (Info.Notes.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Scheme.surfaceContainer, borderRadius: BorderRadius.circular(12)),
              child: SingleChildScrollView(child: Text(Info.Notes, style: AppTheme.Style(Size: 13, Height: 1.7))),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(spacing: 12, children: <Widget>[
            if (Available && Phase == 'ready')
              AppButton(Label: '立即安装', StartIcon: Icons.system_update_alt, OnPressed: () => widget.Controller.InstallUpdate(DownloadPath)),
            if (Phase == 'error' && Available)
              AppButton(Label: '重新下载', StartIcon: Icons.download, OnPressed: Download),
            AppButton(
              Label: Phase == 'checking' ? '正在检查更新' : '检查更新',
              Kind: Available && Phase == 'ready' ? AppButtonKind.Outlined : AppButtonKind.Filled,
              StartIcon: Icons.refresh,
              Enabled: Phase != 'checking' && Phase != 'downloading',
              OnPressed: Check,
            ),
          ]),
        ]),
      ),
      const SizedBox(height: 16),
      Container(
        decoration: BoxDecoration(border: Border.all(color: Scheme.outlineVariant), borderRadius: BorderRadius.circular(16)),
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Column(children: <Widget>[
          AppFormSwitch(Label: '网络加速', Note: '开启后将使用加速源获取更新包', Value: Settings.UpdateProxy, OnChanged: (Value) => Save(<String, dynamic>{'updateProxy': Value})),
          AppFormSwitch(Label: '自动检查更新', Note: '开启后启动应用时自动检查更新并提示', Value: Settings.UpdateCheck, OnChanged: (Value) => Save(<String, dynamic>{'updateCheck': Value})),
        ]),
      ),
    ]);
  }

  String SizeText(int Bytes) {
    if (Bytes <= 0) return '0 MB';
    return '${(Bytes / 1048576).toStringAsFixed(1)} MB';
  }

  Future<void> Save(Map<String, dynamic> Part) async {
    await widget.Controller.SaveSettings(widget.Controller.SettingsValue.Copy(Part));
    setState(() {});
  }
}








