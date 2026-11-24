import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_assistant/master/event_store.dart';
import 'package:voice_assistant/master/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('failed delivery is durable and retryable; success deduplicates', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await MasterStore.open();
    final event = AgentEvent.fromJson({'id':'test-1','cursor':'8','title':'Resultado','created_at':1});
    await expectLater(store.receiveEvent(event, (_) async => throw StateError('notification failed')),throwsStateError);
    expect(store.events.single.id,'test-1');
    expect(store.cursor,isNull);
    expect(store.seen(event.id),false);
    var delivered=0;
    await store.receiveEvent(event, (_) async {delivered++;});
    await store.receiveEvent(event, (_) async {delivered++;});
    expect(delivered,1);
    expect(store.cursor,'8');
    expect(store.events.length,1);
    await store.setCursor('2');
    expect(store.cursor,'8');
  });
}
