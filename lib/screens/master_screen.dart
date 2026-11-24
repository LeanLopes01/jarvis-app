import 'package:flutter/material.dart';
import '../companion_mode.dart';
import 'package:provider/provider.dart';

import '../controllers/app_ctrl.dart';
import '../master/event_stream.dart';
import '../master/master_ctrl.dart';
import '../master/models.dart';
import 'agent_screen.dart';
import 'knowledge_screen.dart';
import 'connections_screen.dart';
import 'updates_screen.dart';
import 'master_diagnostics_screen.dart';
import 'master_landscape.dart';
import 'report_screen.dart';
import 'routines_screen.dart';
import 'projects_screen.dart';

/// The master phone's home: what JARVIS is doing, the music on the computer, the
/// coding agents' reports and the messages, with every other function one tap away.
class MasterScreen extends StatelessWidget {
  const MasterScreen({super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        // Lying on its side (the usual case): limits, voice and buttons in a row.
        builder: (context, box) => !companionMode && box.maxWidth > box.maxHeight
            ? const MasterLandscape()
            : Selector<AppCtrl, bool>(
                selector: (_, app) => app.appScreenState == AppScreenState.agent,
                builder: (_, inCall, __) => inCall ? const AgentScreen() : const _Portrait(),
              ),
      );
}

class _Portrait extends StatelessWidget {
  const _Portrait();

  @override
  Widget build(BuildContext context) {
    final master = context.watch<MasterCtrl>();
    final app = context.read<AppCtrl>();
    return Material(
      child: SafeArea(
        child: Stack(
          children: [
            RefreshIndicator(
              onRefresh: master.refreshMusic,
              child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _Header(master: master),
              const SizedBox(height: 12),
              _VoiceCard(master: master),
              if (master.problems.isNotEmpty) ...[
                const SizedBox(height: 12),
                _ProblemsCard(master: master),
              ],
              const SizedBox(height: 12),
              _LinksRow(master: master),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                  onPressed: app.jarvisApi == null ? null : () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => UpdatesScreen(api: app.jarvisApi!, master: master))),
                  icon: const Icon(Icons.notifications_active_outlined), label: const Text('Atualizações'),
                ),
                OutlinedButton.icon(
                  onPressed: app.jarvisApi == null ? null : () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => ConnectionsScreen(api: app.jarvisApi!))),
                  icon: const Icon(Icons.link), label: const Text('Conexões'),
                ),
                FilledButton.icon(
                  onPressed: app.projects == null ? null : () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => ProjectsScreen(projects: app.projects!))),
                  icon: const Icon(Icons.folder_open), label: const Text('Projects'),
                ),
                OutlinedButton.icon(
                  onPressed: app.jarvisApi == null ? null : () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => KnowledgeScreen(api: app.jarvisApi!))),
                  icon: const Icon(Icons.menu_book_outlined), label: const Text('Knowledge'),
                ),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) =>
                    Scaffold(appBar: AppBar(title: const Text('AI limits')),
                      body: ListenableBuilder(listenable: master, builder: (_, __) =>
                        Padding(padding: const EdgeInsets.all(16), child: UsagePanel(master: master)))))),
                  icon: const Icon(Icons.speed), label: const Text('AI limits'),
                ),
              ]),
              const SizedBox(height: 12),
              _MusicCard(master: master),
              const SizedBox(height: 20),
              _SectionTitle('Reports', count: master.unreadReports),
              if (master.reports.isEmpty)
                const _Empty('No reports yet. Finished Antigravity, Codex and Claude Code turns appear here.')
              else
                ...master.reports.take(20).map((r) => _ReportCard(master: master, event: r)),
              const SizedBox(height: 20),
              if (!companionMode) ...[
              _SectionTitle(
                'Messages',
                count: master.unreadMessages,
                action: master.messages.isEmpty ? null : TextButton(onPressed: master.clearMessages, child: const Text('Clear')),
              ),
              if (master.messages.isEmpty)
                const _Empty('WhatsApp and Instagram messages received on this phone appear here.')
              else
                ...master.messages.take(15).map((m) => _MessageTile(master: master, message: m)),
              ],
              const SizedBox(height: 20),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: app.isSessionStarting ? null : app.connect,
                    icon: const Icon(Icons.call),
                    label: const Text('Start call'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RoutinesScreen())),
                    icon: const Icon(Icons.alarm),
                    label: const Text('Routines'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => MasterDiagnosticsScreen(master: master))),
                    icon: const Icon(Icons.monitor_heart_outlined),
                    label: const Text('Diagnostics'),
                  ),
                ],
              ),
              if (app.statusMessage != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(app.statusMessage!)),
              if (app.errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(app.errorMessage!, style: const TextStyle(color: Colors.redAccent)),
                ),
            ],
          ),
        ),
            AgentCornerNotifications(master: master),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.master});
  final MasterCtrl master;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('J.A.R.V.I.S', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                Text(companionMode ? 'JARVIS · Companion' : 'Master phone', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.tune),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => ChangeNotifierProvider.value(value: master, child: const _SettingsSheet()),
            ),
          ),
        ],
      );
}

