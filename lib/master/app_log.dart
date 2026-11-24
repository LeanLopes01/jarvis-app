import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

/// The app's recent log lines, for JARVIS's diagnostics reports.
///
/// Kept in memory and written to a file every 30 s and after each error, so the
/// lines from before a crash are still there the next time the app opens.
class AppLog {
  AppLog._();

  static final instance = AppLog._();
  static const _limit = 3000;
  static const _fileName = 'app_log.txt';
  static const _previousName = 'app_log.previous.txt';

  final _lines = Queue<String>();
  File? _file;
  String? previousRun;
  Timer? _timer;
  bool _dirty = false;

  Future<void> init() async {
    Logger.root.onRecord.listen(_onRecord);
    try {
      final dir = await getApplicationSupportDirectory();
      final current = File('${dir.path}/$_fileName');
      if (await current.exists()) {
        // What the last run wrote: the most useful part after a crash.
        await current.copy('${dir.path}/$_previousName');
      }
      final previous = File('${dir.path}/$_previousName');
      if (await previous.exists()) previousRun = await previous.readAsString();
      _file = current;
      _timer = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(flush()));
    } catch (_) {
      // Logging must never stop the app.
    }
  }

  void add(String line) {
    _lines.add('${DateTime.now().toIso8601String()} $line');
    while (_lines.length > _limit) {
      _lines.removeFirst();
    }
    _dirty = true;
  }

  void _onRecord(LogRecord record) {
    final error = record.error == null ? '' : ' | ${record.error}';
    add('${record.level.name} ${record.loggerName}: ${record.message}$error');
    if (record.level >= Level.WARNING) unawaited(flush());
  }

  List<String> get lines => List.unmodifiable(_lines);

  Future<void> flush() async {
    final file = _file;
    if (file == null || !_dirty) return;
    _dirty = false;
    try {
      await file.writeAsString(_lines.join('\n'), flush: true);
    } catch (_) {}
  }

  void dispose() => _timer?.cancel();
}
