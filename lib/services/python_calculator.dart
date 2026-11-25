import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'app_log.dart';

typedef PythonCalculation = ({String? value, String? approximation});

class PythonCalculator {
  static const maxBatchSize = 8;
  static const maxExpressionLength = 256;
  static const invalidExpression = '算式无效、无实数结果或超出计算范围';

  static final _directory = File(Platform.resolvedExecutable).parent.path;
  static final _bundled = File('$_directory/python/pythonw.exe');
  static bool get isBundled => _bundled.existsSync();

  final Set<Process> _processes = {};
  int _generation = 0;

  void cancelAll() {
    _generation++;
    for (final process in _processes) {
      process.kill();
    }
  }

  Future<String> calculate(
    String expression,
    Duration budget, {
    AppLog? log,
  }) async {
    final result = (await calculateBatch(
      [expression],
      budget,
      log: log,
    )).single;
    return result.value ?? (throw const FormatException(invalidExpression));
  }

  Future<List<PythonCalculation>> calculateBatch(
    List<String> expressions,
    Duration budget, {
    AppLog? log,
  }) async {
    final generation = _generation;
    final watch = Stopwatch()..start();
    final limit = budget < const Duration(seconds: 5)
        ? budget
        : const Duration(seconds: 5);
    final worker = File(
      '$_directory/data/flutter_assets/assets/python/calculator.py',
    );
    Process? process;
    int? exitCode;
    final output = BytesBuilder(copy: false);
    final errors = BytesBuilder(copy: false);
    Map<String, dynamic> diagnostics() => {
      'expressions': expressions,
      'executable': _bundled.path,
      'worker': worker.path,
      'pid': process?.pid,
      'exitCode': exitCode,
      'elapsedMs': watch.elapsedMilliseconds,
      'timeoutMs': limit.inMilliseconds,
      'stdout': logBytes(output.toBytes()),
      'stderr': logBytes(errors.toBytes()),
    };
    try {
      if (expressions.isEmpty || expressions.length > maxBatchSize) {
        throw const FormatException('本次计算的算式数量无效');
      }
      if (expressions.any(
        (expression) => expression.length > maxExpressionLength,
      )) {
        throw const FormatException('算式过长');
      }
      if (!worker.existsSync() || !isBundled) {
        throw const PythonUnavailable('缺少随包的 Python 或计算脚本，请完整解压 Windows 发行包');
      }
      if (watch.elapsed >= limit) throw TimeoutException('Python 启动前超时');
      final started = await Process.start(_bundled.path, [
        '-I',
        '-S',
        worker.path,
      ]);
      process = started;
      _processes.add(started);
      final exited = started.exitCode.then((code) {
        exitCode = code;
        _processes.remove(started);
      });
      if (generation != _generation) throw const PythonUnavailable('请求已取消');
      started.stdin.writeln(jsonEncode(expressions));
      await Future.wait<void>([
        started.stdin.close(),
        exited,
        started.stdout.forEach(output.add),
        started.stderr.forEach(errors.add),
      ]).timeout(limit - watch.elapsed);
      if (generation != _generation) throw const PythonUnavailable('请求已取消');
      if (exitCode != 0) {
        throw const PythonUnavailable('随包的 Python 或 SymPy 运行失败，请检查发行包是否完整');
      }
      final List<PythonCalculation> results;
      try {
        final data = jsonDecode(utf8.decode(output.toBytes())) as Map;
        final items = data['results'] as List;
        if (items.length != expressions.length) throw const FormatException();
        results = [
          for (final item in items)
            switch (item) {
              {
                'value': final String value,
                'approx': final String approximation,
              } =>
                (value: value, approximation: approximation),
              {'value': final String value} => (
                value: value,
                approximation: null,
              ),
              {'invalid': true} => (value: null, approximation: null),
              _ => throw const FormatException(),
            },
        ];
      } on FormatException {
        throw const PythonUnavailable('本机 Python 返回了无效结果，请检查发行包版本');
      } on TypeError {
        throw const PythonUnavailable('本机 Python 返回了无效结果，请检查发行包版本');
      }
      log?.write('runtime', 'python.calculate.complete', diagnostics());
      return results;
    } catch (error, stack) {
      log?.error('python.calculate.error', error, stack, diagnostics());
      final failure = switch (error) {
        ProcessException() => const PythonUnavailable(
          '无法启动随包的 Python，请检查发行包是否完整',
        ),
        TimeoutException() => const PythonUnavailable('本机 Python 计算超时'),
        IOException() => const PythonUnavailable('无法与随包的 Python 通信'),
        _ => null,
      };
      if (failure != null) Error.throwWithStackTrace(failure, stack);
      rethrow;
    } finally {
      if (process != null && _processes.remove(process)) process.kill();
    }
  }
}

class PythonUnavailable implements Exception {
  const PythonUnavailable(this.message);
  final String message;
}
