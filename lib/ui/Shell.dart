import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../app/AppController.dart';
import '../config/Config.dart';
import '../domain/Models.dart';
import '../format/Formats.dart';
import '../match/Stats.dart';
import 'AppMotion.dart';
import 'AppTheme.dart';
import 'Controls.dart';
import 'pages/AboutPage.dart';
import 'pages/BindingPage.dart';
import 'pages/GalleryPage.dart';
import 'pages/LivePage.dart';
import 'pages/MatchesPage.dart';
import 'pages/SettingsPage.dart';
import 'pages/SetupPage.dart';
import 'pages/StatusPage.dart';
import 'pages/UpdatePage.dart';

class AppRoot extends StatefulWidget {
  const AppRoot({super.key, required this.Controller});

  final AppController Controller;

  @override
  State<AppRoot> createState() => AppRootState();
}

class AppRootState extends State<AppRoot> {
  final GlobalKey<ScaffoldMessengerState> MessengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    widget.Controller.addListener(OnChanged);
    widget.Controller.Boot();
  }

  String? _LastNotice;

  void OnChanged() {
    if (!mounted) return;
    setState(() {});
    final Notice = widget.Controller.Notice;
    if (Notice != null && Notice != _LastNotice) {
      _LastNotice = Notice;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        MessengerKey.currentState?.showSnackBar(SnackBar(content: Text(Notice)));
        widget.Controller.ClearNotice();
      });
    }
  }

  @override
  void dispose() {
    widget.Controller.removeListener(OnChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Controller = widget.Controller;
    final ThemeColor = Controller.Ready ? Controller.SettingsValue.ThemeColor : '#4285f4';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Splatoon3 Record',
      scaffoldMessengerKey: MessengerKey,
      theme: AppTheme.Build(ThemeColor),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(
        body: Controller.Ready
            ? (Controller.SettingsValue.CaptureMode == 'internal' ? ShellView(Controller: Controller) : ShellView(Controller: Controller))
            : BootView(Controller: Controller),
      ),
    );
  }
}

class BootView extends StatelessWidget {
  const BootView({super.key, required this.Controller});

  final AppController Controller;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xff1b1b1f),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const BackgroundLayer(),
          Center(
            child: Image.asset(Config.AppIconPath, width: 132, height: 132),
          ),
        ],
      ),
    );
  }
}

class ShellView extends StatefulWidget {
  const ShellView({super.key, required this.Controller});

  final AppController Controller;

  @override
  State<ShellView> createState() => ShellViewState();
}

