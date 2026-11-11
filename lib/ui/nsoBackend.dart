import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../nso/backend.dart';
import 'controls.dart';
import 'theme.dart';

class NSOBackendBar extends StatelessWidget {
  const NSOBackendBar({super.key, required this.Controller});

  final AppController Controller;

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    final Value = Controller.NSOBackend;
    final Busy = Controller.NSOBackendBusy || Value == null;
    final Online = Value?.Online ?? false;
    final Tone = Busy
        ? Scheme.onSurfaceVariant
        : Online
        ? Scheme.primary
        : Scheme.error;
    final Version = Value?.Version;
    final Latency = Value?.LatencyMs ?? 0;
    final Error = Value?.Error;
    final Message = Busy
        ? '正在检测 znca 校验服务…'
        : Online
        ? 'znca 校验服务可用${Version == null ? '' : ' · NSO $Version'}${Latency > 0 ? ' · ${_Latency(Latency)}' : ''}'
        : 'znca 校验服务不可用${Error == null ? '' : '：$Error'}';
    final Url = Value == null ? '' : _DisplayUrl(Value.Url);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        border: Border.all(
          color: Online
              ? Scheme.primary.withValues(alpha: 0.45)
              : Scheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: LayoutBuilder(
        builder: (Context, Constraints) {
          final Wide = Constraints.maxWidth >= 560;
          return Row(
            children: <Widget>[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(shape: BoxShape.circle, color: Tone),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  Message,
                  style: AppTheme.Style(
                    Size: 13,
                    ColorValue: Tone,
                    Height: 1.45,
                  ),
                ),
              ),
              if (Wide && Url.isNotEmpty) ...<Widget>[
                const SizedBox(width: 12),
                Text(
                  Url,
                  style: AppTheme.Style(
                    Size: 12,
                    ColorValue: Scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(width: 8),
              AppButton(
                Label: '重新检测',
                Kind: AppButtonKind.Text,
                Enabled: !Busy,
                OnPressed: () {
                  Controller.CheckNSOBackend();
                },
              ),
            ],
          );
        },
      ),
    );
  }

  String _Latency(int Milliseconds) => Milliseconds >= 1000
      ? '${(Milliseconds / 1000).toStringAsFixed(1)}s'
      : '${Milliseconds}ms';

  String _DisplayUrl(String Url) {
    final Parsed = Uri.tryParse(Url);
    if (Parsed == null || Parsed.host.isEmpty) return Url;
    final Path = Parsed.path.replaceAll(RegExp(r'/+$'), '');
    return '${Parsed.host}$Path';
  }
}

Future<bool> ConfirmNSOBackend(
  BuildContext Context,
  NSOBackendStatus Status,
) async {
  final Proceed = await showDialog<bool>(
    context: Context,
    builder: (Context) => AppDialog(
      Title: 'znca 校验服务不可用',
      Description: Status.Error == null
          ? '仍要登录 Nintendo 账号吗？'
          : '检测失败：${Status.Error}。仍要登录 Nintendo 账号吗？',
      Content: const SizedBox.shrink(),
      Actions: <Widget>[
        AppButton(
          Label: '取消',
          Kind: AppButtonKind.Text,
          OnPressed: () => Navigator.of(Context).pop(false),
        ),
        AppButton(
          Label: '仍然登录',
          OnPressed: () => Navigator.of(Context).pop(true),
        ),
      ],
    ),
  );
  return Proceed == true;
}

Future<bool> RequestNSOLogin(
  BuildContext Context,
  AppController Controller, [
  String? AccountId,
]) async {
  await Controller.StartNSOLogin(AccountId);
  if (!Context.mounted) return false;
  if (!Controller.NSOBackendBlocked) return true;
  final Status =
      Controller.NSOBackend ??
      NSOBackendStatus(
        Url: Controller.NSO.Servers.first,
        State: NSOBackendState.Offline,
      );
  final Proceed = await ConfirmNSOBackend(Context, Status);
  if (!Context.mounted) return false;
  if (!Proceed) {
    Controller.CancelNSOBackendBlock();
    return false;
  }
  await Controller.StartNSOLogin(AccountId, true);
  return Context.mounted;
}
