import 'updates_screen.dart';
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as sdk;
import 'package:livekit_components/livekit_components.dart' as components;
import 'package:provider/provider.dart';

import '../controllers/app_ctrl.dart';
import '../master/master_ctrl.dart';
import '../master/models.dart';
import 'agent_screen.dart';
import 'diagnostics_reports_screen.dart';
import 'knowledge_screen.dart';
import 'connections_screen.dart';
import 'projects_screen.dart';
import 'master_diagnostics_screen.dart';
import 'report_screen.dart';
import 'routines_screen.dart';

/// The master phone lying on its side, left to right: the AI limits, Jarvis's
/// voice effect with what it is doing, and the buttons (mute, camera, screen,
/// call, alerts, reports and messages).
class MasterLandscape extends StatelessWidget {
  const MasterLandscape({super.key});

  @override
  Widget build(BuildContext context) {
    final master = context.watch<MasterCtrl>();
    return Material(
      child: SafeArea(
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 30, child: UsagePanel(master: master)),
                  const SizedBox(width: 12),
                  Expanded(flex: 40, child: _VoicePanel(master: master)),
                  const SizedBox(width: 12),
                  Expanded(flex: 30, child: _ButtonsPanel(master: master)),
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

/// Silent corner toast shown on the Master app whenever Claude Code, Codex, or
/// Antigravity finishes a task (no voice). Tapping opens the full report.
class AgentCornerNotifications extends StatelessWidget {
  const AgentCornerNotifications({super.key, required this.master});
  final MasterCtrl master;

  static (Color, IconData) _style(String? agent) => switch (agent) {
        'antigravity' => (const Color(0xFF60A5FA), Icons.auto_awesome),
        'claude' => (const Color(0xFFF59E0B), Icons.smart_toy_outlined),
        'codex' => (const Color(0xFF14B8A6), Icons.terminal),
        _ => (Colors.blueGrey, Icons.check_circle_outline),
      };

  @override
  Widget build(BuildContext context) {
    final alerts = master.cornerAlerts;
    if (alerts.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Positioned(
      top: 8,
      right: 12,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 276),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final event in alerts)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _CornerToastCard(
                  event: event,
                  style: _style(event.agent),
                  theme: theme,
                  onTap: () {
                    master.dismissCornerAlert(event.id);
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => ReportScreen(master: master, event: event)),
                    );
                  },
                  onDismiss: () => master.dismissCornerAlert(event.id),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CornerToastCard extends StatelessWidget {
  const _CornerToastCard({
    required this.event,
    required this.style,
    required this.theme,
    required this.onTap,
    required this.onDismiss,
  });

  final AgentEvent event;
  final (Color, IconData) style;
  final ThemeData theme;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final (accent, icon) = style;
    final subtitle = event.project == null || event.project!.isEmpty
        ? formatLocal(event.when)
        : '${event.project} · ${formatLocal(event.when)}';
    return Material(
      elevation: 8,
      color: const Color(0xEE181B22),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: accent.withValues(alpha: 0.7), width: 1.2),
          ),
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 16, color: accent),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${event.agentName} terminou',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: accent,
                        fontSize: 10,
                      ),
                    ),
                    if (event.summary != null && event.summary!.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        event.summary!
                            .replaceAll(RegExp(r'\*\*|__|`|#+'), '')
                            .replaceAll(RegExp(r'\s+'), ' ')
                            .trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(
                width: 24,
                height: 24,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 16,
                  tooltip: 'Fechar aviso',
                  color: Colors.white54,
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Left: limits

class UsagePanel extends StatelessWidget {
  const UsagePanel({required this.master});
  final MasterCtrl master;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: master.refreshUsage,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          Row(
            children: [
              Text('AI limits', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              if (master.usageAt != null)
                Expanded(
                  child: Text(formatLocal(master.usageAt!),
                      textAlign: TextAlign.end, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
                ),
            ],
          ),
          if (master.usageError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(master.usageError!, style: theme.textTheme.bodySmall?.copyWith(color: Colors.orange)),
            ),
          for (final service in master.usage) _ServiceCard(service: service),
          if (master.usage.isEmpty && master.usageError == null)
            const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
        ],
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({required this.service});
  final ServiceUsage service;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(color: theme.cardColor, borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(service.name,
                        style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (service.limitReached) const Icon(Icons.block, size: 14, color: Colors.redAccent),
                ],
              ),
              for (final bar in service.bars) _Bar(bar: bar),
              if (service.note != null)
                Text(service.note!,
                    maxLines: service.bars.isEmpty ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.bar});
  final UsageBar bar;

  @override
  Widget build(BuildContext context) {
    final used = (bar.usedPercent ?? 0).clamp(0, 100) / 100;
    final color = used >= 0.9
        ? Colors.redAccent
        : used >= 0.7
            ? Colors.orange
            : Colors.teal;
    final small = Theme.of(context).textTheme.labelSmall;
    final hint = small?.copyWith(color: Theme.of(context).hintColor, fontSize: 10);
    // One line per window: name, percentage used and when it resets, then the bar.
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(bar.usedPercent == null ? '${bar.label} —' : '${bar.label} ${bar.usedPercent!.round()}%', style: small),
              const SizedBox(width: 6),
              Expanded(
                child: Text(bar.resetText, style: hint, textAlign: TextAlign.end, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 2),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: used.toDouble(),
              minHeight: 4,
              color: color,
              backgroundColor: color.withValues(alpha: 0.15),
            ),
          ),
        ],
      ),
    );
  }
}

