import 'dart:async';

import 'package:flutter/material.dart';

import '../master/models.dart';
import '../master/project_ctrl.dart';

String _when(num? seconds) =>
    seconds == null ? '' : formatLocal(DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round()), withDate: true);

const _stateNames = {
  'received': 'Received',
  'planning': 'Planning',
  'awaiting_approval': 'Awaiting approval',
  'needs_input': 'Needs your answer',
  'running': 'Running',
  'reviewing': 'Reviewing results',
  'idle': 'Idle',
  'failed': 'Failed',
};

/// Projects → DiceVTT: the conversations with the coordinator.
class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key, required this.projects});

  final ProjectCtrl projects;

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  final _text = TextEditingController();
  String _filter = '';
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.projects.refreshList());
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
    final conv = await widget.projects.send('dicevtt', text, newConversation: true);
    _text.clear();
    if (conv != null && mounted) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ConversationScreen(projects: widget.projects, conversationId: conv['id'] as String),
      ));
      unawaited(widget.projects.refreshList());
    }
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Projects · DiceVTT')),
        body: ListenableBuilder(
          listenable: widget.projects,
          builder: (context, _) {
            final items = widget.projects.conversations
                .where((c) => _filter.isEmpty || '${c['title']}'.toLowerCase().contains(_filter))
                .toList();
            return Column(
              children: [
                ListTile(
                  leading: Icon(widget.projects.runtimeOnline == true ? Icons.cloud_done : Icons.cloud_off),
                  title: Text(widget.projects.runtimeOnline == true ? 'Orquestrador conectado' : 'Abra o Orquestrador no BATCOMPUTADOR'),
                  subtitle: const Text('Novos pedidos exigem o aplicativo e o helper em execução no PC.'),
                  trailing: IconButton(onPressed: widget.projects.refreshList, icon: const Icon(Icons.refresh)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _text,
                          decoration: const InputDecoration(hintText: 'New request for DiceVTT…'),
                          onSubmitted: (_) => _start(),
                        ),
                      ),
                      IconButton(onPressed: _sending ? null : _start, icon: const Icon(Icons.send)),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextField(
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search conversations'),
                    onChanged: (value) => setState(() => _filter = value.toLowerCase()),
                  ),
                ),
                if (widget.projects.error != null)
                  Padding(padding: const EdgeInsets.all(8), child: Text(widget.projects.error!, style: const TextStyle(color: Colors.orange))),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: widget.projects.refreshList,
                    child: ListView(
                      children: [
                        if (items.isEmpty) const ListTile(title: Text('No conversations yet.')),
                        for (final c in items)
                          ListTile(
                            title: Text('${c['title']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text('${_stateNames[c['state']] ?? c['state']} · ${_when(c['updated_at'] as num?)}'),
                            trailing: c['state'] == 'awaiting_approval' ? const Icon(Icons.pending_actions, color: Colors.orange) : null,
                            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => ConversationScreen(projects: widget.projects, conversationId: c['id'] as String),
                            )),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );
}

/// One conversation: messages, the plan to approve, runs and their reports.
class ConversationScreen extends StatefulWidget {
  const ConversationScreen({super.key, required this.projects, required this.conversationId});

  final ProjectCtrl projects;
  final String conversationId;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> with WidgetsBindingObserver {
  final _text = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.projects.follow(widget.conversationId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the background: the plan may have changed or been decided elsewhere.
    if (state == AppLifecycleState.resumed) widget.projects.follow(widget.conversationId);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.projects.unfollow();
    _text.dispose();
    super.dispose();
  }

  Future<void> _send([String? override]) async {
    final text = (override ?? _text.text).trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      await widget.projects.send('dicevtt', text, conversationId: widget.conversationId);
      _text.clear();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _requestChanges(Map<String, dynamic> plan) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Request changes to plan ${plan['version']}'),
        content: TextField(controller: controller, autofocus: true, maxLines: 4),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Send')),
        ],
      ),
    );
    if (text != null && text.trim().isNotEmpty) await _send('Alteração pedida para o plano ${plan['version']}: $text');
  }

  static Map<String, dynamic>? _previousPlan(List<Map<String, dynamic>> plans, Map<String, dynamic> plan) {
    final index = plans.indexOf(plan);
    return index > 0 ? plans[index - 1] : null;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: ListenableBuilder(
            listenable: widget.projects,
            builder: (_, __) => Text('${widget.projects.current?['title'] ?? 'Conversation'}', overflow: TextOverflow.ellipsis),
          ),
        ),
        body: ListenableBuilder(
          listenable: widget.projects,
          builder: (context, _) {
            final conv = widget.projects.current;
            if (conv == null || conv['id'] != widget.conversationId) {
              return const Center(child: CircularProgressIndicator());
            }
            final messages = (conv['messages'] as List).cast<Map<String, dynamic>>();
            final plans = (conv['plans'] as List).cast<Map<String, dynamic>>();
            final runs = (conv['runs'] as List).cast<Map<String, dynamic>>();
            // The plan to decide is the newest one still proposed, not just the last row.
            final latestPlan = plans.isEmpty
                ? null
                : plans.lastWhere((p) => p['state'] == 'proposed', orElse: () => plans.last);
            final projects = widget.projects;
            return Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  color: Colors.orange.withValues(alpha: 0.08),
                  child: Text('State: ${_stateNames[conv['state']] ?? conv['state']}'),
                ),
                if (projects.error != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    color: Colors.red.withValues(alpha: 0.08),
                    child: Text('Sem atualização do servidor; mostrando o último estado recebido. (${projects.error})',
                        style: const TextStyle(fontSize: 12)),
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      for (final m in messages) _MessageBubble(message: m),
                      if (latestPlan != null)
                        _PlanCard(
                          plan: latestPlan,
                          previous: _previousPlan(plans, latestPlan),
                          busy: projects.decidingPlanId != null,
                          error: projects.decisionPlanId == latestPlan['id'] ? projects.decisionError : null,
                          notice: projects.decisionPlanId == latestPlan['id'] ? projects.decisionNotice : null,
                          runtimeOnline: projects.runtimeOnline,
                          onApprove: () => projects.decide(latestPlan, 'approve'),
                          onReject: () => projects.decide(latestPlan, 'reject'),
                          onChanges: () => _requestChanges(latestPlan),
                        ),
                      for (final run in runs) _RunCard(run: run, projects: projects),
                      for (final job in (conv['jobs'] as List? ?? const []))
                        _JobTile(job: (job as Map).cast<String, dynamic>()),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 4, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _text,
                            enabled: !_sending && conv['state'] != 'planning',
                            decoration: InputDecoration(
                              hintText: conv['state'] == 'planning' ? 'Antigravity is preparing an answer…' : 'Message',
                            ),
                            onSubmitted: (_) => _send(),
                          ),
                        ),
                        IconButton(onPressed: _sending ? null : _send, icon: const Icon(Icons.send)),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});
  final Map<String, dynamic> message;

  @override
  Widget build(BuildContext context) {
    final mine = message['role'] == 'user';
    final system = message['role'] == 'system';
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: mine ? scheme.primary : (system ? Colors.transparent : scheme.surfaceContainerHighest),
          border: system ? Border.all(color: Theme.of(context).dividerColor) : null,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${message['author']} · ${_when(message['created_at'] as num?)}',
                style: TextStyle(fontSize: 11, color: mine ? scheme.onPrimary.withValues(alpha: 0.7) : Theme.of(context).hintColor)),
            SelectableText('${message['text']}', style: TextStyle(color: mine ? scheme.onPrimary : null)),
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.previous,
    required this.busy,
    required this.error,
    required this.notice,
    required this.runtimeOnline,
    required this.onApprove,
    required this.onReject,
    required this.onChanges,
  });

  final Map<String, dynamic> plan;
  final Map<String, dynamic>? previous;
  final bool busy;
  final String? error;
  final String? notice;
  final bool? runtimeOnline;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onChanges;

  static const _tall = ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(64, 48)));

  Widget _banner(String text, Color color, IconData icon) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          border: Border.all(color: color.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: SelectableText(text)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final body = (plan['body'] as Map).cast<String, dynamic>();
    final tasks = (body['tasks'] as List).cast<Map>();
    final pending = plan['state'] == 'proposed';
    final previousTasks = ((previous?['body'] as Map?)?['tasks'] as List?)?.cast<Map>().map((t) => t['title']).toSet() ?? {};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Plan ${plan['version']} · ${plan['state']} · ${plan['hash']}',
                style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            Text('${body['title']}', style: Theme.of(context).textTheme.titleMedium),
            Text('${body['goal']}'),
            if ('${body['summary']}'.isNotEmpty) Text('${body['summary']}', style: TextStyle(color: Theme.of(context).hintColor)),
            const Divider(),
            for (final t in tasks)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: '${t['key']} · ${t['agent']} · ', style: const TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(text: '${t['title']}'),
                  if (previous != null && !previousTasks.contains(t['title']))
                    const TextSpan(text: '  (new)', style: TextStyle(color: Colors.teal)),
                  TextSpan(
                    text: '\n${t['objective']}\nFiles: ${(t['files'] as List).join(', ')}\n'
                        'Acceptance: ${(t['acceptance'] as List).join('; ')}'
                        '${(t['depends_on'] as List).isEmpty ? '' : '\nAfter: ${(t['depends_on'] as List).join(', ')}'}',
                    style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12),
                  ),
                ])),
              ),
            if ((body['tests'] as List).isNotEmpty) Text('Tests: ${(body['tests'] as List).join('; ')}'),
            if ((body['risks'] as List).isNotEmpty) Text('Risks: ${(body['risks'] as List).join('; ')}'),
            if (pending && runtimeOnline == false)
              _banner('O Orquestrador está fechado no BATCOMPUTADOR: a aprovação será recusada até ele ser aberto.',
                  Colors.orange, Icons.cloud_off),
            if (error != null) _banner(error!, Colors.red, Icons.error_outline),
            if (notice != null) _banner(notice!, Colors.green, Icons.check_circle_outline),
            if (pending) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton(
                    style: _tall,
                    onPressed: busy ? null : onApprove,
                    child: Text('Approve plan ${plan['version']}'),
                  ),
                  OutlinedButton(style: _tall, onPressed: busy ? null : onChanges, child: const Text('Request changes')),
                  TextButton(style: _tall, onPressed: busy ? null : onReject, child: const Text('Reject')),
                  if (busy)
                    const Row(mainAxisSize: MainAxisSize.min, children: [
                      SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 8),
                      Text('Enviando decisão…'),
                    ]),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A job's live telemetry: activity, events, usage when reported. Missing fields
