import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/app.dart';
import 'package:voice_assistant/companion_mode.dart';
import 'package:voice_assistant/master/event_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('companion keeps Projects and limits without social messages', (tester) async {
    if (!companionMode) return; // Run this file separately with the companion define.
    SharedPreferences.setMockInitialValues({});
    await dotenv.load(fileName: 'assets/.env', isOptional: true);
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    appCtrl.master.enabled = true;
    await tester.pumpWidget(const VoiceAssistantApp());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('AI limits'), findsOneWidget);
    expect(find.text('Messages'), findsNothing);
    expect((await appCtrl.master.messagesForAgent())['available'], false);
    expect(tester.takeException(), isNull);
    final store = await MasterStore.open();
    await store.setMasterMode(false);
    await store.setCompanion();
    await store.setWorkMode(true);
    expect(store.masterMode, false);
    expect(store.workMode, true);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async => appCtrl.cleanUp());
  });
}
