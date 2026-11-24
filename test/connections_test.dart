import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/services/jarvis_api.dart';
import 'package:voice_assistant/screens/connections_screen.dart';

class FakeApi extends JarvisApi {
  FakeApi() : super('https://example.test');
  Object? failure;
  final accounts = [
    {
      'id': 'google_a',
      'provider': 'google',
      'label': 'Google A',
      'enabled': true,
      'services': ['calendar', 'drive', 'gmail'],
      'revision': 1
    },
    {
      'id': 'google_b',
      'provider': 'google',
      'label': 'Google B',
      'enabled': true,
      'services': ['calendar', 'drive'],
      'revision': 1
    },
    {
      'id': 'outlook',
      'provider': 'microsoft',
      'label': 'Outlook',
      'enabled': true,
      'services': ['mail'],
      'revision': 1
    },
    {
      'id': 'notion',
      'provider': 'notion',
      'label': 'Notion',
      'enabled': true,
      'services': ['tasks'],
      'revision': 1
    },
  ];
  Map<String, dynamic>? lastChange;
  @override
  Future<Map<String, dynamic>> integrations() async {
    if (failure != null) throw failure!;
    for (final account in accounts) {
      account.putIfAbsent('status', () => 'setup_required');
    }
    return {'schema_version': 1, 'accounts': accounts, 'runtime_enabled': false, 'message': 'Autorizações pendentes.'};
  }

  @override
  Future<Map<String, dynamic>> updateIntegration(String id, Map<String, dynamic> changes) async {
    lastChange = changes;
    final account = accounts.firstWhere((a) => a['id'] == id);
    account.addAll(changes.cast<String, Object>());
    return integrations();
  }
}

void main() {
  testWidgets('server state controls connection label and pause takes precedence', (tester) async {
    final api = FakeApi();
    api.accounts.first['status'] = 'connected';
    await tester.pumpWidget(MaterialApp(home: ConnectionsScreen(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('Conectada'), findsOneWidget);
    api.accounts.first['enabled'] = false;
    await tester.tap(find.byTooltip('Atualizar'));
    await tester.pumpAndSettle();
    expect(find.text('Conectada'), findsNothing);
    expect(find.text('Pausada'), findsOneWidget);
  });

  testWidgets('both variants can configure without claiming OAuth success', (tester) async {
    final api = FakeApi();
    await tester.pumpWidget(MaterialApp(home: ConnectionsScreen(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('Google A'), findsOneWidget);
    expect(find.text('Autorizações pendentes.'), findsOneWidget);
    expect(find.textContaining('Salvar preferências não conecta'), findsOneWidget);
    await tester.tap(find.text('Editar preferências').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Pessoal');
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle(const Duration(milliseconds: 350));
    expect(api.lastChange?['revision'], 1);
    expect(api.lastChange?['label'], 'Pessoal');
    expect(find.text('Pessoal'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final entry in {
    'old server': JarvisCommandException('server_update_required', 'Servidor precisa atualizar.'),
    'denied': JarvisCommandException('personal_access_required', 'Acesso não liberado.'),
    'offline': JarvisApiException(JarvisErrorKind.unavailable),
  }.entries) {
    testWidgets('handles ${entry.key} and can retry without cached accounts', (tester) async {
      final api = FakeApi()..failure = entry.value;
      await tester.pumpWidget(MaterialApp(home: ConnectionsScreen(api: api)));
      await tester.pumpAndSettle();
      expect(find.text('Google A'), findsNothing);
      expect(find.text('Tentar novamente'), findsOneWidget);
      api.failure = null;
      await tester.tap(find.text('Tentar novamente'));
      await tester.pumpAndSettle();
      expect(find.text('Google A'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
