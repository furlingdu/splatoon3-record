import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../config/system.dart';
import 'theme.dart';
import 'controls.dart';

class NSOLoginPanel extends StatefulWidget {
  const NSOLoginPanel({super.key, required this.Controller});

  final AppController Controller;

  @override
  State<NSOLoginPanel> createState() => NSOLoginPanelState();
}

class NSOLoginPanelState extends State<NSOLoginPanel> {
  final TextEditingController Callback = TextEditingController();

  @override
  void dispose() {
    Callback.dispose();
    super.dispose();
  }

  Future<void> CopyLink() async {
    final Url = widget.Controller.PendingAuth?.Url;
    if (Url == null || Url.isEmpty) {
      AppSnack.Show(context, '请先获取 Nintendo 登录链接');
      return;
    }
    await Clipboard.setData(ClipboardData(text: Url));
    if (mounted) AppSnack.Show(context, '登录链接已复制');
  }

  Future<void> PasteLink() async {
    final Data = await Clipboard.getData(Clipboard.kTextPlain);
    final Text = Data?.text?.trim() ?? '';
    if (!mounted) return;
    if (Text.isEmpty) {
      AppSnack.Show(context, '剪贴板中没有可粘贴的链接');
      return;
    }
    Callback.text = Text;
  }

  Future<void> Submit() async {
    if (widget.Controller.AuthBusy) return;
    final Text = Callback.text.trim();
    if (Text.isEmpty) {
      AppSnack.Show(context, '请先粘贴 Nintendo 登录回调链接');
      return;
    }
    await widget.Controller.SubmitAuth(Text);
    if (!mounted) return;
    if (widget.Controller.PendingAuth == null) Callback.clear();
  }

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    final Busy = widget.Controller.AuthBusy;
    if (!PlatformInfo.Mobile) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        Text('点击下方按钮登录 Nintendo 账号并授权鱿鱼圈 3 数据读取，登录成功后应用才能检测对局结果。每次登录前都会自动清除登录窗口的 cookies。', style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant, Height: 1.6)),
        const SizedBox(height: 16),
        AppButton(Label: Busy ? '正在登录…' : '登录 Nintendo 账号', Enabled: !Busy, OnPressed: () => widget.Controller.StartNSOLogin()),
        if (Busy) const Padding(padding: EdgeInsets.only(top: 12), child: AppLinearProgress(Indeterminate: true)),
      ]);
    }
    final Pending = widget.Controller.PendingAuth;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      Text('1. 点击“获取登录链接”。\n2. 复制链接并在浏览器中打开，完成 Nintendo 登录。\n3. 登录后长按“选择此人”按钮，复制回调 URL。\n4. 将回调 URL 粘贴到下方输入框并点击登录。', style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant, Height: 1.7)),
      const SizedBox(height: 12),
      if (Pending == null)
        AppButton(Label: '获取登录链接', Enabled: !Busy, OnPressed: () => widget.Controller.StartNSOLogin())
      else ...<Widget>[
        AppTextField(Label: 'Nintendo 登录链接', Value: Pending.Url, ReadOnly: true, OnIcon: Icons.copy, OnIconTap: CopyLink),
        Row(children: <Widget>[
          Expanded(child: AppButton(Label: '复制登录链接', Kind: AppButtonKind.Outlined, OnPressed: CopyLink)),
          const SizedBox(width: 12),
          Expanded(child: AppButton(Label: '在浏览器中打开', Kind: AppButtonKind.Outlined, OnPressed: () => widget.Controller.OpenAuth())),
        ]),
        AppButton(Label: '重新获取登录链接', Kind: AppButtonKind.Text, Enabled: !Busy, OnPressed: () => widget.Controller.StartNSOLogin()),
      ],
      if (Busy) const Padding(padding: EdgeInsets.only(top: 8), child: AppLinearProgress(Indeterminate: true)),
      AppTextField(
        Label: '回调 URL',
        Controller: Callback,
        Placeholder: '长按“选择此人”复制链接后粘贴到这里',
        Enabled: Pending != null && !Busy,
        OnIcon: Icons.content_paste,
        OnIconTap: PasteLink,
        OnSubmitted: (_) => Submit(),
      ),
      AppButton(Label: Busy ? '正在登录…' : '使用回调链接登录', Enabled: Pending != null && !Busy, OnPressed: Submit),
      if (Pending == null) const AppHint('当前没有待完成的登录，请先获取登录链接。'),
    ]);
  }
}

Future<void> OpenNSOLogin(BuildContext Context, AppController Controller) async {
  if (Controller.PendingAuth == null) await Controller.StartNSOLogin();
  if (!Context.mounted) return;
  await showDialog<void>(
    context: Context,
    builder: (Context) => AppDialog(
      Title: '登录 Nintendo 账号',
      Content: NSOLoginPanel(Controller: Controller),
      Actions: <Widget>[
        AppButton(Label: '关闭', Kind: AppButtonKind.Text, OnPressed: () => Navigator.of(Context).pop()),
      ],
    ),
  );
}