class ShellViewState extends State<ShellView> {
  bool DrawerOpen = true;
  bool? LastWide;
  bool ShowTop = false;
  final ScrollController Scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    if (widget.Controller.Page == 'setup') {
      WidgetsBinding.instance.addPostFrameCallback((_) => _SetupWindow());
    }
  }

  Future<void> _SetupWindow() async {}

  @override
  Widget build(BuildContext context) {
    final Controller = widget.Controller;
    if (!Controller.CurrentConfig.SetupDone) {
      return SetupPage(Controller: Controller);
    }
    return LayoutBuilder(
      builder: (Context, Constraints) {
        final Wide = Constraints.maxWidth >= 840;
        if (LastWide != Wide) {
          LastWide = Wide;
          DrawerOpen = Wide;
        }
        final Page = Controller.Page;
        return Material(
          color: Colors.transparent,
          child: Stack(
            children: <Widget>[
            Positioned.fill(child: BackgroundLayer(Path: Controller.SettingsValue.BackgroundPath, Dim: Controller.SettingsValue.BackgroundDim)),
            if (Controller.SettingsValue.BackgroundPath.isEmpty)
              Positioned(
                right: 0,
                bottom: 0,
                width: (MediaQuery.sizeOf(context).width * 0.34).clamp(280, 560).toDouble(),
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 0.5,
                    child: Image.asset(Config.CharacterPath, fit: BoxFit.contain),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 64,
              child: TopBar(
                OnMenu: () => setState(() => DrawerOpen = !DrawerOpen),
              ),
            ),
            if (Wide)
              AnimatedPositioned(
                duration: AppMotion.DrawerDuration,
                curve: AppMotion.DrawerCurve,
                left: DrawerOpen ? 0 : -360,
                top: 64,
                bottom: 0,
                width: 360,
                child: DrawerPanel(
                  Page: Page,
                  Controller: Controller,
                  OnSelect: (Value) {
                    Controller.Navigate(Value);
                    WidgetsBinding.instance.addPostFrameCallback((_) => Scroll.jumpTo(0));
                    if (ShowTop) setState(() => ShowTop = false);
                    if (!Wide) setState(() => DrawerOpen = false);
                  },
                ),
              ),
            AnimatedPositioned(
              duration: AppMotion.DrawerDuration,
              curve: AppMotion.DrawerCurve,
              left: Wide && DrawerOpen ? 360 : 0,
              right: 0,
              top: 64,
              bottom: 0,
              child: NotificationListener<ScrollNotification>(
                onNotification: (Notification) {
                  final Next = Notification.metrics.pixels > 240;
                  if (Next != ShowTop) setState(() => ShowTop = Next);
                  return false;
                },
                child: Scrollbar(
                  controller: Scroll,
                  thumbVisibility: false,
                  child: SingleChildScrollView(
                    controller: Scroll,
                    child: TweenAnimationBuilder<double>(
                      key: ValueKey<String>(Page),
                      tween: Tween<double>(begin: 0.0, end: 1.0),
                      duration: AppMotion.PageDuration,
                      curve: AppMotion.PageCurve,
                      builder: (Context, Value, Child) => Opacity(
                        opacity: Value,
                        child: Transform.translate(offset: Offset(0, AppMotion.PageOffset * (1 - Value)), child: Child),
                      ),
                      child: RepaintBoundary(child: BuildPage(Page, Controller)),
                    ),
                  ),
                ),
              ),
            ),
            if (Page == 'matches' && ShowTop)
              Positioned(
                right: 24,
                bottom: 24,
                child: FloatingActionButton.small(
                  onPressed: () => Scroll.animateTo(0, duration: AppMotion.PageDuration, curve: AppMotion.PageCurve),
                  child: const Icon(Icons.arrow_upward),
                ),
              ),
            if (!Wide && DrawerOpen)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => setState(() => DrawerOpen = false),
                  child: Container(color: Colors.black54),
                ),
              ),
            if (!Wide)
              AnimatedPositioned(
                duration: AppMotion.DrawerDuration,
                curve: AppMotion.DrawerCurve,
                left: DrawerOpen ? 0 : -360,
                top: 64,
                bottom: 0,
                width: 360,
                child: DrawerPanel(
                  Page: Page,
                  Controller: Controller,
                  OnSelect: (Value) {
                    Controller.Navigate(Value);
                    setState(() => DrawerOpen = false);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget BuildPage(String Page, AppController Controller) {
    switch (Page) {
      case 'binding':
        return BindingPage(Controller: Controller);
      case 'matches':
        return MatchesPage(Controller: Controller);
      case 'gallery':
        return GalleryPage(Controller: Controller);
      case 'live':
        return LivePage(Controller: Controller);
      case 'settings':
        return SettingsPage(Controller: Controller);
      case 'update':
        return UpdatePage(Controller: Controller);
      case 'about':
        return AboutPage(Controller: Controller);
      case 'setup':
        return SetupPage(Controller: Controller);
      default:
        return StatusPage(Controller: Controller);
    }
  }
}

class TopBar extends StatelessWidget {
  const TopBar({super.key, required this.OnMenu});

  final VoidCallback OnMenu;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0x9917161d),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: <Widget>[
          Tooltip(
            message: '打开/关闭菜单',
            child: InkWell(
              onTap: OnMenu,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Image.asset(Config.AppIconPath, width: 28, height: 28),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text('Splatoon3 Record', style: AppTheme.Style(Size: 17, Weight: FontWeight.w600)),
          const Spacer(),
        ],
      ),
    );
  }
}

class DrawerPanel extends StatelessWidget {
  const DrawerPanel({super.key, required this.Page, required this.Controller, required this.OnSelect});

  final String Page;
  final AppController Controller;
  final ValueChanged<String> OnSelect;

  static const List<List<String>> Items = <List<String>>[
    <String>['status', '状态', 'monitor'],
    <String>['binding', '绑定', 'link'],
    <String>['matches', '对局', 'videocam'],
    <String>['gallery', '相册', 'movie'],
    <String>['live', '直播', 'cast'],
    <String>['settings', '设置', 'settings'],
    <String>['update', '更新', 'update'],
    <String>['about', '关于', 'info'],
  ];

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    return Container(
      color: const Color(0x8017161d),
      padding: const EdgeInsets.only(top: 8),
      child: ListView.builder(
        itemCount: Items.length,
        itemBuilder: (Context, Index) {
          final Item = Items[Index];
          final Active = Item[0] == Page;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Material(
              color: Active ? Scheme.secondaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(28),
              child: InkWell(
                borderRadius: BorderRadius.circular(28),
                onTap: () => OnSelect(Item[0]),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(
                    children: <Widget>[
                      Icon(IconFor(Item[2]), color: Active ? Scheme.onSecondaryContainer : Scheme.onSurfaceVariant),
                      const SizedBox(width: 16),
                      Text(Item[1], style: AppTheme.Style(Size: 16, ColorValue: Active ? Scheme.onSecondaryContainer : Scheme.onSurface)),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class BackgroundLayer extends StatelessWidget {
  const BackgroundLayer({super.key, this.Path = '', this.Dim = 40});

  final String Path;
  final int Dim;

  @override
  Widget build(BuildContext context) {
    final Alpha = (Dim / 100).clamp(0.0, 1.0).toDouble();
    if (Path.isNotEmpty && File(Path).existsSync()) {
      return Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Image.file(File(Path), fit: BoxFit.cover, errorBuilder: (_, __, ___) => Image.asset(Config.BackgroundPath, fit: BoxFit.cover)),
          Container(color: Colors.black.withValues(alpha: Alpha)),
        ],
      );
    }
    return Container(
      color: const Color(0xff1b1b1f),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Image.asset(Config.BackgroundPath, fit: BoxFit.none, repeat: ImageRepeat.repeat),
          Container(color: Colors.black.withValues(alpha: Alpha)),
        ],
      ),
    );
  }
}


class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.Children});

  final List<Widget> Children;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1120),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 48),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: Children),
        ),
      ),
    );
  }
}

