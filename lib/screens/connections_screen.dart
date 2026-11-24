import 'dart:async';
import 'package:flutter/material.dart';
import '../services/jarvis_api.dart';

const _serviceNames = {
  'calendar': 'Calendários',
  'drive': 'Drive',
  'gmail': 'Gmail',
  'mail': 'E-mails',
  'tasks': 'Tarefas',
};

const _connectionStates = {
  'setup_required': 'Aguardando configuração e autorização',
  'authorizing': 'Aguardando autorização no provedor',
  'connected': 'Conectada',
  'partial': 'Conectada parcialmente — confira os serviços',
  'expired': 'Autorização expirada',
  'error': 'Falha na conexão',
  'paused': 'Pausada',
  'disconnected': 'Desconectada',
};

/// Both phone variants share this screen and the server's versioned preferences.
class ConnectionsScreen extends StatefulWidget {
  const ConnectionsScreen({super.key, required this.api});
  final JarvisApi api;

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  String _message(Object error) {
    if (error is JarvisApiException) return error.userMessage;
    if (error is JarvisCommandException) return error.message;
    return 'Não foi possível carregar as conexões. Tente novamente.';
  }

  Map<String, dynamic> _validate(Map<String, dynamic> data) {
    if (data['schema_version'] != 1 || data['accounts'] is! List) {
      throw JarvisCommandException('unsupported_version', 'Atualize o aplicativo para usar esta versão das conexões.');
    }
    return data;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _data = null;
    });
    try {
      final data = _validate(await widget.api.integrations());
      if (mounted) setState(() => _data = data);
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(Map<String, dynamic> account, Map<String, dynamic> changes) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final data = _validate(
          await widget.api.updateIntegration(account['id'] as String, {...changes, 'revision': account['revision']}));
      if (mounted) {
        setState(() => _data = data);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Preferências salvas no servidor.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_message(e))));
        await _load();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit(Map<String, dynamic> account) async {
    var name = account['label'] as String;
    final services = List<String>.from(account['services'] as List);
    final options = account['provider'] == 'google' ? ['calendar', 'drive', 'gmail'] : List<String>.from(services);
    final changes = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => AlertDialog(
                title: const Text('Preferências da conta'),
                content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextFormField(
                      initialValue: name,
                      onChanged: (value) => update(() => name = value),
                      maxLength: 60,
                      decoration: const InputDecoration(labelText: 'Apelido', hintText: 'Ex.: Pessoal ou Trabalho')),
                  for (final service in options)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(_serviceNames[service] ?? service),
                      value: services.contains(service),
                      onChanged: (value) => update(() {
                        value == true ? services.add(service) : services.remove(service);
                      }),
                    ),
                  if (options.contains('gmail'))
                    const Text(
                        'Gmail pode ser selecionado em uma das duas contas. Para trocar, desmarque na outra primeiro.'),
                ])),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
                  FilledButton(
                      onPressed: services.isEmpty || name.trim().isEmpty
                          ? null
                          : () {
                              Navigator.pop(ctx, {'label': name.trim(), 'services': services});
                            },
                      child: const Text('Salvar')),
                ],
              )),
    );
    if (changes != null && mounted) await _save(account, changes);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Conexões'), actions: [
          IconButton(
              tooltip: 'Atualizar', onPressed: _loading || _saving ? null : _load, icon: const Icon(Icons.refresh)),
        ]),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!, textAlign: TextAlign.center),
                            const SizedBox(height: 16),
                            FilledButton(onPressed: _load, child: const Text('Tentar novamente')),
                          ],
                        )))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(16),
                      children: [
                        Text('Suas contas no Jarvis', style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: 8),
                        const Text(
                            'Defina os apelidos e os serviços que deseja usar. As preferências são compartilhadas entre seus aparelhos.'),
                        const SizedBox(height: 16),
                        Card(
                            child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  const Text('Configuração inicial', style: TextStyle(fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 8),
                                  Text(_data?['message'] as String? ?? 'Aguardando configuração.'),
                                  const SizedBox(height: 8),
                                  const Text(
                                      'Salvar preferências não conecta uma conta. Os logins serão autorizados no Google, Microsoft e Notion; nenhuma senha é solicitada aqui.'),
                                ]))),
                        for (final raw in _data?['accounts'] as List? ?? [])
                          _accountCard(Map<String, dynamic>.from(raw as Map)),
                        const SizedBox(height: 16),
                        const Text('Como será usado', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        const Text(
                            'Depois de autorizar as contas, você poderá consultar agendas, buscar arquivos e e-mails e acompanhar tarefas. Esta etapa prepara consultas de leitura.'),
                        const SizedBox(height: 12),
                        const Text(
                            'As credenciais ficam no seu servidor. Os trechos consultados para responder podem ser enviados ao modelo de IA usado pelo Jarvis.'),
                      ],
                    )),
      );

  Widget _accountCard(Map<String, dynamic> account) {
    final enabled = account['enabled'] == true;
    final services = List<String>.from(account['services'] as List);
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(account['label'] as String),
                subtitle: Text(!enabled ? 'Pausada' : _connectionStates[account['status']] ?? 'Estado não informado'),
                value: enabled,
                onChanged: _saving ? null : (value) => _save(account, {'enabled': value}),
              ),
              Wrap(
                  spacing: 6,
                  children: [for (final service in services) Chip(label: Text(_serviceNames[service] ?? service))]),
              TextButton.icon(
                  onPressed: _saving ? null : () => _edit(account),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Editar preferências')),
            ])));
  }
}
