import 'package:aether_player/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('opens an ONS texture, forwards Return, and can reopen', (
    tester,
  ) async {
    const channel = MethodChannel('aether/ons_player');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'chooseFolder' => '/test/ons',
        'open' => {'textureId': 7, 'title': 'ONS fixture'},
        _ => null,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const AetherPlayerApp());
    for (var session = 0; session < 2; session++) {
      await tester.tap(find.text('Open Game'));
      await tester.pump();
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall('frameSize', {'width': 640, 'height': 480}),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();

      final texture = find.byType(Texture);
      expect(tester.widget<Texture>(texture).textureId, 7);
      expect(tester.getSize(texture).aspectRatio, closeTo(4 / 3, 0.001));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);

      await tester.tap(find.text('Close Game'));
      await tester.pumpAndSettle();
      expect(find.byType(Texture), findsNothing);
    }

    expect(calls.where((call) => call.method == 'open').length, 2);
    expect(calls.where((call) => call.method == 'close').length, 2);
    expect(
      calls
          .where((call) => call.method == 'input')
          .map((call) => call.arguments),
      [
        {'type': 5, 'key': 13},
        {'type': 6, 'key': 13},
        {'type': 5, 'key': 13},
        {'type': 6, 'key': 13},
      ],
    );
  });
}
