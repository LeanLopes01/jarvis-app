import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:livekit_client/livekit_client.dart' as sdk;
import 'package:livekit_components/livekit_components.dart' as components;
import 'package:logging/logging.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'package:geolocator/geolocator.dart';

import '../master/master_ctrl.dart';
import '../master/project_ctrl.dart';
import '../services/alarms.dart';
import '../services/jarvis_api.dart';

final String homepageAgentTokenEndpoint = 'https://livekit.com/api/homepage-agent/token';

/// How long to wait for the home server to start the agent before giving up.
const _serverStartTimeout = Duration(seconds: 90);
const _heartbeatInterval = Duration(seconds: 20);

enum AppScreenState { welcome, agent }

enum AgentScreenState { visualizer, transcription }

class AppCtrl extends ChangeNotifier implements CallHost {
  static const uuid = Uuid();
  static const _systemChannel = MethodChannel('jarvis/system');
  static final _logger = Logger('AppCtrl');

  // States
  AppScreenState appScreenState = AppScreenState.welcome;
  AgentScreenState agentScreenState = AgentScreenState.visualizer;

  bool isUserCameEnabled = false;
  bool isScreenSharing = false;

  // Android: true while the app is shown as a floating picture-in-picture window.
  bool isInPip = false;
  bool _backgroundModeOn = false;

  static bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final messageCtrl = TextEditingController();
  final messageFocusNode = FocusNode();

  late final sdk.Room room = sdk.Room(roomOptions: const sdk.RoomOptions(enableVisualizer: true));
  late final roomContext = components.RoomContext(room: room);

  // Home server (jarvis-control). When JARVIS_API_URL is set, every call first asks
  // the server to start the agent, and the server stops it again after the call.
  static final String? _jarvisApiUrl = dotenv.env['JARVIS_API_URL']?.replaceAll('"', '').trim();
  @override
  final JarvisApi? jarvisApi =
      (_jarvisApiUrl == null || _jarvisApiUrl!.isEmpty) ? null : JarvisApi(_jarvisApiUrl!);

  /// The dedicated master phone: wake word, reports, messages, music policy.
  late final MasterCtrl master = MasterCtrl(this);

  /// Projects (DiceVTT) through the coordinator; null without a server.
  late final ProjectCtrl? projects = jarvisApi == null ? null : ProjectCtrl(jarvisApi!, master);

  /// Whether the current call publishes the microphone (false: Jarvis only speaks).
  bool _callHasAudio = true;
  bool _masterCall = false;
  final JarvisTokenSource _jarvisTokens = JarvisTokenSource();
  String? _serverSessionId;
  bool _startCancelled = false;
  bool _roomWasConnected = false;
  Timer? _heartbeatTimer;

  /// Progress shown on the welcome screen while the server starts the agent.
  String? statusMessage;

  /// Last error from the home server, shown on the welcome screen.
  String? errorMessage;

  /// Null until the stored pairing has been checked.
  bool? isPaired;

  @override
  late final sdk.Session session = jarvisApi != null
      ? sdk.Session.fromFixedTokenSource(_jarvisTokens, options: sdk.SessionOptions(room: room))
      : _createSession(room: room);

  static sdk.Session _createSession({required sdk.Room room}) {
    // Development-only hardcoded credentials (optional).
    const hardcodedServerUrl = null; // e.g. 'wss://your-host'
    const hardcodedToken = null; // e.g. 'eyJ...'

    if (hardcodedServerUrl != null && hardcodedToken != null) {
      return sdk.Session.fromFixedTokenSource(
        sdk.LiteralTokenSource(
          serverUrl: hardcodedServerUrl,
          participantToken: hardcodedToken,
        ),
        options: sdk.SessionOptions(room: room),
      );
    }

    final sandboxId = dotenv.env['LIVEKIT_SANDBOX_ID']?.replaceAll('"', '');
    final agentName = dotenv.env['LIVEKIT_AGENT_NAME']?.replaceAll('"', '').trim();
    final agentDeployment = dotenv.env['LIVEKIT_AGENT_DEPLOYMENT']?.replaceAll('"', '').trim();
    sdk.EndpointTokenSource tokenSource;
    if (sandboxId == null || sandboxId.isEmpty || sandboxId == '<your-sandbox-id>') {
      tokenSource = sdk.EndpointTokenSource(url: Uri.parse(homepageAgentTokenEndpoint));
    } else {
      tokenSource = sdk.DevelopmentTokenSource(id: sandboxId);
    }

    return sdk.Session.fromConfigurableTokenSource(
      tokenSource,
      tokenOptions: sdk.TokenRequestOptions(
        agentName: agentName?.isEmpty ?? true ? null : agentName,
        agentDeployment: agentDeployment?.isEmpty ?? true ? null : agentDeployment,
      ),
      options: sdk.SessionOptions(room: room),
    );
  }