class _VoiceCard extends StatelessWidget {
  const _VoiceCard({required this.master});
  final MasterCtrl master;

  ({IconData icon, String label, Color color}) get _look => switch (master.voice) {
        VoiceState.standby => (icon: Icons.hearing, label: 'Standby · say "Jarvis"', color: Colors.teal),
        VoiceState.listening => (icon: Icons.mic, label: 'Listening', color: Colors.redAccent),
        VoiceState.processing => (icon: Icons.hourglass_top, label: 'Processing', color: Colors.orange),
        VoiceState.speaking => (icon: Icons.record_voice_over, label: 'Speaking', color: Colors.blue),
        VoiceState.inCall => (icon: Icons.graphic_eq, label: 'In a call', color: Colors.blue),
        VoiceState.paused => (icon: Icons.hearing_disabled, label: 'Listening paused', color: Colors.grey),
        VoiceState.preparing => (icon: Icons.downloading, label: 'Starting the on-device voice…', color: Colors.grey),
        VoiceState.unavailable => (icon: Icons.error_outline, label: 'Voice unavailable', color: Colors.redAccent),
        VoiceState.off => (icon: Icons.power_settings_new, label: 'Off', color: Colors.grey),
      };

  @override
  Widget build(BuildContext context) {
    final look = _look;
    final canListen = master.voice == VoiceState.standby || master.voice == VoiceState.paused;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(radius: 26, backgroundColor: look.color.withValues(alpha: 0.15), child: Icon(look.icon, color: look.color, size: 28)),
                const SizedBox(width: 14),
                Expanded(child: Text(look.label, style: Theme.of(context).textTheme.titleMedium)),
              ],
            ),
            if (master.lastHeard != null) ...[
              const SizedBox(height: 10),
              Text('Heard: "${master.lastHeard}"', style: Theme.of(context).textTheme.bodySmall),
            ],
            if (master.lastAction != null)
              Text(master.lastAction!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: master.voice == VoiceState.standby ? master.listenNow : null,
                  icon: const Icon(Icons.mic_none),
                  label: const Text('Tap to speak'),
                ),
                OutlinedButton.icon(
                  onPressed: canListen ? () => master.setListening(!master.settings.listening) : null,
                  icon: Icon(master.settings.listening ? Icons.pause : Icons.play_arrow),
                  label: Text(master.settings.listening ? 'Pause listening' : 'Resume listening'),
                ),
                OutlinedButton.icon(
                  onPressed: () => master.setAnnouncements(!master.settings.announcements),
                  icon: Icon(master.settings.announcements ? Icons.volume_up : Icons.volume_off),
                  label: Text(master.settings.announcements ? 'Pause announcements' : 'Resume announcements'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProblemsCard extends StatelessWidget {
  const _ProblemsCard({required this.master});
  final MasterCtrl master;

  @override
  Widget build(BuildContext context) => Card(
        color: Colors.orange.withValues(alpha: 0.12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final entry in master.problems.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.warning_amber, size: 18, color: Colors.orange),
                      const SizedBox(width: 8),
                      Expanded(child: SelectableText(entry.value)),
                      if (entry.key == 'messages')
                        TextButton(onPressed: master.openSocialSettings, child: const Text('Allow')),
                      if (entry.key == 'voice' || entry.key == 'microphone')
                        TextButton(onPressed: master.start, child: const Text('Retry')),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
}

class _LinksRow extends StatelessWidget {
  const _LinksRow({required this.master});
  final MasterCtrl master;

  @override
  Widget build(BuildContext context) {
    final stream = switch (master.streamState) {
      StreamState.online => ('Reports: live', Colors.teal),
      StreamState.connecting => ('Reports: connecting', Colors.orange),
      StreamState.notMaster => ('Reports: not master', Colors.redAccent),
      StreamState.offline => ('Reports: offline', Colors.redAccent),
    };
    final music = master.music;
    final pc = music == null
        ? ('PC: …', Colors.grey)
        : music.error != null
            ? ('PC: ${music.error}', Colors.redAccent)
            : ('PC: online', Colors.teal);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (label, color) in [stream, pc])
          Chip(
            avatar: Icon(Icons.circle, size: 10, color: color),
            label: Text(label),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

class _MusicCard extends StatelessWidget {
  const _MusicCard({required this.master});
  final MasterCtrl master;

  @override
  Widget build(BuildContext context) {
    final music = master.music;
    final where = music == null || music.error != null
        ? 'Music plays only on the BATCOMPUTADOR'
        : music.onComputer
            ? (music.isPlaying ? 'Playing on BATCOMPUTADOR' : 'Paused on BATCOMPUTADOR')
            : 'Spotify is on ${music.device ?? 'another device'} · JARVIS moves it back to the BATCOMPUTADOR';
    final offline = music?.error != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.music_note),
                const SizedBox(width: 8),
                Expanded(child: Text(where, style: Theme.of(context).textTheme.titleSmall)),
                IconButton(onPressed: master.refreshMusic, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
              ],
            ),
            if (music?.track != null)
              Padding(padding: const EdgeInsets.only(left: 32), child: Text(music!.track!, maxLines: 2, overflow: TextOverflow.ellipsis)),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                    onPressed: offline ? null : () => master.musicControl('previous'), icon: const Icon(Icons.skip_previous)),
                IconButton(
                  onPressed: offline ? null : () => master.musicControl(music?.isPlaying == true ? 'pause' : 'resume'),
                  icon: Icon(music?.isPlaying == true ? Icons.pause_circle : Icons.play_circle, size: 36),
                ),
                IconButton(onPressed: offline ? null : () => master.musicControl('next'), icon: const Icon(Icons.skip_next)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {required this.count, this.action});
  final String title;
  final int count;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            if (count > 0) ...[
              const SizedBox(width: 8),
              Badge(label: Text('$count')),
            ],
            const Spacer(),
            if (action != null) action!,
          ],
        ),
      );
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(text, style: TextStyle(color: Theme.of(context).hintColor)));
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.master, required this.event});
  final MasterCtrl master;
  final AgentEvent event;

  @override
  Widget build(BuildContext context) {
    final icon = switch (event.status) {
      'approval' => Icons.front_hand_outlined,
      'question' => Icons.help_outline,
      'interrupted' || 'failed' => Icons.cancel_outlined,
      _ => Icons.check_circle_outline,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: event.read ? Theme.of(context).hintColor : null),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    event.title,
                    style: TextStyle(fontWeight: event.read ? FontWeight.w400 : FontWeight.w600),
                  ),
                ),
                Text(formatLocal(event.when), style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(width: 8),
              ],
            ),
            if (event.summary != null)
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 4, right: 8),
                child: Text(event.summary!, maxLines: 3, overflow: TextOverflow.ellipsis),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => master.readReport(event), child: const Text('Read report')),
                TextButton(
                  onPressed: () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => ReportScreen(master: master, event: event))),
                  child: const Text('Open details'),
                ),
                if (!event.read) TextButton(onPressed: () => master.markRead(event), child: const Text('Mark as read')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.master, required this.message});
  final MasterCtrl master;
  final SocialMessage message;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: CircleAvatar(child: Text(message.app == 'instagram' ? 'IG' : 'WA')),
        title: Text(
          [message.sender ?? message.appName, if (message.conversation != null && message.conversation != message.sender) message.conversation]
              .join(' · '),
          style: TextStyle(fontWeight: message.read ? FontWeight.w400 : FontWeight.w600),
        ),
        subtitle: Text(message.text ?? 'Content hidden by ${message.appName}', maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Text(formatLocal(message.when), style: Theme.of(context).textTheme.bodySmall),
        onTap: () => master.readMessage(message),
      );
}

