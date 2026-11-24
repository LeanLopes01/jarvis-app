/// Commands the master phone handles without the voice model.
///
/// After "Jarvis" the phone transcribes the command itself. Short, unambiguous
/// requests (music controls, reading a report or a message) run here or through
/// the server's command API; everything else opens a voice session with the text.
library;

sealed class LocalIntent {
  const LocalIntent();
}

/// pause, resume, next or previous, always on the computer.
class MusicControl extends LocalIntent {
  const MusicControl(this.action);
  final String action;
}

class MusicPlay extends LocalIntent {
  const MusicPlay(this.query);
  final String query;
}

class MusicVolume extends LocalIntent {
  const MusicVolume(this.percent);
  final int percent;
}

/// [agent] is "claude", "codex", "antigravity", "all" or null for the latest report.
class ReadReport extends LocalIntent {
  const ReadReport(this.agent);
  final String? agent;
}

class ReadMessage extends LocalIntent {
  const ReadMessage();
}

class StopListening extends LocalIntent {
  const StopListening();
}

/// Nothing to do: "never mind", or no words at all.
class Dismiss extends LocalIntent {
  const Dismiss();
}

/// Anything else goes to the voice model as the user's words.
class AskJarvis extends LocalIntent {
  const AskJarvis(this.text);
  final String text;
}

/// "Jarvis, what are you doing?" / "are you still working?": answered from the
/// recorded state, never by asking a model to guess.
class StatusQuery extends LocalIntent {
  const StatusQuery();
}

/// "Jarvis, stop what you are doing" ([all]: "stop all tasks"); [agent] names a
/// coding agent's task ("cancel the Codex task").
class StopOperation extends LocalIntent {
  const StopOperation({this.all = false, this.agent});
  final bool all;
  final String? agent;
}

/// "Jarvis, write a report on how you are working" / "report the last freeze".
class DiagnosticsRequest extends LocalIntent {
  const DiagnosticsRequest(this.note, {this.lastFreeze = false});
  final String note;
  final bool lastFreeze;
}

/// A request about a managed project, e.g. "no DiceVTT, melhore a iniciativa".
class ProjectRequest extends LocalIntent {
  const ProjectRequest(this.project, this.text);
  final String project;
  final String text;
}

/// "Aprovo o plano 3" / "approve the plan". [version] is null when not said.
class PlanDecision extends LocalIntent {
  const PlanDecision(this.decision, {this.version, this.changes});
  final String decision; // approve | reject | changes
  final int? version;
  final String? changes; // "aprove, mas mantenha a interface": a change request
}

/// Status, stop and report requests, recognised even while JARVIS is busy.
LocalIntent? parsePriority(String text) {
  if (_any(text, [
    r'(?:o )?que (?:você )?(?:está|esta|ta|tá) fazendo',
    r'(?:você )?(?:ainda )?(?:está|esta|tá|ta) (?:trabalhando|aí|ai|processando)',
    r'(?:qual|como) (?:é |e )?(?:o )?(?:status|andamento)(?: da tarefa)?',
    r'status',
    r'what are you doing',
    r'are you still (?:working|there|busy)',
    r"what'?s (?:the )?status",
  ])) {
    return const StatusQuery();
  }
  if (_any(text, [
    r'(?:pare|para|parar) (?:todas as tarefas|tudo|todos os trabalhos)',
    r'(?:cancele|cancela|cancelar) (?:todas as tarefas|tudo)',
    r'stop (?:all tasks|everything)',
    r'cancel (?:all tasks|everything)',
  ])) {
    return const StopOperation(all: true);
  }
  final cancelAgent = RegExp(r'^(?:cancele|cancela|cancelar|pare|para|stop|cancel) (?:a |the )?tarefa (?:do |da )?(claude|cloud|clod|codex|codecs|antigravity|gemini)$|^(?:cancel|stop) (?:the )?(claude|codex|antigravity) task$')
      .firstMatch(text);
  if (cancelAgent != null) {
    final who = (cancelAgent.group(1) ?? cancelAgent.group(2))!;
    return StopOperation(
      agent: who.startsWith('cod') ? 'codex' : (who.startsWith('c') ? 'claude' : 'antigravity'),
    );
  }
  if (_any(text, [
    r'(?:pare|para|parar|cancele|cancela) (?:o que (?:você )?(?:está|esta|ta|tá) fazendo|isso|a tarefa|o comando)',
    r'stop (?:what you(?: are|.re) doing|that|this|the task)',
    r'cancel (?:that|this|the task|the command)',
  ])) {
    return const StopOperation();
  }
  if (_any(text, [
    r'(?:relate|relata|reporte) o último travamento',
    r'(?:o que|por que) (?:você )?travou.*',
    r'report the last (?:freeze|crash|hang)',
  ])) {
    return DiagnosticsRequest(text, lastFreeze: true);
  }
  if (_any(text, [
    r'(?:faça|faz|gere|gera|crie|cria) (?:um )?(?:relatório|relatorio|diagnóstico|diagnostico).*(?:funcionamento|problema|travamento|falha|lentidão|lentidao|erro).*',
    r'(?:faça|faz|gere|gera) (?:um )?(?:diagnóstico|diagnostico)',
    r'(?:write|make|create) (?:a )?(?:diagnostics? )?report (?:on|about) (?:how you(?: are|.re) working|yourself|your problems).*',
    r'(?:run|make) (?:a )?diagnostics?',
  ])) {
    return DiagnosticsRequest(text);
  }
  return null;
}

