import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The Android side of the master phone (MainActivity.kt, JarvisService.kt,
/// SocialListener.kt): the always-on service, sounds, notification access and
/// the WhatsApp/Instagram listener.
class MasterPlatform {
  MasterPlatform({required this.onServiceAction, required this.onMessage}) {
    if (isAndroid) _channel.setMethodCallHandler(_handle);
  }

  static const _channel = MethodChannel('jarvis/master');
  static bool get isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// "pause", "resume" or "listen", from the buttons on the service notification.
  final void Function(String action) onServiceAction;

  /// A WhatsApp or Instagram message notification, already filtered on Android.
  final bool Function(Map<String, dynamic> message) onMessage;

  Future<dynamic> _handle(MethodCall call) async {
    switch (call.method) {
      case 'serviceAction':
        onServiceAction(call.arguments as String);
      case 'socialPosted':
        return onMessage((call.arguments as Map).cast<String, dynamic>());
    }
  }

  Future<T?> _call<T>(String method, [Object? arguments]) async {
    if (!isAndroid) return null;
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      debugPrint('master platform $method: $error');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Keeps the app alive (foreground service with a microphone type) and shows
  /// [status] in its notification, with Pause/Resume listening buttons.
  Future<void> setStandby({required bool enabled, required String status, required bool listening}) =>
      _call('standby', {'enabled': enabled, 'status': status, 'listening': listening});

  /// A short tone: "wake" (listening now), "done" or "error".
  Future<void> beep(String kind) => _call('beep', {'kind': kind});

  /// {dnd: Do Not Disturb is on, inCall: a phone or VoIP call is active}.
  Future<({bool dnd, bool inCall})> audioContext() async {
    final result = (await _call<Map>('audioContext'))?.cast<String, dynamic>() ?? const {};
    return (dnd: result['dnd'] == true, inCall: result['inCall'] == true);
  }

  Future<bool> batteryOptimized() async => await _call<bool>('batteryOptimized') ?? false;
  Future<void> requestBatteryExemption() => _call('requestBatteryExemption');

  Future<bool> socialAccess() async => await _call<bool>('socialAccess') ?? false;
  Future<void> openSocialSettings() => _call('openSocialSettings');

  /// Messages the listener saw while the Flutter side was not running.
  Future<List<Map<String, dynamic>>> socialPending() async =>
      ((await _call<List>('socialPending')) ?? const []).map((m) => (m as Map).cast<String, dynamic>()).toList();

  /// Per-app channels and categories seen (metadata), to tune the message filter.
  Future<List<Map<String, dynamic>>> socialChannels() async =>
      ((await _call<List>('socialChannels')) ?? const []).map((m) => (m as Map).cast<String, dynamic>()).toList();
}