  bool isSendButtonEnabled = false;
  @override
  bool isSessionStarting = false;
  bool _hasCleanedUp = false;

  AppCtrl() {
    final format = DateFormat('HH:mm:ss');
    // configure logs for debugging
    Logger.root.level = Level.FINE;
    Logger.root.onRecord.listen((record) {
      debugPrint('${format.format(record.time)}: ${record.message}');
    });

    messageCtrl.addListener(() {
      final newValue = messageCtrl.text.isNotEmpty;
      if (newValue != isSendButtonEnabled) {
        isSendButtonEnabled = newValue;
        notifyListeners();
      }
    });

    session.addListener(_handleSessionChange);
    room.registerRpcMethod('screen.share', _handleScreenShareRpc);
    room.registerRpcMethod('browser.open', _handleOpenUrlRpc);
    room.registerRpcMethod('messages.recent', _handleMessagesRpc);
    if (_isAndroid) _systemChannel.setMethodCallHandler(_handleSystemCall);
    unawaited(_loadPairing());
    _lifecycle = AppLifecycleListener(onResume: () {
      unawaited(checkNotifications());
      master.onResume();
    });
  }

  late final AppLifecycleListener _lifecycle;

  /// Routines kept on the server; each change reschedules the phone's alarms.
  List<JarvisRoutine> routines = [];

  Future<void> _loadPairing() async {
    final api = jarvisApi;
    isPaired = api == null ? true : await api.isPaired();
    notifyListeners();
    if (api != null && isPaired == true) {
      await Alarms.rememberApi(_jarvisApiUrl!);
      unawaited(refreshRoutines().catchError((Object e) => _logger.warning('Routines: $e')));
      unawaited(checkNotifications());
      unawaited(master.init().catchError((Object e) => _logger.warning('Master phone: $e')));
      projects; // hooks into the master phone's voice commands
    }
  }

  /// Fetches the routines and schedules their alarms on this phone.
  Future<void> refreshRoutines() async {
    final api = jarvisApi;
    if (api == null) return;
    routines = await api.routines();
    await Alarms.scheduleRoutines(routines);
    notifyListeners();
  }

  Future<void> saveRoutine(JarvisRoutine routine) async {
    await jarvisApi?.saveRoutine(routine);
    await refreshRoutines();
  }

  Future<void> deleteRoutine(String id) async {
    await jarvisApi?.deleteRoutine(id);
    await refreshRoutines();
  }

  /// Shows "task finished" notifications that arrived while the app was closed.
  Future<void> checkNotifications() async {
    try {
      await Alarms.checkAgentNotifications();
    } catch (error) {
      _logger.fine('Notification check failed: $error');
    }
  }

  /// Called when an alarm or notification opens the app.
  void openFromNotification(String payload) {
    if (payload.startsWith('report:')) {
      unawaited(master.openReportNotification(payload.substring('report:'.length)));
      return;
    }
    if (!payload.startsWith(Alarms.routinePrefix)) return;
    if (isSessionStarting || session.connectionState != sdk.ConnectionState.disconnected) return;
    connect(routineId: payload.substring(Alarms.routinePrefix.length));
  }