final _projectNames = RegExp(r'\b(?:dice ?vtt|dice v ?t ?t|daisvtt|dice btt|dice vt)\b');

LocalIntent? _parseProject(String text, String original) {
  final approve = RegExp(r'^(?:eu )?(?:aprovo|aprovado|aprove|aprova|approve|approved)(?: o| the)?(?: plano| plan)?(?: (?:número |number |versão |version )?(\d+))?(?:\s+(?:mas|but)\s+(.+))?$')
      .firstMatch(text);
  if (approve != null) {
    final changes = approve.group(2);
    return PlanDecision(
      changes == null ? 'approve' : 'changes',
      version: approve.group(1) == null ? null : int.parse(approve.group(1)!),
      changes: changes,
    );
  }
  final reject = RegExp(r'^(?:eu )?(?:rejeito|rejeite|rejeita|recuso|reject)(?: o| the)?(?: plano| plan)?(?: (\d+))?$').firstMatch(text);
  if (reject != null) {
    return PlanDecision('reject', version: reject.group(1) == null ? null : int.parse(reject.group(1)!));
  }
  if (_projectNames.hasMatch(text)) return ProjectRequest('dicevtt', original.trim());
  return null;
}

// What is left of the wake word at the start of the transcript, as Whisper hears
// it: "Jarvis,", "Javis", "vis,", "Carves", "de Arves", "Marvel's".
final _wakeResidue = RegExp(
  r'^\s*(?:(?:hey|ei|oi|ok|de|e|o|a|os)\s+)?'
  r"(?:[a-zà-ú']{0,4}(?:ar|á|a)?[vb][ei]?[sz]|j[aá]r?[vb]is|vis|marvel'?s)"
  r'[\s,.!?:;-]+',
  caseSensitive: false,
);

/// The command without the wake word the recording may have kept.
String stripWakeWord(String text) {
  var result = text.trim();
  final match = _wakeResidue.firstMatch(result);
  // Only a short leading fragment: "visitar o site" must stay intact.
  if (match != null && match.end <= 14 && match.end < result.length) {
    result = result.substring(match.end);
  }
  return result.trim();
}

