import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as sdk;

/// Why a call to the JARVIS home server failed, phrased for the user.
enum JarvisErrorKind { unauthorized, busy, maintenance, unavailable, startFailed, invalidCode }

class JarvisApiException implements Exception {
  JarvisApiException(this.kind, [this.detail]);

  final JarvisErrorKind kind;
  final String? detail;

  String get userMessage => switch (kind) {
        JarvisErrorKind.unauthorized => 'Este aparelho precisa ser pareado novamente com o servidor.',
        JarvisErrorKind.busy => 'O JARVIS já está em uma chamada em outro aparelho.',
        JarvisErrorKind.maintenance => 'O JARVIS está sendo atualizado. Tente de novo em instantes.',
        JarvisErrorKind.unavailable => 'Servidor indisponível. Verifique a internet ou se o servidor está ligado.',
        JarvisErrorKind.startFailed => 'O JARVIS não respondeu a tempo. Tente novamente.',
        JarvisErrorKind.invalidCode => 'Código de pareamento inválido ou expirado.',
      };

  @override
  String toString() => 'JarvisApiException($kind, $detail)';
}

/// A structured command the server or the PC refused, e.g. "pc_offline" or "policy".
class JarvisCommandException implements Exception {
  JarvisCommandException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'JarvisCommandException($code, $message)';
}

/// A session on the home server, as returned by jarvis-control.
class JarvisSession {
  JarvisSession.fromJson(Map<String, dynamic> json)
      : id = json['id'] as String,
        state = json['state'] as String,
        endReason = json['end_reason'] as String?,
        connection = json['connection'] == null
            ? null
            : sdk.TokenSourceResponse(
                serverUrl: json['connection']['server_url'] as String,
                participantToken: json['connection']['participant_token'] as String,
                roomName: json['connection']['room_name'] as String?,
              );

  final String id;
  final String state;
  final String? endReason;
  final sdk.TokenSourceResponse? connection;

  bool get isStarting => state == 'starting';
  bool get isUsable => state == 'ready' || state == 'active';
}

/// Client for jarvis-control: pairing, and starting/watching/ending sessions so the
/// agent only runs on the server while a call is open.
class JarvisApi {
  JarvisApi(String baseUrl) : _base = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/');

  static const _tokenKey = 'jarvis_device_token';
  static const _timeout = Duration(seconds: 15);
  static const _storage = FlutterSecureStorage();

  final Uri _base;
  final http.Client _http = http.Client();
  String? _token;

  Future<String?> _deviceToken() async => _token ??= await _storage.read(key: _tokenKey);

  Future<bool> isPaired() async => (await _deviceToken()) != null;

  Future<void> forget() async {
    _token = null;
    await _storage.delete(key: _tokenKey);
  }