// Centre: Jarvis's voice

class _VoicePanel extends StatelessWidget {
  const _VoicePanel({required this.master});
  final MasterCtrl master;

  String get _label => switch (master.voice) {
        VoiceState.standby => 'Say "Jarvis"',
        VoiceState.listening => 'Listening…',
        VoiceState.processing => 'Processing…',
        VoiceState.speaking => 'Speaking',
        VoiceState.inCall => 'In a call',
        VoiceState.paused => 'Muted',
        VoiceState.preparing => 'Starting…',
        VoiceState.unavailable => 'Voice unavailable',
        VoiceState.off => 'Off',
      };

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppCtrl>();
    final theme = Theme.of(context);
    final inCall = app.appScreenState == AppScreenState.agent;
    final music = master.music;
    return Column(
      children: [
        Expanded(
          // The real effect, from Jarvis's audio, during a call; otherwise the same
          // bars driven by what the phone is doing.
          child: inCall ? const AgentTrackView() : _JarvisBars(state: master.voice),
        ),
        Text(_label, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        if (master.operation != null)
          Text('${master.operation!.stage} · ${master.operation!.seconds}s',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: Colors.orange)),
        if (master.lastHeard != null && !inCall)
          Text('"${master.lastHeard}"',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
        if (master.problems.isNotEmpty)
          TextButton.icon(
            onPressed: () => _showProblems(context, master),
            icon: const Icon(Icons.warning_amber, size: 16, color: Colors.orange),
            label: Text('${master.problems.length} to fix', style: const TextStyle(color: Colors.orange)),
          ),
        // The music on the computer, with its controls.
        Row(
          children: [
            const Icon(Icons.music_note, size: 16),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                music == null
                    ? 'BATCOMPUTADOR'
                    : music.error ?? (music.track ?? (music.onComputer ? 'BATCOMPUTADOR' : 'Not on the BATCOMPUTADOR')),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: music?.error != null ? null : () => master.musicControl('previous'),
              icon: const Icon(Icons.skip_previous, size: 20),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: music?.error != null ? null : () => master.musicControl(music?.isPlaying == true ? 'pause' : 'resume'),
              icon: Icon(music?.isPlaying == true ? Icons.pause : Icons.play_arrow, size: 22),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: music?.error != null ? null : () => master.musicControl('next'),
              icon: const Icon(Icons.skip_next, size: 20),
            ),
          ],
        ),
      ],
    );
  }
}

