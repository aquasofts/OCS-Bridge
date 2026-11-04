import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'domain/config.dart';
import 'domain/answer.dart';
import 'services/config_store.dart';
import 'services/model_gateway.dart';
import 'services/bridge_server.dart';
import 'services/app_log.dart';

class RequestRecord {
  RequestRecord({
    required this.question,
    required this.model,
    required this.time,
    required this.duration,
    this.result,
    this.error,
    this.cached = false,
    String? id,
    this.modelSettings = const {},
    this.providerSettings = const {},
    this.errorStack,
  }) : id = id ?? newId();
  final String id;
  final Question question;
  final String model;
  final DateTime time;
  final Duration duration;
  final AnswerResult? result;
  final String? error;
  final bool cached;
  final Map<String, dynamic> modelSettings, providerSettings;
  final String? errorStack;
  Map<String, dynamic> toJson() => {
    'id': id,
    'question': question.toJson(),
    'model': model,
    'time': time.toUtc().toIso8601String(),
    'durationMs': duration.inMilliseconds,
    'cached': cached,
    'result': result?.toJson(),
    'error': error,
    'errorStack': errorStack,
    'modelSettings': modelSettings,
    'providerSettings': providerSettings,
  };
  factory RequestRecord.fromJson(Map<String, dynamic> j) => RequestRecord(
    id: j['id'] as String,
    question: Question.fromJson(
      Map<String, dynamic>.from(j['question'] as Map),
    ),
    model: j['model'] as String,
    time: DateTime.parse(j['time'] as String).toLocal(),
    duration: Duration(milliseconds: j['durationMs'] as int),
    cached: j['cached'] as bool? ?? false,
    result: j['result'] is Map
        ? AnswerResult.fromJson(Map<String, dynamic>.from(j['result'] as Map))
        : null,
    error: j['error'] as String?,
    errorStack: j['errorStack'] as String?,
    modelSettings: Map<String, dynamic>.from(j['modelSettings'] as Map? ?? {}),
    providerSettings: Map<String, dynamic>.from(
      j['providerSettings'] as Map? ?? {},
    ),
  );
}

class AppController extends ChangeNotifier {
  AppController({
    required this.config,
    required this.store,
    required this.secrets,
    ModelGateway? gateway,
    this.log,
  }) : gateway = gateway ?? ModelGateway(log: log),
       server = BridgeServer(log: log) {
    if (log != null) this.gateway.log = log;
    store.log = log;
    log?.onStatusChanged = _changed;
    if (log != null) {
      _retentionTimer = Timer.periodic(
        const Duration(minutes: 1),
        (_) => _pruneRecords(),
      );
    }
  }
  final AppLog? log;
  final AppConfig config;
  final ConfigStore store;
  final SecretStore secrets;
  final ModelGateway gateway;
  final BridgeServer server;
  Timer? _retentionTimer;
  bool _disposed = false;
  final List<RequestRecord> records = [];
  final LinkedHashMap<String, AnswerResult> _cache = LinkedHashMap();
  final Map<String, Future<AnswerResult>> _inflight = {};
  bool switching = false;
  int pending = 0;
  ModelConfig? get activeModel =>
      config.models.where((x) => x.id == config.activeModelId).firstOrNull;
  ProviderConfig? provider(String id) =>
      config.providers.where((x) => x.id == id).firstOrNull;
  String get wrapperJson => const JsonEncoder.withIndent(
    '  ',
  ).convert(ocsWrappers(config.port, config.token));
  int get cacheSize => _cache.length;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void audit(String event, [Map<String, dynamic> data = const {}]) =>
      log?.write('runtime', event, data);
  Future<void> restoreRecords() async {
    final events = await log?.read('answers') ?? [];
    for (final event in events) {
      if (event['event'] == 'answer.clear') {
        records.clear();
        continue;
      }
      if (event['event'] != 'answer.record') continue;
      try {
        records.add(
          RequestRecord.fromJson(
            Map<String, dynamic>.from(event['data'] as Map),
          ),
        );
      } catch (error, stack) {
        log?.error('records.restore.error', error, stack, {'event': event});
      }
    }
    records.sort((a, b) => b.time.compareTo(a.time));
    _pruneRecords();
    audit('records.restored', {'count': records.length});
  }

