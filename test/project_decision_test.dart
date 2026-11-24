import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/master/master_ctrl.dart';
import 'package:voice_assistant/master/project_ctrl.dart';
import 'package:voice_assistant/screens/projects_screen.dart';
import 'package:voice_assistant/services/jarvis_api.dart';

/// Plan approval on the phone: outcome on screen, one request per tap, honest errors.
class FakeApi extends Fake implements JarvisApi {
  FakeApi(this.plan);

  Map<String, dynamic> plan;
  final decisions = <Map<String, Object?>>[];
  Object? failWith;
  Completer<void>? hold;
  bool decideOnServerAnyway = false;
  bool pcOnline = true;

  Map<String, dynamic> get conv => {
        'id': 'c1',
        'title': 'Rolagem 3D',
        'state': plan['state'] == 'proposed' ? 'awaiting_approval' : 'running',
        'messages': <Map<String, dynamic>>[],
        'plans': [plan],
        'runs': <Map<String, dynamic>>[],
        'jobs': [
          {
            'id': 'j1',
            'agent': 'claude',
            'state': 'running',
            'updated_at': 1792670030,
            'progress': {
              'stage': 'running',
              'activity': 'Read: Dado.cs',
              'events': [
                {'id': 'j1:1', 'at': 1792670029, 'kind': 'tool', 'text': 'Read: Dado.cs'},
              ],
              'usage': {'input_tokens': 1234, 'output_tokens': 42, 'source': 'claude-cli'},
            },
          },
        ],
      };

  @override
  Future<Map<String, dynamic>> conversation(String id) async => conv;

  @override
  Future<Map<String, dynamic>> orchestrationRuntime() async => {'online': pcOnline};

  @override
  Future<Map<String, dynamic>> decidePlan(String planId, String decision,
      {int? version, String? hash, String? text}) async {
    decisions.add({'id': planId, 'decision': decision, 'version': version, 'hash': hash});
    if (hold != null) await hold!.future;
    if (decideOnServerAnyway) plan = {...plan, 'state': decision == 'approve' ? 'approved' : 'rejected'};
    if (failWith != null) throw failWith!;
    plan = {...plan, 'state': decision == 'approve' ? 'approved' : 'rejected'};
    return {'plan_id': planId, 'state': plan['state']};
  }
}

class FakeMaster extends Fake implements MasterCtrl {
  final spoken = <String>[];
  Completer<bool> speech = Completer<bool>(); // never completes unless asked: like a stuck call

  @override
  Future<bool> say(String text, {bool force = true}) {
    spoken.add(text);
    return speech.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.isSetter ? null : super.noSuchMethod(invocation); // callback wiring
}

Map<String, dynamic> proposed() => {
      'id': 'p2',
      'conversation_id': 'c1',
      'version': 2,
      'hash': 'abc123',
      'state': 'proposed',
      'body': {
        'title': 'Dados 3D',
        'goal': 'Rolagem mais rápida',
        'summary': '',
        'tasks': [
          {'key': 'task-1', 'agent': 'claude', 'title': 'Física', 'objective': 'Ajustar giro',
           'files': ['Assets/Dado.cs'], 'acceptance': ['gira'], 'depends_on': []},
        ],
        'tests': [],
        'risks': [],
      },
    };

void main() {
  test('approval sends version and hash once and shows the outcome without waiting for speech', () async {
    final api = FakeApi(proposed());
    final master = FakeMaster();
    final ctrl = ProjectCtrl(api, master);
    await ctrl.decide(api.plan, 'approve'); // returns although speech never ends
    expect(api.decisions, [
      {'id': 'p2', 'decision': 'approve', 'version': 2, 'hash': 'abc123'},
    ]);
    expect(ctrl.decisionNotice, contains('Plano 2 aprovado'));
    expect(ctrl.decisionError, isNull);
    expect(ctrl.current?['plans'][0]['state'], 'approved'); // reopened after the answer
    expect(master.spoken.single, contains('approved'));
  });

  test('a second tap while the first decision is in flight sends nothing', () async {
    final api = FakeApi(proposed())..hold = Completer<void>();
    final ctrl = ProjectCtrl(api, FakeMaster());
    final first = ctrl.decide(api.plan, 'approve');
    expect(ctrl.decidingPlanId, 'p2');
    await ctrl.decide(api.plan, 'approve');
    await ctrl.decide(api.plan, 'reject');
    api.hold!.complete();
    await first;
    expect(api.decisions.length, 1);
    expect(ctrl.decidingPlanId, isNull);
  });

  test('server refusals stay on screen with their reason', () async {
    final cases = {
      JarvisCommandException('orchestrator_offline', 'Abra o Orquestrador no BATCOMPUTADOR antes de enviar.'):
          'Abra o Orquestrador no BATCOMPUTADOR',
      JarvisCommandException('changed', 'The plan changed after it was shown.'): 'mudou ou já foi decidido',
      JarvisCommandException('work_access_required', 'jarvis-control work ID'): 'não tem permissão',
      JarvisCommandException('unauthorized', 'Pair this device again.'): 'Pareie de novo',
    };
    for (final entry in cases.entries) {
      final api = FakeApi(proposed())..failWith = entry.key;
      final ctrl = ProjectCtrl(api, FakeMaster());
      await ctrl.decide(api.plan, 'approve');
      expect(ctrl.decisionError, contains(entry.value), reason: entry.key.code);
      expect(ctrl.decisionNotice, isNull);
      expect(ctrl.decisionPlanId, 'p2');
    }
  });

  test('no answer: the saved decision is checked before asking for another tap', () async {
    final applied = FakeApi(proposed())
      ..failWith = TimeoutException('no answer')
      ..decideOnServerAnyway = true;
    final ctrl = ProjectCtrl(applied, FakeMaster());
    await ctrl.decide(applied.plan, 'approve');
    expect(ctrl.decisionNotice, contains('aprovado'));
    expect(ctrl.decisionError, isNull);

    final lost = FakeApi(proposed())..failWith = TimeoutException('no answer');
    final ctrl2 = ProjectCtrl(lost, FakeMaster());
    await ctrl2.decide(lost.plan, 'approve');
    expect(ctrl2.decisionError, contains('não foi confirmada'));
    expect(lost.decisions.length, 1); // never retried on its own
  });

  testWidgets('the plan card shows the PC warning, the refusal and live job telemetry', (tester) async {
    final api = FakeApi(proposed())
      ..pcOnline = false
      ..failWith = JarvisCommandException('orchestrator_offline', 'Abra o Orquestrador no BATCOMPUTADOR.');
    final ctrl = ProjectCtrl(api, FakeMaster());
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: ConversationScreen(projects: ctrl, conversationId: 'c1')));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('a aprovação será recusada'), findsOneWidget);
    expect(find.textContaining('Read: Dado.cs'), findsWidgets); // activity, not a raw map
    expect(find.textContaining('{'), findsNothing);

    await tester.tap(find.text('Approve plan 2'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Abra o Orquestrador no BATCOMPUTADOR.'), findsOneWidget);
    expect(find.text('Approve plan 2'), findsOneWidget); // still pending: can try again
    ctrl.unfollow();
  });
}
