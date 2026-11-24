import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/master/message_announcement_cooldown.dart';
import 'package:voice_assistant/master/models.dart';

SocialMessage message(String? sender, {String app = 'whatsapp', String? chat}) => SocialMessage(
      key: '$app:$sender:$chat',
      app: app,
      sender: sender,
      conversation: chat,
      text: 'hello',
      postedAt: 0,
    );

void main() {
  late DateTime now;
  late MessageAnnouncementCooldown cooldown;
  setUp(() {
    now = DateTime(2026, 10, 19);
    cooldown = MessageAnnouncementCooldown(now: () => now);
  });

  test('X is silent for ten minutes while Y can be announced', () {
    final x = message('X');
    final batch = cooldown.reserve([x]);
    cooldown.complete(batch, spoken: true);
    now = now.add(const Duration(seconds: 599));
    expect(cooldown.allows(x), isFalse);
    expect(cooldown.allows(message('Y')), isTrue);
    now = now.add(const Duration(seconds: 1));
    expect(cooldown.allows(x), isTrue);
    expect(x.read, isFalse);
    expect(x.text, 'hello');
  });

  test('pending speech blocks duplicate alerts even during a long call', () {
    final batch = cooldown.reserve([message('X')]);
    now = now.add(const Duration(minutes: 15));
    expect(cooldown.reserve([message('X'), message('Y')]).map((m) => m.sender), ['Y']);
    cooldown.complete(batch, spoken: true);
    now = now.add(const Duration(seconds: 599));
    expect(cooldown.allows(message('X')), isFalse);
  });

  test('failed or cancelled speech permits the next notification', () {
    final batch = cooldown.reserve([message('X')]);
    cooldown.complete(batch, spoken: false);
    expect(cooldown.allows(message('X')), isTrue);
  });

  test('suppressed messages do not extend the interval', () {
    final batch = cooldown.reserve([message('X')]);
    cooldown.complete(batch, spoken: true);
    now = now.add(const Duration(minutes: 5));
    expect(cooldown.reserve([message('X')]), isEmpty);
    now = now.add(const Duration(minutes: 5));
    expect(cooldown.reserve([message('X')]), hasLength(1));
  });

  test('one batch counts all messages and normalizes the sender', () {
    final batch = cooldown.reserve([message(' X '), message('x')]);
    expect(batch, hasLength(2));
    cooldown.complete(batch, spoken: true);
    expect(cooldown.allows(message('X', chat: 'Group')), isFalse);
    expect(cooldown.allows(message('X', app: 'instagram')), isTrue);
  });

  test('unknown senders use the conversation instead of muting all chats', () {
    cooldown.reserve([message(null, chat: 'One')]);
    expect(cooldown.allows(message(null, chat: 'One')), isFalse);
    expect(cooldown.allows(message(null, chat: 'Two')), isTrue);
  });
}
