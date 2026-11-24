import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'app.dart';
import 'master/app_log.dart';
import 'services/alarms.dart';

// Load environment variables before starting the app
// This is used to configure the LiveKit sandbox ID for development
// The file is optional; without it the app connects to a default agent (see app_ctrl.dart)
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLog.instance.init();
  // Uncaught errors go to the log that diagnostics reports collect.
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    AppLog.instance.add('FLUTTER ERROR ${details.exceptionAsString()}\n${details.stack}');
    previousOnError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.instance.add('UNCAUGHT $error\n$stack');
    return false;
  };
  await dotenv.load(fileName: 'assets/.env', isOptional: true);
  await Alarms.init(onOpen: (payload) => appCtrl.openFromNotification(payload));
  // A routine alarm may have opened the app: start that routine's call.
  final launchedBy = await Alarms.launchPayload();
  runApp(const VoiceAssistantApp());
  if (launchedBy != null) appCtrl.openFromNotification(launchedBy);
  try {
    await Alarms.startBackgroundChecks();
  } catch (error) {
    debugPrint('Background checks unavailable: $error');
  }
}