/// Five rounded bars like the call's audio visualizer, animated by the voice state.
class _JarvisBars extends StatefulWidget {
  const _JarvisBars({required this.state});
  final VoiceState state;

  @override
  State<_JarvisBars> createState() => _JarvisBarsState();
}

class _JarvisBarsState extends State<_JarvisBars> with SingleTickerProviderStateMixin {
  late final AnimationController _ticker = AnimationController(vsync: this, duration: const Duration(seconds: 1))
    ..repeat();
  double _time = 0;
  final _random = Random();
  final _jitter = List<double>.filled(5, 0);

  @override
  void initState() {
    super.initState();
    _ticker.addListener(() {
      _time += 1 / 60;
      if (widget.state == VoiceState.speaking && _random.nextDouble() < 0.15) {
        for (var i = 0; i < 5; i++) {
          _jitter[i] = _random.nextDouble();
        }
      }
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  double _height(int i) {
    final t = _time;
    switch (widget.state) {
      case VoiceState.speaking:
        return 0.35 + 0.55 * (0.5 + 0.5 * sin(t * 9 + i * 1.3)) * (0.6 + 0.4 * _jitter[i]);
      case VoiceState.listening:
        return 0.2 + 0.25 * (0.5 + 0.5 * sin(t * 5 + i * 0.9));
      case VoiceState.processing:
        // A wave running across the bars.
        return 0.15 + 0.5 * max(0, sin(t * 6 - i * 0.8));
      case VoiceState.standby:
      case VoiceState.inCall:
        return 0.1 + 0.05 * (0.5 + 0.5 * sin(t * 1.5 + i * 0.6));
      default:
        return 0.06;
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.state != VoiceState.paused && widget.state != VoiceState.off && widget.state != VoiceState.unavailable;
    final color = active ? Theme.of(context).colorScheme.primary : Theme.of(context).disabledColor;
    return AnimatedBuilder(
      animation: _ticker,
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) {
          final width = min(32.0, box.maxWidth / 9);
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 5; i++)
                Container(
                  margin: EdgeInsets.symmetric(horizontal: width * 0.3),
                  width: width,
                  height: max(width, box.maxHeight * 0.9 * _height(i)),
                  decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(width / 2)),
                ),
            ],
          );
        },
      ),
    );
  }
}

void _showProblems(BuildContext context, MasterCtrl master) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('To fix'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final p in master.problems.values) Padding(padding: const EdgeInsets.only(bottom: 8), child: SelectableText(p))],
          ),
        ),
        actions: [
          TextButton(onPressed: master.openSocialSettings, child: const Text('Notification access')),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              unawaited(master.start());
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );

// Right: buttons

