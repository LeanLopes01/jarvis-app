import 'models.dart';

/// Limits automatic alerts only; every message remains available for reading.
class MessageAnnouncementCooldown {
  MessageAnnouncementCooldown({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const interval = Duration(minutes: 10);
  final DateTime Function() _now;
  final _announcedAt = <String, DateTime>{};
  final _pending = <String>{};

  String _key(SocialMessage message) {
    final sender = message.sender?.trim().toLowerCase();
    final chat = message.conversation?.trim().toLowerCase();
    final identity = sender != null && sender.isNotEmpty ? 'sender:$sender' : 'chat:${chat ?? "unknown"}';
    // Names from different apps cannot safely be treated as the same account.
    return '${message.app}:$identity';
  }

  bool allows(SocialMessage message) {
    final now = _now();
    _announcedAt.removeWhere((_, at) => now.difference(at) >= interval);
    final key = _key(message);
    return !_pending.contains(key) && !_announcedAt.containsKey(key);
  }

  /// Reserve senders while speech waits behind a call or another announcement.
  List<SocialMessage> reserve(List<SocialMessage> messages) {
    final eligible = messages.where(allows).toList();
    _pending.addAll(eligible.map(_key));
    return eligible;
  }

  void complete(List<SocialMessage> messages, {required bool spoken}) {
    final now = _now();
    for (final key in messages.map(_key).toSet()) {
      _pending.remove(key);
      if (spoken) _announcedAt[key] = now;
    }
  }
}
