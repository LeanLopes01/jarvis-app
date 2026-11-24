import 'dart:async';
import 'dart:collection';

import 'package:logging/logging.dart';

/// One spoken line at a time, using the same voice session as calls.
///
/// Speaking never opens the microphone: [onSpeaking] lets the controller close it
/// first (so Jarvis cannot wake itself) and open it again afterwards.
class SpeechQueue {
  SpeechQueue({required this.onSpeaking, required this.speak, required this.stopSpeaking});

  static final _logger = Logger('SpeechQueue');

  final Future<void> Function(bool speaking) onSpeaking;
  final Future<bool> Function(String text) speak;
  final Future<void> Function() stopSpeaking;
  final _queue = Queue<_Line>();
  bool _busy = false;
  int _holds = 0;
  _Line? _current;
  int _generation = 0; // stop() starts a new one; late callbacks are ignored

  /// The voice in use and whether it works without the internet; null until ready.
  String? voiceName = 'JARVIS call voice';
  bool? voiceOffline = false;
  bool available = false;

  Future<void> init() async {
    available = true;
  }

  /// Delay spoken lines while the user is speaking a command or in a call.
  void hold() => _holds++;

  void release() {
    if (_holds > 0) _holds--;
    unawaited(_drain());
  }

  bool get isBusy => _busy || _queue.isNotEmpty;

  /// Queues [text]; the future completes when it was spoken (true) or dropped.
  /// [force]: speak even while alerts are held (answers to "status" or "stop").
  Future<bool> say(String text, {bool urgent = false, bool force = false}) {
    final line = _Line(text, force: force);
    urgent || force ? _queue.addFirst(line) : _queue.add(line);
    unawaited(_drain());
    return line.done.future;
  }

  bool get isSpeaking => _current != null;

  /// Silence now: the line being spoken and everything queued are released.
  Future<void> stop() async {
    _generation++;
    for (final line in _queue) {
      if (!line.done.isCompleted) line.done.complete(false);
    }
    _queue.clear();
    final current = _current;
    if (current != null && !current.done.isCompleted) current.done.complete(false);
    try {
      if (current != null) await stopSpeaking().timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  /// A line may never report its end (a TTS engine bug): give up after a time that
  /// fits its length, so nothing waits on it forever.
  static Duration _deadline(String text) => Duration(milliseconds: 45000 + text.length * 100);

  Future<void> _drain() async {
    if (_busy || _queue.isEmpty || (_holds > 0 && !_queue.first.force)) return;
    _busy = true;
    try {
      await onSpeaking(true);
      while (_queue.isNotEmpty && (_holds == 0 || _queue.first.force)) {
        final line = _queue.removeFirst();
        final generation = _generation;
        _current = line;
        var ok = false;
        if (available) {
          try {
            final spoken = speak(line.text);
            ok = await Future.any([spoken, line.done.future.then((_) => false)])
                .timeout(_deadline(line.text));
          } on TimeoutException {
            _logger.warning('speech did not finish in time; stopping it');
            try {
              await stopSpeaking().timeout(const Duration(seconds: 10));
            } catch (_) {}
          } catch (error) {
            _logger.warning('speak failed: $error');
          }
        }
        _current = null;
        if (!line.done.isCompleted) line.done.complete(ok && generation == _generation);
      }
    } finally {
      _busy = false;
      await onSpeaking(false);
    }
  }
}

class _Line {
  _Line(this.text, {this.force = false});
  final String text;
  final bool force;
  final done = Completer<bool>();
}
