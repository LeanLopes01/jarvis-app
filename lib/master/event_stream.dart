import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';

import '../services/jarvis_api.dart';
import 'event_store.dart';
import 'models.dart';

enum StreamState { offline, connecting, online, notMaster }

/// The master phone's live link for agent events: a light WebSocket to
/// jarvis-control (no LiveKit, no audio). It resumes from the stored cursor, so a
/// drop or a restart only delays events; the background check covers the rest.
class EventStream {
  EventStream(this._api, this._store, {required this.onEvent});

  static final _logger = Logger('EventStream');

  final JarvisApi _api;
  final MasterStore _store;

  /// Called once per new event; returns when the phone has handled it.
  final Future<void> Function(AgentEvent event) onEvent;

  final _state = StreamController<StreamState>.broadcast();
  Stream<StreamState> get states => _state.stream;
  StreamState state = StreamState.offline;

  WebSocket? _socket;
  bool _running = false;
  int _failures = 0;
  Completer<void>? _wake;
  DateTime? lastEventAt;

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop());
  }

  Future<void> stop() async {
    _running = false;
    _wake?.complete();
    await _socket?.close();
    _setState(StreamState.offline);
  }

  /// Reconnect now instead of waiting for the backoff (network came back, app resumed).
  void nudge() {
    if (_wake != null && !_wake!.isCompleted) _wake!.complete();
  }

  void ack(String eventId, String stage) {
    final socket = _socket;
    if (socket != null && socket.readyState == WebSocket.open) {
      socket.add(jsonEncode({'type': 'ack', 'event_id': eventId, 'stage': stage}));
    } else {
      unawaited(_api.ackEvent(eventId, stage).catchError((Object e) => _logger.fine('ack later: $e')));
    }
  }

  void _setState(StreamState next) {
    if (state == next) return;
    state = next;
    _state.add(next);
  }

  Future<void> _loop() async {
    while (_running) {
      _setState(StreamState.connecting);
      try {
        await _store.reload();
        final socket = await _api.openEventStream(_store.cursor);
        _socket = socket;
        _failures = 0;
        _setState(StreamState.online);
        await for (final raw in socket) {
          final message = jsonDecode(raw as String) as Map<String, dynamic>;
          if (message['type'] == 'event') {
            await _handle(AgentEvent.fromJson((message['event'] as Map).cast<String, dynamic>()));
          } else if (message['type'] == 'ready') {
            // First connection ever: start from now, without replaying old history.
            if (_store.cursor == null) await _store.setCursor(message['cursor'] as String);
          }
        }
        if (socket.closeCode == 4001) {
          _setState(StreamState.notMaster);
          _running = false;
          return;
        }
      } on JarvisApiException catch (error) {
        _logger.fine('event stream: $error');
        if (error.kind == JarvisErrorKind.unauthorized) {
          _setState(StreamState.notMaster);
          _running = false;
          return;
        }
      } catch (error) {
        _logger.fine('event stream dropped: $error');
      }
      _socket = null;
      if (!_running) break;
      _setState(StreamState.offline);
      // 1, 2, 4 … 60 seconds, with jitter.
      final delay = min(60, 1 << min(_failures++, 6)) + Random().nextDouble();
      _wake = Completer<void>();
      await Future.any([_wake!.future, Future<void>.delayed(Duration(milliseconds: (delay * 1000).round()))]);
    }
  }

  Future<void> _handle(AgentEvent event) async {
    lastEventAt = DateTime.now();
    await _store.receiveEvent(event, onEvent);
    ack(event.id, 'received');
  }
}
