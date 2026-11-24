import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../services/jarvis_api.dart';
import 'master_ctrl.dart';

/// Projects through JARVIS (the first is DiceVTT): the user's requests go to the
/// coordinator on the server, plans come back for approval, runs report at the end.
///
/// Voice: "Jarvis, no DiceVTT, ..." continues the project's latest conversation;
/// "Jarvis, aprovo o plano 2" approves exactly that version. The server checks the
/// version and its hash, so an older plan can never start the newer one's work.
class ProjectCtrl extends ChangeNotifier {
  ProjectCtrl(this._api, this._master) {
    _master
      ..onProjectRequest = request
      ..onPlanDecision = decideByVoice
      ..onActiveRuns = activeSummary
      ..onCancelAgent = cancelAgent
      ..onCancelAllRuns = cancelAll
      ..onProjectEvent = onEvent;
  }

  static final _logger = Logger('ProjectCtrl');
  static const _uuid = Uuid();
  static const _activeKey = 'jarvis_project_conversation';

  final JarvisApi _api;
  final MasterCtrl _master;

  List<Map<String, dynamic>> conversations = [];
  Map<String, dynamic>? current;
  String? error;
  bool? runtimeOnline;
  DateTime? _runtimeCheckedAt;

  /// The plan decision in flight (taps are ignored meanwhile) and the last outcome,
  /// shown on that plan's card until the next decision.
  String? decidingPlanId;
  String? decisionPlanId;
  String? decisionError;
  String? decisionNotice;
  String? _pendingText;
  String? _pendingTarget;
  String? _pendingRequestId;
  Timer? _poll;