  /// Approximate position for the weather; null without permission. Uses the last
  /// known fix first, so it does not wake up the GPS.
  Future<Map<String, double>?> _approximateLocation() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        return null;
      }
      final position = await Geolocator.getLastKnownPosition() ??
          await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.low,
              timeLimit: Duration(seconds: 5),
            ),
          );
      return {'lat': position.latitude, 'lon': position.longitude};
    } catch (error) {
      _logger.fine('No location: $error');
      return null;
    }
  }

  /// Exchanges a one-time code from `sudo jarvis-control pair --kind app`.
  Future<void> pair(String code, String deviceName) async {
    final api = jarvisApi;
    if (api == null) return;
    await api.pair(code, deviceName);
    isPaired = true;
    errorMessage = null;
    notifyListeners();
    await Alarms.rememberApi(_jarvisApiUrl!);
    await Alarms.requestPermissions();
    await refreshRoutines();
    await master.init();
  }

  Future<void> unpair() async {
    await jarvisApi?.forget();
    isPaired = jarvisApi == null;
    notifyListeners();
  }

  /// Asks the server for a session and waits until the agent is registered and
  /// dispatched into its room, then hands the credentials to the SDK session.
  Future<void> _prepareServerSession(
    JarvisApi api, {
    String? routineId,
    String? command,
    bool audio = true,
  }) async {
    _startCancelled = false;
    statusMessage = 'Iniciando o JARVIS no servidor…';
    notifyListeners();

    var info = await api.createSession(
      uuid.v4(),
      routineId: routineId,
      // Location can take seconds (or prompt for permission). Only weather
      // routines need it here; normal calls must start immediately.
      location: routineId == null ? null : await _approximateLocation(),
      command: command,
      audio: audio,
    );
    _serverSessionId = info.id;
    final deadline = DateTime.now().add(_serverStartTimeout);
    var failures = 0;
    while (info.isStarting) {
      if (_startCancelled) throw StateError('cancelled');
      if (DateTime.now().isAfter(deadline)) throw JarvisApiException(JarvisErrorKind.startFailed);
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        info = await api.getSession(info.id);
        failures = 0;
      } on JarvisApiException catch (error) {
        if (error.kind != JarvisErrorKind.unavailable || ++failures >= 3) rethrow;
      }
    }
    if (_startCancelled) throw StateError('cancelled');
    if (!info.isUsable || info.connection == null) {
      throw JarvisApiException(JarvisErrorKind.startFailed, info.endReason);
    }
    _jarvisTokens.next = info.connection;
    statusMessage = 'Conectando…';
    notifyListeners();
  }

  /// Releases the server session so the agent can stop. Safe to call repeatedly.
  Future<void> _releaseServerSession() async {
    _stopHeartbeat();
    final api = jarvisApi;
    final id = _serverSessionId;
    _serverSessionId = null;
    _jarvisTokens.next = null;
    if (api == null || id == null) return;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        await api.endSession(id);
        return;
      } catch (error) {
        _logger.warning('Could not release session (attempt $attempt): $error');
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
      }
    }
    // The server also ends sessions whose room stays empty, so the agent stops anyway.
  }

  void _startHeartbeat() {
    final api = jarvisApi;
    final id = _serverSessionId;
    if (api == null || id == null) return;
    _heartbeatTimer?.cancel();
    // An extra signal only: the server decides from who is in the room, so a phone
    // that suspends the app in the background does not end a healthy call.
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      unawaited(api.heartbeat(id).then((_) {}, onError: (Object error) {
        _logger.fine('Heartbeat failed: $error');
      }));
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Cancels a start that is still waiting for the server.
  void cancelStart() {
    if (!isSessionStarting || _serverSessionId == null) return;
    _startCancelled = true;
    statusMessage = 'Cancelando…';
    notifyListeners();
  }

  Future<dynamic> _handleSystemCall(MethodCall call) async {
    switch (call.method) {
      case 'pipChanged':
        isInPip = call.arguments as bool;
        notifyListeners();
      case 'hangUp':
        await disconnect();
    }
  }

  // Called by the agent's open_on_device tool with device "phone". Returns "opened"
  // or "failed"; only http(s) links are opened, in the phone's browser.
  // Called by the agent's check_phone_messages tool: WhatsApp and Instagram messages
  // the master phone saw in its notifications. Shared only when the user asks.
  Future<String> _handleMessagesRpc(sdk.RpcInvocationData data) async {
    final request = jsonDecode(data.payload.isEmpty ? '{}' : data.payload) as Map<String, dynamic>;
    return jsonEncode(await master.messagesForAgent(
      onlyUnread: request['only_unread'] != false,
      limit: (request['limit'] as num?)?.toInt() ?? 10,
    ));
  }

  Future<String> _handleOpenUrlRpc(sdk.RpcInvocationData data) async {
    final url = Uri.tryParse((jsonDecode(data.payload) as Map<String, dynamic>)['url'] as String? ?? '');
    if (url == null || !(url.scheme == 'https' || url.scheme == 'http')) return 'failed';
    try {
      return await launchUrl(url, mode: LaunchMode.externalApplication) ? 'opened' : 'failed';
    } catch (error) {
      _logger.warning('Could not open $url: $error');
      return 'failed';
    }
  }

  // Called by the agent's share_phone_screen tool. Returns "sharing", "stopped" or "denied".
  Future<String> _handleScreenShareRpc(sdk.RpcInvocationData data) async {
    final enabled = (jsonDecode(data.payload) as Map<String, dynamic>)['enabled'] == true;
    final ok = await setScreenShare(enabled);
    if (!ok) return 'denied';
    return enabled ? 'sharing' : 'stopped';
  }

  // Keeps mic/audio running in the background and enables the floating window on Android.
  void _syncBackgroundMode() {
    final shouldRun = appScreenState == AppScreenState.agent;
    if (!_isAndroid || shouldRun == _backgroundModeOn) return;
    _backgroundModeOn = shouldRun;
    if (!shouldRun) isScreenSharing = false;
    unawaited(_systemChannel.invokeMethod(
      shouldRun ? 'startSession' : 'stopSession',
      // Calls that do not publish the microphone are shown as such.
      shouldRun ? {'audio': _callHasAudio} : null,
    ));
  }

  Future<void> cleanUp() async {
    if (_hasCleanedUp) return;
    _hasCleanedUp = true;

    session.removeListener(_handleSessionChange);
    room.unregisterRpcMethod('screen.share');
    room.unregisterRpcMethod('browser.open');
    room.unregisterRpcMethod('messages.recent');
    await _releaseServerSession();
    await session.dispose();
    await room.dispose();
    roomContext.dispose();
    messageCtrl.dispose();
    messageFocusNode.dispose();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(cleanUp());
    super.dispose();
  }

  void sendMessage() async {
    isSendButtonEnabled = false;

    final text = messageCtrl.text;
    messageCtrl.clear();
    notifyListeners();

    if (text.isEmpty) return;
    await session.sendText(text);
  }

  void toggleUserCamera(components.MediaDeviceContext? deviceCtx) {
    isUserCameEnabled = !isUserCameEnabled;
    isUserCameEnabled ? deviceCtx?.enableCamera() : deviceCtx?.disableCamera();
    notifyListeners();
  }

  void toggleScreenShare() {
    final sharing = room.localParticipant?.isScreenShareEnabled() ?? false;
    unawaited(setScreenShare(!sharing).catchError((_) => false));
  }

  /// Returns false when the user declines the screen capture prompt.
  Future<bool> setScreenShare(bool enabled) async {
    final participant = room.localParticipant;
    if (participant == null) return false;

    if (!enabled) {
      await participant.setScreenShareEnabled(false);
      if (_isAndroid) await _systemChannel.invokeMethod('setScreenCapture', {'enabled': false});
    } else {
      if (_isAndroid) {
        // ignore: experimental_member_use
        if (!await sdk.Hardware.instance.requestCapturePermission()) return false;
        // Android 14+ needs a mediaProjection foreground service before capture starts.
        await _systemChannel.invokeMethod('setScreenCapture', {'enabled': true});
      }
      try {
        await participant.setScreenShareEnabled(true);
      } catch (error) {
        _logger.warning('Screen share failed: $error');
        if (_isAndroid) await _systemChannel.invokeMethod('setScreenCapture', {'enabled': false});
        rethrow;
      }
    }

    isScreenSharing = enabled;
    notifyListeners();
    return true;
  }

  void toggleAgentScreenMode() {
    agentScreenState =
        agentScreenState == AgentScreenState.visualizer ? AgentScreenState.transcription : AgentScreenState.visualizer;
    notifyListeners();
  }

  /// A call started by the master phone: a transcribed [command] (no microphone)
  /// or, in cloud mode, a call that takes the audio after "Jarvis". Both hang up
  /// by themselves after Jarvis has answered.
  @override
  Future<void> connectForMaster({String? command, required bool audio}) =>
      _connect(command: command, audio: audio, masterCall: true);

  /// The Start call button, and routines opened by an alarm. On the master phone
  /// a routine only speaks: the microphone is not published.
  void connect({String? routineId}) {
    final speakOnly = routineId != null && master.enabled;
    unawaited(_connect(routineId: routineId, audio: !speakOnly, masterCall: speakOnly));
  }

  Future<void> _connect({String? routineId, String? command, required bool audio, required bool masterCall}) async {
    if (isSessionStarting || session.connectionState != sdk.ConnectionState.disconnected) {
      _logger.fine('Connection attempt ignored: session already starting.');
      return;
    }

    _logger.info('Starting session connection…');
    isSessionStarting = true;
    errorMessage = null;
    _callHasAudio = audio;
    _masterCall = masterCall;
    notifyListeners();

    // The master phone hands its microphone over (or keeps it closed) first.
    await master.beforeCall(audio: audio, autoHangUp: masterCall);
    var connected = false;
    final api = jarvisApi;
    try {
      if (api != null) {
        if (!await api.isPaired()) {
          isPaired = false;
          return;
        }
        await _prepareServerSession(api, routineId: routineId, command: command, audio: audio);
      }
      if (audio) {
        await session.start();
      } else {
        // Session.start() would publish the microphone: join to listen only.
        final credentials = _jarvisTokens.next;
        if (credentials == null) throw StateError('No credentials for the call.');
        await room.connect(credentials.serverUrl, credentials.participantToken);
      }
      if (_startCancelled) {
        await session.end();
        await _releaseServerSession();
      } else if (session.connectionState == sdk.ConnectionState.connected) {
        connected = true;
        _roomWasConnected = true;
        appScreenState = AppScreenState.agent;
        _syncBackgroundMode();
        _startHeartbeat();
        notifyListeners();
      } else {
        await _releaseServerSession();
      }
    } on JarvisApiException catch (error) {
      _logger.warning('Home server: $error');
      errorMessage = error.userMessage;
      if (error.kind == JarvisErrorKind.unauthorized) isPaired = false;
      appScreenState = AppScreenState.welcome;
      await _releaseServerSession();
    } catch (error, stackTrace) {
      if (!_startCancelled) _logger.severe('Connection error: $error', error, stackTrace);
      appScreenState = AppScreenState.welcome;
      await _releaseServerSession();
    } finally {
      isSessionStarting = false;
      statusMessage = null;
      if (!connected) master.afterCall();
      notifyListeners();
    }
  }

  /// Whether this call was started by the master phone (it ends by itself).
  bool get isMasterCall => _masterCall;

  /// Whether the microphone is published in this call.
  @override
  bool get callHasAudio => _callHasAudio;

  @override
  Future<void> disconnect() async {
    _roomWasConnected = false;
    try {
      await session.end();
    } finally {
      // Runs even if ending the LiveKit session failed, so the server can stop the agent.
      unawaited(_releaseServerSession());
    }
    session.restoreMessageHistory(const []);
    appScreenState = AppScreenState.welcome;
    agentScreenState = AgentScreenState.visualizer;
    _syncBackgroundMode();
    master.afterCall();
    notifyListeners();
  }

  void _handleSessionChange() {
    final sdk.ConnectionState state = session.connectionState;
    AppScreenState? nextScreen;
    switch (state) {
      case sdk.ConnectionState.connected:
      case sdk.ConnectionState.reconnecting:
        nextScreen = AppScreenState.agent;
        break;
      case sdk.ConnectionState.disconnected:
        nextScreen = AppScreenState.welcome;
        break;
      case sdk.ConnectionState.connecting:
        nextScreen = null;
        break;
    }

    // The room closed without the user hanging up here: the agent ended the call,
    // or the connection was lost for good. Release the server session too.
    if (state == sdk.ConnectionState.disconnected && _roomWasConnected && !isSessionStarting) {
      _roomWasConnected = false;
      unawaited(_releaseServerSession());
      master.afterCall();
    }

    if (nextScreen != null && nextScreen != appScreenState) {
      appScreenState = nextScreen;
      _syncBackgroundMode();
      notifyListeners();
    }
  }
}
