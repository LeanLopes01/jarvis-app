import 'package:flutter/material.dart';

import '../master/master_ctrl.dart';
import '../services/jarvis_api.dart';

/// Reports about JARVIS itself, saved in JARVIS-Notas/Relatorios: when, complete or
/// partial, which sources were missing, and the readable summary.
class DiagnosticsReportsScreen extends StatefulWidget {
  const DiagnosticsReportsScreen({super.key, required this.api, required this.master});

  final JarvisApi api;
  final MasterCtrl master;

  @override
  State<DiagnosticsReportsScreen> createState() => _DiagnosticsReportsScreenState();
}

class _DiagnosticsReportsScreenState extends State<DiagnosticsReportsScreen> {
  late Future<List<Map<String, dynamic>>> _reports = widget.api.diagnosticReports();

  void _reload() => setState(() => _reports = widget.api.diagnosticReports());

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Diagnostics reports'),
          actions: [IconButton(onPressed: _reload, icon: const Icon(Icons.refresh))],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            await widget.master.requestDiagnostics(note: 'Requested from the reports screen');
            _reload();
          },
          icon: const Icon(Icons.bug_report_outlined),
          label: const Text('New report'),
        ),
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _reports,
          builder: (context, snapshot) {
            if (snapshot.hasError) return Center(child: Text('Could not load the reports: ${snapshot.error}'));
            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
            final reports = snapshot.data!;
            if (reports.isEmpty) return const Center(child: Text('No reports yet.'));
            return ListView(
              children: [
                for (final r in reports)
                  ListTile(
                    leading: Icon(
                      r['state'] == 'ready'
                          ? Icons.check_circle_outline
                          : r['state'] == 'collecting'
                              ? Icons.hourglass_top
                              : Icons.warning_amber,
                    ),
                    title: Text(r['name'] as String? ?? ''),
                    subtitle: Text([
                      r['state'],
                      if (r['published'] == 1) 'saved in Relatorios' else 'not saved in Nextcloud yet',
                      if ((r['note'] as String?)?.isNotEmpty ?? false) r['note'],
                      ..._missing(r),
                    ].join(' · ')),
                    onTap: r['state'] == 'collecting'
                        ? null
                        : () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => _ReportText(api: widget.api, id: r['id'] as String, name: r['name'] as String),
                            )),
                  ),
              ],
            );
          },
        ),
      );

  static Iterable<String> _missing(Map<String, dynamic> report) {
    final sources = ((report['summary'] as Map?)?['sources'] as List?)?.cast<Map>() ?? const [];
    final gaps = sources.where((s) => s['status'] != 'collected').map((s) => s['source']).toList();
    return gaps.isEmpty ? const [] : ['missing: ${gaps.join(', ')}'];
  }
}

class _ReportText extends StatelessWidget {
  const _ReportText({required this.api, required this.id, required this.name});

  final JarvisApi api;
  final String id;
  final String name;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(name)),
        body: FutureBuilder<String>(
          future: api.diagnosticReportText(id),
          builder: (context, snapshot) {
            if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(snapshot.data!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            );
          },
        ),
      );
}
