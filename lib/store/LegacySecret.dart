import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:ffi/ffi.dart';

import '../domain/Models.dart';

class LegacySecret {
  static Future<Map<String, dynamic>?> Load(AppDirectories Directories) async {
    if (!Platform.isWindows) return null;
    try {
      final SecretFile = File(Directories.SecretFile);
      if (!SecretFile.existsSync()) return null;
      final Outer = jsonDecode(await SecretFile.readAsString());
      if (Outer is! Map) return null;
      final Encrypted = Outer['encrypted'] == true;
      final Value = base64Decode('${Outer['value'] ?? ''}');
      if (!Encrypted) {
        final Text = utf8.decode(Value);
        final Inner = jsonDecode(Text);
        return Inner is Map<String, dynamic> ? Inner : null;
      }
      if (Value.length < 32 || !_Same(Value, 'v10')) return null;
      final Key = await _Key();
      if (Key == null) return null;
      final Nonce = Value.sublist(3, 15);
      final Tag = Value.sublist(Value.length - 16);
      final Cipher = Value.sublist(15, Value.length - 16);
      final Clear = await AesGcm.with256bits().decrypt(
        SecretBox(Cipher, nonce: Nonce, mac: Mac(Tag)),
        secretKey: SecretKey(Key),
      );
      final Inner = jsonDecode(utf8.decode(Clear));
      return Inner is Map<String, dynamic> ? Inner : null;
    } catch (_) {
      return null;
    }
  }

  static bool _Same(List<int> Value, String Prefix) {
    if (Value.length < Prefix.length) return false;
    for (var Index = 0; Index < Prefix.length; Index++) {
      if (Value[Index] != Prefix.codeUnitAt(Index)) return false;
    }
    return true;
  }

  static Future<Uint8List?> _Key() async {
    final AppData = Platform.environment['APPDATA'];
    if (AppData == null) return null;
    for (final Name in <String>['splatoon3record', 'Splatoon3Record', 'Splatoon3 Record']) {
      final FileRef = File('$AppData${Platform.pathSeparator}$Name${Platform.pathSeparator}Local State');
      if (!FileRef.existsSync()) continue;
      try {
        final Data = jsonDecode(await FileRef.readAsString());
        final Encoded = '${Data['os_crypt']?['encrypted_key'] ?? ''}';
        final Raw = base64Decode(Encoded);
        if (Raw.length < 10) continue;
        final Protected = Raw.sublist(5);
        return _Unprotect(Uint8List.fromList(Protected));
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  static Uint8List? Protect(Uint8List Data) {
    final Crypt = DynamicLibrary.open('crypt32.dll');
    final Kernel = DynamicLibrary.open('kernel32.dll');
    final ProtectFn = Crypt.lookupFunction<
        Int32 Function(Pointer<DataBlob>, Pointer<Utf16>, Pointer<DataBlob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<DataBlob>),
        int Function(Pointer<DataBlob>, Pointer<Utf16>, Pointer<DataBlob>, Pointer<Void>, Pointer<Void>, int, Pointer<DataBlob>)>('CryptProtectData');
    final Free = Kernel.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('LocalFree');
    final Input = malloc<Uint8>(Data.length);
    final InputBlob = malloc<DataBlob>();
    final OutputBlob = malloc<DataBlob>();
    try {
      Input.asTypedList(Data.length).setAll(0, Data);
      InputBlob.ref.CbData = Data.length;
      InputBlob.ref.PbData = Input;
      final Ok = ProtectFn(InputBlob, nullptr, nullptr, nullptr, nullptr, 1, OutputBlob);
      if (Ok == 0) return null;
      final Output = Uint8List.fromList(OutputBlob.ref.PbData.asTypedList(OutputBlob.ref.CbData));
      Free(OutputBlob.ref.PbData.cast<Void>());
      return Output;
    } finally {
      malloc.free(Input);
      malloc.free(InputBlob);
      malloc.free(OutputBlob);
    }
  }

  static Uint8List? UnprotectData(Uint8List Data) => _Unprotect(Data);

  static Uint8List? _Unprotect(Uint8List Data) {
    final Crypt = DynamicLibrary.open('crypt32.dll');
    final Kernel = DynamicLibrary.open('kernel32.dll');
    final Unprotect = Crypt.lookupFunction<
        Int32 Function(Pointer<DataBlob>, Pointer<Pointer<Utf16>>, Pointer<DataBlob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<DataBlob>),
        int Function(Pointer<DataBlob>, Pointer<Pointer<Utf16>>, Pointer<DataBlob>, Pointer<Void>, Pointer<Void>, int, Pointer<DataBlob>)>(CryptUnprotectName);
    final Free = Kernel.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('LocalFree');
    final Input = malloc<Uint8>(Data.length);
    final InputBlob = malloc<DataBlob>();
    final OutputBlob = malloc<DataBlob>();
    try {
      Input.asTypedList(Data.length).setAll(0, Data);
      InputBlob.ref.CbData = Data.length;
      InputBlob.ref.PbData = Input;
      final Ok = Unprotect(InputBlob, nullptr, nullptr, nullptr, nullptr, 0, OutputBlob);
      if (Ok == 0) return null;
      final Output = Uint8List.fromList(OutputBlob.ref.PbData.asTypedList(OutputBlob.ref.CbData));
      Free(OutputBlob.ref.PbData.cast<Void>());
      return Output;
    } finally {
      malloc.free(Input);
      malloc.free(InputBlob);
      malloc.free(OutputBlob);
    }
  }

  static const String CryptUnprotectName = 'CryptUnprotectData';

  static List<NSOAccount> Accounts(Map<String, dynamic> Secret) {
    final Result = <NSOAccount>[];
    final AccountsRaw = Secret['nsoAccounts'];
    if (AccountsRaw is List) {
      for (final Item in AccountsRaw) {
        if (Item is! Map) continue;
        final Account = NSOAccount.FromMap(Map<String, dynamic>.from(Item));
        if (Account.Id.isEmpty || Account.Session.isEmpty) continue;
        Account.State = Account.Token.Expired() ? 'expired' : 'connected';
        Result.add(Account);
      }
    } else if (Secret['nsoSession'] is String && Secret['nsoToken'] is Map) {
      final Account = NSOAccount(
        Id: 'legacy',
        Nickname: 'Nintendo 账号',
        Session: Secret['nsoSession'] as String,
        Token: NSOToken.FromMap(Map<String, dynamic>.from(Secret['nsoToken'] as Map)),
        AddedAt: DateTime.now().millisecondsSinceEpoch,
      );
      Account.State = Account.Token.Expired() ? 'expired' : 'connected';
      Result.add(Account);
    }
    return Result;
  }

  static String? Current(Map<String, dynamic> Secret) => Secret['currentNSOAccountId'] is String ? Secret['currentNSOAccountId'] as String : null;
}

final class DataBlob extends Struct {
  @Uint32()
  external int CbData;

  external Pointer<Uint8> PbData;
}