String _normalize(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[.!?,;:]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

bool _any(String text, List<String> patterns) => patterns.any((p) => RegExp('^(?:$p)\$').hasMatch(text));

// Where the music should play is always the computer; drop the place if spoken.
final _placeSuffix = RegExp(
  r'\s+(?:no|na|on the|on my|in the|pelo|pela)\s+(?:computador|pc|batcomputador|computer|spotify)$',
);
final _playVerb = RegExp(
  r'^(?:toque|toca|tocar|toque a|toca a|coloque|coloca|coloca a|põe|ponha|bota|play|talk|tock|took)\s+(.+)$',
);
final _volume = RegExp(r'^(?:volume|o volume|set the volume|set volume)(?:\s+(?:em|para|pra|to|at|no))?\s+(\d{1,3})(?:\s*(?:%|por cento|percent))?$');

LocalIntent parseCommand(String raw) {
  final full = _normalize(stripWakeWord(raw));
  if (full.isEmpty) return const Dismiss();

  // First what must work while JARVIS is busy: status, stop, report.
  final priority = parsePriority(full);
  if (priority != null) return priority;
  final project = _parseProject(full, stripWakeWord(raw));
  if (project != null) return project;

  // "continue a música no Spotify": the place never changes a music control.
  final text = full.replaceFirst(_placeSuffix, '');
  if (_any(text, [
    r'(?:pause|pausa|pausar|pare|para|parar)(?: a)?(?: (?:música|musica|música no computador|som))?',
    r'pause the music',
    r'stop the music',
  ])) {
    return const MusicControl('pause');
  }
  if (_any(text, [
    r'(?:continue|continua|continuar|retome|retoma|retomar|despause)(?: a)?(?: (?:música|musica))?',
    r'resume(?: the music)?',
    r'(?:play|toca|toque)',
  ])) {
    return const MusicControl('resume');
  }
  if (_any(text, [
    r'(?:próxima|proxima|pula|pular|passa|avança)(?: (?:música|musica|faixa))?',
    r'(?:mude|muda|mudar|troca|troque|trocar)(?: de)?(?: a)? (?:música|musica|faixa)',
    r'outra (?:música|musica)',
    r'(?:next|skip)(?: (?:song|track))?',
    r'change the (?:song|music|track)',
  ])) {
    return const MusicControl('next');
  }
  if (_any(text, [
    r'(?:anterior|volta|voltar|volte)(?: a)?(?: (?:música|musica|faixa))?(?: anterior)?',
    r'(?:música|musica|faixa) anterior',
    r'previous(?: (?:song|track))?',
    r'go back',
  ])) {
    return const MusicControl('previous');
  }
  final volume = _volume.firstMatch(text);
  if (volume != null) {
    return MusicVolume(int.parse(volume.group(1)!).clamp(0, 100));
  }
  if (_any(text, [
    r'(?:leia|ler|lê|le|read|fale|fala|me fale|me fala|diga|diz|mostre|mostra|qual(?: é| e| foi)?)(?: o| a| os| the| me o)? (?:último |ultimo |última |ultima |latest |last )?(?:relatório|relatorio|relatórios|relatorios|report|reports|output|saída|saida|resultado|resposta)(?: (?:do|da|de|dos|das|from|of)(?: o| a)? (?:(?:claude|cloud|clod|claude code|codex|codecs|antigravity|anti gravity|antigravidade|anti gravidade|antigrav|gemini)(?:[\s,]+(?:e |and )?(?:claude|cloud|clod|claude code|codex|codecs|antigravity|anti gravity|antigravidade|anti gravidade|antigrav|gemini))*|cada um|todos|todos os três|todos os tres|três|tres|agentes))?',
    r'(?:último|ultimo) (?:relatório|relatorio|output|resultado) (?:do|da|de) (?:(?:claude|cloud|clod|claude code|codex|codecs|antigravity|anti gravity|antigravidade|anti gravidade|antigrav|gemini)(?:[\s,]+(?:e |and )?(?:claude|cloud|clod|claude code|codex|codecs|antigravity|anti gravity|antigravidade|anti gravidade|antigrav|gemini))*|cada um|todos)',
  ])) {
    if (RegExp(r'\b(?:cada um|todos|três|tres|agentes)\b').hasMatch(text)) {
      return const ReadReport('all');
    }
    final matches = RegExp(
      r'\b(claude code|claude|cloud|clod|codex|codecs|antigravity|anti gravity|antigravidade|anti gravidade|antigrav|gemini)\b',
    ).allMatches(text).map((m) => m.group(1)!).toList();
    final agents = matches.map((who) {
      if (who.startsWith('cod')) return 'codex';
      if (who.startsWith('anti') || who == 'gemini') return 'antigravity';
      return 'claude';
    }).toSet();
    if (agents.length > 1) return const ReadReport('all');
    return ReadReport(agents.isEmpty ? null : agents.first);
  }
  if (_any(text, [
    r'(?:leia|ler|lê|le|read)(?: a| as| the| me a)? (?:última |ultima |last |new )?(?:mensagem|mensagens|message|messages)',
  ])) {
    return const ReadMessage();
  }
  if (_any(text, [
    r'(?:pare|para|parar) de (?:ouvir|escutar)',
    r'stop listening',
  ])) {
    return const StopListening();
  }
  if (_any(text, [r'(?:nada|esquece|deixa pra lá|deixa|cancela|cancelar|never mind|nevermind|cancel|nothing)'])) {
    return const Dismiss();
  }
  final play = _playVerb.firstMatch(full);
  if (play != null) {
    final query = play.group(1)!.replaceFirst(_placeSuffix, '').trim();
    if (query.isNotEmpty && !RegExp(r'^(?:no|na|on)\s').hasMatch(query)) {
      return MusicPlay(query);
    }
  }
  return AskJarvis(stripWakeWord(raw));
}
