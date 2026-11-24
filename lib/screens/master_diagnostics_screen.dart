import 'dart:convert';

import 'package:flutter/material.dart';
import '../companion_mode.dart';

import '../master/master_ctrl.dart';
import '../master/models.dart';

/// What works on the master phone and why something does not: coverage of each
/// coding agent host, the PC outbox, the event stream, the voice and permissions.
class MasterDiagnosticsScreen extends StatefulWidget {
  const MasterDiagnosticsScreen({super.key, required this.master});

  final MasterCtrl master;

  @override
  State<MasterDiagnosticsScreen> createState() => _MasterDiagnosticsScreenState();
}

class _MasterDiagnosticsScreenState extends State<MasterDiagnosticsScreen> {
  late Future<Map<String, dynamic>> _data = widget.master.diagnostics();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Diagnostics'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => setState(() => _data = widget.master.diagnostics()),
            ),
          ],
        ),
        body: FutureBuilder<Map<String, dynamic>>(
          future: _data,
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
            final data = snapshot.data!;
            final server = (data['server'] as Map?)?.cast<String, dynamic>() ?? const {};
            final desktop = (server['desktop'] as Map?)?.cast<String, dynamic>() ?? const {};
            final outbox = (desktop['outbox'] as Map?)?.cast<String, dynamic>();
            final coverage = (server['coverage'] as List?)?.cast<Map>() ?? const [];
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const _Heading('Device'),
                _Row('ID', '${data['device_id'] ?? 'not paired'}'),
                _Row('Role', data['companion'] == true ? 'Companion' : 'Master'),
                _Row('Work access', '${data['work_access']}'),
                const _Heading('Voice on this phone'),
                _Row('State', '${data['voice']}'),
                _Row('Microphone open', '${data['microphone_open']}'),
                _Row('Audio chunks / peak', '${data['audio_chunks']} / ${data['audio_peak']}'),
                _Row('Last audio', '${data['last_audio_at'] ?? 'none'}'),
                _Row('Last action', '${data['last_action'] ?? 'none'}'),
                _Row('Transcription', data['stt_mode'] == 'cloud' ? 'cloud voice (not offline)' : 'on the phone (offline)'),
                _Row('Last transcription', data['last_transcription_ms'] == null ? '—' : '${data['last_transcription_ms']} ms'),
                _Row('Speech voice', '${data['tts_voice'] ?? 'default'}'),
                _Row('Voice works offline', '${data['tts_offline'] ?? 'unknown'}'),
                const _Heading('Reports'),
                _Row('Event stream', '${data['event_stream']}'),
                _Row('Last event received', '${data['last_event_at'] ?? '—'}'),
                _Row('Open streams on the server', '${server['event_streams'] ?? '—'}'),
                if (server['error'] != null) _Row('Server', '${server['error']}'),
                const _Heading('Computer'),
                _Row('Connected', '${desktop['online'] ?? '—'} ${desktop['device'] ?? ''}'),
                _Row(
                  'Outbox',
                  outbox == null
                      ? 'no report from the PC yet'
                      : '${outbox['pending']} pending${outbox['saturated'] == true ? ' · BACKED UP' : ''}',
                ),
                const _Heading('Completion alerts by app'),
                if (coverage.isEmpty)
                  const Text('No events yet. Finish a turn in each app (CLI, VS Code…) to confirm its alerts work.'),
                for (final row in coverage)
                  _Row(
                    '${row['agent']} · ${row['host']}',
                    '${row['kind']}: ${row['events']}, last ${formatLocal(DateTime.fromMillisecondsSinceEpoch(((row['last_at'] as num) * 1000).round()), withDate: true)}',
                  ),
                const Text(
                  'An app missing from this list has no working completion alerts: '
                  'Completion alerts unavailable for it until its hooks or adapter are set up.',
                  style: TextStyle(fontSize: 12),
                ),
                const _Heading('Android'),
                _Row('Notification access', '${data['notification_access']}'),
                _Row('Battery optimisation', data['battery_optimized'] == true ? 'on (may stop JARVIS)' : 'off'),
                Wrap(spacing: 8, children: [
                  if (!companionMode) OutlinedButton(onPressed: widget.master.openSocialSettings, child: const Text('Notification access')),
                  OutlinedButton(onPressed: widget.master.requestBatteryExemption, child: const Text('Battery: always on')),
                ]),
                if (!companionMode) ...[
                  const _Heading('Message notifications seen (metadata)'),
                  SelectableText(const JsonEncoder.withIndent('  ').convert(data['message_channels'] ?? [])),
                ],
              ],
            );
          },
        ),
      );
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 6),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      );
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 170, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500))),
            Expanded(child: SelectableText(value)),
          ],
        ),
      );
}
