import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/models.dart';
import 'legacy.dart';

class SecretStore {
  SecretStore(this.Directories);

  final AppDirectories Directories;
  Map<String, dynamic> Data = <String, dynamic>{};

  String get FilePath => '${Directories.Root}${Platform.pathSeparator}secrets.v2.json';

  Future<Map<String, dynamic>> Load() async {
    final FileRef = File(FilePath);
    if (FileRef.existsSync()) {
      try {
        final Outer = jsonDecode(await FileRef.readAsString());
        if (Outer is Map) {
          final Bytes = base64Decode('${Outer['value'] ?? ''}');
          final Clear = Outer['encrypted'] == true
              ? (Platform.isWindows ? LegacySecret.UnprotectData(Uint8List.fromList(Bytes)) : null)
              : Bytes;
          if (Clear != null) {
            final Inner = jsonDecode(utf8.decode(Clear));
            if (Inner is Map<String, dynamic>) {
              Data = Inner;
              return Data;
            }
          }
        }
      } catch (_) {}
    }
    final Legacy = await LegacySecret.Load(Directories);
    if (Legacy != null) Data = Map<String, dynamic>.from(Legacy);
    return Data;
  }

  Future<void> Save(Map<String, dynamic> Value) async {
    Data = Value;
    final Clear = utf8.encode(jsonEncode(Value));
    final Protected = Platform.isWindows ? LegacySecret.Protect(Uint8List.fromList(Clear)) : null;
    final Bytes = Protected ?? Uint8List.fromList(Clear);
    final Outer = <String, dynamic>{'encrypted': Protected != null, 'value': base64Encode(Bytes)};
    await File(FilePath).writeAsString(jsonEncode(Outer), flush: true);
  }

  String? Text(String Key) => Data[Key] is String ? Data[Key] as String : null;
}