class _ButtonsPanel extends StatelessWidget {
  const _ButtonsPanel({required this.master});
  final MasterCtrl master;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppCtrl>();
    final session = context.watch<sdk.Session>();
    final inCall = app.appScreenState == AppScreenState.agent;
    final connecting = app.isSessionStarting || (session.connectionState != sdk.ConnectionState.disconnected && !inCall);
    return components.MediaDeviceContextBuilder(
      builder: (context, roomCtx, devices) {
        final buttons = <Widget>[
          // Mute: the call's microphone during a call, the "Jarvis" detector otherwise.
          inCall
              ? _RoundButton(
                  icon: devices.microphoneOpened ? Icons.mic : Icons.mic_off,
                  label: devices.microphoneOpened ? 'Mute' : 'Unmute',
                  active: !devices.microphoneOpened,
                  onTap: () => devices.microphoneOpened ? devices.disableMicrophone() : devices.enableMicrophone(),
                )
              : _RoundButton(
                  icon: master.settings.listening ? Icons.mic : Icons.mic_off,
                  label: master.settings.listening ? 'Mute' : 'Unmute',
                  active: !master.settings.listening,
                  onTap: () => master.setListening(!master.settings.listening),
                ),
          _RoundButton(
            icon: Icons.record_voice_over,
            label: 'Speak',
            onTap: master.voice == VoiceState.standby ? master.listenNow : null,
          ),
          _RoundButton(
            icon: Icons.info_outline,
            label: 'Status',
            onTap: master.speakStatus,
          ),
          _RoundButton(
            icon: Icons.stop_circle_outlined,
            label: 'Stop',
            color: master.operation != null ? Colors.redAccent : null,
            onTap: () => master.stopCurrent(),
          ),
          _RoundButton(
            icon: Icons.bug_report_outlined,
            label: 'Report',
            onTap: () => master.requestDiagnostics(note: 'Requested with the Report button'),
          ),
          _RoundButton(
            icon: devices.cameraOpened ? Icons.videocam : Icons.videocam_off,
            label: 'Camera',
            active: devices.cameraOpened,
            onTap: inCall ? () => app.toggleUserCamera(devices) : null,
          ),
          _RoundButton(
            icon: Icons.screen_share,
            label: 'Share screen',
            active: app.isScreenSharing,
            onTap: inCall ? app.toggleScreenShare : null,
          ),
          _RoundButton(
            icon: Icons.chat_bubble_outline,
            label: 'Transcript',
            onTap: inCall ? () => _openTranscript(context, app) : null,
          ),
          _RoundButton(
            icon: inCall ? Icons.call_end : Icons.call,
            label: inCall ? 'Hang up' : (connecting ? 'Connecting' : 'Call'),
            color: inCall ? Colors.redAccent : Colors.teal,
            onTap: connecting ? null : (inCall ? app.disconnect : app.connect),
          ),
          _RoundButton(
            icon: master.settings.announcements ? Icons.notifications_active : Icons.notifications_off,
            label: 'Alerts',
            active: !master.settings.announcements,
            onTap: () => master.setAnnouncements(!master.settings.announcements),
          ),
          _RoundButton(
            icon: Icons.assignment_outlined,
            label: 'Reports',
            badge: master.unreadReports,
            onTap: () => _openReports(context, master),
          ),
          _RoundButton(
            icon: Icons.forum_outlined,
            label: 'Messages',
            badge: master.unreadMessages,
            onTap: () => _openMessages(context, master),
          ),
          _RoundButton(
            icon: Icons.account_tree_outlined,
            label: 'Projects',
            onTap: app.projects == null
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProjectsScreen(projects: app.projects!))),
          ),
          _RoundButton(
            icon: Icons.more_horiz,
            label: 'More',
            onTap: () => _openMore(context, master),
          ),
        ];
        return LayoutBuilder(
          builder: (context, box) {
            const columns = 4;
            final rows = (buttons.length / columns).ceil();
            final cell = min(box.maxWidth / columns, box.maxHeight / rows);
            return Center(
              child: Wrap(
                alignment: WrapAlignment.center,
                children: [for (final b in buttons) SizedBox(width: cell, height: cell, child: b)],
              ),
            );
          },
        );
      },
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.label, this.onTap, this.active = false, this.color, this.badge = 0});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final Color? color;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    final background = color ?? (active ? scheme.primary : Theme.of(context).cardColor);
    final foreground = color != null || active ? (color != null ? Colors.white : scheme.onPrimary) : scheme.onSurface;
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.maxHeight * 0.6;
        return Opacity(
          opacity: enabled ? 1 : 0.35,
          child: InkWell(
            borderRadius: BorderRadius.circular(size),
            onTap: onTap,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Badge(
                  isLabelVisible: badge > 0,
                  label: Text('$badge'),
                  child: Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(color: background, shape: BoxShape.circle),
                    child: Icon(icon, color: foreground, size: size * 0.5),
                  ),
                ),
                const SizedBox(height: 2),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10)),
              ],
            ),
          ),
        );
      },
    );
  }
}

void _openTranscript(BuildContext context, AppCtrl app) {
  app.agentScreenState = AgentScreenState.transcription;
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => Scaffold(appBar: AppBar(title: const Text('Transcript')), body: const AgentScreen()),
  ));
}

