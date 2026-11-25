import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Application audit journal. Payloads are intentionally not redacted.
class AppLog {
  AppLog({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  static const retention = Duration(hours: 24);
  final DateTime Function() _clock;
  final String session =
      '${DateTime.now().microsecondsSinceEpoch}-$pid-${Random.secure().nextInt(1 << 30)}';
  final Stopwatch _uptime = Stopwatch()..start();
  Directory? directory;
  final Map<String, String> _failures = {};
  String? get lastError => _failures.isEmpty
      ? null
      : _failures.entries.map((e) => '${e.key}: ${e.value}').join('\n');
  set lastError(String? error) => reportFailure('initialization', error);
  void reportFailure(String area, Object? error) {
    final previous = _failures[area];
    if (error == null) {
      _failures.remove(area);
    } else {
      _failures[area] = error.toString();
    }
    if (previous != _failures[area]) onStatusChanged?.call();
  }

  void Function()? onStatusChanged;
  Future<void> _pending = Future.value();
  final List<Map<String, dynamic>> _backlog = [];
  Timer? _timer;
  int _sequence = 0;
  bool _closed = false;

  Future<void> initialize(Directory path) async {
    directory = path;
    await path.create(recursive: true);
    await prune();
    _timer ??= Timer.periodic(const Duration(minutes: 1), (_) {
      write('runtime', 'runtime.heartbeat', {
        'uptimeMs': _uptime.elapsedMilliseconds,
        'currentRss': ProcessInfo.currentRss,
        'maxRss': ProcessInfo.maxRss,
      });
      unawaited(prune());
    });
    if (_backlog.isNotEmpty) _schedule();
  }

  static Directory defaultDirectory() {
    final root =
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    return Directory('$root/OCSBridge/logs');
  }

  void write(
    String channel,
    String event,
    Map<String, dynamic> data, {
    String level = 'debug',
  }) {
    if (_closed) return;
    final now = _clock().toUtc();
    // Snapshot values immediately; later edits must not rewrite past events.
    final entry =
        jsonDecode(
              jsonEncode({
                'time': now.toIso8601String(),
                'localOffsetMinutes': _clock().timeZoneOffset.inMinutes,
                'session': session,
                'pid': pid,
                'sequence': ++_sequence,
                if (Zone.current[#ocsTraceId] != null)
                  'traceId': Zone.current[#ocsTraceId].toString(),
                'uptimeMs': _uptime.elapsedMilliseconds,
                'channel': channel,
                'level': level,
                'event': event,
                'data': data,
              }),
            )
            as Map<String, dynamic>;
    _backlog.add(entry);
    if (directory != null) _schedule();
  }

  void error(
    String event,
    Object error,
    StackTrace stack, [
    Map<String, dynamic> data = const {},
  ]) {
    write('runtime', event, {
      ...data,
      'errorType': error.runtimeType.toString(),
      'error': error.toString(),
      'stack': stack.toString(),
    }, level: 'error');
  }

  void _schedule() {
    _pending = _pending.then((_) async {
      var remaining = _backlog.length;
      while (remaining-- > 0 && _backlog.isNotEmpty && directory != null) {
        final entry = _backlog.first;
        try {
          final stamp = DateTime.parse(entry['time'] as String).toUtc();
          if (stamp.isBefore(_clock().toUtc().subtract(retention))) {
            _backlog.removeAt(0);
            continue;
          }
          final bucket = stamp
              .toIso8601String()
              .substring(0, 16)
              .replaceAll(RegExp('[-:]'), '')
              .replaceAll('T', '-');
          final file = File(
            '${directory!.path}/${entry['channel']}-$bucket-$session.jsonl',
          );
          await file.writeAsString(
            '${jsonEncode(entry)}\n',
            mode: FileMode.append,
            flush: true,
          );
          _backlog.removeAt(0);
          reportFailure('write', null);
        } catch (error) {
          reportFailure('write', error);
          break; // Retain unwritten entries for the next write/flush attempt.
        }
      }
    });
  }

  Future<void> flush() async {
    if (_backlog.isNotEmpty && directory != null) _schedule();
    await _pending;
    if (_failures['write'] != null) {
      throw FileSystemException(_failures['write']!, directory?.path);
    }
  }

  Future<void> prune() {
    final work = _pending.then((_) async {
      if (directory == null || !await directory!.exists()) return;
      final cutoff = _clock().toUtc().subtract(retention);
      final files = await directory!
          .list(followLinks: false)
          .where((f) => f is File)
          .cast<File>()
          .toList();
      for (final file in files) {
        final name = file.uri.pathSegments.last;
        final match = RegExp(
          r'^(runtime|network|answers|interaction)-(\d{8})-(\d{4})-.+\.jsonl$',
        ).firstMatch(name);
        if (match == null) {
          if (RegExp(r'^native-.+\.(log|dmp)$').hasMatch(name) &&
              (await file.stat()).modified.toUtc().isBefore(cutoff)) {
            await file.delete();
          }
          continue;
        }
        final d = match[2]!, t = match[3]!;
        final start = DateTime.utc(
          int.parse(d.substring(0, 4)),
          int.parse(d.substring(4, 6)),
          int.parse(d.substring(6, 8)),
          int.parse(t.substring(0, 2)),
          int.parse(t.substring(2, 4)),
        );
        if (!start.add(const Duration(minutes: 1)).isAfter(cutoff)) {
          await file.delete();
        } else if (start.isBefore(cutoff)) {
          final kept = <String>[];
          await for (final line
              in file
                  .openRead()
                  .transform(utf8.decoder)
                  .transform(const LineSplitter())) {
            try {
              final entry = jsonDecode(line) as Map;
              if (!DateTime.parse(
                entry['time'] as String,
              ).toUtc().isBefore(cutoff)) {
                kept.add(line);
              }
            } catch (_) {
              /* Discard an expired or incomplete boundary entry. */
            }
          }
          if (kept.isEmpty) {
            await file.delete();
          } else {
            final temp = File('${file.path}.$session.prune');
            await temp.writeAsString('${kept.join('\n')}\n', flush: true);
            await temp.rename(file.path);
          }
        }
      }
    });
    _pending = work.then((_) => reportFailure('retention', null)).catchError((
      Object error,
      StackTrace stack,
    ) {
      reportFailure('retention', error);
    });
    return _pending;
  }

  Future<List<Map<String, dynamic>>> read(String channel) async {
    await flush();
    if (directory == null || !await directory!.exists()) return [];
    final result = <Map<String, dynamic>>[];
    final cutoff = _clock().toUtc().subtract(retention);
    await for (final entity in directory!.list(followLinks: false)) {
      if (entity is! File ||
          !entity.uri.pathSegments.last.startsWith('$channel-') ||
          !entity.path.endsWith('.jsonl')) {
        continue;
      }
      await for (final line
          in entity
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        try {
          final entry = jsonDecode(line) as Map<String, dynamic>;
          if (!DateTime.parse(
            entry['time'] as String,
          ).toUtc().isBefore(cutoff)) {
            result.add(entry);
          }
        } catch (error, stack) {
          this.error('journal.read.error', error, stack, {
            'file': entity.path,
            'line': line,
          });
        }
      }
    }
    result.sort((a, b) {
      final time = (a['time'] as String).compareTo(b['time'] as String);
      if (time != 0) return time;
      final sessionOrder = (a['session'] as String).compareTo(
        b['session'] as String,
      );
      return sessionOrder != 0
          ? sessionOrder
          : (a['sequence'] as int).compareTo(b['sequence'] as int);
    });
    return result;
  }

  Future<void> close() async {
    if (_closed) return;
    _timer?.cancel();
    write('runtime', 'runtime.stop', {'uptimeMs': _uptime.elapsedMilliseconds});
    await flush();
    _closed = true;
  }
}

Map<String, List<String>> logHeaders(HttpHeaders headers) {
  final result = <String, List<String>>{};
  headers.forEach((name, values) => result[name] = List.of(values));
  return result;
}

Map<String, dynamic> logBytes(List<int> bytes) => {
  'byteLength': bytes.length,
  'utf8': utf8.decode(bytes, allowMalformed: true),
  'base64': base64Encode(bytes),
};

Map<String, dynamic>? logConnection(HttpConnectionInfo? info) => info == null
    ? null
    : {
        'remoteAddress': info.remoteAddress.address,
        'remotePort': info.remotePort,
        'localPort': info.localPort,
      };

Map<String, dynamic> logResponseMetadata(HttpClientResponse response) {
  final certificate = response.certificate;
  return {
    'status': response.statusCode,
    'reason': response.reasonPhrase,
    'headers': logHeaders(response.headers),
    'contentLength': response.contentLength,
    'compressionState': response.compressionState.name,
    'persistentConnection': response.persistentConnection,
    'isRedirect': response.isRedirect,
    'redirects': response.redirects
        .map(
          (r) => {
            'status': r.statusCode,
            'method': r.method,
            'location': r.location.toString(),
          },
        )
        .toList(),
    'connection': logConnection(response.connectionInfo),
    if (certificate != null)
      'certificate': {
        'subject': certificate.subject,
        'issuer': certificate.issuer,
        'startValidity': certificate.startValidity.toUtc().toIso8601String(),
        'endValidity': certificate.endValidity.toUtc().toIso8601String(),
        'pem': certificate.pem,
        'der': base64Encode(certificate.der),
      },
  };
}
