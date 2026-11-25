import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_controller.dart';
import 'domain/config.dart';
import 'services/config_store.dart';
import 'services/app_log.dart';
import 'services/interaction_audit.dart';
import 'services/python_calculator.dart';
import 'ui/app_shell.dart';
import 'ui/components.dart';

void main(List<String> arguments) {
  final log = AppLog();
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      try {
        await log.initialize(AppLog.defaultDirectory());
      } catch (error, stack) {
        log.lastError = error.toString();
        log.error('journal.initialize.error', error, stack);
      }
      log.write('runtime', 'runtime.start', {
        'arguments': arguments,
        'version': '0.2.3+6',
        'os': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'dartVersion': Platform.version,
        'executable': Platform.resolvedExecutable,
        'workingDirectory': Directory.current.path,
        'locale': Platform.localeName,
        'processors': Platform.numberOfProcessors,
        'logDirectory': log.directory?.path,
        'retentionHours': 24,
        'redacted': false,
      });
      FlutterError.onError = (details) {
        log.error(
          'flutter.error',
          details.exception,
          details.stack ?? StackTrace.current,
          {
            'library': details.library,
            'context': details.context?.toDescription(),
            'silent': details.silent,
            'information': details.informationCollector
                ?.call()
                .map((d) => d.toDescription())
                .toList(),
          },
        );
        FlutterError.presentError(details);
      };
      WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
        log.error('platform.unhandled', error, stack);
        unawaited(log.flush().catchError((Object _) {}));
        return true;
      };
      final audit = InteractionAudit(log)..start();
      final appKey = GlobalKey<_BootstrapState>();
      const MethodChannel('dev.ocsbridge/lifecycle').setMethodCallHandler((
        call,
      ) async {
        if (call.method != 'closeRequested') throw MissingPluginException();
        log.write('runtime', 'window.close.requested', {});
        try {
          await appKey.currentState?.app?.shutdown();
        } catch (error, stack) {
          log.error('app.shutdown.error', error, stack);
        }
        audit.dispose();
        await log.close();
        return null;
      });
      runApp(Bootstrap(key: appKey, log: log));
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          final status = await const MethodChannel(
            'dev.ocsbridge/files',
          ).invokeMapMethod<String, dynamic>('diagnosticsStatus');
          log.write('runtime', 'native.diagnostics.status', {'status': status});
          log.reportFailure(
            'native',
            status?['active'] == true ? null : '原生日志未启动',
          );
        } catch (error, stack) {
          log.error('native.diagnostics.error', error, stack);
          log.reportFailure('native', error);
        }
      });
      if (arguments.contains('--smoke-test') ||
          arguments.contains('--smoke-test-close') ||
          arguments.contains('--smoke-test-visible')) {
        unawaited(
          _nativeSmokeTest(
            log,
            closeWindow:
                arguments.contains('--smoke-test-close') ||
                arguments.contains('--smoke-test-visible'),
            expectVisible: arguments.contains('--smoke-test-visible'),
          ),
        );
      }
    },
    (error, stack) {
      log.error('zone.unhandled', error, stack);
      unawaited(log.flush().catchError((Object _) {}));
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        log.write('runtime', 'console.print', {'text': line});
        parent.print(zone, line);
      },
    ),
  );
}

