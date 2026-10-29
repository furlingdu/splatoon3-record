import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splatoon3record/ui/drop.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('TextDrop toggles native drop and forwards text', () async {
    final Methods = <String>[];
    final Messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Messenger.setMockMethodCallHandler(TextDrop.Channel, (Call) async {
      Methods.add(Call.method);
      return null;
    });
    addTearDown(() => Messenger.setMockMethodCallHandler(TextDrop.Channel, null));
    final Dropped = <String>[];
    final Active = <bool>[];
    final Drop = TextDrop(OnDrop: Dropped.add, OnActive: Active.add);
    await Drop.Start();
    expect(Methods, contains('Enable'));
    await Drop.Receive(const MethodCall('Active', true));
    await Drop.Receive(const MethodCall('Drop', '  npf71b963c1b7b6d119://auth#state=abc&session_token_code=def  '));
    await Drop.Receive(const MethodCall('Drop', '   '));
    expect(Active, <bool>[true]);
    expect(Dropped, <String>['npf71b963c1b7b6d119://auth#state=abc&session_token_code=def']);
    await Drop.Stop();
    expect(Methods, contains('Disable'));
  });
}
