import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/screens/knowledge_screen.dart';
import 'package:voice_assistant/services/jarvis_api.dart';

class FakeApi extends JarvisApi {
  FakeApi({this.online = true}) : super('https://jarvis.invalid/');

  final bool online;
  final asks = <String>[];

  @override
  Future<Map<String, dynamic>> ragHealth() async {
    if (!online) throw JarvisCommandException('pc_offline', 'O PC principal (helper + RAG) não está conectado.');
    return {
      'online': true,
      'rag': {
        'index': {'state': 'ready', 'code_pointers': 494, 'document_chunks': 869, 'documents': 12},
        'model': {'state': 'unloaded'},
      },
    };
  }

  @override
  Future<Map<String, dynamic>> ragRetrieve(String query, {int textLimit = 6000}) async => {
        'warnings': ['document_needs_reindex: antigo.md mudou'],
        'sources': [
          {
            'id': 'S1',
            'kind': 'code_pointer',
            'relpath': 'Assets/Scripts/Salas/SteamLobbyManager.cs',
            'hash': 'a' * 64,
            'lines': [1, 3],
            'text': 'public class SteamLobbyManager {}',
            'read_at': '2026-10-21T21:00:00-03:00',
            'provenance': {'main_class': 'SteamLobbyManager'},
          },
        ],
      };

  @override
  Future<Map<String, dynamic>> ragAsk(String query, {required String requestId}) async {
    asks.add(requestId);
    return {'ask_id': 'ask1', 'state': 'queued', 'query': query};
  }
}

void main() {
  testWidgets('searches the PC RAG and shows sources with warnings', (tester) async {
    final api = FakeApi();
    await tester.pumpWidget(MaterialApp(home: KnowledgeScreen(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('RAG do PC conectado'), findsOneWidget);
    expect(find.textContaining('494 scripts'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Como o lobby é criado?');
    await tester.tap(find.text('Buscar fontes'));
    await tester.pumpAndSettle();
    expect(find.textContaining('[S1] Assets/Scripts/Salas/SteamLobbyManager.cs'), findsOneWidget);
    expect(find.textContaining('document_needs_reindex'), findsOneWidget);
    await tester.tap(find.text('Perguntar ao modelo do PC'));
    await tester.pump();
    expect(api.asks, hasLength(1));
    expect(find.text('Resposta do modelo local'), findsOneWidget);
  });

  testWidgets('explains when the PC is offline', (tester) async {
    await tester.pumpWidget(MaterialApp(home: KnowledgeScreen(api: FakeApi(online: false))));
    await tester.pumpAndSettle();
    expect(find.text('RAG do PC desligado'), findsOneWidget);
    expect(find.textContaining('não está conectado'), findsOneWidget);
    final search = tester.widget<FilledButton>(find.ancestor(of: find.text('Buscar fontes'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(search.onPressed, isNull);
  });
}