void _openReports(BuildContext context, MasterCtrl master) => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChangeNotifierProvider.value(
        value: master,
        child: Scaffold(
          appBar: AppBar(title: const Text('Reports')),
          body: Consumer<MasterCtrl>(
            builder: (context, master, _) => master.reports.isEmpty
                ? const Center(child: Text('No reports yet.'))
                : ListView(
                    children: [
                      for (final r in master.reports)
                        ListTile(
                          title: Text(r.title, style: TextStyle(fontWeight: r.read ? FontWeight.w400 : FontWeight.w600)),
                          subtitle: Text(r.summary ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(formatLocal(r.when)),
                            IconButton(icon: const Icon(Icons.volume_up), onPressed: () => master.readReport(r)),
                          ]),
                          onTap: () => Navigator.of(context)
                              .push(MaterialPageRoute(builder: (_) => ReportScreen(master: master, event: r))),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    ));

void _openMessages(BuildContext context, MasterCtrl master) => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChangeNotifierProvider.value(
        value: master,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Messages'),
            actions: [TextButton(onPressed: master.clearMessages, child: const Text('Clear'))],
          ),
          body: Consumer<MasterCtrl>(
            builder: (context, master, _) => master.messages.isEmpty
                ? const Center(child: Text('No messages yet.'))
                : ListView(
                    children: [
                      for (final m in master.messages)
                        ListTile(
                          leading: CircleAvatar(child: Text(m.app == 'instagram' ? 'IG' : 'WA')),
                          title: Text(m.sender ?? m.appName,
                              style: TextStyle(fontWeight: m.read ? FontWeight.w400 : FontWeight.w600)),
                          subtitle: Text(m.text ?? 'Content hidden by ${m.appName}', maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: Text(formatLocal(m.when)),
                          onTap: () => master.readMessage(m),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    ));

void _openMore(BuildContext context, MasterCtrl master) => showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined), title: const Text('Atualizações'),
              onTap: () {
                final api = context.read<AppCtrl>().jarvisApi;
                if (api == null) return;
                Navigator.of(ctx)..pop()..push(MaterialPageRoute(builder: (_) => UpdatesScreen(api: api, master: master)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('Knowledge (DiceVTT RAG on the PC)'),
              onTap: () {
                final api = context.read<AppCtrl>().jarvisApi;
                if (api == null) return;
                Navigator.of(ctx)
                  ..pop()
                  ..push(MaterialPageRoute(builder: (_) => KnowledgeScreen(api: api)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.link), title: const Text('Conexões'),
              onTap: () {
                final api = context.read<AppCtrl>().jarvisApi;
                if (api == null) return;
                Navigator.of(ctx)..pop()..push(MaterialPageRoute(builder: (_) => ConnectionsScreen(api: api)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.alarm),
              title: const Text('Routines'),
              onTap: () => Navigator.of(ctx)
                ..pop()
                ..push(MaterialPageRoute(builder: (_) => const RoutinesScreen())),
            ),
            ListTile(
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('Notification access (WhatsApp, Instagram)'),
              onTap: () {
                Navigator.of(ctx).pop();
                unawaited(master.openSocialSettings());
              },
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Diagnostics reports'),
              onTap: () {
                final api = context.read<AppCtrl>().jarvisApi;
                if (api == null) return;
                Navigator.of(ctx)
                  ..pop()
                  ..push(MaterialPageRoute(builder: (_) => DiagnosticsReportsScreen(api: api, master: master)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.monitor_heart_outlined),
              title: const Text('Diagnostics'),
              onTap: () => Navigator.of(ctx)
                ..pop()
                ..push(MaterialPageRoute(builder: (_) => MasterDiagnosticsScreen(master: master))),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.screen_rotation),
              title: const Text('Keep the screen horizontal'),
              value: master.settings.landscape,
              onChanged: (value) {
                unawaited(master.setLandscape(value));
                Navigator.of(ctx).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.power_settings_new),
              title: const Text('Leave master phone mode'),
              onTap: () {
                Navigator.of(ctx).pop();
                unawaited(master.setEnabled(false));
              },
            ),
          ],
        ),
      ),
    );