  void _pruneRecords() {
    final cutoff = DateTime.now().subtract(AppLog.retention);
    final before = records.length;
    records.removeWhere((r) => r.time.isBefore(cutoff));
    if (before != records.length) {
      audit('records.expired', {'count': before - records.length});
      _changed();
    }
  }

  Future<void> save() async {
    await store.save(config);
    audit('config.applied', {'config': config.toJson()});
    _changed();
  }

  Future<void> selectModel(String id) async {
    audit('model.select', {'id': id});
    config.activeModelId = id;
    await save();
  }

  Future<void> saveProvider(ProviderConfig p, String key) async {
    audit('provider.save.start', {'provider': p.toJson(), 'key': key});
    validateProvider(p);
    if (!p.supportsResponses &&
        config.models.any(
          (m) => m.providerId == p.id && m.protocol == ApiProtocol.responses,
        )) {
      throw const FormatException('请先将关联模型切换为 Chat Completions');
    }
    await secrets.write(p.id, key.trim());
    final index = config.providers.indexWhere((x) => x.id == p.id);
    if (index < 0) {
      config.providers.add(p);
    } else {
      config.providers[index] = p;
    }
    clearCache();
    await save();
  }

  Future<void> deleteProvider(String id) async {
    audit('provider.delete', {'id': id});
    if (config.models.any((m) => m.providerId == id)) {
      throw const FormatException('请先删除或迁移关联模型');
    }
    await secrets.delete(id);
    config.providers.removeWhere((p) => p.id == id);
    clearCache();
    await save();
  }

  Future<void> saveModel(ModelConfig m) async {
    audit('model.save.start', {'model': m.toJson()});
    final p = provider(m.providerId);
    if (p == null) {
      throw const FormatException('请选择供应商');
    }
    validateModel(m, p);
    final i = config.models.indexWhere((x) => x.id == m.id);
    if (i < 0) {
      config.models.add(m);
    } else {
      config.models[i] = m;
    }
    config.activeModelId ??= m.id;
    clearCache();
    await save();
  }

  Future<void> deleteModel(String id) async {
    audit('model.delete', {'id': id});
    config.models.removeWhere((m) => m.id == id);
    if (config.activeModelId == id) {
      config.activeModelId = config.models.firstOrNull?.id;
    }
    clearCache();
    await save();
  }

  Future<List<String>> fetchModels(ProviderConfig p, {String? key}) async {
    audit('models.fetch', {'provider': p.toJson()});
    final secret = key ?? await secrets.read(p.id) ?? '';
    if (secret.isEmpty) {
      throw const GatewayException('请填写 API Key');
    }
    return gateway.listModels(p, secret);
  }

  Future<void> toggleServer() async {
    if (switching) {
      return;
    }
    switching = true;
    audit('server.toggle', {'running': server.running});
    _changed();
    try {
      if (server.running) {
        gateway.cancelAll();
        await server.stop();
      } else {
        if (activeModel == null) {
          throw const GatewayException('请先添加模型');
        }
        final key = await secrets.read(activeModel!.providerId);
        if (key == null || key.isEmpty) {
          throw const GatewayException('请先设置 API Key');
        }
        await server.start(
          port: config.port,
          token: config.token,
          answer: (q) => answer(q),
        );
      }
    } finally {
      switching = false;
      _changed();
    }
  }

