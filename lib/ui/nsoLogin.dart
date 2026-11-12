import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../config/system.dart';
import '../nso/callback.dart';
import 'drop.dart';
import 'nsoBackend.dart';
import 'theme.dart';
import 'controls.dart';

class NSOLoginPanel extends StatefulWidget {
  const NSOLoginPanel({super.key, required this.Controller, this.OnLogin});

  final AppController Controller;

  /// Called when the login completes, so a dialog hosting this panel can close
  /// itself instead of leaving the user on a stale success screen.
  final VoidCallback? OnLogin;

  @override
  State<NSOLoginPanel> createState() => NSOLoginPanelState();
}

class NSOLoginPanelState extends State<NSOLoginPanel> {
  final TextEditingController Callback = TextEditingController();
  TextDrop? Drop;
  bool DropActive = false;
  // Feedback is rendered inside the panel: a SnackBar belongs to the page's
  // Scaffold, so it is hidden behind the login dialog.
  String? Message;
  bool MessageError = false;
  bool Awaiting = false;

  @override
  void initState() {
    super.initState();
    widget.Controller.addListener(FollowAuth);
    if (!PlatformInfo.IOS) return;
    Drop = TextDrop(OnDrop: Accept, OnActive: Highlight);
    unawaited(Drop!.Start());
  }

  @override
  void dispose() {
    widget.Controller.removeListener(FollowAuth);
    unawaited(Drop?.Stop());
    Callback.dispose();
    super.dispose();
  }

  void Highlight(bool Value) {
    if (!mounted || DropActive == Value) return;
    setState(() => DropActive = Value);
  }

  // The callback can arrive through the app link handler, which completes the
  // login without Submit awaiting anything, so success is also detected here.
  void FollowAuth() {
    if (!mounted || !Awaiting) return;
    if (widget.Controller.PendingAuth != null) return;
    Awaiting = false;
    if (widget.OnLogin != null) {
      widget.OnLogin!.call();
      return;
    }
    Notice('Nintendo 登录成功');
  }

  void Notice(String Value, {bool Error = false}) {
    if (!mounted) return;
    setState(() {
      Message = Value;
      MessageError = Error;
    });
  }

  void Accept(String Value) {
    if (!mounted) return;
    if (widget.Controller.PendingAuth == null || widget.Controller.AuthBusy) {
      Notice('请先获取登录链接', Error: true);
      return;
    }
    if (NSOAuthCallback.ParseInput(Value) == null) {
      Notice('未识别 Nintendo 登录回调链接', Error: true);
      return;
    }
    Callback.text = Value;
    Notice('已填入回调链接');
  }

  Future<void> CopyLink() async {
    final Url = widget.Controller.PendingAuth?.Url;
    if (Url == null || Url.isEmpty) {
      Notice('请先获取 Nintendo 登录链接', Error: true);
      return;
    }
    await Clipboard.setData(ClipboardData(text: Url));
    Notice('登录链接已复制');
  }

  Future<void> PasteLink() async {
    final Data = await Clipboard.getData(Clipboard.kTextPlain);
    final Text = Data?.text?.trim() ?? '';
    if (!mounted) return;
    if (Text.isEmpty) {
      Notice('剪贴板中没有可粘贴的链接', Error: true);
      return;
    }
    Callback.text = Text;
    Notice('已填入剪贴板内容');
  }

