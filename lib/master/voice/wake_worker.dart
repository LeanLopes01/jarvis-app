import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

/// Runs in its own isolate: the "Jarvis" spotter, the end-of-command detector and
/// the offline transcription, all on the phone. Audio arrives as 16 kHz mono PCM.
///
/// In standby only the spotter sees the audio, and each chunk is dropped after it
/// is analysed (a one-second rolling buffer keeps the start of a command spoken
/// together with "Jarvis"). Nothing is recorded to disk or sent anywhere.
const sampleRate = 16000;
const _preRollSeconds = 0.4; // audio kept from just before the wake word ended
const _startTimeout = 2.5; // a bare wake word gets an acknowledgement
const _endSilence = 0.7; // + VAD's 0.25 s: about one second of silence
const _maxCommand = 30.0;
const _ignoreResidue = 0.25; // do not discard short commands after the wake word

class WakeWorkerConfig {
  const WakeWorkerConfig({
    required this.modelsDir,
    required this.keywordsFile,
    required this.sensitivity,
    required this.language,
  });

  final String modelsDir;
  final String keywordsFile;
  final double sensitivity;
  final String language;

  Map<String, Object> toMap() => {
        'modelsDir': modelsDir,
        'keywordsFile': keywordsFile,
        'sensitivity': sensitivity,
        'language': language,
      };

  factory WakeWorkerConfig.fromMap(Map map) => WakeWorkerConfig(
        modelsDir: map['modelsDir'] as String,
        keywordsFile: map['keywordsFile'] as String,
        sensitivity: (map['sensitivity'] as num).toDouble(),
        language: map['language'] as String,
      );
}

/// Isolate entry point. The first message sent back is this isolate's SendPort.
void wakeWorkerMain(SendPort toMain) {
  final inbox = ReceivePort();
  toMain.send(inbox.sendPort);
  _Worker? worker;
  inbox.listen((message) {
    final m = message as Map;
    switch (m['cmd']) {
      case 'init':
        try {
          so.initBindings();
          worker = _Worker(WakeWorkerConfig.fromMap(m['config'] as Map), toMain);
          toMain.send({'event': 'ready'});
        } catch (error) {
          toMain.send({'event': 'error', 'message': '$error'});
        }
      case 'audio':
        final bytes = (m['data'] as TransferableTypedData).materialize();
        worker?.feed(bytes.asInt16List(0, bytes.lengthInBytes ~/ 2));
      case 'mode':
        worker?.setMode(m['value'] as String);
      case 'listen':
        worker?.startCapture(manual: true);
      case 'dispose':
        worker?.free();
        inbox.close();
        Isolate.exit();
    }
  });
}

class _Worker {
  _Worker(WakeWorkerConfig config, this._out)
      : _kws = so.KeywordSpotter(so.KeywordSpotterConfig(
          model: so.OnlineModelConfig(
            transducer: so.OnlineTransducerModelConfig(
              encoder: '${config.modelsDir}/kws/encoder.int8.onnx',
              decoder: '${config.modelsDir}/kws/decoder.onnx',
              joiner: '${config.modelsDir}/kws/joiner.int8.onnx',
            ),
            tokens: '${config.modelsDir}/kws/tokens.txt',
            numThreads: 1,
            debug: false,
          ),
          keywordsFile: config.keywordsFile,
          // Tested on the desktop with these values: every "Jarvis" heard and no
          // wake on ordinary Portuguese sentences. Sensitivity moves both.
          keywordsScore: 1.5 + config.sensitivity,
          keywordsThreshold: 0.25 - 0.17 * config.sensitivity,
        )),
        _vad = so.VoiceActivityDetector(
          config: so.VadModelConfig(
            sileroVad: so.SileroVadModelConfig(
              model: '${config.modelsDir}/vad/silero_vad.onnx',
              minSilenceDuration: 0.25,
              minSpeechDuration: 0.15,
              maxSpeechDuration: _maxCommand,
            ),
            numThreads: 1,
            debug: false,
          ),
          bufferSizeInSeconds: _maxCommand + 5,
        ),
        _asr = so.OfflineRecognizer(so.OfflineRecognizerConfig(
          model: so.OfflineModelConfig(
            whisper: so.OfflineWhisperModelConfig(
              encoder: '${config.modelsDir}/whisper/tiny-encoder.int8.onnx',
              decoder: '${config.modelsDir}/whisper/tiny-decoder.int8.onnx',
              language: config.language,
              task: 'transcribe',
            ),
            tokens: '${config.modelsDir}/whisper/tiny-tokens.txt',
            numThreads: 4,
            debug: false,
          ),
        )) {
    _stream = _kws.createStream();
  }