  Future<void> pair(String code, String deviceName) async {
    final response = await _send('POST', 'v1/pair', body: {'code': code.trim(), 'name': deviceName}, auth: false);
    if (response.statusCode != 201) throw JarvisApiException(JarvisErrorKind.invalidCode);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['kind'] != 'app') throw JarvisApiException(JarvisErrorKind.invalidCode, 'code is not for the app');
    _token = body['device_token'] as String;
    await _storage.write(key: _tokenKey, value: _token);
  }

  /// [routineId] makes Jarvis speak first with that routine; [location] is the
  /// phone's approximate position, used for the weather. [command] is a request
  /// already transcribed on the phone; with it, or with [audio] false, the phone
  /// joins without publishing its microphone.
  Future<JarvisSession> createSession(
    String idempotencyKey, {
    String? routineId,
    Map<String, double>? location,
    String? command,
    bool audio = true,
  }) async =>
      _session(await _send('POST', 'v1/sessions', headers: {
        'Idempotency-Key': idempotencyKey
      }, body: {
        if (routineId != null) 'routine_id': routineId,
        if (location != null) 'location': location,
        if (command != null) 'command': {'text': command},
        if (!audio) 'audio': false,
      }));

  /// This phone's role: {"master": bool, "music_target": "computer" | null}.
  Future<Map<String, dynamic>> deviceProfile() async => _json(await _send('GET', 'v1/devices/me'));
  Future<Map<String, dynamic>> softwareUpdates(String channel) async => _checked(await _send('GET', 'v1/updates?channel=$channel'));
  Future<String?> installUpdate(String hash) => const MethodChannel('jarvis/updates').invokeMethod<String>('install', {'token': _token, 'sha256': hash});

  Future<Map<String, dynamic>> integrations() async {
    final response = await _send('GET', 'v1/integrations');
    if (response.statusCode == 404) {
      throw JarvisCommandException('server_update_required', 'O servidor ainda precisa receber a atualização de Conexões. As outras funções continuam disponíveis.');
    }
    return _checked(response);
  }

  Future<Map<String, dynamic>> updateIntegration(String id, Map<String, dynamic> changes) async =>
      _checked(await _send('PATCH', 'v1/integrations/${Uri.encodeComponent(id)}', body: changes));

  /// Agent events after [cursor]; a null cursor returns none and the latest cursor.
  Future<({List<Map<String, dynamic>> events, String cursor})> events(String? cursor) async {
    final body = _json(await _send('GET', 'v1/events?after=${cursor ?? 'latest'}'));
    return (events: (body['events'] as List).cast<Map<String, dynamic>>(), cursor: body['cursor'] as String);
  }

  Future<Map<String, dynamic>> report(String eventId) async => _json(await _send('GET', 'v1/reports/$eventId'));

  /// Latest full output/report for one or all coding agents ("all", "claude", "codex", "antigravity").
  Future<Map<String, dynamic>?> latestReport(String agent) async {
    final http.Response response;
    try {
      response = await _send('GET', 'v1/reports/latest?agent=${Uri.encodeQueryComponent(agent)}',
          timeout: const Duration(seconds: 15));
    } on JarvisApiException {
      return null;
    }
    if (response.statusCode != 200) return null;
    return _json(response);
  }

  /// stage: received, displayed, announced or read.
  Future<void> ackEvent(String eventId, String stage) async {
    await _send('POST', 'v1/events/$eventId/ack', body: {'stage': stage});
  }

  /// Message notifications seen on this phone: metadata only, never the text.
  Future<void> reportMessages(List<Map<String, dynamic>> items) async {
    await _send('POST', 'v1/mobile-notifications', body: {'items': items});
  }

  Future<Map<String, dynamic>> diagnostics() async => _json(await _send('GET', 'v1/diagnostics'));

  /// Claude Code, Codex and Antigravity (Gemini) limits, read on the PC.
  Future<Map<String, dynamic>> usage() async {
    final http.Response response;
    try {
      response = await _send('GET', 'v1/usage');
    } on JarvisApiException catch (error) {
      if (error.detail == 'pc_offline') throw JarvisCommandException('pc_offline', 'The computer is not connected.');
      if (error.detail == 'timeout') throw JarvisCommandException('timeout', 'No answer in time.');
      rethrow;
    }
    final body = _json(response);
    if (response.statusCode != 200) {
      throw JarvisCommandException(body['error'] as String? ?? 'failed', body['message'] as String? ?? 'No usage.');
    }
    return body;
  }

  /// Runs a structured command (music.play, music.control, music.volume,
  /// music.status) once per [id]. Returns the result, or throws [JarvisCommandException].
  Future<Map<String, dynamic>> command(
    String id,
    String kind,
    Map<String, dynamic> params, {
    Duration ttl = const Duration(seconds: 30),
    Future<void>? abort,
  }) async {
    final deadline = DateTime.now().add(ttl).millisecondsSinceEpoch / 1000;
    final http.Response response;
    try {
      response = await _send(
        'POST',
        'v1/commands',
        body: {'id': id, 'kind': kind, 'params': params, 'deadline': deadline},
        // A little longer than the server's own deadline, so its answer arrives.
        timeout: ttl + const Duration(seconds: 5),
        abort: abort,
      );
    } on JarvisApiException catch (error) {
      if (error.detail == 'pc_offline') throw JarvisCommandException('pc_offline', 'The computer is not connected.');
      if (error.detail == 'aborted') throw JarvisCommandException('aborted', 'Stopped on the phone.');
      if (error.detail == 'timeout') throw JarvisCommandException('timeout', 'No answer in time.');
      throw JarvisCommandException('unavailable', error.userMessage);
    }
    final body = _json(response);
    if (response.statusCode == 200) return (body['result'] as Map?)?.cast<String, dynamic>() ?? {};
    throw JarvisCommandException(body['error'] as String? ?? 'failed', body['message'] as String? ?? 'The command failed.');
  }

  /// What is running for this phone, read without touching the music queue.
  Future<Map<String, dynamic>> runtime({Duration timeout = const Duration(seconds: 3)}) async =>
      _json(await _send('GET', 'v1/runtime', timeout: timeout));

  /// Ask to stop one operation; the answer says whether it is confirmed.
  Future<Map<String, dynamic>> cancelOperation(String id) async =>
      _json(await _send('POST', 'v1/operations/$id/cancel', timeout: const Duration(seconds: 4)));

  Future<Map<String, dynamic>> cancelAllOperations() async =>
      _json(await _send('POST', 'v1/operations/cancel-all', timeout: const Duration(seconds: 4)));

  /// Collect a report about JARVIS itself (saved in JARVIS-Notas/Relatorios).
  Future<Map<String, dynamic>> createDiagnosticReport(Map<String, dynamic> body) async =>
      _json(await _send('POST', 'v1/diagnostic-reports', body: body, timeout: const Duration(seconds: 20)));

  Future<List<Map<String, dynamic>>> diagnosticReports() async =>
      ((_json(await _send('GET', 'v1/diagnostic-reports'))['reports'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();

  Future<String> diagnosticReportText(String id) async {
    final response = await _send('GET', 'v1/diagnostic-reports/$id/md');
    if (response.statusCode != 200) throw JarvisApiException(JarvisErrorKind.unavailable, 'HTTP ${response.statusCode}');
    return utf8.decode(response.bodyBytes);
  }

  // Projects (DiceVTT): conversations with the coordinator, plans, runs.
  Future<Map<String, dynamic>> orchestrationRuntime() async =>
      _checked(await _send('GET', 'v1/orchestration/runtime'));

  Future<Map<String, dynamic>> _checked(http.Response response) async {
    final body = _json(response);
    if (response.statusCode >= 400) {
      throw JarvisCommandException(body['error'] as String? ?? 'failed', body['message'] as String? ?? 'HTTP ${response.statusCode}');
    }
    return body;
  }

  Future<List<Map<String, dynamic>>> conversations(String project) async =>
      ((await _checked(await _send('GET', 'v1/conversations?project=$project')))['conversations'] as List)
          .cast<Map<String, dynamic>>();

  Future<Map<String, dynamic>> conversation(String id) async => _checked(await _send('GET', 'v1/conversations/$id'));

  /// Starts a conversation, or continues [conversationId]. Returns at once.
  Future<Map<String, dynamic>> sendProjectMessage(String project, String text,
      {String? conversationId, required String requestId}) async {
    final path = conversationId == null ? 'v1/conversations' : 'v1/conversations/$conversationId/messages';
    return _checked(await _send('POST', path, body: {'project': project, 'text': text, 'request_id': requestId}));
  }

  Future<List<Map<String, dynamic>>> pendingPlans() async =>
      ((await _checked(await _send('GET', 'v1/plans/pending')))['plans'] as List).cast<Map<String, dynamic>>();

  /// decision: approve or reject. [version] and [hash] make sure the plan shown is the plan decided.
  Future<Map<String, dynamic>> decidePlan(String planId, String decision, {int? version, String? hash, String? text}) async =>
      _checked(await _send('POST', 'v1/plans/$planId/$decision', body: {
        if (version != null) 'version': version,
        if (hash != null) 'hash': hash,
        if (text != null) 'text': text,
      }));

  Future<Map<String, dynamic>> cancelRun(String runId) async => _checked(await _send('POST', 'v1/runs/$runId/cancel'));

  Future<Map<String, dynamic>> applyRun(String runId) async =>
      _checked(await _send('POST', 'v1/runs/$runId/apply', timeout: const Duration(seconds: 150)));

  Future<List<Map<String, dynamic>>> orchestrationActive() async =>
      ((await _checked(await _send('GET', 'v1/orchestration/active', timeout: const Duration(seconds: 3))))['active'] as List)
          .cast<Map<String, dynamic>>();

  Future<Map<String, dynamic>> orchestrationCancel({String? agent}) async =>
      _checked(await _send('POST', 'v1/orchestration/cancel', body: {if (agent != null) 'agent': agent}));

  // DiceVTT RAG: runs on the primary PC with the helper; the server relays.
  Future<Map<String, dynamic>> ragHealth() async =>
      _checked(await _send('GET', 'v1/rag/health', timeout: const Duration(seconds: 12)));

  /// Sources only (scripts read from disk now + documentation chunks), in seconds.
  Future<Map<String, dynamic>> ragRetrieve(String query, {int textLimit = 6000}) async => _checked(await _send(
      'POST', 'v1/rag/retrieve',
      body: {'project_id': 'dicevtt', 'query': query, 'text_limit': textLimit}, timeout: const Duration(seconds: 65)));

  /// Starts a local AirLLM answer on the PC (minutes); poll [ragAskStatus]. [requestId]
  /// makes a resend return the same request.
  Future<Map<String, dynamic>> ragAsk(String query, {required String requestId}) async => _checked(await _send(
      'POST', 'v1/rag/asks', body: {'project_id': 'dicevtt', 'query': query, 'request_id': requestId},
      timeout: const Duration(seconds: 35)));

  Future<Map<String, dynamic>> ragAskStatus(String askId) async => _checked(await _send('GET', 'v1/rag/asks/$askId'));

  Future<Map<String, dynamic>> ragAskCancel(String askId) async =>
      _checked(await _send('POST', 'v1/rag/asks/$askId/cancel'));

  /// scope: code, documents or all.
  Future<Map<String, dynamic>> ragIndex(String scope) async =>
      _checked(await _send('POST', 'v1/rag/index-jobs', body: {'project_id': 'dicevtt', 'scope': scope}));

  Future<Map<String, dynamic>> ragIndexStatus(String jobId) async => _checked(await _send('GET', 'v1/rag/index-jobs/$jobId'));

  /// The event stream for the master phone, resumed after [cursor].
  Future<WebSocket> openEventStream(String? cursor) async {
    final token = await _deviceToken();
    if (token == null) throw JarvisApiException(JarvisErrorKind.unauthorized);
    final http = _base.resolve('v1/events/stream?after=${cursor ?? 'latest'}');
    final ws = http.replace(scheme: http.scheme == 'https' ? 'wss' : 'ws');
    try {
      return await WebSocket.connect(ws.toString(), headers: {'Authorization': 'Bearer $token'}).timeout(_timeout);
    } on WebSocketException catch (error) {
      // 401/403 arrive as a failed upgrade; the caller checks the profile.
      throw JarvisApiException(JarvisErrorKind.unavailable, error.message);
    } on SocketException catch (error) {
      throw JarvisApiException(JarvisErrorKind.unavailable, error.message);
    } on TimeoutException {
      throw JarvisApiException(JarvisErrorKind.unavailable, 'timeout');
    }
  }

  static Map<String, dynamic> _json(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      return body is Map<String, dynamic> ? body : {};
    } catch (_) {
      return {};
    }
  }

  Future<List<JarvisRoutine>> routines() async {
    final response = await _send('GET', 'v1/routines');
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['routines'] as List).map((r) => JarvisRoutine.fromJson(r as Map<String, dynamic>)).toList();
  }

  Future<JarvisRoutine> saveRoutine(JarvisRoutine routine) async {
    final response = routine.id == null
        ? await _send('POST', 'v1/routines', body: routine.toJson())
        : await _send('PUT', 'v1/routines/${routine.id}', body: routine.toJson());
    if (response.statusCode == 400) {
      final message = (jsonDecode(response.body) as Map<String, dynamic>)['message'] as String?;
      throw JarvisApiException(JarvisErrorKind.startFailed, message ?? 'Rotina inválida.');
    }
    return JarvisRoutine.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> deleteRoutine(String id) async {
    await _send('DELETE', 'v1/routines/$id');
  }

  /// Notifications newer than [after] (for example "Claude Code finished").
  Future<List<Map<String, dynamic>>> notifications(int after) async {
    final response = await _send('GET', 'v1/notifications?after=$after');
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['notifications'] as List).cast<Map<String, dynamic>>();
  }

  Future<JarvisSession> getSession(String id) async => _session(await _send('GET', 'v1/sessions/$id'));

  Future<JarvisSession> heartbeat(String id) async => _session(await _send('POST', 'v1/sessions/$id/heartbeat'));

  Future<void> endSession(String id) async {
    final response = await _send('DELETE', 'v1/sessions/$id');
    if (response.statusCode != 204 && response.statusCode != 404) {
      throw JarvisApiException(JarvisErrorKind.unavailable, 'end session: ${response.statusCode}');
    }
  }

  JarvisSession _session(http.Response response) {
    if (response.statusCode == 200 || response.statusCode == 202) {
      return JarvisSession.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    }
    throw JarvisApiException(JarvisErrorKind.unavailable, 'HTTP ${response.statusCode}');
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    bool auth = true,
    Duration? timeout,
    Future<void>? abort,
  }) async {
    // One deadline for the whole exchange, body included, and a real abort of the
    // request (not just giving up on waiting for it).
    final expired = Completer<void>();
    final timer = Timer(timeout ?? _timeout, () {
      if (!expired.isCompleted) expired.complete();
    });
    final trigger = abort == null ? expired.future : Future.any([expired.future, abort]);
    final request = http.AbortableRequest(method, _base.resolve(path), abortTrigger: trigger)
      ..headers.addAll(headers);
    if (auth) {
      final token = await _deviceToken();
      if (token == null) throw JarvisApiException(JarvisErrorKind.unauthorized);
      request.headers['Authorization'] = 'Bearer $token';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      response = await http.Response.fromStream(await _http.send(request))
          // Backstop in case the abort is not honoured by the platform.
          .timeout((timeout ?? _timeout) + const Duration(seconds: 2));
    } on http.RequestAbortedException {
      throw JarvisApiException(JarvisErrorKind.unavailable, expired.isCompleted ? 'timeout' : 'aborted');
    } on SocketException catch (error) {
      throw JarvisApiException(JarvisErrorKind.unavailable, error.message);
    } on TimeoutException {
      throw JarvisApiException(JarvisErrorKind.unavailable, 'timeout');
    } on http.ClientException catch (error) {
      throw JarvisApiException(JarvisErrorKind.unavailable, error.message);
    } finally {
      timer.cancel();
    }

    switch (response.statusCode) {
      case 401:
        if (auth) await forget();
        throw JarvisApiException(JarvisErrorKind.unauthorized);
      case 409:
        if (path.startsWith('v1/integrations/')) return response;
        // A command still running, or being stopped, and every project conflict
        // (an older plan, a wrong version): the body explains it.
        if (_errorCode(response) == 'in_progress' || _errorCode(response) == 'cancelled') return response;
        if (path.startsWith('v1/conversations') || path.startsWith('v1/plans') || path.startsWith('v1/runs')) {
          return response;
        }
        throw JarvisApiException(JarvisErrorKind.busy);
      case 429:
        throw JarvisApiException(JarvisErrorKind.unavailable, 'rate limited');
      case 503:
        final code = _errorCode(response);
        if (code == 'orchestrator_offline') return response;
        throw JarvisApiException(
            code == 'maintenance' ? JarvisErrorKind.maintenance : JarvisErrorKind.unavailable, code);
      case 504:
        // The PC did not answer a command in time; the body explains it.
        if (_errorCode(response) == 'timeout') return response;
        throw JarvisApiException(JarvisErrorKind.unavailable, 'HTTP 504');
      case >= 500:
        // 502/530 from Cloudflare: the tunnel or the server is down.
        throw JarvisApiException(JarvisErrorKind.unavailable, 'HTTP ${response.statusCode}');
    }
    return response;
  }

  static String? _errorCode(http.Response response) {
    try {
      return (jsonDecode(response.body) as Map<String, dynamic>)['error'] as String?;
    } catch (_) {
      return null;
    }
  }
}

