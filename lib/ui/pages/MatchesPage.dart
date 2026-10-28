import 'package:flutter/material.dart';

import '../../app/AppController.dart';
import '../../domain/Models.dart';
import '../../format/Formats.dart';
import '../AppTheme.dart';
import '../Controls.dart';
import '../Shell.dart';
import '../VideoActions.dart';
import '../VideoDialog.dart';

class MatchesPage extends StatefulWidget {
  const MatchesPage({super.key, required this.Controller});

  final AppController Controller;

  @override
  State<MatchesPage> createState() => MatchesPageState();
}

class MatchesPageState extends State<MatchesPage> {

  @override
  Widget build(BuildContext context) {
    final Matches = widget.Controller.Matches;
    return PageBody(
      Children: <Widget>[
        const AppPageTitle('对局'),
        StatGrid(Matches),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(children: <Widget>[
            AppButton(Label: '刷新', Kind: AppButtonKind.Text, OnPressed: () => widget.Controller.RefreshMatches()),
          ]),
        ),
        if (Matches.isEmpty)
          const AppEmpty('暂无对局记录')
        else
          ...Matches.map((Match) => MatchRow(
                Match: Match,
                OnPlay: () => Play(Match),
                OnOpen: Match.HasVideo ? () => widget.Controller.OpenPath(Match.VideoPath!) : null,
                OnSave: Match.HasVideo ? () => widget.Controller.SaveMatchVideo(Match) : null,
                OnSaveToGallery: Match.HasVideo ? () => SaveToGallery(context, Match.VideoPath!) : null,
                OnShare: Match.HasVideo ? () => ShareVideo(context, Match.VideoPath!, Formats.MatchTitle(Match.Kind, Match.EndAt)) : null,
              )),
      ],
    );
  }

  Future<void> Play(BattleMatch Match) async {
    if (!Match.HasVideo) {
      AppSnack.Show(context, '录像文件不存在');
      return;
    }
    await ShowVideoDialog(context, Match.VideoPath!, Match.Kind, Match.EndAt);
  }

}

class StatGrid extends StatelessWidget {
  const StatGrid(this.Matches, {super.key});

  final List<BattleMatch> Matches;

  @override
  Widget build(BuildContext context) {
    final Rows = <List<String>>[
      <String>['涂地', 'turf', 'regular'],
      <String>['真格', 'anarchy', 'anarchyOpen,anarchySeries'],
      <String>['私人比赛', 'private', 'private'],
      <String>['活动比赛', 'event', 'event'],
      <String>['X比赛', 'x', 'xBattle'],
    ];
    return LayoutBuilder(builder: (Context, Constraints) {
      final Count = (Constraints.maxWidth / 200).floor().clamp(1, 5);
      return Column(
        children: <Widget>[
          for (var Index = 0; Index < Rows.length; Index += Count)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (var Slot = 0; Slot < Count; Slot++)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: Slot == Count - 1 ? 0 : 12, bottom: 12),
                      child: Index + Slot < Rows.length ? StatCard(Rows[Index + Slot], Matches) : const SizedBox.shrink(),
                    ),
                  ),
              ],
            ),
        ],
      );
    });
  }
}

class StatCard extends StatelessWidget {
  const StatCard(this.Row, this.Matches, {super.key});

  final List<String> Row;
  final List<BattleMatch> Matches;

  @override
  Widget build(BuildContext context) {
    final Kinds = Row[2].split(',');
    final List = Matches.where((Item) => Kinds.contains(Item.Kind)).toList();
    var Win = 0;
    var Lose = 0;
    var Kill = 0;
    var Death = 0;
    var Special = 0;
    var Paint = 0;
    for (final Match in List) {
      if (RegExp('WIN', caseSensitive: false).hasMatch(Match.Result)) Win++;
      if (RegExp('LOSE|DEEMED_LOSE|EXEMPTED_LOSE', caseSensitive: false).hasMatch(Match.Result)) Lose++;
      final Stats = Personal(Match);
      Kill += Stats.$1;
      Death += Stats.$2;
      Special += Stats.$3;
      Paint += Stats.$4;
    }
    final Scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(border: Border.all(color: Scheme.outlineVariant), borderRadius: BorderRadius.circular(14)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text(Row[0], style: AppTheme.Style(Size: 15, Weight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('${List.length} 局', style: AppTheme.Style(Size: 16, Weight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('胜 $Win · 负 $Lose', style: AppTheme.Style(Size: 12, ColorValue: Scheme.onSurfaceVariant)),
        Text('个人 K/D ${Death == 0 ? '-' : (Kill / Death).toStringAsFixed(2)}', style: AppTheme.Style(Size: 12, ColorValue: Scheme.onSurfaceVariant)),
        Text('大招 $Special · 涂地 ${Paint}p', style: AppTheme.Style(Size: 12, ColorValue: Scheme.onSurfaceVariant)),
      ]),
    );
  }

  (int, int, int, int) Personal(BattleMatch Match) {
    final Raw = Match.Raw;
    final Data = Raw['rawData'] is Map ? Raw['rawData'] as Map : Raw;
    final Root = Data['data'] is Map ? Data['data'] as Map : Data;
    final Detail = Root['vsHistoryDetail'] is Map ? Root['vsHistoryDetail'] as Map : Root['coopHistoryDetail'] is Map ? Root['coopHistoryDetail'] as Map : Root;
    final MyTeam = Detail['myTeam'] is Map ? Detail['myTeam'] as Map : null;
    final Players = MyTeam?['players'] is List ? MyTeam!['players'] as List : const <dynamic>[];
    for (final Player in Players) {
      if (Player is! Map || Player['isMyself'] != true) continue;
      final Result = Player['result'] is Map ? Player['result'] as Map : const <String, dynamic>{};
      final KillOrAssist = (Result['kill'] as num?)?.toInt() ?? 0;
      final Assist = (Result['assist'] as num?)?.toInt() ?? 0;
      return (
        (KillOrAssist - Assist).clamp(0, 1 << 31),
        (Result['death'] as num?)?.toInt() ?? 0,
        (Result['special'] as num?)?.toInt() ?? 0,
        (Player['paint'] as num?)?.toInt() ?? 0,
      );
    }
    final Coop = Detail['myResult'] is Map ? Detail['myResult'] as Map : const <String, dynamic>{};
    final CoopPlayer = Coop['player'] is Map ? Coop['player'] as Map : const <String, dynamic>{};
    return ((Coop['defeatEnemyCount'] as num?)?.toInt() ?? 0, 0, 0, (CoopPlayer['paint'] as num?)?.toInt() ?? 0);
  }
}

class MatchRowWidget extends StatelessWidget {
  const MatchRowWidget({super.key, required this.Match, required this.OnPlay, required this.Controller});

  final BattleMatch Match;
  final VoidCallback OnPlay;
  final AppController Controller;

  @override
  Widget build(BuildContext context) => MatchRow(Match: Match, OnPlay: OnPlay);

  String Title(BattleMatch Item) {
    final Kind = Formats.Kind(Item.Kind);
    final Rule = Formats.Rule(Item.Rule);
    return Kind == Rule ? Kind : '$Kind · $Rule';
  }
}













