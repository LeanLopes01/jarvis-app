/// What Jarvis says for proactive alerts, in British English. Spoken alerts only
/// state what the source reported: a finished turn is not called a passed test.
library;

import 'models.dart';

String _place(AgentEvent event) => event.project == null ? '' : ' for ${event.project}';

String eventPhrase(AgentEvent event) {
  // Events raised by the server itself, not by a coding agent.
  switch (event.kind) {
    case 'diagnostic_ready':
      return event.data['state'] == 'partial'
          ? "Your report on how I'm working is saved, Sir, although some sources were missing."
          : "Your report on how I'm working is saved, Sir.";
    case 'operation_stalled':
      return 'Sir, a task stopped answering: ${event.summary ?? event.title}';
    case 'plan_ready':
    case 'project_reply':
    case 'project_working':
    case 'run_update':
    case 'run_finished':
      return event.summary ?? event.title;
  }
  final who = event.agentName;
  switch (event.status) {
    case 'interrupted':
      return '$who was interrupted${_place(event)}, Sir.';
    case 'failed':
      return '$who stopped with an error${_place(event)}, Sir.';
    case 'approval':
      return '$who needs your approval${_place(event)}, Sir.';
    case 'question':
      return '$who has a question for you${_place(event)}, Sir.';
    default:
      return '$who has finished its response${_place(event)}, Sir.';
  }
}

/// One sentence for several alerts that arrived together (for example after the
/// phone was offline); each report stays available on its own card.
String eventsPhrase(List<AgentEvent> events) {
  if (events.length == 1) return eventPhrase(events.first);
  // Reports and project updates are said one by one.
  if (events.any((e) => !e.kind.startsWith('agent_'))) return events.map(eventPhrase).join(' ');
  final parts = events.take(3).map((e) {
    final verb = switch (e.status) {
      'approval' => 'needs approval',
      'question' => 'has a question',
      'interrupted' => 'was interrupted',
      'failed' => 'stopped with an error',
      _ => 'finished',
    };
    return '${e.agentName} $verb${e.project == null ? '' : ' on ${e.project}'}';
  }).toList();
  final more = events.length - parts.length;
  final list = more > 0 ? '${parts.join(', ')}, and $more more' : _join(parts);
  return 'Sir, you have ${events.length} new reports: $list.';
}

String messagesPhrase(List<SocialMessage> messages) {
  final byApp = <String, List<SocialMessage>>{};
  for (final m in messages) {
    byApp.putIfAbsent(m.appName, () => []).add(m);
  }
  final sentences = byApp.entries.map((entry) {
    final senders = entry.value.map((m) => m.sender).whereType<String>().toSet().toList();
    final count = entry.value.length;
    final what = count == 1 ? 'a new ${entry.key} message' : '$count new ${entry.key} messages';
    if (senders.isEmpty) return 'you have $what';
    final from = senders.length > 3 ? '${senders.take(3).join(', ')} and others' : _join(senders);
    return 'you have $what from $from';
  }).toList();
  return 'Sir, ${_join(sentences)}.';
}

/// Reads a message aloud with its original text; says so when the app hid it.
String readMessagePhrase(SocialMessage message) {
  final from = message.sender == null ? '' : ' from ${message.sender}';
  final group = message.conversation != null && message.conversation != message.sender
      ? ' in ${message.conversation}'
      : '';
  if (message.text == null || message.text!.trim().isEmpty) {
    return '${message.appName} message$from$group. ${message.appName} did not show its content.';
  }
  return '${message.appName} message$from$group: ${message.text}';
}

/// A report read aloud: markdown, code and long paths make poor speech.
String speakableReport(String text, {int limit = 1200}) {
  var clean = text
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' (code omitted) ')
      .replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m[1]!)
      .replaceAll(RegExp(r'^#+\s*', multiLine: true), '')
      .replaceAll(RegExp(r'\*\*|__|\*|\|'), '')
      .replaceAll(RegExp(r'^\s*[-•]\s+', multiLine: true), '')
      // Long paths: only the file name is worth hearing.
      .replaceAllMapped(RegExp(r'(?:[A-Za-z]:)?[\\/]?(?:[\w.-]+[\\/]){2,}([\w.-]+)'), (m) => m[1]!)
      .replaceAll(RegExp(r'https?://\S+'), 'a link')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (clean.length > limit) {
    final cut = clean.lastIndexOf(RegExp(r'[.!?]\s'), limit);
    clean = '${clean.substring(0, cut > limit ~/ 2 ? cut + 1 : limit)} The rest of the report is on the screen.';
  }
  return clean;
}

String _join(List<String> items) {
  if (items.length <= 1) return items.join();
  return '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';
}