/// stay missing (unknown), never shown as zero.
class _JobTile extends StatelessWidget {
  const _JobTile({required this.job});

  final Map<String, dynamic> job;

  @override
  Widget build(BuildContext context) {
    final progress = (job['progress'] as Map?)?.cast<String, dynamic>() ?? const {};
    final events = ((progress['events'] as List?) ?? const []).cast<Map>();
    final usage = (progress['usage'] as Map?)?.cast<String, dynamic>();
    final hint = TextStyle(color: Theme.of(context).hintColor, fontSize: 12);
    final updated = job['updated_at'] as num?;
    return Card(
      child: ExpansionTile(
        title: Text('${job['agent'] ?? 'Coordenador'} · ${job['state']}'),
        subtitle: Text(
          '${progress['activity'] ?? progress['stage'] ?? 'Aguardando progresso'}'
          '${updated == null ? '' : '\nÚltimo sinal: ${_when(updated)}'}',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (usage != null)
            Text(
              'Uso deste job: ${usage['input_tokens'] ?? '?'} tokens de entrada, '
              '${usage['output_tokens'] ?? '?'} de saída'
              '${usage['model'] == null ? '' : ' · ${usage['model']}'}',
              style: hint,
            ),
          for (final e in events.reversed.take(20))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text.rich(TextSpan(children: [
                TextSpan(text: '${_when(e['at'] as num?)} · ${e['kind']} · ', style: hint),
                TextSpan(text: '${e['text']}'),
              ])),
            ),
          if ('${progress['reasoning_summary'] ?? ''}'.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Resumo de raciocínio', style: Theme.of(context).textTheme.labelMedium),
            SelectableText('${progress['reasoning_summary']}'),
          ],
          for (final key in const ['stderr_tail', 'stdout_tail'])
            if ('${progress[key] ?? ''}'.trim().isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(key == 'stderr_tail' ? 'Erros (stderr)' : 'Saída (stdout)', style: hint),
                children: [
                  SelectableText('${progress[key]}', style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                ],
              ),
        ],
      ),
    );
  }
}

