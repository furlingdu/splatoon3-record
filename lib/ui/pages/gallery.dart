import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../config/system.dart';
import '../../domain/models.dart';
import '../../format/formats.dart';
import '../theme.dart';
import '../controls.dart';
import '../shell.dart';
import '../video.dart';

class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key, required this.Controller});

  final AppController Controller;

  @override
  State<GalleryPage> createState() => GalleryPageState();
}

class GalleryPageState extends State<GalleryPage> {
  String Kind = 'all';
  bool HideUnrecorded = true;
  final Set<String> Picked = <String>{};

  @override
  Widget build(BuildContext context) {
    final All = widget.Controller.Matches.toList();
    final Kinds = <String>{'all', ...All.map((Item) => Item.Kind)}.toList();
    final Visible = All.where((Item) => (Kind == 'all' || Item.Kind == Kind) && (!HideUnrecorded || Item.HasVideo)).toList();
    final PickedList = Visible.where((Item) => Picked.contains(Item.Key) && Item.HasVideo).toList();
    return PageBody(
      Children: <Widget>[
        const AppPageTitle('相册'),
        Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 200,
              child: AppSelect<String>(
                Label: '比赛类型',
                Value: Kind,
                Items: Kinds,
                Display: (Value) => Value == 'all' ? '全部类型' : Formats.Kind(Value),
                OnChanged: (Value) => setState(() => Kind = Value),
              ),
            ),
            Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
              Checkbox(value: HideUnrecorded, onChanged: (Value) => setState(() => HideUnrecorded = Value ?? true)),
              const Text('不显示未录制对局'),
            ]),
            AppButton(Label: '刷新', Kind: AppButtonKind.Text, OnPressed: () => widget.Controller.RefreshMatches()),
            if (Picked.isNotEmpty)
              AppButton(
                Label: '清空选择',
                Kind: AppButtonKind.Text,
                OnPressed: () => setState(() => Picked.clear()),
              ),
            if (PlatformInfo.Desktop)
              AppButton(
                Label: PickedList.isEmpty ? '批量打码' : '批量打码 ${PickedList.length}',
                Kind: AppButtonKind.Tonal,
                Enabled: PickedList.isNotEmpty,
                OnPressed: () => BlurBatch(PickedList),
              ),
            AppButton(
              Label: PickedList.isEmpty ? '批量删除' : '批量删除 ${PickedList.length}',
              Kind: AppButtonKind.Tonal,
              Enabled: PickedList.isNotEmpty,
              OnPressed: () => DeleteBatch(PickedList),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (Visible.isEmpty)
          const AppEmpty('暂无对局录像')
        else
          LayoutBuilder(builder: (Context, Constraints) {
            final Count = (Constraints.maxWidth / 245).floor().clamp(1, 6);
            return Column(
              children: <Widget>[
                for (var Index = 0; Index < Visible.length; Index += Count)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      for (var Slot = 0; Slot < Count; Slot++)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(right: Slot == Count - 1 ? 0 : 16, bottom: 16),
                            child: Index + Slot < Visible.length ? CardView(Visible[Index + Slot]) : const SizedBox.shrink(),
                          ),
                        ),
                    ],
                  ),
              ],
            );
          }),
      ],
    );
  }

  Widget CardView(BattleMatch Match) {
    final Scheme = Theme.of(context).colorScheme;
    final Thumb = '${widget.Controller.Directories.Thumbs}${Platform.pathSeparator}${widget.Controller.Archive.SafeName(Match.Key)}.jpg';
    final Win = RegExp('WIN', caseSensitive: false).hasMatch(Match.Result);
    final Highlight = Match.Kind == 'highlight';
    final Badge = Highlight ? '高亮' : Match.IsDisconnected ? '掉线' : Formats.Result(Match.Result);
    final BadgeColor = Highlight ? const Color(0xd94285f4) : Match.IsDisconnected || !Win ? const Color(0xd9c84a4a) : const Color(0xd930a557);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Open(Match),
      child: Container(
        decoration: BoxDecoration(color: Scheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Container(color: Colors.black),
                  if (Thumb.isNotEmpty && File(Thumb).existsSync())
                    Image.file(File(Thumb), fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink())
                  else
                    Center(child: Icon(Icons.movie, size: 40, color: Scheme.onSurfaceVariant)),
                  if (Match.HasVideo)
                    Positioned(
                      right: 4,
                      top: 4,
                      child: Checkbox(
                        value: Picked.contains(Match.Key),
                        onChanged: (Value) => setState(() => Value == true ? Picked.add(Match.Key) : Picked.remove(Match.Key)),
                      ),
                    ),
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
                      decoration: BoxDecoration(color: BadgeColor, borderRadius: BorderRadius.circular(1000)),
                      child: Text(Badge, style: AppTheme.Style(Size: 12, ColorValue: Colors.white)),
                    ),
                  ),
                  if (Match.Duration > 0)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                        child: Text(Formats.Duration(Match.Duration), style: AppTheme.Style(Size: 12, ColorValue: Colors.white)),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(Formats.Kind(Match.Kind), style: AppTheme.Style(Size: 14, Weight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    '${Match.AccountNickname == null ? '' : '${Match.AccountNickname} · '}${Formats.Rule(Match.Rule)} · ${Formats.ShortDateTime(Match.EndAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.Style(Size: 12, ColorValue: Scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> Open(BattleMatch Match) async {
    if (!Match.HasVideo) {
      AppSnack.Show(context, '此对局未录制或录像文件不存在');
      return;
    }
    await ShowVideoDialog(context, Match.VideoPath!, Match.Kind, Match.EndAt);
  }

  Future<void> DeleteBatch(List<BattleMatch> Matches) async {
    var WithBlur = false;
    final Ok = await showDialog<bool>(
      context: context,
      builder: (Context) => StatefulBuilder(builder: (Context, SetLocal) {
        return AppDialog(
          Title: '删除录像',
          Description: '将同时删除归档视频与比赛记录，确定删除？',
          Content: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
            Checkbox(value: WithBlur, onChanged: (Value) => SetLocal(() => WithBlur = Value ?? false)),
            const Text('同时删除打码副本'),
          ]),
          Actions: <Widget>[
            AppButton(Label: '取消', Kind: AppButtonKind.Text, OnPressed: () => Navigator.of(Context).pop(false)),
            AppButton(Label: '删除', OnPressed: () => Navigator.of(Context).pop(true)),
          ],
        );
      }),
    );
    if (Ok != true) return;
    for (final Match in Matches) {
      await widget.Controller.DeleteMatch(Match, WithBlur);
    }
    if (!mounted) return;
    Picked.clear();
    setState(() {});
  }

  Future<void> BlurBatch(List<BattleMatch> Matches) async {
    var Done = 0;
    for (final Match in Matches) {
      if (await widget.Controller.BlurMatch(Match)) Done++;
    }
    if (!mounted) return;
    AppSnack.Show(context, Done == 0 ? '昵称打码失败，请检查模型与采集画面' : '已完成 $Done 个对局的昵称打码');
    setState(() {});
  }
}












