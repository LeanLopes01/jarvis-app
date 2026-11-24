import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:workmanager/workmanager.dart';

import '../master/event_store.dart';
import '../master/models.dart';
import 'jarvis_api.dart';

/// Routine alarms and "task finished" notifications, without a background service:
/// Android's alarm manager fires the routines and WorkManager checks for agent
/// notifications every 15 minutes, both handled by the system to save battery.
///
/// On the master phone the live event stream delivers reports at once; this check
/// only recovers what it missed, with the same cursor and the same "already shown"
/// list, so nothing is shown twice.
class Alarms {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const routinePrefix = 'routine:';
  static const _apiUrlKey = 'jarvis_api_url';
  static const _lastNotificationKey = 'jarvis_last_notification_id';
  static const _checkTask = 'check-agent-notifications';

  static const _routineChannel = AndroidNotificationChannel(
    'routines',
    'Rotinas do JARVIS',
    description: 'Alarmes que abrem o JARVIS, como a rotina de acordar.',
    importance: Importance.max,
  );
  static const _agentsChannel = AndroidNotificationChannel(
    'agents',
    'Agentes de programação',
    description: 'Avisos quando o Claude Code ou o Codex terminam uma tarefa.',
    importance: Importance.high,
  );

  /// Sets up notifications; [onOpen] receives the payload when one is tapped.
  static Future<void> init({void Function(String payload)? onOpen}) async {
    tzdata.initializeTimeZones();
    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null && onOpen != null) onOpen(payload);
      },
    );
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(_routineChannel);
    await android?.createNotificationChannel(_agentsChannel);
  }

  /// The payload of the notification or alarm that opened the app, if any.
  static Future<String?> launchPayload() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    return details?.notificationResponse?.payload;
  }

  static Future<void> requestPermissions() async {
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();
    await android?.requestFullScreenIntentPermission();
  }

  /// Replaces all scheduled routine alarms with [routines] (times in GMT-3).
  static Future<void> scheduleRoutines(List<JarvisRoutine> routines) async {
    await _plugin.cancelAllPendingNotifications();
    final zone = tz.getLocation('America/Sao_Paulo');
    final now = tz.TZDateTime.now(zone);
    for (final routine in routines.where((r) => r.enabled && r.id != null)) {
      for (final day in routine.days) {
        var when = tz.TZDateTime(zone, now.year, now.month, now.day, routine.hour, routine.minute);
        // Monday is 0 in a routine and DateTime.monday (1) in Dart.
        while (when.weekday != day + 1 || !when.isAfter(now)) {
          when = when.add(const Duration(days: 1));
        }
        await _plugin.zonedSchedule(
          id: _alarmId(routine.id!, day),
          title: routine.name,
          body: 'O JARVIS está chegando. Toque se ele não abrir sozinho.',
          scheduledDate: when,
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              _routineChannel.id,
              _routineChannel.name,
              channelDescription: _routineChannel.description,
              importance: Importance.max,
              priority: Priority.max,
              category: AndroidNotificationCategory.alarm,
              fullScreenIntent: true,
              autoCancel: true,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.alarmClock,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
          payload: '$routinePrefix${routine.id}',
        );
      }
    }
  }

  static int _alarmId(String routineId, int day) => (routineId.hashCode & 0x0FFFFFFF) * 7 + day;

  /// Remembers the API so the background check can reach it without the UI.
  static Future<void> rememberApi(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_apiUrlKey, url);
  }

  static Future<void> startBackgroundChecks() async {
    await Workmanager().initialize(callbackDispatcher);
    await Workmanager().registerPeriodicTask(
      _checkTask,
      _checkTask,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }

  static NotificationDetails get _agentDetails => NotificationDetails(
        android: AndroidNotificationDetails(
          _agentsChannel.id,
          _agentsChannel.name,
          channelDescription: _agentsChannel.description,
          importance: Importance.high,
          priority: Priority.high,
        ),
      );

  /// A report or request from a coding agent, in the notification shade.
  static Future<void> showAgentEvent(AgentEvent event) async {
    await _plugin.show(
      id: 200000 + ((int.tryParse(event.cursor) ?? event.id.hashCode) & 0x7FFFF),
      title: event.title,
      body: '${formatLocal(event.when)} · ${event.summary ?? ''}',
      notificationDetails: _agentDetails,
      payload: 'report:${event.id}',
    );
  }

  /// Master phone: events the live stream missed, from the shared cursor.
  static Future<void> _recoverMasterEvents(JarvisApi api, MasterStore store) async {
    await store.reload();
    final page = await api.events(store.cursor);
    for (final raw in page.events) {
      final event = AgentEvent.fromJson(raw);
      await store.receiveEvent(event, (item) async {
        if (!item.isProgress) await showAgentEvent(item);
      });
      await api.ackEvent(event.id, 'displayed');
    }
    await store.setCursor(page.cursor);
  }

  /// Shows notifications the server received since the last check.
  static Future<void> checkAgentNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final url = prefs.getString(_apiUrlKey);
    if (url == null) return;
    final api = JarvisApi(url);
    if (!await api.isPaired()) return;
    final store = MasterStore(prefs);
    if (store.masterMode || store.workMode) {
      await _recoverMasterEvents(api, store);
      return;
    }
    final last = prefs.getInt(_lastNotificationKey);
    final items = await api.notifications(last ?? 0);
    if (items.isEmpty) return;
    final newest = items.map((n) => n['id'] as int).reduce((a, b) => a > b ? a : b);
    await prefs.setInt(_lastNotificationKey, newest);
    if (last == null) return; // first run: do not replay old notifications
    for (final item in items) {
      await _plugin.show(
        id: 100000 + (item['id'] as int),
        title: item['title'] as String?,
        body: item['body'] as String?,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _agentsChannel.id,
            _agentsChannel.name,
            channelDescription: _agentsChannel.description,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    }
  }
}

/// WorkManager entry point: runs in a background isolate.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      await Alarms.init();
      await Alarms.checkAgentNotifications();
    } catch (_) {
      // Try again at the next run; never crash the background worker.
    }
    return true;
  });
}
