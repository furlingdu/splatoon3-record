import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/controller.dart';
import '../../config/system.dart';
import '../../domain/models.dart';
import '../../format/formats.dart';
import '../theme.dart';
import '../controls.dart';
import '../nsoLogin.dart';
import '../shell.dart';

class BindingPage extends StatelessWidget {
  const BindingPage({super.key, required this.Controller});

  final AppController Controller;

  @override
  Widget build(BuildContext context) {
    final Status = Controller.Status;
    final Scheme = Theme.of(context).colorScheme;
    final Accounts = Status?.NSOAccounts ?? <NSOAccount>[];
    return PageBody(
      Children: <Widget>[
        const AppPageTitle('绑定'),
        const AppSectionTitle('Nintendo Switch Online'),
        const NSONotice(),
        const SizedBox(height: 16),
        StatusGrid(
          Children: <Widget>[
            AppStatusItem(Label: '当前 NSO 账户', Value: AppStatusText(Status?.NSOCurrentNickname ?? '未选择')),
            AppStatusItem(Label: '已绑定账户', Value: AppStatusText('${Accounts.length} / 5')),
            AppStatusItem(Label: 'NSO 状态', Value: AppStatusText(Formats.BindingState(Status?.NSOState ?? 'unbound'))),
          ],
        ),
        if (Status?.NSOError != null && Status?.NSOState != 'unbound')
          Text('失败原因：${Status!.NSOError}', style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant)),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: <Widget>[
              AppButton(Label: '添加 Nintendo 账号', Enabled: Accounts.length < 5, OnPressed: () => PlatformInfo.Mobile ? OpenNSOLogin(context, Controller) : Controller.StartNSOLogin()),
            ],
          ),
        ),
        if (Accounts.isEmpty)
          const AppEmpty('尚未绑定 NSO 账户')
        else
          ...Accounts.map((Account) => Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: Account.State == 'connected' ? Scheme.primary : Scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: LayoutBuilder(builder: (Context, Constraints) {
                  final Info = Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    Row(children: <Widget>[
                      Flexible(child: Text(Account.Nickname, style: AppTheme.Style(Size: 15, Weight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                      if (Account.Id == Status?.NSOCurrentId)
                        Container(
                          margin: const EdgeInsets.only(left: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                          decoration: BoxDecoration(color: Scheme.primaryContainer, borderRadius: BorderRadius.circular(8)),
                          child: Text('当前', style: AppTheme.Style(Size: 12, ColorValue: Scheme.onPrimaryContainer)),
                        ),
                    ]),
                    Text(
                      '${Formats.BindingState(Account.State)}${Account.LastMatchAt == null ? '' : ' · 最近对局 ${Formats.DateTimeText(Account.LastMatchAt!)}'}',
                      style: AppTheme.Style(Size: 12, ColorValue: Scheme.onSurfaceVariant),
                    ),
                    if (Account.Error != null) Text(Account.Error!, style: AppTheme.Style(Size: 12, ColorValue: Scheme.error)),
                  ]);
                  final Actions = Wrap(spacing: 2, children: <Widget>[
                    AppButton(Label: '设为当前', Kind: AppButtonKind.Text, Enabled: Account.Id != Status?.NSOCurrentId, OnPressed: () => Controller.SelectNSOAccount(Account.Id)),
                    AppButton(Label: '重新登录', Kind: AppButtonKind.Text, OnPressed: () => PlatformInfo.Mobile ? OpenNSOLogin(context, Controller) : Controller.StartNSOLogin(Account.Id)),
                    AppButton(Label: '删除', Kind: AppButtonKind.Text, Enabled: Accounts.length > 1, OnPressed: () => RemoveAccount(context, Account.Id)),
                  ]);
                  if (Constraints.maxWidth < 560) {
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[Info, const SizedBox(height: 6), Actions]);
                  }
                  return Row(children: <Widget>[
                    Expanded(child: Info),
                    Actions,
                  ]);
                }),
              )),
        const SizedBox(height: 8),
        Text('至少需要保留一个 NSO 账户。', style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant)),
        const AppSectionTitle('QQBot'),
        Text(
          '请点击下方按钮获取机器人绑定二维码，并跟随指引创建机器人。当你创建完毕后，请在私聊窗口中发送/bind以绑定用户。',
          style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant, Height: 1.6),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Wrap(spacing: 12, runSpacing: 8, children: <Widget>[
            AppButton(Label: '获取绑定机器人二维码', Enabled: Status?.QQState != 'connecting' && Status?.QQState != 'connected', OnPressed: () => Controller.StartQQLogin()),
            AppButton(Label: '解除 QQBot 绑定', Kind: AppButtonKind.Outlined, Enabled: Status?.QQState != 'unbound', OnPressed: () => Controller.UnbindQQ()),
          ]),
        ),
        StatusGrid(
          Children: <Widget>[
            AppStatusItem(Label: 'QQBot 状态', Value: AppStatusText(Formats.BindingState(Status?.QQState ?? 'unbound'))),
            AppStatusItem(Label: '推送用户', Value: AppStatusText(Status?.QQOwner != null ? '已绑定' : '未通过 /bind 绑定')),
          ],
        ),
        if (Status?.QrCode != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(children: <Widget>[
              QrView(Data: Status!.QrCode!),
              const SizedBox(height: 10),
              Text('请使用创建机器人的 QQ 扫描该二维码完成授权', style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant)),
            ]),
          ),
      ],
    );
  }

  Future<void> RemoveAccount(BuildContext Context, String Id) async {
    final Ok = await showDialog<bool>(
      context: Context,
      builder: (Context) => AppDialog(
        Title: '删除 NSO 账户',
        Description: '将移除该账户的登录凭证。历史录像和归档不会被删除。',
        Content: const SizedBox.shrink(),
        Actions: <Widget>[
          AppButton(Label: '取消', Kind: AppButtonKind.Text, OnPressed: () => Navigator.of(Context).pop(false)),
          AppButton(Label: '删除', OnPressed: () => Navigator.of(Context).pop(true)),
        ],
      ),
    );
    if (Ok == true) await Controller.DeleteNSOAccount(Id);
  }
}

class NSONotice extends StatelessWidget {
  const NSONotice({super.key});

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant, Height: 1.6),
        children: <InlineSpan>[
          const TextSpan(text: '为获取到您的Nintendo Switch Online数据，程序将要求登录您的Nintendo账户。由于Nintendo限制，在登录过程中会涉及到使用第三方Nintendo Switch Online Api以实现加密包体获取，你的 Nintendo 账号 id_token 将被发送到第三方 API（'),
          WidgetSpan(
            child: InkWell(
              onTap: () => ControllerOpen(context),
              child: Text('nxapi-znca-api', style: AppTheme.Style(Size: 14, ColorValue: Scheme.primary).copyWith(decoration: TextDecoration.underline)),
            ),
          ),
          const TextSpan(text: '）用于完成令牌校验。\n请注意，由于涉及到了第三方Api进行操作，该操作可能存在部分风险或稳定性较差，开发者不对账户安全性进行保证。但请放心，id_token并不会泄露您的账户。您的Nintendo Switch Online账户数据将会被加密保存至本地。'),
        ],
      ),
    );
  }

  Future<void> ControllerOpen(BuildContext Context) async {
    await launchUrl(Uri.parse('https://github.com/samuelthomas2774/nxapi-znca-api'), mode: LaunchMode.externalApplication);
  }
}