  Future<String?> _activeConversation(String project) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_activeKey.$project');
  }

  Future<void> _remember(String project, String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_activeKey.$project', id);
  }

  Future<void> refreshList([String project = 'dicevtt']) async {
    try {
      conversations = await _api.conversations(project);
      runtimeOnline = (await _api.orchestrationRuntime())['online'] == true;
      error = null;
    } catch (e) {
      runtimeOnline = null;
      error = '$e';
    }
    notifyListeners();
  }

  /// A failed refresh keeps what is on screen and says so (error).
  Future<void> open(String id) async {
    try {
      current = await _api.conversation(id);
      error = null;
      if (_hasPendingPlan(current) && _runtimeDue()) {
        // Approval needs the Orquestrador open on the PC: say so before the tap.
        _runtimeCheckedAt = DateTime.now();
        runtimeOnline = (await _api.orchestrationRuntime())['online'] == true;
      }
    } catch (e) {
      error = '$e';
    }
    notifyListeners();
  }

  static bool _hasPendingPlan(Map<String, dynamic>? conv) =>
      ((conv?['plans'] as List?) ?? const []).any((p) => (p as Map)['state'] == 'proposed');

  bool _runtimeDue() =>
      _runtimeCheckedAt == null || DateTime.now().difference(_runtimeCheckedAt!) > const Duration(seconds: 15);

  /// While a conversation is on screen, follow it every few seconds.
  void follow(String id) {
    _poll?.cancel();
    unawaited(open(id));
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => unawaited(open(id)));
  }

  void unfollow() {
    _poll?.cancel();
    _poll = null;
  }

  /// A server event about a project (plan ready, run finished): refresh what is shown.
  void onEvent(String? conversationId) {
    if (conversationId != null && current?['id'] == conversationId) unawaited(open(conversationId));
    unawaited(refreshList());
  }

  /// Text or voice: continue the project's latest conversation, or start one.
  Future<Map<String, dynamic>?> send(String project, String text, {String? conversationId, bool newConversation = false}) async {
    final target = newConversation ? null : (conversationId ?? await _activeConversation(project));
    try {
      if (_pendingText != text || _pendingTarget != target || _pendingRequestId == null) {
        _pendingText = text;
        _pendingTarget = target;
        _pendingRequestId = _uuid.v4();
      }
      final conv = await _api.sendProjectMessage(project, text, conversationId: target, requestId: _pendingRequestId!);
      _pendingRequestId = null;
      await _remember(project, conv['id'] as String);
      current = conv;
      error = null;
      notifyListeners();
      return conv;
    } on JarvisCommandException catch (e) {
      if (e.code == 'not_found' && target != null) {
        return send(project, text, newConversation: true); // the old conversation is gone
      }
      error = e.message;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> request(String project, String text) async {
    unawaited(_master.say('Processing your request, Sir.'));
    try {
      await send(project, text);
    } on JarvisCommandException catch (e) {
      await _master.say(e.code == 'busy' ? "I'm still preparing the previous answer, Sir." : "I couldn't send that to the project, Sir.");
    } catch (e) {
      _logger.warning('project request failed: $e');
      await _master.say("I couldn't reach the server, Sir.");
    }
  }

  /// "Aprovo o plano 3", "rejeito o plano", "aprove, mas mantenha a interface".
  Future<void> decideByVoice(String decision, int? version, String? changes) async {
    List<Map<String, dynamic>> pending;
    try {
      pending = await _api.pendingPlans();
    } catch (_) {
      await _master.say("I couldn't reach the server to check the plans, Sir.");
      return;
    }
    if (version != null) pending = pending.where((p) => p['version'] == version).toList();
    if (pending.isEmpty) {
      await _master.say(version == null ? 'There is no plan waiting for approval, Sir.' : 'Plan $version is not waiting for approval, Sir.');
      return;
    }
    if (pending.length > 1) {
      await _master.say('There are ${pending.length} plans waiting, Sir. Please say which number, or decide on the panel.');
      return;
    }
    final plan = pending.single;
    if (decision == 'changes') {
      await send('dicevtt', 'Alteração pedida para o plano ${plan['version']}: $changes', conversationId: plan['conversation_id'] as String);
      await _master.say("I've asked for a revised plan, Sir. You'll hear when it is ready.");
      return;
    }
    await decide(plan, decision);
  }

  /// Same contract as the web panel: POST /v1/plans/{id}/approve|reject with the
  /// version and hash shown. The screen shows the outcome first; speech never holds it.
  Future<void> decide(Map<String, dynamic> plan, String decision, {String? text}) async {
    if (decidingPlanId != null) return; // a second tap while the first is in flight
    final id = plan['id'] as String;
    final version = plan['version'];
    final cid = plan['conversation_id'] as String? ?? current?['id'] as String?;
    final expected = decision == 'approve' ? 'approved' : 'rejected';
    decidingPlanId = id;
    decisionPlanId = id;
    decisionError = null;
    decisionNotice = null;
    notifyListeners();
    String spoken;
    try {
      await _api.decidePlan(id, decision, version: version as int, hash: plan['hash'] as String, text: text);
      decisionNotice = _decided(expected, version);
      spoken = decision == 'approve'
          ? "Plan $version approved, Sir. I'll tell you when the work is done."
          : 'Plan $version rejected, Sir.';
    } on JarvisCommandException catch (e) {
      decisionError = _decisionProblem(e);
      spoken = 'That plan could not be ${decision}d, Sir. The reason is on the screen.';
    } catch (e) {
      // No answer (timeout, network): the server may have decided anyway. Look
      // before asking for another tap, so nothing is sent twice blindly.
      _logger.warning('plan decision without an answer: $e');
      if (await _savedPlanState(cid, id) == expected) {
        decisionNotice = _decided(expected, version);
        spoken = 'Plan $version is $expected, Sir.';
      } else {
        decisionError = 'Sem resposta do servidor; a decisão não foi confirmada. '
            'Confira a conexão e toque de novo.';
        spoken = "I couldn't reach the server, Sir.";
      }
    } finally {
      decidingPlanId = null;
    }
    if (cid != null) await open(cid); // also notifies
    notifyListeners();
    unawaited(_master.say(spoken));
  }

  static String _decided(String state, Object? version) => state == 'approved'
      ? 'Plano $version aprovado. O trabalho começou no BATCOMPUTADOR.'
      : 'Plano $version rejeitado.';

  static String _decisionProblem(JarvisCommandException e) => switch (e.code) {
        'unauthorized' => 'Este aparelho não está mais pareado com o servidor. Pareie de novo.',
        'work_access_required' || 'not_master' => 'Este aparelho não tem permissão para decidir planos. ${e.message}',
        'orchestrator_offline' => e.message,
        'version_mismatch' || 'changed' || 'not_pending' =>
          'O plano mudou ou já foi decidido; a tela foi atualizada. (${e.message})',
        'rate_limited' => 'Muitas tentativas seguidas. Aguarde um minuto e tente de novo.',
        _ => '${e.message} (${e.code})',
      };

  Future<String?> _savedPlanState(String? conversationId, String planId) async {
    if (conversationId == null) return null;
    try {
      final conv = await _api.conversation(conversationId);
      for (final p in (conv['plans'] as List? ?? const [])) {
        if ((p as Map)['id'] == planId) return p['state'] as String?;
      }
    } catch (_) {}
    return null;
  }

  Future<List<String>> activeSummary() async {
    try {
      final active = await _api.orchestrationActive();
      return active.map((a) {
        if (a['kind'] == 'planning') return 'Antigravity is preparing a plan for ${a['title']}';
        final agent = a['agent'] == null ? 'the project run' : '${a['agent']}';
        return '$agent is working on ${a['task'] ?? 'a task'} (${a['state']})';
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<String> cancelAgent(String agent) async {
    try {
      final stopped = ((await _api.orchestrationCancel(agent: agent))['stopped'] as List?) ?? const [];
      return stopped.isEmpty ? 'There is no $agent task running, Sir' : 'I asked $agent to stop ${stopped.join(', ')}';
    } catch (_) {
      return "I couldn't reach the server to stop $agent";
    }
  }

  Future<int> cancelAll() async {
    try {
      return ((await _api.orchestrationCancel())['runs'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> cancelRun(String runId) async {
    final result = await _api.cancelRun(runId);
    await _master.say(result['state'] == 'cancelled' ? 'The run was stopped, Sir.' : "I've asked the run to stop, Sir.");
    if (current != null) await open(current!['id'] as String);
  }

  Future<Map<String, dynamic>> apply(String runId) async {
    final result = await _api.applyRun(runId);
    if (current != null) await open(current!['id'] as String);
    return result;
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }
}
