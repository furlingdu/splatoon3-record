import 'package:flutter/services.dart';

class TextDrop {
  TextDrop({required this.OnDrop, required this.OnActive});

  static const MethodChannel Channel = MethodChannel('splatoon3record/text_drop');

  final ValueChanged<String> OnDrop;
  final ValueChanged<bool> OnActive;
  bool _Started = false;

  Future<void> Start() async {
    if (_Started) return;
    _Started = true;
    Channel.setMethodCallHandler(Receive);
    try {
      await Channel.invokeMethod<void>('Enable');
    } catch (_) {}
  }

  Future<void> Stop() async {
    if (!_Started) return;
    _Started = false;
    Channel.setMethodCallHandler(null);
    try {
      await Channel.invokeMethod<void>('Disable');
    } catch (_) {}
  }

  Future<void> Receive(MethodCall Call) async {
    if (Call.method == 'Active') {
      OnActive(Call.arguments == true);
      return;
    }
    if (Call.method != 'Drop') return;
    final Value = Call.arguments;
    if (Value is! String) return;
    final Text = Value.trim();
    if (Text.isEmpty) return;
    OnDrop(Text);
  }
}