/// Token source fed by [JarvisApi]: the controller prepares credentials for each
/// session before calling `Session.start()`, which then connects with them.
class JarvisTokenSource implements sdk.TokenSourceFixed {
  sdk.TokenSourceResponse? next;

  @override
  Future<sdk.TokenSourceResponse> fetch() async {
    final response = next;
    if (response == null) throw StateError('No JARVIS session was prepared before connecting.');
    return response;
  }
}


/// A scheduled moment when Jarvis speaks first (times are in GMT-3).
class JarvisRoutine {
  JarvisRoutine({
    this.id,
    required this.name,
    required this.enabled,
    required this.time,
    required this.days,
    required this.prompt,
    required this.location,
  });

  factory JarvisRoutine.fromJson(Map<String, dynamic> json) => JarvisRoutine(
        id: json['id'] as String?,
        name: json['name'] as String,
        enabled: json['enabled'] as bool? ?? true,
        time: json['time'] as String,
        days: (json['days'] as List).cast<int>(),
        prompt: json['prompt'] as String,
        location: json['location'] as String? ?? '',
      );

  final String? id;
  final String name;
  final bool enabled;
  final String time; // HH:MM
  final List<int> days; // 0 = Monday ... 6 = Sunday
  final String prompt;
  final String location;

  int get hour => int.parse(time.split(':')[0]);
  int get minute => int.parse(time.split(':')[1]);

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'name': name,
        'enabled': enabled,
        'time': time,
        'days': days,
        'prompt': prompt,
        'location': location,
      };

  JarvisRoutine copyWith({bool? enabled}) => JarvisRoutine(
        id: id,
        name: name,
        enabled: enabled ?? this.enabled,
        time: time,
        days: days,
        prompt: prompt,
        location: location,
      );
}
