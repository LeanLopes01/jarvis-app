import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// What the master phone keeps between runs: the event cursor, which events were
/// already shown (shared with the background check, so nothing is announced
/// twice), recent reports and messages, and its settings.
class MasterStore {
  MasterStore(this._prefs);

  static const workModeKey = 'jarvis_work_mode';
  static const companionKey = 'jarvis_companion';
  static const modeKey = 'jarvis_master_mode';
  static const _cursorKey = 'jarvis_events_cursor';
  static const _seenKey = 'jarvis_events_seen';
  static const _eventsKey = 'jarvis_events_recent';
  static const _messagesKey = 'jarvis_social_recent';
  static const _settingsKey = 'jarvis_master_settings';
  static const _pendingMetadataKey = 'jarvis_social_metadata_pending';
  static const _seenLimit = 400;
  static const _keepEvents = 300;
  static const _keepMessages = 60;

  final SharedPreferences _prefs;

  static Future<MasterStore> open() async => MasterStore(await SharedPreferences.getInstance());

  /// Picks up what the other isolate (UI or background check) wrote.
  Future<void> reload() => _prefs.reload();

  bool get workMode => _prefs.getBool(workModeKey) ?? false;
  bool get companionConfigured => _prefs.getBool(companionKey) ?? false;
  Future<void> setCompanion() => _prefs.setBool(companionKey, true);
  Future<void> setWorkMode(bool value) => _prefs.setBool(workModeKey, value);

  bool get masterMode => _prefs.getBool(modeKey) ?? false;
  Future<void> setMasterMode(bool value) => _prefs.setBool(modeKey, value);

  String? get cursor => _prefs.getString(_cursorKey);

  /// Moves the cursor forward only: a late, older delivery never rewinds it.
  Future<void> setCursor(String next) async {
    final current = int.tryParse(cursor ?? '');
    final value = int.tryParse(next);
    if (value == null) return;
    if (current == null || value > current) await _prefs.setString(_cursorKey, next);
  }

  Set<String> get _seen => (_prefs.getStringList(_seenKey) ?? const []).toSet();

  bool seen(String eventId) => _seen.contains(eventId);

  /// Records [eventId]; false when it was already there.
  Future<bool> markSeen(String eventId) async {
    final list = _prefs.getStringList(_seenKey) ?? <String>[];
    if (list.contains(eventId)) return false;
    list.add(eventId);
    await _prefs.setStringList(_seenKey, list.length > _seenLimit ? list.sublist(list.length - _seenLimit) : list);
    return true;
  }

  List<AgentEvent> get events => _decodeList(_eventsKey).map(AgentEvent.fromJson).toList();

  Future<void> saveEvents(List<AgentEvent> events) => _prefs.setString(
        _eventsKey,
        jsonEncode(events.take(_keepEvents).map((e) => e.toJson()).toList()),
      );

  /// Persist before acknowledging or moving the cursor. A failed handler remains
  /// retryable and notification IDs stay stable across delivery retries.
  Future<void> receiveEvent(AgentEvent event, Future<void> Function(AgentEvent) handle) async {
    await reload();
    if (!seen(event.id)) {
      final previous = events.where((item) => item.id == event.id).firstOrNull;
      if (previous != null) event.read = previous.read;
      await saveEvents([event, ...events.where((item) => item.id != event.id)]);
      await handle(event);
      await markSeen(event.id);
    }
    await setCursor(event.cursor);
  }

  List<SocialMessage> get messages => _decodeList(_messagesKey).map(SocialMessage.fromJson).toList();

  Future<void> saveMessages(List<SocialMessage> messages) => _prefs.setString(
        _messagesKey,
        jsonEncode(messages.take(_keepMessages).map((m) => m.toJson()).toList()),
      );

  /// Message metadata not yet accepted by the server.
  List<Map<String, dynamic>> get pendingMetadata => _decodeList(_pendingMetadataKey);

  Future<void> savePendingMetadata(List<Map<String, dynamic>> items) =>
      _prefs.setString(_pendingMetadataKey, jsonEncode(items.length > 200 ? items.sublist(items.length - 200) : items));

  MasterSettings get settings {
    final raw = _prefs.getString(_settingsKey);
    if (raw == null) return const MasterSettings();
    try {
      return MasterSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const MasterSettings();
    }
  }

  Future<void> saveSettings(MasterSettings settings) => _prefs.setString(_settingsKey, jsonEncode(settings.toJson()));

  List<Map<String, dynamic>> _decodeList(String key) {
    final raw = _prefs.getString(key);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }
}

/// How the master phone listens and speaks.
class MasterSettings {
  const MasterSettings({
    this.listening = true,
    this.announcements = true,
    this.sttMode = 'local',
    this.sttLanguage = '',
    this.sensitivity = 0.5,
    this.announceMessages = true,
    this.landscape = true,
  });

  factory MasterSettings.fromJson(Map<String, dynamic> json) => MasterSettings(
        listening: json['listening'] as bool? ?? true,
        announcements: json['announcements'] as bool? ?? true,
        sttMode: json['stt_mode'] as String? ?? 'local',
        sttLanguage: json['stt_language'] as String? ?? '',
        sensitivity: (json['sensitivity'] as num?)?.toDouble() ?? 0.5,
        announceMessages: json['announce_messages'] as bool? ?? true,
        landscape: json['landscape'] as bool? ?? true,
      );

  /// Waiting for "Jarvis" (false: listening paused by the user).
  final bool listening;

  /// Speak reports and messages (false: cards and history only).
  final bool announcements;

  /// "local": the phone transcribes the command offline. "cloud": after "Jarvis",
  /// a normal call sends the audio to the voice model (not offline).
  final String sttMode;

  /// Whisper language: "" detects it, or "pt" / "en".
  final String sttLanguage;

  /// 0 (fewer false wakes) to 1 (wakes more easily).
  final double sensitivity;

  final bool announceMessages;

  /// Keep the screen horizontal (the phone lies flat, so auto-rotate is unreliable).
  final bool landscape;

  MasterSettings copyWith({
    bool? listening,
    bool? announcements,
    String? sttMode,
    String? sttLanguage,
    double? sensitivity,
    bool? announceMessages,
    bool? landscape,
  }) =>
      MasterSettings(
        listening: listening ?? this.listening,
        announcements: announcements ?? this.announcements,
        sttMode: sttMode ?? this.sttMode,
        sttLanguage: sttLanguage ?? this.sttLanguage,
        sensitivity: sensitivity ?? this.sensitivity,
        announceMessages: announceMessages ?? this.announceMessages,
        landscape: landscape ?? this.landscape,
      );

  Map<String, dynamic> toJson() => {
        'listening': listening,
        'announcements': announcements,
        'stt_mode': sttMode,
        'stt_language': sttLanguage,
        'sensitivity': sensitivity,
        'announce_messages': announceMessages,
        'landscape': landscape,
      };
}