class _RunCard extends StatelessWidget {
  const _RunCard({required this.run, required this.projects});

  final Map<String, dynamic> run;
  final ProjectCtrl projects;

  @override
  Widget build(BuildContext context) {
    final tasks = (run['tasks'] as List).cast<Map>();
    final report = (run['report'] as Map?)?.cast<String, dynamic>();
    final applied = (run['applied'] as Map?)?.cast<String, dynamic>();
    final active = const {'running', 'reviewing', 'cancelling', 'queued'}.contains(run['state']);
    final finished = const {'completed', 'completed_with_issues'}.contains(run['state']);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Run ${(run['id'] as String).substring(0, 8)} · ${run['state']} · on the BATCOMPUTADOR',
                style: Theme.of(context).textTheme.titleSmall),
            for (final t in tasks)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('${t['key']} · ${t['agent']} · ${t['state']}'),
                subtitle: Text('${t['title']}'),
                children: [
                  if (t['result'] != null) ...[
                    SelectableText('${(t['result'] as Map)['text'] ?? (t['result'] as Map)['problem'] ?? ''}'),
                    SelectableText(
                      '${((t['result'] as Map)['changes'] as Map?)?['diff'] ?? ''}',
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    ),
                  ],
                ],
              ),
            if (report != null) ...[
              const Divider(),
              Text('Report: ${report['outcome']}', style: const TextStyle(fontWeight: FontWeight.w600)),
              SelectableText('${report['reply']}'),
              if ((report['verifications'] as List?)?.isNotEmpty ?? false)
                Text('Checked: ${(report['verifications'] as List).join('; ')}'),
              if ((report['pending'] as List?)?.isNotEmpty ?? false)
                Text('Pending: ${(report['pending'] as List).join('; ')}', style: const TextStyle(color: Colors.orange)),
            ],
            if (applied != null)
              Text('Applied: ${(applied['applied'] as List).length} file(s); conflicts: ${(applied['conflicts'] as List).join(', ')}'),
            Wrap(
              spacing: 8,
              children: [
                if (active) OutlinedButton(onPressed: () => projects.cancelRun(run['id'] as String), child: const Text('Stop run')),
                if (finished && applied == null)
                  FilledButton(
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Apply to DiceVTT?'),
                          content: const Text(
                            'The changed files are copied into the real project folder. A file you changed '
                            'since the run started is not overwritten (it is listed as a conflict). Nothing is '
                            'committed to Plastic.',
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apply')),
                          ],
                        ),
                      );
                      if (ok == true) await projects.apply(run['id'] as String);
                    },
                    child: const Text('Apply to DiceVTT'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
