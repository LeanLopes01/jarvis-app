import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../services/jarvis_api.dart';

const _states = {
  'ready': 'pronto',
  'loading': 'carregando',
  'unloaded': 'sob demanda',
  'not_configured': 'não configurado',
  'error': 'erro',
  'running': 'ativo',
  'stopped': 'parado',
  'queued': 'na fila',
  'completed': 'concluído',
  'failed': 'falhou',
  'cancelled': 'cancelado',
  'interrupted': 'interrompido',
  'documents_recovering': 'recuperando documentos',
};

String _label(Object? state) => _states['$state'] ?? '${state ?? '—'}';

/// Projects → DiceVTT knowledge: the RAG on the primary PC. Search returns the current
/// C# scripts and the collected documentation with their origin; the local model
/// (AirLLM on the PC's CPU) answers in a few minutes.
class KnowledgeScreen extends StatefulWidget {
  const KnowledgeScreen({super.key, required this.api});

  final JarvisApi api;

  @override
  State<KnowledgeScreen> createState() => _KnowledgeScreenState();
}

class _KnowledgeScreenState extends State<KnowledgeScreen> {
  static const _uuid = Uuid();
  final _query = TextEditingController();
  Map<String, dynamic>? _health;
  Map<String, dynamic>? _retrieval;
  Map<String, dynamic>? _ask;
  String? _error;
  String? _askId;
  String? _pendingQuery;
  String? _pendingRequestId;
  bool _busy = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _query.dispose();
    super.dispose();
  }

  String _message(Object error) => error is JarvisCommandException
      ? error.message
      : error is JarvisApiException
          ? error.userMessage
          : '$error';

  Future<void> _refresh() async {
    try {
      final health = await widget.api.ragHealth();
      if (!mounted) return;
      setState(() {
        _health = health;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _health = null;
        _error = _message(error);
      });
    }
  }

  Future<void> _search() async {
    final query = _query.text.trim();
    if (query.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.api.ragRetrieve(query);
      if (mounted) setState(() => _retrieval = result);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startAsk() async {
    final query = _query.text.trim();
    if (query.isEmpty || _busy) return;
    if (_pendingQuery != query) {
      _pendingQuery = query;
      _pendingRequestId = _uuid.v4();
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final created = await widget.api.ragAsk(query, requestId: _pendingRequestId!);
      _pendingQuery = null;
      _askId = created['ask_id'] as String?;
      setState(() => _ask = created);
      _follow();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _follow() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) async {
      final id = _askId;
      if (id == null) return;
      try {
        final state = await widget.api.ragAskStatus(id);
        if (!mounted) return;
        setState(() => _ask = state);
        if (!{'queued', 'running'}.contains(state['state'])) _poll?.cancel();
      } catch (error) {
        if (mounted) setState(() => _error = _message(error));
      }
    });
  }

  Future<void> _cancel() async {
    final id = _askId;
    if (id == null) return;
    try {
      await widget.api.ragAskCancel(id);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final rag = _health?['rag'] as Map<String, dynamic>?;
    final index = rag?['index'] as Map<String, dynamic>?;
    final model = rag?['model'] as Map<String, dynamic>?;
    final online = _health?['online'] == true;
    final asking = _ask != null && {'queued', 'running'}.contains(_ask!['state']);
    return Scaffold(
      appBar: AppBar(title: const Text('Conhecimento · DiceVTT')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
          children: [
            Card(
              child: ListTile(
                leading: Icon(online ? Icons.cloud_done : Icons.cloud_off, color: online ? Colors.greenAccent : Colors.orange),
                title: Text(online ? 'RAG do PC conectado' : 'RAG do PC desligado'),
                subtitle: Text(online
                    ? '${index?['code_pointers'] ?? 0} scripts · ${index?['document_chunks'] ?? 0} trechos de '
                        '${index?['documents'] ?? 0} documentos · índice ${_label(index?['state'])} · '
                        'modelo ${_label(model?['state'])}'
                    : _error ?? 'Ligue o helper no BATCOMPUTADOR (iniciar-tudo.cmd).'),
                trailing: IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _query,
              minLines: 2,
              maxLines: 5,
              maxLength: 2000,
              decoration: const InputDecoration(
                hintText: 'Ex.: como o SteamLobbyManager cria o lobby?',
                border: OutlineInputBorder(),
              ),
            ),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                onPressed: online && !_busy ? _search : null,
                icon: const Icon(Icons.search),
                label: const Text('Buscar fontes'),
              ),
              OutlinedButton.icon(
                onPressed: online && !_busy && !asking && model?['state'] != 'not_configured' ? _startAsk : null,
                icon: const Icon(Icons.smart_toy_outlined),
                label: const Text('Perguntar ao modelo do PC'),
              ),
            ]),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Buscar é rápido. A resposta do modelo local roda no CPU do PC e leva alguns minutos.',
                  style: TextStyle(fontSize: 12, color: Colors.white60)),
            ),
            if (_error != null && online)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: Colors.orange))),
            if (_ask != null) ..._answer(asking),
            if (_retrieval != null) ...[
              const SizedBox(height: 16),
              Text('Fontes encontradas', style: Theme.of(context).textTheme.titleMedium),
              ..._warnings(_retrieval!['warnings']),
              ..._sources(_retrieval!['sources']),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _answer(bool asking) {
    final ask = _ask!;
    final progress = ask['progress'] as Map<String, dynamic>?;
    final result = ask['result'] as Map<String, dynamic>?;
    return [
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: Text('Resposta do modelo local', style: Theme.of(context).textTheme.titleMedium)),
        Chip(label: Text(_label(ask['state']))),
      ]),
      if (asking)
        ListTile(
          leading: const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
          title: Text('${progress?['message'] ?? 'Na fila de geração…'}'),
          subtitle: progress == null ? null : Text('${((progress['elapsed_ms'] as num) / 1000).round()} s'),
          trailing: TextButton(onPressed: _cancel, child: const Text('Cancelar')),
        ),
      if (ask['error'] != null) Text('${ask['error']}', style: const TextStyle(color: Colors.orange)),
      if (result != null) ...[
        SelectableText('${result['answer']}'),
        const SizedBox(height: 6),
        Text('${result['model']} · ${result['generated_tokens']} tokens · '
            '${(((result['timings_ms'] as Map?)?['total'] as num? ?? 0) / 1000).round()} s',
            style: const TextStyle(fontSize: 12, color: Colors.white60)),
        ..._warnings(result['warnings']),
        ..._sources(result['sources']),
      ],
    ];
  }

  List<Widget> _warnings(Object? items) => [
        for (final warning in (items as List? ?? const []))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('⚠ $warning', style: const TextStyle(fontSize: 12, color: Colors.amber)),
          ),
      ];

  List<Widget> _sources(Object? items) => [
        for (final raw in (items as List? ?? const []))
          Builder(builder: (context) {
            final source = raw as Map<String, dynamic>;
            final provenance = (source['provenance'] as Map?)?.cast<String, dynamic>() ?? const {};
            final code = source['kind'] == 'code_pointer';
            final lines = source['lines'] as List?;
            final details = [
              code ? 'Script C#' : 'Documentação',
              if (source['section'] != null) '› ${source['section']}',
              if (lines != null) 'linhas ${lines[0]}-${lines[1]}',
              if (source['scope'] != null) 'prompt: ${source['scope']}',
              'sha256 ${'${source['hash']}'.substring(0, 10)}',
            ].join(' · ');
            return Card(
              child: ExpansionTile(
                leading: Icon(code ? Icons.code : Icons.description_outlined),
                title: Text('[${source['id']}] ${source['relpath']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(details, style: const TextStyle(fontSize: 11)),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: [
                  if (provenance['source_url'] != null)
                    Align(alignment: Alignment.centerLeft, child: SelectableText('Fonte: ${provenance['source_url']}')),
                  if (provenance['extracted_at'] != null)
                    Align(alignment: Alignment.centerLeft, child: Text('Extraído em ${provenance['extracted_at']}')),
                  if ((source['read_at'] ?? '') != '')
                    Align(alignment: Alignment.centerLeft, child: Text('Lido do disco em ${source['read_at']}')),
                  const SizedBox(height: 6),
                  SelectableText('${source['text'] ?? ''}',
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                ],
              ),
            );
          }),
      ];
}
