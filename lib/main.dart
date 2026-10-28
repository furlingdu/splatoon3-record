import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'app/controller.dart';
import 'config/constants.dart';
import 'config/system.dart';
import 'app/links.dart';
import 'store/storage.dart';
import 'ui/preview.dart';
import 'ui/shell.dart';

Future<void> main(List<String> Args) async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (Details) {
    try {
      File('${Directory.systemTemp.path}${Platform.pathSeparator}s3r-errors.log').writeAsStringSync('${Details.exception}\n${Details.stack}\n', mode: FileMode.append);
    } catch (_) {}
    FlutterError.presentError(Details);
  };
  if (PlatformInfo.Mobile) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ));
    try {
      final Documents = await getApplicationDocumentsDirectory();
      final Support = await getApplicationSupportDirectory();
      final Target = '${Documents.path}${Platform.pathSeparator}.splatoon3record';
      final Legacy = '${Support.path}${Platform.pathSeparator}.splatoon3record';
      if (!Directory(Target).existsSync() && Directory(Legacy).existsSync()) {
        try {
          await Directory(Legacy).rename(Target);
        } catch (_) {}
      }
      PathStore.MobileRoot = Target;
    } catch (_) {}
  }
  if (Args.contains('--preview') && PlatformInfo.Desktop) {
    await PreviewMode(Args.contains('--hidden'));
    return;
  }
  final Incoming = Args.where((Item) => Item.startsWith('npf')).isEmpty ? null : Uri.tryParse(Args.firstWhere((Item) => Item.startsWith('npf')));
  ExternalLinkBus.Pending = Incoming;
  var Width = 1440.0;
  var Height = 900.0;
  var DisplayWidth = 1440.0;
  var DisplayHeight = 900.0;
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await windowManager.ensureInitialized();
    try {
      final Display = await screenRetriever.getPrimaryDisplay();
      DisplayWidth = Display.size.width;
      DisplayHeight = Display.size.height;
      Width = min(1440, DisplayWidth);
      Height = min(900, DisplayHeight);
    } catch (_) {}
    final Options = WindowOptions(
      size: Size(Width, Height),
      minimumSize: Size(min(960, Width), min(640, Height)),
      center: true,
      backgroundColor: const Color(0xff1b1b1f),
      title: 'Splatoon3 Record',
    );
    await windowManager.waitUntilReadyToShow(Options, () async {
      await windowManager.show();
      if (DisplayWidth < 1000) await windowManager.setSize(Size(DisplayWidth, DisplayHeight));
      await windowManager.focus();
    });
    var Existing = false;
    try {
      final Client = await Socket.connect(InternetAddress.loopbackIPv4, Config.SingleInstancePort, timeout: const Duration(milliseconds: 600));
      Client.write(Incoming == null ? 'FOCUS' : 'LINK $Incoming');
      await Client.flush();
      await Client.close();
      Existing = true;
    } catch (_) {}
    if (Existing) exit(0);
    ServerSocket? Lock;
    for (var Attempt = 0; Attempt < 10 && Lock == null; Attempt++) {
      try {
        Lock = await ServerSocket.bind(InternetAddress.loopbackIPv4, Config.SingleInstancePort, shared: false);
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    Lock?.listen((Socket Client) async {
      try {
        final Data = await Client.first.timeout(const Duration(seconds: 3));
        final Text = utf8.decode(Data).trim();
        if (Text.startsWith('LINK ')) ExternalLinkBus.Add(Uri.parse(Text.substring(5)));
        Client.write('OK');
        await Client.flush();
        await Client.close();
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
    });
  }
  final Controller = AppController();
  runApp(RecordApp(Controller: Controller));
}

Future<void> PreviewMode(bool Hidden) async {
  await windowManager.ensureInitialized();
  var Ready = false;
  bool? Pending;
  var Visible = !Hidden;

  Future<void> ApplyVisibility(bool Value) async {
    if (!Ready) {
      Pending = Value;
      return;
    }
    Visible = Value;
    await windowManager.setSkipTaskbar(!Value);
    if (Value) {
      await windowManager.show();
      await windowManager.focus();
    } else {
      await windowManager.hide();
    }
  }

  try {
    final Lock = await ServerSocket.bind(InternetAddress.loopbackIPv4, Config.PreviewInstancePort, shared: false);
    Lock.listen((Socket Client) async {
      try {
        final Data = await Client.first.timeout(const Duration(seconds: 2));
        Client.destroy();
        if (utf8.decode(Data).trim() == 'QUIT') exit(0);
        await ApplyVisibility(true);
      } catch (_) {}
    });
  } catch (_) {
    exit(0);
  }
  var Width = 1280.0;
  var Height = 720.0;
  try {
    final Display = await screenRetriever.getPrimaryDisplay();
    Width = min(1024, Display.size.width * 0.8);
    Height = Width * 9 / 16;
    if (Height > Display.size.height * 0.8) {
      Height = Display.size.height * 0.8;
      Width = Height * 16 / 9;
    }
  } catch (_) {}
  final Options = WindowOptions(
    size: Size(Width, Height),
    minimumSize: const Size(480, 270),
    center: true,
    skipTaskbar: Hidden,
    backgroundColor: Colors.black,
    title: 'Splatoon3 Record 预览',
  );
  await windowManager.waitUntilReadyToShow(Options, () async {
    Ready = true;
    final Value = Pending ?? Visible;
    Pending = null;
    await ApplyVisibility(Value);
  });
  windowManager.addListener(PreviewWindowListener());
  windowManager.setPreventClose(true);
  runApp(const PreviewWindowApp());
}

class PreviewWindowListener with WindowListener {
  @override
  Future<void> onWindowClose() async {
    await windowManager.setSkipTaskbar(true);
    await windowManager.hide();
  }
}

class RecordApp extends StatefulWidget {
  const RecordApp({super.key, required this.Controller});

  final AppController Controller;

  @override
  State<RecordApp> createState() => RecordAppState();
}

class RecordAppState extends State<RecordApp> with WindowListener {
  bool? SetupApplied;

  @override
  void initState() {
    super.initState();
    widget.Controller.addListener(OnChanged);
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
  }

  Future<void> OnChanged() async {
    if (!widget.Controller.Ready) return;
    final Done = widget.Controller.CurrentConfig.SetupDone;
    if (SetupApplied == Done) return;
    SetupApplied = Done;
    if (Done) {
      await windowManager.setResizable(true);
      try {
        final Display = await screenRetriever.getPrimaryDisplay();
        await windowManager.setSize(Size(min(1180, Display.size.width), min(760, Display.size.height)));
      } catch (_) {
        await windowManager.setSize(const Size(1180, 760));
      }
      await windowManager.center();
      return;
    }
    await windowManager.setResizable(false);
    try {
      final Display = await screenRetriever.getPrimaryDisplay();
      await windowManager.setSize(Size(min(760, Display.size.width), min(640, Display.size.height)));
    } catch (_) {
      await windowManager.setSize(const Size(760, 640));
    }
    await windowManager.center();
  }

  @override
  Future<void> onWindowClose() async {
    try {
      await windowManager.hide();
      if (widget.Controller.Ready) await widget.Controller.Shutdown();
    } finally {
      try {
        await windowManager.destroy().timeout(const Duration(seconds: 2));
      } catch (_) {}
      exit(0);
    }
  }

  @override
  void dispose() {
    widget.Controller.removeListener(OnChanged);
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      windowManager.removeListener(this);
    }
    widget.Controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppRoot(Controller: widget.Controller);
  }
}

















