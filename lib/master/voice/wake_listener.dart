import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:record/record.dart';

import 'voice_models.dart';
import 'wake_worker.dart';

sealed class WakeEvent {
  const WakeEvent();
}

/// "Jarvis" was heard (or the user tapped to speak).
class WakeHeard extends WakeEvent {
  const WakeHeard({required this.manual});
  final bool manual;
}

class SpeechStarted extends WakeEvent {
  const SpeechStarted();
}

/// The command ended: "silence", "max" (30 s), or "no_speech" (nothing said).
class CommandEnded extends WakeEvent {
  const CommandEnded(this.reason);
  final String reason;
}

class Transcript extends WakeEvent {
  const Transcript(this.text, {required this.audioSeconds, required this.elapsed, this.language});
  final String text;
  final double audioSeconds;
  final Duration elapsed;
  final String? language;
}

class WakeError extends WakeEvent {
  const WakeError(this.message);
  final String message;
}

/// The phone's microphone and the on-device voice worker.
///
/// The microphone is open only while waiting for "Jarvis" or capturing the
/// command after it. It is closed while the command is processed, while Jarvis
/// speaks, during calls (LiveKit takes it) and when listening is paused.
class WakeListener {
  static final _logger = Logger('WakeListener');

  final _events = StreamController<WakeEvent>.broadcast();
  Stream<WakeEvent> get events => _events.stream;

  Isolate? _isolate;
  SendPort? _worker;
  ReceivePort? _inbox;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _audio;
  Uint8List? _odd; // half of a 16-bit sample split across two chunks
  bool _ready = false;
  bool get ready => _ready;
  bool get micOpen => _audio != null;
  Future<void> _micTransition = Future<void>.value();
  DateTime? lastAudioAt;
  int audioChunks = 0;
  int peakLevel = 0;

  Future<void> _serialMic(Future<void> Function() action) {
    final next = _micTransition.then((_) => action());
    _micTransition = next.catchError((Object _) {});
    return next;
  }

  Future<void> start(VoiceModels models, {required double sensitivity, required String language}) async {
    if (_worker != null) return;
    final inbox = ReceivePort();
    _inbox = inbox;
    final ready = Completer<void>();
    _isolate = await Isolate.spawn(wakeWorkerMain, inbox.sendPort, debugName: 'jarvis-voice');
    inbox.listen((message) {
      if (message is SendPort) {
        _worker = message;
        message.send({
          'cmd': 'init',
          'config': WakeWorkerConfig(
            modelsDir: models.dir,
            keywordsFile: models.keywordsFile,
            sensitivity: sensitivity,
            language: language,
          ).toMap(),
        });
        return;
      }
      final m = message as Map;
      switch (m['event']) {
        case 'ready':
          _ready = true;
          if (!ready.isCompleted) ready.complete();
        case 'error':
          final error = WakeError(m['message'] as String);
          if (!ready.isCompleted) {
            ready.completeError(error.message);
          } else {
            _events.add(error);
          }
        case 'wake':
          _events.add(WakeHeard(manual: m['manual'] == true));
        case 'speech':
          _events.add(const SpeechStarted());
        case 'endpoint':
          _events.add(CommandEnded(m['reason'] as String));
        case 'transcript':
          _events.add(Transcript(
            m['text'] as String,
            audioSeconds: (m['seconds'] as num).toDouble(),
            elapsed: Duration(milliseconds: m['ms'] as int),
            language: m['lang'] as String?,
          ));
      }
    });
    try {
      // Loading the models takes a few seconds on a slow phone.
      await ready.future.timeout(const Duration(seconds: 90));
    } catch (error) {
      await dispose();
      rethrow;
    }
  }

  void _send(Map<String, Object> message) => _worker?.send(message);

  /// standby (spot "Jarvis"), idle (drop audio) or paused.
  void setMode(String mode) => _send({'cmd': 'mode', 'value': mode});

  /// Capture a command now, without the wake word (the on-screen button).
  void listenNow() => _send({'cmd': 'listen'});

  Future<bool> hasPermission() async => (_recorder ??= AudioRecorder()).hasPermission();

  Future<void> openMic() => _serialMic(_openMic);

  Future<void> _openMic() async {
    if (_audio != null || !ready) return;
    final recorder = _recorder ??= AudioRecorder();
    if (!await recorder.hasPermission()) throw StateError('microphone permission denied');
    final stream = await recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: sampleRate,
      numChannels: 1,
      // Do not take audio focus: the recording must not pause Spotify or the
      // phone's speech, nor stop when they play.
      audioInterruption: AudioInterruptionMode.none,
      androidConfig: AndroidRecordConfig(audioSource: AndroidAudioSource.voiceRecognition, manageBluetooth: false),
    ));
    _logger.info('Wake microphone opened');
    _audio = stream.listen(_forward, onError: (Object error) {
      _logger.warning('microphone stream error: $error');
      _events.add(WakeError('microphone: $error'));
    });
  }

  void _forward(Uint8List chunk) {
    lastAudioAt = DateTime.now();
    audioChunks++;
    var bytes = chunk;
    final odd = _odd;
    if (odd != null) {
      bytes = Uint8List(odd.length + chunk.length)
        ..setAll(0, odd)
        ..setAll(odd.length, chunk);
      _odd = null;
    }
    if (bytes.length.isOdd) {
      _odd = Uint8List.fromList([bytes.last]);
      bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
    }
    if (bytes.isEmpty) return;
    final pcm = ByteData.sublistView(bytes);
    var peak = 0;
    for (var i = 0; i < bytes.length; i += 2) {
      final value = pcm.getInt16(i, Endian.little).abs();
      if (value > peak) peak = value;
    }
    peakLevel = peak;
    _send({'cmd': 'audio', 'data': TransferableTypedData.fromList([bytes])});
  }

  Future<void> closeMic() => _serialMic(_closeMic);

  Future<void> _closeMic() async {
    final audio = _audio;
    _audio = null;
    _odd = null;
    await audio?.cancel();
    if (audio != null) _logger.info('Wake microphone closed after $audioChunks chunks');
    try {
      await _recorder?.stop();
    } catch (error) {
      _logger.fine('recorder stop: $error');
    }
  }

  Future<void> dispose() async {
    await closeMic();
    await _recorder?.dispose();
    _recorder = null;
    _send({'cmd': 'dispose'});
    _worker = null;
    _ready = false;
    _inbox?.close();
    _inbox = null;
    // The worker frees its models and exits; this only covers a stuck one.
    final isolate = _isolate;
    _isolate = null;
    Future<void>.delayed(const Duration(seconds: 3), () => isolate?.kill());
  }
}
