import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/master/speech_queue.dart';

void main() {
  test('readings wait for calls and use the supplied call voice in order', () async {
    final spoken = <String>[];
    final queue = SpeechQueue(
      onSpeaking: (_) async {},
      speak: (text) async { spoken.add(text); return true; },
      stopSpeaking: () async {},
    );
    await queue.init();
    queue.hold();
    final first = queue.say('message');
    final second = queue.say('report');
    await Future<void>.delayed(Duration.zero);
    expect(spoken, isEmpty);
    queue.release();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(spoken, ['message', 'report']);
    expect(queue.voiceOffline, isFalse);
  });

  test('failed online speech is not reported as read', () async {
    final queue = SpeechQueue(
      onSpeaking: (_) async {},
      speak: (_) async => false,
      stopSpeaking: () async {},
    );
    await queue.init();
    expect(await queue.say('message'), isFalse);
  });

  test('stop cancels the active reading and queued reports', () async {
    final started = Completer<void>();
    var stopped = false;
    final queue = SpeechQueue(
      onSpeaking: (_) async {},
      speak: (_) { started.complete(); return Completer<bool>().future; },
      stopSpeaking: () async { stopped = true; },
    );
    await queue.init();
    final active = queue.say('message');
    final pending = queue.say('report');
    await started.future;
    await queue.stop();
    expect(await active, isFalse);
    expect(await pending, isFalse);
    expect(stopped, isTrue);
  });
}
