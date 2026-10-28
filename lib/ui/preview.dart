import 'dart:async';

import 'package:flutter/material.dart';

import '../media/capture/bridge.dart';
import 'theme.dart';

class PreviewWindowApp extends StatefulWidget {
  const PreviewWindowApp({super.key});

  @override
  State<PreviewWindowApp> createState() => PreviewWindowAppState();
}

class PreviewWindowAppState extends State<PreviewWindowApp> {
  Timer? _Poll;
  int? _Texture;
  bool _Active = false;
  String? _Message = '正在连接采集画面…';

  @override
  void initState() {
    super.initState();
    _Init();
    _Poll = Timer.periodic(const Duration(milliseconds: 500), (_) => _Refresh());
  }

  Future<void> _Init() async {
    if (!CaptureBridge.Supported) {
      if (mounted) setState(() => _Message = '当前平台暂不提供原生画面预览');
      return;
    }
    try {
      final Texture = await CaptureBridge.PreviewTexture();
      if (Texture >= 0) _Texture = Texture;
      await _Refresh();
    } catch (_) {
      if (mounted) setState(() => _Message = '预览通道不可用');
    }
  }

  Future<void> _Refresh() async {
    if (!mounted || !CaptureBridge.Supported) return;
    try {
      final State = await CaptureBridge.PreviewState();
      final Active = State['active'] == true;
      if (mounted && (Active != _Active || (_Texture == null && State['publish'] != null))) {
        setState(() {
          _Active = Active;
          _Message = Active ? null : '等待录制开始';
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _Poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.Build('#4285f4'),
      home: ColoredBox(
        color: Colors.black,
        child: Center(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: _Active && _Texture != null
                ? Texture(textureId: _Texture!, filterQuality: FilterQuality.low)
                : ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: Text(
                        _Message ?? '等待录制开始',
                        textAlign: TextAlign.center,
                        style: AppTheme.Style(Size: 15, ColorValue: Colors.white70),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