  Future<AnswerResult> answer(Question q, {String? modelId}) => runZoned(
    () => _answer(q, modelId: modelId),
    zoneValues: {#ocsTraceId: Zone.current[#ocsTraceId] ?? newId()},
  );

  Future<AnswerResult> _answer(Question q, {String? modelId}) async {
    final m = modelId == null
        ? activeModel
        : config.models.where((x) => x.id == modelId).firstOrNull;
    if (m == null) {
      throw const GatewayException('请选择模型');
    }
    final p = provider(m.providerId);
    if (p == null) {
      throw const GatewayException('供应商不存在');
    }
    final started = DateTime.now();
    final requestId = Zone.current[#ocsTraceId] as String? ?? newId();
    audit('answer.start', {
      'requestId': requestId,
      'question': q.toJson(),
      'model': m.toJson(),
      'provider': p.toJson(),
    });
    final timer = Stopwatch()..start();
    final cacheKey = sha256
        .convert(utf8.encode(jsonEncode([m.toJson(), p.toJson(), q.toJson()])))
        .toString();
    var cached = false;
    pending++;
    _changed();
    try {
      AnswerResult result;
      if (config.cacheEnabled && _cache.containsKey(cacheKey)) {
        cached = true;
        audit('answer.cache.hit', {
          'requestId': requestId,
          'cacheKey': cacheKey,
        });
        result = _cache.remove(cacheKey)!;
        _cache[cacheKey] = result;
      } else {
        final existing = _inflight[cacheKey];
        if (existing != null) {
          audit('answer.inflight.join', {
            'requestId': requestId,
            'cacheKey': cacheKey,
          });
          result = await existing;
        } else {
          audit('answer.dispatch', {
            'requestId': requestId,
            'cacheKey': cacheKey,
            'pending': pending,
          });
          final work = (() async {
            final key = await secrets.read(p.id) ?? '';
            if (key.isEmpty) {
              throw const GatewayException('请设置 API Key');
            }
            return gateway.answer(m, p, key, q);
          })();
          _inflight[cacheKey] = work;
          try {
            result = await work;
          } finally {
            _inflight.remove(cacheKey);
          }
        }
        if (config.cacheEnabled && result.answers.isNotEmpty) {
          _cache[cacheKey] = result;
          audit('answer.cache.saved', {
            'requestId': requestId,
            'cacheKey': cacheKey,
          });
          while (_cache.length > 100) {
            _cache.remove(_cache.keys.first);
          }
        }
      }
      _record(
        RequestRecord(
          question: q,
          id: requestId,
          modelSettings: m.toJson(),
          providerSettings: p.toJson(),
          model: m.name,
          time: started,
          duration: timer.elapsed,
          result: result,
          cached: cached,
        ),
      );
      return result;
    } catch (e, stack) {
      log?.error('answer.error', e, stack, {
        'requestId': requestId,
        'question': q.toJson(),
      });
      _record(
        RequestRecord(
          question: q,
          id: requestId,
          modelSettings: m.toJson(),
          providerSettings: p.toJson(),
          errorStack: stack.toString(),
          model: m.name,
          time: started,
          duration: timer.elapsed,
          error: e is GatewayException
              ? e.message
              : e is FormatException
              ? e.message
              : '请求失败',
        ),
      );
      rethrow;
    } finally {
      pending--;
      audit('answer.finished', {
        'requestId': requestId,
        'pending': pending,
        'elapsedMs': timer.elapsedMilliseconds,
      });
      _changed();
    }
  }

  void _record(RequestRecord r) {
    records.insert(0, r);
    log?.write('answers', 'answer.record', r.toJson());
    _pruneRecords();
  }

  void clearCache() {
    audit('cache.clear', {'count': _cache.length});
    _cache.clear();
    _changed();
  }

  void clearRecords() {
    log?.write('answers', 'answer.clear', {'count': records.length});
    records.clear();
    _changed();
  }

  Future<void> shutdown() async {
    audit('app.shutdown.start', {'pending': pending});
    gateway.cancelAll();
    await server.stop();
    await Future.wait(
      _inflight.values.map((f) async {
        try {
          await f;
        } catch (_) {}
      }),
    );
    await Future<void>.delayed(Duration.zero);
    await store.flush();
    audit('app.shutdown.complete');
    await log?.flush();
  }

  @override
  void dispose() {
    _disposed = true;
    _retentionTimer?.cancel();
    if (log?.onStatusChanged == _changed) log?.onStatusChanged = null;
    gateway.cancelAll();
    server.stop();
    super.dispose();
  }
}