class MatchRow extends StatelessWidget {
  const MatchRow({super.key, required this.Match, this.OnPlay, this.OnOpen, this.OnSave});

  final BattleMatch Match;
  final VoidCallback? OnPlay;
  final VoidCallback? OnOpen;
  final VoidCallback? OnSave;

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    final String Kind = Formats.Kind(Match.Kind);
    final String Rule = Formats.Rule(Match.Rule);
    final String Title = Kind == Rule ? Kind : '$Kind · $Rule';
    final String Account = Match.AccountNickname == null ? '' : '${Match.AccountNickname} · ';
    final String State = Match.IsDisconnected ? '掉线' : Formats.Result(Match.Result);
    final String RecordState = Match.VideoPath != null ? '已录制' : Match.SkipReason != null ? '账户冲突，未自动裁剪' : '未录制';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(border: Border.all(color: Scheme.outlineVariant), borderRadius: BorderRadius.circular(14)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(Title, style: AppTheme.Style(Size: 15, Weight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('$Account${Formats.DateTimeText(Match.EndAt)} · ${Formats.Duration(Match.Duration)} · $State · $RecordState', style: AppTheme.Style(Size: 12, ColorValue: Scheme.onSurfaceVariant)),
              const SizedBox(height: 2),
              Text(MatchStats.Text(Match), style: AppTheme.Style(Size: 12, ColorValue: Scheme.onSurfaceVariant)),
            ]),
          ),
          const SizedBox(width: 16),
          Wrap(
            spacing: 2,
            children: <Widget>[
              AppButton(Label: '播放录像', Kind: AppButtonKind.Text, Enabled: Match.VideoPath != null, OnPressed: OnPlay ?? () {}),
              AppButton(Label: '打开位置', Kind: AppButtonKind.Text, Enabled: Match.VideoPath != null, OnPressed: OnOpen ?? () {}),
              AppButton(Label: '保存录像', Kind: AppButtonKind.Text, Enabled: Match.VideoPath != null, OnPressed: OnSave ?? () {}),
            ],
          ),
        ],
      ),
    );
  }
}

const List<int> QualityTiers = <int>[18, 22, 28];
const List<String> ThemeColors = <String>['#4285f4', '#3f51b5', '#9c27b0', '#e91e63', '#f44336', '#ff9800', '#4caf50', '#009688', '#00bcd4', '#607d8b'];


