class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet();

  @override
  Widget build(BuildContext context) {
    final master = context.watch<MasterCtrl>();
    final settings = master.settings;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(companionMode ? 'JARVIS · Companion' : 'Master phone', style: Theme.of(context).textTheme.titleLarge),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(companionMode ? 'Work reports and Projects' : 'Master phone mode'),
              subtitle: const Text(companionMode ? 'Reports, AI limits and requests on your main PC' : 'Wake word, reports, messages; music only on the computer'),
              value: master.enabled,
              onChanged: master.setEnabled,
            ),
            if (!companionMode) SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Announce messages'),
              value: settings.announceMessages,
              onChanged: master.setAnnounceMessages,
            ),
            const SizedBox(height: 8),
            const Text('Command transcription'),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'local', label: Text('On the phone')),
                ButtonSegment(value: 'cloud', label: Text('Cloud voice')),
              ],
              selected: {settings.sttMode},
              onSelectionChanged: (value) => master.setVoiceOptions(sttMode: value.first),
            ),
            if (settings.sttMode == 'cloud')
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Not offline: after "Jarvis", your voice goes to the voice model in a call.',
                    style: TextStyle(color: Colors.orange)),
              ),
            const SizedBox(height: 12),
            const Text('Language of commands'),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: '', label: Text('Detect')),
                ButtonSegment(value: 'pt', label: Text('Português')),
                ButtonSegment(value: 'en', label: Text('English')),
              ],
              selected: {settings.sttLanguage},
              onSelectionChanged: (value) => master.setVoiceOptions(sttLanguage: value.first),
            ),
            const SizedBox(height: 12),
            Text('Wake word sensitivity: ${(settings.sensitivity * 100).round()}%'),
            Slider(
              value: settings.sensitivity,
              divisions: 10,
              onChangeEnd: (value) => master.setVoiceOptions(sensitivity: value),
              onChanged: (_) {},
            ),
            Row(
              children: [
                TextButton(onPressed: master.testSpeech, child: const Text('Test voice')),
                TextButton(onPressed: master.requestBatteryExemption, child: const Text('Battery: always on')),
                if (!companionMode) TextButton(onPressed: master.openSocialSettings, child: const Text('Notification access')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