Future<void> _nativeSmokeTest(
  AppLog log, {
  bool closeWindow = false,
  bool expectVisible = false,
}) async {
  final timeout = Timer(const Duration(seconds: 45), () {
    log.write('runtime', 'native.smoke.timeout', {}, level: 'error');
    exit(1);
  });
  final secrets = AuditedSecrets(VaultSecrets(), log);
  final id = 'smoke-${newId()}';
  var stage = 'config';
  try {
    final store = await ConfigStore.open();
    await store.load();
    if (PythonCalculator.isBundled) {
      stage = 'bundled-python';
      final python = PythonCalculator();
      const budget = Duration(seconds: 5);
      final results = await python.calculateBatch(
        [
          '0.1 + 0.2',
          'sin(radians(30))',
          'sqrt(72)',
          'solve(x^2 - 5*x + 6)',
          '1 / 0',
        ],
        budget,
        log: log,
      );
      final values = results.map((item) => item.value).toList();
      if (values[0] != '0.3' ||
          values[1] != '0.5' ||
          values[2] != '6*sqrt(2)' ||
          results[2].approximation == null ||
          values[3] != '{2, 3}' ||
          values[4] != null) {
        throw StateError('Bundled Python calculation mismatch');
      }
      final pending = python.calculate('1 + 1', budget, log: log);
      python.cancelAll();
      try {
        await pending;
        throw StateError('Bundled Python cancellation failed');
      } on PythonUnavailable catch (error) {
        if (error.message != '请求已取消') rethrow;
      }
      log.write('runtime', 'native.smoke.python', {
        'results': values,
        'cancelled': true,
      });
    }
    stage = 'vault-write';
    await secrets.write(id, 'native-smoke-placeholder');
    stage = 'vault-read';
    if (await secrets.read(id) != 'native-smoke-placeholder') {
      throw StateError('Vault mismatch');
    }
    stage = 'vault-delete';
    await secrets.delete(id);
    if (await secrets.read(id) != null) {
      throw StateError('Vault deletion failed');
    }
    stage = 'export-dialog';
    if (await const MethodChannel(
          'dev.ocsbridge/files',
        ).invokeMethod<bool>('probe') !=
        true) {
      throw StateError('Save dialog unavailable');
    }
    stage = 'frame';
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
    if (expectVisible) {
      stage = 'visible-window';
      var visible = false;
      for (var i = 0; i < 20 && !visible; i++) {
        visible =
            await const MethodChannel(
              'dev.ocsbridge/files',
            ).invokeMethod<bool>('windowVisible') ==
            true;
        if (!visible) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      if (!visible) throw StateError('Desktop window did not become visible');
    }
    await _smokeOutput({'nativeSmoke': 'passed', 'frame': true, 'vault': true});
    log.write('runtime', 'native.smoke.passed', {
      'frame': true,
      'vault': true,
      'visibleWindowChecked': expectVisible,
    });
    await log.flush();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    timeout.cancel();
    if (closeWindow) {
      await const MethodChannel(
        'dev.ocsbridge/files',
      ).invokeMethod<void>('requestSelfClose');
      return;
    }
    exit(0);
  } catch (error, stack) {
    log.error('native.smoke.failed', error, stack, {'stage': stage});
    try {
      await log.flush();
    } catch (_) {
      /* Preserve the original failure. */
    }
    try {
      await secrets.delete(id);
    } catch (_) {
      /* Best-effort cleanup. */
    }
    await _smokeOutput({
      'nativeSmoke': 'failed',
      'stage': stage,
      'type': error.runtimeType.toString(),
      if (error is PlatformException) 'code': error.code,
      if (error is PlatformException && error.details is int)
        'win32': error.details,
    });
    timeout.cancel();
    exit(1);
  }
}

Future<void> _smokeOutput(Map<String, dynamic> data) => const MethodChannel(
  'dev.ocsbridge/files',
).invokeMethod<void>('diagnosticOutput', jsonEncode(data));

class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key, this.log});
  final AppLog? log;
  @override
  State<Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<Bootstrap> {
  AppController? app;
  String? error;
  AppLifecycleListener? lifecycle;
  @override
  void initState() {
    super.initState();
    lifecycle = AppLifecycleListener(
      onStateChange: (state) => widget.log?.write(
        'runtime',
        'window.lifecycle',
        {'state': state.name},
      ),
    );
    load();
  }

  Future<void> load() async {
    setState(() => error = null);
    try {
      final store = await ConfigStore.open();
      store.log = widget.log;
      final config = await store.load();
      final controller = AppController(
        config: config,
        store: store,
        secrets: widget.log == null
            ? VaultSecrets()
            : AuditedSecrets(VaultSecrets(), widget.log!),
        log: widget.log,
      );
      try {
        await controller.restoreRecords();
      } catch (error, stack) {
        widget.log?.error('records.restore.failed', error, stack);
      }
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() => app = controller);
    } catch (failure, stack) {
      widget.log?.error('bootstrap.load.error', failure, stack);
      if (mounted) {
        setState(() => error = '配置读取失败，请检查配置文件');
      }
    }
  }

  @override
  void dispose() {
    app?.dispose();
    lifecycle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (app != null) {
      return BridgeApp(app: app!);
    }
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light),
      home: Scaffold(
        body: Center(
          child: error == null
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(error!),
                    const SizedBox(height: 24),
                    FilledButton(onPressed: load, child: const Text('重试')),
                  ],
                ),
        ),
      ),
    );
  }
}

class BridgeApp extends StatelessWidget {
  const BridgeApp({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: app,
    builder: (context, _) => MaterialApp(
      title: 'OCS Bridge',
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      themeMode: app.config.darkMode ? ThemeMode.dark : ThemeMode.light,
      themeAnimationDuration: motion,
      themeAnimationCurve: ease,
      home: AppShell(app: app),
      builder: (context, child) => AuditScope(log: app.log, child: child!),
    ),
  );
}
