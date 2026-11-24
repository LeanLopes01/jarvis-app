import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/app.dart';
import 'package:voice_assistant/master/models.dart';

void main() {
  test('usage report becomes the three limit cards', () {
    final usage = ServiceUsage.fromReport({
      'claude_code': {
        'five_hour': {'used_percent': 42.0, 'resets_in_minutes': 130, 'resets_at': '2026-10-18 14:00'},
        'weekly': {'used_percent': 12.5, 'resets_in_minutes': 5000, 'resets_at': '2026-10-22 09:00'},
        'observed_minutes_ago': 3,
      },
      'codex': null,
      'codex_note': 'No Codex usage recorded in the last two weeks.',
      'antigravity': {
        'models': [
          {'label': 'Gemini 3.8 Flash (High)', 'remaining_percent': 90.4, 'resets_in_minutes': 8388, 'resets_at': '2026-10-24 07:29'},
          {'label': 'Gemini 3.8 Flash (Low)', 'remaining_percent': 90.4, 'resets_in_minutes': 8388, 'resets_at': '2026-10-24 07:29'},
          {'label': 'Claude Sonnet 4.6 (Thinking)', 'remaining_percent': 100.0},
        ],
        'source': 'live',
      },
    });
    expect(usage.map((u) => u.name), ['Claude Code', 'Codex', 'Gemini · Antigravity']);
    expect(usage[0].bars.map((b) => (b.label, b.usedPercent)), [('5 h', 42.0), ('Week', 12.5)]);
    expect(usage[0].bars.first.resetText, 'resets in 2 h 10 min');
    expect(usage[1].note, 'No Codex usage recorded in the last two weeks.');
    // The Gemini model is shown once, as used (100 - remaining); other models are left out.
    expect(usage[2].bars.map((b) => b.label), ['3.8 Flash']);
    expect(usage[2].bars.single.usedPercent!.toStringAsFixed(1), '9.6');
  });

  testWidgets('master phone lying on its side fits the screen', (tester) async {
    await dotenv.load(fileName: 'assets/.env', isOptional: true, mergeWith: const {'LIVEKIT_SANDBOX_ID': 'test'});
    // About a Moto G8 Power Lite in landscape.
    tester.view.physicalSize = const Size(1600, 720);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    appCtrl.master
      ..enabled = true
      ..usage = ServiceUsage.fromReport({
        'claude_code': {
          'five_hour': {'used_percent': 95.0, 'resets_in_minutes': 30},
          'weekly': {'used_percent': 71.0, 'resets_in_minutes': 3000, 'resets_at': '2026-10-20 10:00'},
        },
        'codex': {
          'five_hour': {'used_percent': 5.0, 'resets_in_minutes': 200},
          'weekly': {'used_percent': 40.0, 'resets_in_minutes': 6000, 'resets_at': '2026-10-22 10:00'},
        },
        'antigravity': {'limit_reached': {'resets_in_minutes': 2101, 'resets_at': '2026-10-20 19:01'}, 'source': 'log'},
      })
      ..usageAt = DateTime(2026, 10, 18, 12);

    await tester.pumpWidget(const VoiceAssistantApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('AI limits'), findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('Gemini · Antigravity'), findsOneWidget);
    for (final label in ['Mute', 'Camera', 'Share screen', 'Call', 'Reports', 'Messages']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(tester.takeException(), isNull); // no overflow

    // Corner toast notification appears without overflow and can be dismissed.
    appCtrl.master.showCornerAlert(AgentEvent(
      id: 'toast-1',
      cursor: '99',
      kind: 'agent_finished',
      status: 'turn_completed',
      agent: 'antigravity',
      host: 'Antigravity',
      project: 'Orquestrador',
      title: 'Antigravity finished · Orquestrador',
      summary: 'Tarefa finalizada com sucesso.',
      hasReport: true,
      createdAt: DateTime.now().millisecondsSinceEpoch / 1000,
      finishedAt: DateTime.now().millisecondsSinceEpoch / 1000,
      data: const {},
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Antigravity terminou'), findsOneWidget);
    expect(find.text('Tarefa finalizada com sucesso.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    appCtrl.master.dismissCornerAlert('toast-1');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Antigravity terminou'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async => appCtrl.cleanUp());
  });
}
