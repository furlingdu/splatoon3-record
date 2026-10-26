import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splatoon3record/domain/Models.dart';
import 'package:splatoon3record/ui/AppTheme.dart';
import 'package:splatoon3record/ui/Controls.dart';
import 'package:splatoon3record/ui/Shell.dart';

void main() {
  testWidgets('Controls render with the Splatoon theme', (WidgetTester Tester) async {
    await Tester.pumpWidget(MaterialApp(
      theme: AppTheme.Build('#4285f4'),
      home: Material(
        child: Column(children: <Widget>[
          AppButton(Label: '开始录制', OnPressed: () {}),
          AppButton(Label: '停止录制', Kind: AppButtonKind.Outlined, OnPressed: () {}),
          AppStatusItem(Label: '采集方式', Value: const AppStatusText('软件内捕获')),
          AppFormSwitch(Label: '开机自启动', Note: '开机后自动运行', Value: true, OnChanged: (_) {}),
          const AppLinearProgress(Value: 0.5),
          AppButton(Label: '禁用', Enabled: false, OnPressed: () {}),
        ]),
      ),
    ));
    expect(find.text('开始录制'), findsOneWidget);
    expect(find.text('停止录制'), findsOneWidget);
    expect(find.text('采集方式'), findsOneWidget);
    expect(find.text('软件内捕获'), findsOneWidget);
    expect(find.text('开机后自动运行'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(Tester.getSize(find.byType(AppButton).first).height, 40);
  });

  testWidgets('Match row centers actions and hides archive repair', (WidgetTester Tester) async {
    final Match = BattleMatch.FromMap(<String, dynamic>{
      'matchId': 'm1',
      'kind': 'regular',
      'mode': 'nawabari',
      'rule': 'TURF_WAR',
      'startAt': 0,
      'endAt': 10000,
      'duration': 10000,
      'result': 'WIN',
      'rawData': <String, dynamic>{},
    });
    await Tester.pumpWidget(MaterialApp(
      theme: AppTheme.Build('#4285f4'),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 900, child: MatchRow(Match: Match, OnPlay: () {})),
        ),
      ),
    ));
    expect(find.text('补归档'), findsNothing);
    final ActionCenter = Tester.getCenter(find.widgetWithText(AppButton, '播放录像')).dy;
    final WrapCenter = Tester.getCenter(find.byType(Wrap)).dy;
    expect((ActionCenter - WrapCenter).abs(), lessThan(0.5));
  });
}