  Future<void> Submit() async {
    if (widget.Controller.AuthBusy) return;
    final Text = Callback.text.trim();
    if (Text.isEmpty) {
      Notice('请先粘贴 Nintendo 登录回调链接', Error: true);
      return;
    }
    Awaiting = true;
    Notice('正在完成 Nintendo 登录…');
    await widget.Controller.SubmitAuth(Text);
    if (!mounted || !Awaiting) return;
    Awaiting = false;
    if (widget.Controller.PendingAuth == null) {
      Callback.clear();
      widget.OnLogin?.call();
      return;
    }
    Notice(widget.Controller.Notice ?? '登录未完成，请检查回调链接后重试', Error: true);
  }

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    final Busy = widget.Controller.AuthBusy;
    if (!PlatformInfo.Mobile) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        Text('点击下方按钮登录 Nintendo 账号并授权鱿鱼圈 3 数据读取，登录成功后应用才能检测对局结果。每次登录前都会自动清除登录窗口的 cookies。', style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant, Height: 1.6)),
        const SizedBox(height: 16),
        AppButton(Label: Busy ? '正在登录…' : '登录 Nintendo 账号', Enabled: !Busy, OnPressed: () => RequestNSOLogin(context, widget.Controller)),
        if (Busy) const Padding(padding: EdgeInsets.only(top: 12), child: AppLinearProgress(Indeterminate: true)),
      ]);
    }
    final Pending = widget.Controller.PendingAuth;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      Text('1. 点击“获取登录链接”。\n2. 复制链接并在浏览器中打开，完成 Nintendo 登录。\n3. 登录后长按“选择此人”按钮，复制回调 URL。\n4. 将回调 URL 粘贴${PlatformInfo.IOS ? '或拖入' : '到'}下方输入框并点击登录。', style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant, Height: 1.7)),
      const SizedBox(height: 12),
      if (Pending == null)
        AppButton(Label: '获取登录链接', Enabled: !Busy, OnPressed: () => RequestNSOLogin(context, widget.Controller))
      else ...<Widget>[
        AppTextField(Label: 'Nintendo 登录链接', Value: Pending.Url, ReadOnly: true, OnIcon: Icons.copy, OnIconTap: CopyLink),
        Row(children: <Widget>[
          Expanded(child: AppButton(Label: '复制登录链接', Kind: AppButtonKind.Outlined, OnPressed: CopyLink)),
          const SizedBox(width: 12),
          Expanded(child: AppButton(Label: '在浏览器中打开', Kind: AppButtonKind.Outlined, OnPressed: () => widget.Controller.OpenAuth())),
        ]),
        AppButton(Label: '重新获取登录链接', Kind: AppButtonKind.Text, Enabled: !Busy, OnPressed: () => RequestNSOLogin(context, widget.Controller)),
      ],
      if (Busy) const Padding(padding: EdgeInsets.only(top: 8), child: AppLinearProgress(Indeterminate: true)),
      AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: DropActive ? Scheme.primary.withValues(alpha: 0.06) : Colors.transparent,
          border: Border.all(color: DropActive ? Scheme.primary : Colors.transparent, width: 1.5),
          borderRadius: BorderRadius.circular(14),
        ),
        child: AppTextField(
          Label: '回调 URL',
          Controller: Callback,
          Placeholder: PlatformInfo.IOS
              ? (DropActive ? '松开即可填入回调链接' : '长按“选择此人”复制链接后粘贴或拖入这里')
              : '长按“选择此人”复制链接后粘贴到这里',
          Enabled: Pending != null && !Busy,
          OnIcon: Icons.content_paste,
          OnIconTap: PasteLink,
          OnChanged: (_) {
            if (Message != null) setState(() => Message = null);
          },
          OnSubmitted: (_) => Submit(),
        ),
      ),
      if (Message != null) AppHint(Message!, Error: MessageError),
      AppButton(Label: Busy ? '正在登录…' : '登录', Enabled: Pending != null && !Busy, OnPressed: Submit),
      if (Pending == null) const AppHint('当前没有待完成的登录，请先获取登录链接。'),
    ]);
  }
}

Future<void> OpenNSOLogin(BuildContext Context, AppController Controller) async {
  final Ok = await RequestNSOLogin(Context, Controller);
  if (!Ok || !Context.mounted) return;
  final WasPending = Controller.PendingAuth != null;
  await showDialog<void>(
    context: Context,
    builder: (DialogContext) => AppDialog(
      Title: '登录 Nintendo 账号',
      Content: NSOLoginPanel(Controller: Controller, OnLogin: () => Navigator.of(DialogContext).pop()),
      Actions: <Widget>[
        AppButton(Label: '关闭', Kind: AppButtonKind.Text, OnPressed: () => Navigator.of(DialogContext).pop()),
      ],
    ),
  );
  // The dialog closes as soon as the login completes; confirm it on the page,
  // where the SnackBar is no longer hidden by the dialog route.
  if (WasPending && Controller.PendingAuth == null && Context.mounted) {
    AppSnack.Show(Context, 'Nintendo 登录成功');
  }
}
