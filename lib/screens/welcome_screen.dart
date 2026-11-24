import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/material.dart';
import '../companion_mode.dart';
import 'package:livekit_client/livekit_client.dart' as sdk;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl;
import '../controllers/app_ctrl.dart' as ctrl;
import '../services/jarvis_api.dart' show JarvisApiException;
import 'routines_screen.dart';
import 'connections_screen.dart';
import '../widgets/agent_status_indicator.dart';
import '../widgets/button.dart' as buttons;

/// Asks for the one-time code printed by `sudo jarvis-control pair --kind app`.
Future<void> showPairingDialog(BuildContext ctx, ctrl.AppCtrl appCtrl) async {
  final codeCtrl = TextEditingController();
  final nameCtrl = TextEditingController(text: companionMode ? 'S23 FE' : 'Mestre');
  String? error;
  var busy = false;

  await showDialog<void>(
    context: ctx,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (dialogCtx, setState) => AlertDialog(
        title: const Text('Parear com o servidor'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            const Text('No servidor, rode: sudo jarvis-control pair --kind app'),
            TextField(
              controller: codeCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Código (ABCD-EFGH)'),
            ),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Nome deste aparelho'),
            ),
            if (error != null) Text(error!, style: const TextStyle(color: Colors.redAccent)),
          ],
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.of(dialogCtx).pop(), child: const Text('Cancelar')),
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    try {
                      await appCtrl.pair(codeCtrl.text, nameCtrl.text.trim().isEmpty ? 'Mestre' : nameCtrl.text.trim());
                      if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
                    } on JarvisApiException catch (e) {
                      setState(() {
                        error = e.userMessage;
                        busy = false;
                      });
                    }
                  },
            child: const Text('Parear'),
          ),
        ],
      ),
    ),
  );
}

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext ctx) => Material(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 30,
                children: [
                  Image.asset(
                    'assets/terminal.png',
                    width: 80,
                    height: 80,
                    color: Theme.brightnessOf(ctx) == Brightness.light ? Colors.black : Colors.white,
                  ),
                  Text.rich(
                    textAlign: TextAlign.center,
                    TextSpan(
                      children: [
                        const TextSpan(
                          text: 'Start a call to chat with your voice agent. Need help getting set up? Check out the ',
                        ),
                        TextSpan(
                          text: 'Voice AI quickstart',
                          style: const TextStyle(
                            color: Colors.blue,
                            decoration: TextDecoration.underline,
                            decorationColor: Colors.blue,
                            decorationThickness: 1,
                          ),
                          recognizer: TapGestureRecognizer()
                            ..onTap = () async {
                              await launchUrl(Uri.parse('https://docs.livekit.io/agents/start/voice-ai/'));
                            },
                        ),
                        const TextSpan(
                          text: '.',
                        ),
                      ],
                    ),
                  ),
                  // Agent status indicator
                  const AgentStatusIndicator(),
                  Consumer2<ctrl.AppCtrl, sdk.Session>(
                    builder: (ctx, appCtrl, session, child) {
                      if (appCtrl.isPaired == false) {
                        return buttons.Button(
                          text: 'Parear com o servidor',
                          onPressed: () => showPairingDialog(ctx, appCtrl),
                        );
                      }
                      final isProgressing =
                          appCtrl.isSessionStarting || session.connectionState != sdk.ConnectionState.disconnected;
                      return Column(
                        spacing: 12,
                        children: [
                          buttons.Button(
                            text: isProgressing ? 'Connecting' : 'Start call',
                            isProgressing: isProgressing,
                            onPressed: () => appCtrl.connect(),
                          ),
                          if (appCtrl.statusMessage != null) Text(appCtrl.statusMessage!, textAlign: TextAlign.center),
                          if (appCtrl.jarvisApi != null && !isProgressing)
                            TextButton.icon(
                              onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => ConnectionsScreen(api: appCtrl.jarvisApi!))),
                              icon: const Icon(Icons.link), label: const Text('Conexões'),
                            ),
                          if (appCtrl.isSessionStarting && appCtrl.statusMessage != null)
                            TextButton(onPressed: appCtrl.cancelStart, child: const Text('Cancelar')),
                          if (appCtrl.jarvisApi != null && !isProgressing)
                            TextButton.icon(
                              onPressed: () => Navigator.of(ctx).push(
                                MaterialPageRoute(builder: (_) => const RoutinesScreen()),
                              ),
                              icon: const Icon(Icons.alarm),
                              label: const Text('Rotinas'),
                            ),
                          if (appCtrl.jarvisApi != null && !isProgressing)
                            TextButton.icon(
                              // A dedicated phone that stays on: wake word, reports and
                              // messages; music only on the computer.
                              onPressed: () async {
                                try {
                                  await appCtrl.master.setEnabled(true);
                                } catch (error) {
                                  if (!ctx.mounted) return;
                                  await showDialog<void>(
                                    context: ctx,
                                    builder: (context) => AlertDialog(
                                      title: const Text('Could not start master mode'),
                                      content: Text('$error'),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(context),
                                          child: const Text('OK'),
                                        ),
                                      ],
                                    ),
                                  );
                                }
                              },
                              icon: const Icon(Icons.hearing),
                              label: const Text(companionMode ? 'Ativar reports e Projects' : 'Use as master phone'),
                            ),
                          if (appCtrl.errorMessage != null)
                            Text(
                              appCtrl.errorMessage!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.redAccent),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
