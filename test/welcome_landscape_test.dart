import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/app.dart';

void main() {
  testWidgets('master button is reachable on a landscape phone', (tester) async {
    await dotenv.load(fileName: 'assets/.env', isOptional: true, mergeWith: const {
      'JARVIS_API_URL': 'https://example.invalid',
    });
    tester.view.physicalSize = const Size(1600, 720);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    appCtrl.isPaired = true;
    await tester.pumpWidget(const VoiceAssistantApp());
    await tester.pump(const Duration(milliseconds: 100));
    final button = find.widgetWithText(TextButton, 'Use as master phone');
    await tester.ensureVisible(button);
    await tester.pump();
    expect(button.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async => appCtrl.cleanUp());
  });
}
