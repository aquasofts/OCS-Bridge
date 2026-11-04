import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../domain/config.dart';
import 'app_log.dart';

abstract class SecretStore {
  Future<String?> read(String id);
  Future<void> write(String id, String value);
  Future<void> delete(String id);
}

class VaultSecrets implements SecretStore {
  static const _channel = MethodChannel('dev.ocsbridge/vault');
  @override
  Future<String?> read(String id) =>
      _channel.invokeMethod<String>('read', {'id': id});
  @override
  Future<void> write(String id, String value) =>
      _channel.invokeMethod<void>('write', {'id': id, 'value': value});
  @override
  Future<void> delete(String id) =>
      _channel.invokeMethod<void>('delete', {'id': id});
}

class AuditedSecrets implements SecretStore {
  AuditedSecrets(this.inner, this.log);
  final SecretStore inner;
  final AppLog log;
  Future<T> _run<T>(
    String operation,
    String id,
    Future<T> Function() action, [
    String? value,
  ]) async {
    log.write('runtime', 'vault.$operation.start', {'id': id, 'value': ?value});
    try {
      final result = await action();
      log.write('runtime', 'vault.$operation.complete', {
        'id': id,
        if (result is String) 'value': result,
      });
      return result;
    } catch (error, stack) {
      log.error('vault.$operation.error', error, stack, {'id': id});
      rethrow;
    }
  }

  @override
  Future<String?> read(String id) => _run('read', id, () => inner.read(id));
  @override
  Future<void> write(String id, String value) =>
      _run('write', id, () => inner.write(id, value), value);
  @override
  Future<void> delete(String id) => _run('delete', id, () => inner.delete(id));
}

class ConfigStore {
  ConfigStore(this.directory);
  final Directory directory;
  AppLog? log;
  Future<void> _pending = Future.value();
  static Future<ConfigStore> open() async => ConfigStore(
    Directory('${(await getApplicationSupportDirectory()).path}/OCSBridge'),
  );
  File get file => File('${directory.path}/config.json');
  Future<AppConfig> load() async {
    log?.write('runtime', 'config.load.start', {'file': file.path});
    if (!await file.exists()) {
      final initial = AppConfig.initial();
      log?.write('runtime', 'config.load.defaults', {
        'config': initial.toJson(),
      });
      return initial;
    }
    final raw = await file.readAsString();
    log?.write('runtime', 'config.load.raw', {'file': file.path, 'text': raw});
    try {
      final config = AppConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      log?.write('runtime', 'config.load.complete', {
        'config': config.toJson(),
      });
      return config;
    } catch (error, stack) {
      log?.error('config.load.error', error, stack);
      rethrow;
    }
  }

  Future<void> save(AppConfig config) {
    final payload = const JsonEncoder.withIndent('  ').convert(config.toJson());
    log?.write('runtime', 'config.save.queued', {
      'file': file.path,
      'text': payload,
    });
    final work = _pending.catchError((Object _) {}).then((_) async {
      await directory.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(payload, flush: true);
      // Windows rename replaces an existing regular file atomically.
      await temp.rename(file.path);
      log?.write('runtime', 'config.save.complete', {
        'file': file.path,
        'bytes': utf8.encode(payload).length,
      });
    });
    _pending = work;
    return work;
  }

  Future<void> flush() => _pending;
}
