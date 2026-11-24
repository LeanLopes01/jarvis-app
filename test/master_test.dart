import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/master/command_router.dart';
import 'package:voice_assistant/master/models.dart';
import 'package:voice_assistant/master/phrases.dart';

AgentEvent event({String? status, String agent = 'codex', String? project = 'site', String kind = 'agent_finished'}) =>
    AgentEvent(
      id: 'e1',
      cursor: '1',
      kind: kind,
      status: status,
      agent: agent,
      host: 'CLI',
      project: project,
      title: 't',
      summary: 's',
      hasReport: true,
      createdAt: 0,
      finishedAt: null,
      data: const {},
    );

SocialMessage message(String app, String? sender, {String? text = 'oi'}) => SocialMessage(
      key: '$app$sender',
      app: app,
      sender: sender,
      conversation: null,
      text: text,
      postedAt: 0,
    );

void main() {
  group('wake word left in the transcript', () {
    test('is removed when it starts the command', () {
      expect(stripWakeWord('Jarvis, you there?'), 'you there?');
      expect(stripWakeWord('vis, talk back in black do acdc.'), 'talk back in black do acdc.');
      expect(stripWakeWord('Javis, Talk Back in Black do ACDC.'), 'Talk Back in Black do ACDC.');
      expect(stripWakeWord('de Arves, Leia o Relatório do Clod.'), 'Leia o Relatório do Clod.');
      expect(stripWakeWord("Marvel's Médio a música."), 'Médio a música.');
    });

    test('keeps ordinary words', () {
      expect(stripWakeWord('Toque backing black do acdc.'), 'Toque backing black do acdc.');
      expect(stripWakeWord('visitar o site da USP'), 'visitar o site da USP');
      expect(stripWakeWord('Jarvis'), 'Jarvis');
    });
  });

  group('local commands', () {
    T parsed<T extends LocalIntent>(String text) {
      final intent = parseCommand(text);
      expect(intent, isA<T>(), reason: '"$text" gave $intent');
      return intent as T;
    }

    test('music controls, in Portuguese and English', () {
      expect(parsed<MusicControl>('Jarvis, mude a música').action, 'next');
      expect(parsed<MusicControl>('próxima').action, 'next');
      expect(parsed<MusicControl>('Skip.').action, 'next');
      expect(parsed<MusicControl>('pausa a música').action, 'pause');
      expect(parsed<MusicControl>('Pause.').action, 'pause');
      expect(parsed<MusicControl>('continua').action, 'resume');
      expect(parsed<MusicControl>('música anterior').action, 'previous');
      expect(parsed<MusicVolume>('volume 30').percent, 30);
      expect(parsed<MusicVolume>('volume para 150 por cento').percent, 100);
    });

    test('play requests keep the query and drop the place', () {
      expect(parsed<MusicPlay>('Toque Back in Black do AC DC.').query, 'back in black do ac dc');
      expect(parsed<MusicPlay>('talk back in black').query, 'back in black');
      expect(parsed<MusicPlay>('toca Legião Urbana no computador').query, 'legião urbana');
    });

    test('reports, messages and listening', () {
      expect(parsed<ReadReport>('Leia o relatório do Claude.').agent, 'claude');
      expect(parsed<ReadReport>('leia o relatório do Clod').agent, 'claude');
      expect(parsed<ReadReport>('read the report from codex').agent, 'codex');
      expect(parsed<ReadReport>('leia o relatório').agent, isNull);
      expect(parsed<ReadReport>('Jarvis, qual o último relatório do Antigravity').agent, 'antigravity');
      expect(parsed<ReadReport>('qual é o último relatório do Claude').agent, 'claude');
      expect(parsed<ReadReport>('qual foi o último relatório do Codex').agent, 'codex');
      expect(parsed<ReadReport>('qual o último relatório de cada um').agent, 'all');
      expect(parsed<ReadReport>('qual o último relatório do claude, codex e antigravity').agent, 'all');
      expect(event(agent: 'antigravity').agentName, 'Antigravity');
      expect(event(agent: 'antigravity').isFinishedTask, isTrue);
      parsed<ReadMessage>('leia a mensagem');
      parsed<ReadMessage>('Read the last message.');
      parsed<StopListening>('pare de ouvir');
      parsed<Dismiss>('esquece');
      parsed<Dismiss>('');
    });

    test('anything else goes to Jarvis as spoken', () {
      expect(parsed<AskJarvis>('Jarvis, you there?').text, 'you there?');
      expect(parsed<AskJarvis>('qual a previsão do tempo amanhã?').text, 'qual a previsão do tempo amanhã?');
      expect(parsed<AskJarvis>('calcule o que sobrou para o beta').text, 'calcule o que sobrou para o beta');
    });
  });

  group('spoken alerts', () {
    test('a finished turn is not called a success', () {
      expect(eventPhrase(event()), 'Codex has finished its response for site, Sir.');
      expect(eventPhrase(event(status: 'interrupted')), 'Codex was interrupted for site, Sir.');
      expect(eventPhrase(event(status: 'approval', agent: 'claude', kind: 'agent_waiting')),
          'Claude Code needs your approval for site, Sir.');
      expect(eventPhrase(event(project: null)), 'Codex has finished its response, Sir.');
    });

    test('project answers and progress are said in their own words', () {
      expect(eventPhrase(event(kind: 'project_reply')), 's');
      expect(eventPhrase(event(kind: 'project_working')), 's');
      final working = event(kind: 'project_working');
      expect(working.isProgress, isTrue);
      expect(working.isFreshProgress(DateTime.fromMillisecondsSinceEpoch(60000)), isTrue);
      expect(working.isFreshProgress(DateTime.fromMillisecondsSinceEpoch(600000)), isFalse);
    });

    test('a burst of reports becomes one sentence', () {
      final burst = List.generate(5, (i) => event(project: 'p$i'));
      expect(eventsPhrase(burst), 'Sir, you have 5 new reports: Codex finished on p0, Codex finished on p1, '
          'Codex finished on p2, and 2 more.');
    });

    test('messages are grouped by app and sender', () {
      expect(messagesPhrase([message('whatsapp', 'Ana')]), 'Sir, you have a new WhatsApp message from Ana.');
      expect(
        messagesPhrase([message('whatsapp', 'Ana'), message('whatsapp', 'Bruno'), message('instagram', null)]),
        'Sir, you have 2 new WhatsApp messages from Ana and Bruno and you have a new Instagram message.',
      );
      expect(readMessagePhrase(message('whatsapp', 'Ana', text: null)),
          'WhatsApp message from Ana. WhatsApp did not show its content.');
    });

    test('reports are cleaned up for speech', () {
      final spoken = speakableReport('## Done\n- Fixed `login.py` in C:\\work\\jarvis\\src\\login.py\n```\ncode\n```\nSee https://x.y');
      expect(spoken, 'Done Fixed login.py in login.py (code omitted) See a link');
      expect(speakableReport('A. ' * 1000).endsWith('The rest of the report is on the screen.'), isTrue);
    });
  });

  group('busy-time commands and projects', () {
    T parsed<T extends LocalIntent>(String text) {
      final intent = parseCommand(text);
      expect(intent, isA<T>(), reason: '"$text" gave $intent');
      return intent as T;
    }

    test('the reported phrase keeps the direct music control', () {
      expect(parsed<MusicControl>('Jarvis, continue a música no Spotify.').action, 'resume');
      expect(parsed<MusicControl>('pause a música no computador').action, 'pause');
      expect(parsed<MusicControl>('próxima música no Spotify').action, 'next');
    });

    test('status, stop and reports', () {
      parsed<StatusQuery>('Jarvis, o que está fazendo?');
      parsed<StatusQuery>('ainda está trabalhando?');
      parsed<StatusQuery>('What are you doing?');
      expect(parsed<StopOperation>('pare o que está fazendo').all, isFalse);
      expect(parsed<StopOperation>('pare todas as tarefas').all, isTrue);
      expect(parsed<StopOperation>('cancele a tarefa do Codex').agent, 'codex');
      expect(parsed<StopOperation>('cancela a tarefa do Clod').agent, 'claude');
      expect(parsed<DiagnosticsRequest>('Faça um relatório sobre seu funcionamento').lastFreeze, isFalse);
      expect(parsed<DiagnosticsRequest>('relate o último travamento').lastFreeze, isTrue);
      // "pare" alone still pauses the music; "pare de ouvir" stops listening.
      expect(parsed<MusicControl>('pare').action, 'pause');
      parsed<StopListening>('pare de ouvir');
    });

    test('project requests and plan decisions', () {
      expect(parsed<ProjectRequest>('Jarvis, quero melhorar o sistema de iniciativa do DiceVTT.').project, 'dicevtt');
      expect(parsed<ProjectRequest>('no dice vtt, corrija a rolagem').text, contains('corrija'));
      expect(parsed<PlanDecision>('Aprovo o plano 3.').version, 3);
      expect(parsed<PlanDecision>('aprovo').decision, 'approve');
      final change = parsed<PlanDecision>('Aprove, mas mantenha a interface atual.');
      expect(change.decision, 'changes');
      expect(change.changes, 'mantenha a interface atual');
      expect(parsed<PlanDecision>('rejeito o plano').decision, 'reject');
    });
  });
}