  final SendPort _out;
  final so.KeywordSpotter _kws;
  final so.VoiceActivityDetector _vad;
  final so.OfflineRecognizer _asr;
  late so.OnlineStream _stream;

  String _mode = 'standby'; // standby | capture | idle | paused
  final _recent = Float32List(sampleRate); // rolling last second, standby only
  int _recentEnd = 0;
  int _recentFill = 0;
  final _command = <Float32List>[];
  int _captured = 0;
  bool _speech = false;
  int _lastSpeech = 0;

  void setMode(String mode) {
    if (mode == 'standby') {
      _kws.reset(_stream);
      _recentFill = 0;
    }
    if (mode != 'capture') _clearCommand();
    _mode = mode;
  }

  void feed(Int16List pcm) {
    if (_mode == 'idle' || _mode == 'paused' || pcm.isEmpty) return;
    final samples = Float32List(pcm.length);
    for (var i = 0; i < pcm.length; i++) {
      samples[i] = pcm[i] / 32768.0;
    }
    if (_mode == 'standby') {
      _remember(samples);
      _stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
      while (_kws.isReady(_stream)) {
        _kws.decode(_stream);
        if (_kws.getResult(_stream).keyword.isNotEmpty) {
          _kws.reset(_stream);
          _out.send({'event': 'wake'});
          startCapture(manual: false);
          return;
        }
      }
    } else if (_mode == 'capture') {
      _capture(samples);
    }
  }

  void _remember(Float32List samples) {
    for (final s in samples) {
      _recent[_recentEnd] = s;
      _recentEnd = (_recentEnd + 1) % _recent.length;
    }
    _recentFill = min(_recent.length, _recentFill + samples.length);
  }

  void startCapture({required bool manual}) {
    _clearCommand();
    _vad.reset();
    _mode = 'capture';
    if (manual) {
      _out.send({'event': 'wake', 'manual': true});
    } else {
      // Keep the start of "Jarvis, change the song" said in one breath.
      final keep = min(_recentFill, (_preRollSeconds * sampleRate).round());
      final pre = Float32List(keep);
      for (var i = 0; i < keep; i++) {
        pre[i] = _recent[(_recentEnd - keep + i + _recent.length) % _recent.length];
      }
      _recentFill = 0;
      _capture(pre, preRoll: true);
    }
  }

  void _capture(Float32List samples, {bool preRoll = false}) {
    _command.add(samples);
    _captured += samples.length;
    _vad.acceptWaveform(samples);
    final seconds = _captured / sampleRate;
    if (!preRoll && _vad.isDetected() && seconds > _ignoreResidue) {
      if (!_speech) _out.send({'event': 'speech'});
      _speech = true;
      _lastSpeech = _captured;
    }
    if (!_speech && seconds > _startTimeout) {
      _finish('no_speech');
    } else if (_speech && (_captured - _lastSpeech) / sampleRate > _endSilence) {
      _finish('silence');
    } else if (seconds > _maxCommand) {
      _finish('max');
    }
  }

  void _finish(String reason) {
    _mode = 'idle';
    _out.send({'event': 'endpoint', 'reason': reason});
    if (reason == 'no_speech') {
      _clearCommand();
      return;
    }
    final audio = Float32List(_captured);
    var offset = 0;
    for (final chunk in _command) {
      audio.setAll(offset, chunk);
      offset += chunk.length;
    }
    _clearCommand(); // the audio exists only until it is transcribed
    final started = DateTime.now();
    final stream = _asr.createStream();
    try {
      stream.acceptWaveform(samples: audio, sampleRate: sampleRate);
      _asr.decode(stream);
      final result = _asr.getResult(stream);
      _out.send({
        'event': 'transcript',
        'text': result.text.trim(),
        'lang': result.lang,
        'seconds': audio.length / sampleRate,
        'ms': DateTime.now().difference(started).inMilliseconds,
      });
    } catch (error) {
      _out.send({'event': 'error', 'message': 'transcription failed: $error'});
    } finally {
      stream.free();
    }
  }

  void _clearCommand() {
    _command.clear();
    _captured = 0;
    _speech = false;
    _lastSpeech = 0;
  }

  void free() {
    _stream.free();
    _kws.free();
    _vad.free();
    _asr.free();
  }
}
