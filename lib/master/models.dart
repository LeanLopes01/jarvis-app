import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

/// A report or request from a coding agent, as stored by jarvis-control.
class AgentEvent {
  AgentEvent({
    required this.id,
    required this.cursor,
    required this.kind,
    required this.status,
    required this.agent,
    required this.host,
    required this.project,
    required this.title,
    required this.summary,
    required this.hasReport,
    required this.createdAt,
    required this.finishedAt,
    required this.data,
    this.startedAt,
    this.read = false,
  });

  factory AgentEvent.fromJson(Map<String, dynamic> json) => AgentEvent(
        id: json['id'] as String,
        cursor: json['cursor'] as String? ?? '0',
        kind: json['kind'] as String? ?? 'agent_finished',
        status: json['status'] as String?,
        agent: json['agent'] as String?,
        host: json['host'] as String?,
        project: json['project'] as String?,
        title: json['title'] as String? ?? 'JARVIS',
        summary: json['summary'] as String?,
        hasReport: json['has_report'] as bool? ?? false,
        createdAt: (json['created_at'] as num?)?.toDouble() ?? 0,
        finishedAt: (json['finished_at'] as num?)?.toDouble(),
        startedAt: (json['started_at'] as num?)?.toDouble(),
        data: (json['data'] as Map?)?.cast<String, dynamic>() ?? const {},
        read: json['read'] as bool? ?? false,
      );

  final String id;
  final String cursor;
  final String kind; // agent_finished | agent_waiting
  final String? status; // turn_completed | interrupted | failed | approval | question
  final String? agent; // claude | codex | antigravity
  final String? host;
  final String? project;
  final String title;
  final String? summary;
  final bool hasReport;
  final double createdAt;
  final double? finishedAt;
  final double? startedAt;
  final Map<String, dynamic> data;
  bool read;

  bool get isWaiting => kind == 'agent_waiting';

  bool get isCodingAgent => const {'claude', 'codex', 'antigravity'}.contains(agent);

  bool get isFinishedTask => kind == 'agent_finished' && isCodingAgent;

  /// "Still working" updates from the orchestrator: worth hearing only while current.
  bool get isProgress => kind == 'project_working';

  bool isFreshProgress(DateTime now) => now.difference(when).inMinutes < 5;

  String get agentName => switch (agent) {
        'claude' => 'Claude Code',
        'codex' => 'Codex',
        'antigravity' => 'Antigravity',
        _ => 'A coding agent',
      };

  /// When it happened on the PC (the original time, also after a late delivery).
  DateTime get when => DateTime.fromMillisecondsSinceEpoch(((finishedAt ?? createdAt) * 1000).round());

  Map<String, dynamic> toJson() => {
        'id': id,
        'cursor': cursor,
        'kind': kind,
        'status': status,
        'agent': agent,
        'host': host,
        'project': project,
        'title': title,
        'summary': summary,
        'has_report': hasReport,
        'created_at': createdAt,
        'finished_at': finishedAt,
        'started_at': startedAt,
        'data': data,
        'read': read,
      };
}

/// A WhatsApp or Instagram message seen in this phone's notifications. The text
/// stays on the phone.
class SocialMessage {
  SocialMessage({
    required this.key,
    required this.app,
    required this.sender,
    required this.conversation,
    required this.text,
    required this.postedAt,
    this.read = false,
  });

  factory SocialMessage.fromJson(Map<String, dynamic> json) => SocialMessage(
        key: json['key'] as String,
        app: json['app'] as String,
        sender: json['sender'] as String?,
        conversation: json['conversation'] as String?,
        text: json['text'] as String?,
        postedAt: (json['posted_at'] as num?)?.toDouble() ?? DateTime.now().millisecondsSinceEpoch / 1000,
        read: json['read'] as bool? ?? false,
      );

  final String key;
  final String app; // whatsapp | instagram
  final String? sender;
  final String? conversation; // group or chat title, when different from the sender
  final String? text; // null when the app hid the content
  final double postedAt;
  bool read;

  String get appName => app == 'instagram' ? 'Instagram' : 'WhatsApp';

  DateTime get when => DateTime.fromMillisecondsSinceEpoch((postedAt * 1000).round());

  Map<String, dynamic> toJson() => {
        'key': key,
        'app': app,
        'sender': sender,
        'conversation': conversation,
        'text': text,
        'posted_at': postedAt,
        'read': read,
      };

  /// What the server may store: no text.
  Map<String, dynamic> toMetadata() => {
        'key': key,
        'app': app,
        if (sender != null) 'sender': sender,
        if (conversation != null) 'conversation': conversation,
        'posted_at': postedAt,
      };
}

/// What Spotify on the computer reports.
class MusicState {
  const MusicState({this.track, this.isPlaying = false, this.device, this.onComputer = false, this.error});

  factory MusicState.fromJson(Map<String, dynamic> json) => MusicState(
        track: json['track'] as String?,
        isPlaying: json['is_playing'] as bool? ?? false,
        device: json['device'] as String?,
        onComputer: json['on_computer'] as bool? ?? false,
      );

