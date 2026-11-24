import 'package:flutter/material.dart';

import '../master/master_ctrl.dart';
import '../master/models.dart';

/// One agent report in full: the final answer as the agent wrote it (secrets
/// removed on the PC), with the request and the files it changed.
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key, required this.master, required this.event});

  final MasterCtrl master;
  final AgentEvent event;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  late final Future<String?> _report = widget.master.fullReport(widget.event);

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final files = (event.data['files_changed'] as List?)?.cast<String>() ?? const [];
    final request = event.data['request'] as String?;
    return Scaffold(
      appBar: AppBar(title: Text(event.agentName)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(event.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          _Field('When', '${formatLocal(event.when, withDate: true)} (São Paulo)'),
          _Field('Status', switch (event.status) {
            'turn_completed' => 'Finished its response (the turn ended; not proof that every step succeeded)',
            'interrupted' => 'Interrupted',
            'failed' => 'Stopped with an error',
            'approval' => 'Waiting for your approval',
            'question' => 'Waiting for your answer',
            final other => other ?? 'Unknown',
          }),
          _Field('Where', [event.host ?? 'unknown app', event.project ?? 'unknown project'].join(' · ')),
          if (event.startedAt != null)
            _Field(
              'Started',
              formatLocal(DateTime.fromMillisecondsSinceEpoch((event.startedAt! * 1000).round()), withDate: true),
            ),
          if (event.data['continued_after_hook'] == true) const _Field('Note', 'It continued after a stop hook.'),
          if (event.data['tool'] != null) _Field('Tool', '${event.data['tool']} ${event.data['detail'] ?? ''}'),
          if (request != null) _Field('Request', request),
          if (files.isNotEmpty) _Field('Files changed', files.join(', ')),
          const Divider(height: 32),
          FutureBuilder<String?>(
            future: _report,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) return Text('Could not load the report: ${snapshot.error}');
              return SelectableText(snapshot.data ?? 'No report text.');
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              FilledButton.icon(
                onPressed: () => widget.master.readReport(event),
                icon: const Icon(Icons.volume_up),
                label: const Text('Read report'),
              ),
              const SizedBox(width: 8),
              if (!event.read)
                OutlinedButton(
                  onPressed: () async {
                    await widget.master.markRead(event);
                    if (context.mounted) setState(() {});
                  },
                  child: const Text('Mark as read'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.w600)),
          TextSpan(text: value),
        ])),
      );
}