  final String? track;
  final bool isPlaying;
  final String? device;
  final bool onComputer;
  final String? error;
}

/// One usage bar: how much of a limit is used and when it resets.
class UsageBar {
  const UsageBar(this.label, this.usedPercent, {this.resetsInMinutes, this.resetsAt, this.note});

  final String label;
  final double? usedPercent;
  final int? resetsInMinutes;
  final String? resetsAt; // "YYYY-MM-DD HH:MM", the PC's local time (São Paulo)
  final String? note;

  /// "resets in 2 h 10 min" or "resets Fri 07:29".
  String get resetText {
    final minutes = resetsInMinutes;
    if (minutes == null) return note ?? '';
    if (minutes < 60) return 'resets in $minutes min';
    if (minutes < 24 * 60) return 'resets in ${minutes ~/ 60} h ${minutes % 60} min';
    final at = resetsAt == null ? null : DateTime.tryParse(resetsAt!.replaceFirst(' ', 'T'));
    return at == null ? 'resets in ${minutes ~/ 1440} d' : 'resets ${DateFormat('EEE HH:mm').format(at)}';
  }
}

/// The limits of one AI service, as the usage panel shows them.
class ServiceUsage {
  const ServiceUsage(this.name, this.bars, {this.note, this.limitReached = false});

  final String name;
  final List<UsageBar> bars;
  final String? note;
  final bool limitReached;

  static UsageBar? _bar(String label, Object? raw) {
    if (raw is! Map) return null;
    return UsageBar(
      label,
      (raw['used_percent'] as num?)?.toDouble(),
      resetsInMinutes: raw['resets_in_minutes'] as int?,
      resetsAt: raw['resets_at'] as String?,
      note: raw['note'] as String?,
    );
  }

  static String? _age(Map data) {
    final minutes = data['observed_minutes_ago'] as int?;
    if (minutes == null || minutes < 30) return data['note'] as String?;
    return minutes < 120 ? 'seen $minutes min ago' : 'seen ${minutes ~/ 60} h ago';
  }

  /// Claude Code or Codex: 5-hour and weekly windows.
  static ServiceUsage windows(String name, Object? raw, String? missing) {
    if (raw is! Map) return ServiceUsage(name, const [], note: missing ?? 'No data yet');
    final bars = [_bar('5 h', raw['five_hour']), _bar('Week', raw['weekly'])].whereType<UsageBar>().toList();
    return ServiceUsage(name, bars, note: _age(raw), limitReached: raw['limit_reached'] != null);
  }

  /// Antigravity: the Gemini models' remaining quota, shown as used.
  static ServiceUsage antigravity(Object? raw, String? missing) {
    const name = 'Gemini · Antigravity';
    if (raw is! Map) return ServiceUsage(name, const [], note: missing ?? 'Open Antigravity once to read it');
    final models = (raw['models'] as List?)?.cast<Map>() ?? const [];
    final gemini = models.where((m) => '${m['label']}'.toLowerCase().contains('gemini')).toList();
    final bars = <UsageBar>[];
    final seen = <String>{};
    for (final m in gemini.isEmpty ? models : gemini) {
      // "Gemini 3.8 Flash (High/Medium/Low)" share one quota: show it once.
      final label = '${m['label']}'.replaceAll(RegExp(r'\s*\((High|Medium|Low)\)$'), '').replaceFirst('Gemini ', '');
      final remaining = (m['remaining_percent'] as num?)?.toDouble();
      if (!seen.add(label)) continue;
      bars.add(UsageBar(label, remaining == null ? null : 100 - remaining,
          resetsInMinutes: m['resets_in_minutes'] as int?, resetsAt: m['resets_at'] as String?, note: m['note'] as String?));
    }
    final hit = raw['limit_reached'] as Map?;
    if (bars.isEmpty && hit != null) {
      bars.add(UsageBar('Limit', 100, resetsInMinutes: hit['resets_in_minutes'] as int?, resetsAt: hit['resets_at'] as String?));
    }
    return ServiceUsage(name, bars.take(3).toList(), note: _age(raw), limitReached: hit != null);
  }

  static List<ServiceUsage> fromReport(Map<String, dynamic> report) => [
        windows('Claude Code', report['claude_code'], report['claude_code_note'] as String?),
        windows('Codex', report['codex'], report['codex_note'] as String?),
        antigravity(report['antigravity'], report['antigravity_note'] as String?),
      ];
}

final _zoneName = 'America/Sao_Paulo';

/// Times are shown in São Paulo time, whatever the phone's own setting.
String formatLocal(DateTime time, {bool withDate = false}) {
  DateTime local;
  try {
    local = tz.TZDateTime.from(time, tz.getLocation(_zoneName));
  } catch (_) {
    local = time.toUtc().subtract(const Duration(hours: 3));
  }
  final now = DateTime.now().toUtc().subtract(const Duration(hours: 3));
  final sameDay = local.year == now.year && local.month == now.month && local.day == now.day;
  return DateFormat(withDate || !sameDay ? 'dd/MM HH:mm' : 'HH:mm').format(local);
}
