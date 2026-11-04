import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../domain/answer.dart';
import '../domain/config.dart';
import 'app_log.dart';

typedef AnswerHandler = Future<AnswerResult> Function(Question question);

List<Map<String, dynamic>> ocsWrappers(int port, String token) => [
  {
    'name': 'OCS Bridge',
    'url': 'http://127.0.0.1:$port/answer',
    'method': 'post',
    'type': 'GM_xmlhttpRequest',
    'contentType': 'json',
    'responseType': 'json',
    'headers': {'Content-Type': 'application/json', 'X-OCS-Token': token},
    'data': {
      'title': r'${title}',
      'options': r'${options}',
      'type': r'${type}',
      'images': {'handler': 'return (env) => env.images || []'},
    },
    'handler':
        'return (res) => { if (res.code !== 0) throw new Error(res.message || "OCS Bridge 请求失败"); return res.answer ? [res.question, res.answer] : undefined; }',
  },
];

class BridgeServer {
  BridgeServer({this.log});
  final AppLog? log;
  final Expando<String> _ids = Expando();
  HttpServer? _server;
  bool get running => _server != null;
  int get port => _server?.port ?? 0;
  int _active = 0;
  Future<void> start({
    required int port,
    required String token,
    required AnswerHandler answer,
  }) async {
    if (running) {
      log?.write('runtime', 'bridge.start.skipped', {'port': this.port});
      return;
    }
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
      shared: false,
    );
    _server = server;
    log?.write('runtime', 'bridge.started', {
      'address': server.address.address,
      'port': server.port,
      'token': token,
    });
    server.listen(
      (request) {
        unawaited(
          runZoned(
            () => _handle(request, token, answer),
            zoneValues: {#ocsTraceId: newId()},
          ),
        );
      },
      onError: (Object error, StackTrace stack) =>
          log?.error('bridge.listen.error', error, stack),
      onDone: () => log?.write('runtime', 'bridge.listener.closed', {}),
    );
  }

  Future<void> stop() async {
    log?.write('runtime', 'bridge.stop', {'port': port, 'active': _active});
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(
    HttpRequest req,
    String token,
    AnswerHandler answer,
  ) async {
    var counted = false;
    final id = Zone.current[#ocsTraceId] as String? ?? newId();
    _ids[req] = id;
    final watch = Stopwatch()..start();
    var responseWritten = false;
    log?.write('network', 'local.request.headers', {
      'requestId': id,
      'method': req.method,
      'uri': req.uri.toString(),
      'protocolVersion': req.protocolVersion,
      'headers': logHeaders(req.headers),
      'connection': logConnection(req.connectionInfo),
      'contentLength': req.contentLength,
      'persistentConnection': req.persistentConnection,
    });
    try {
      req.response.headers.contentType = ContentType.json;
      req.response.headers.set('Access-Control-Allow-Origin', '*');
      req.response.headers.set(
        'Access-Control-Allow-Methods',
        'GET, POST, OPTIONS',
      );
      req.response.headers.set(
        'Access-Control-Allow-Headers',
        'Content-Type, X-OCS-Token',
      );
      req.response.headers.set('Access-Control-Allow-Private-Network', 'true');
      req.response.headers.set('Cache-Control', 'no-store');
      if (_active >= 4) {
        _reply(req, 429, {'code': 429, 'message': '请求过多，请降低 OCS 并发'});
        responseWritten = true;
        log?.write('network', 'local.request.body.not_read', {
          'requestId': id,
          'reason': 'concurrency_limit',
        });
        return;
      }
      _active++;
      counted = true;
      final bytes = <int>[];
      var chunkIndex = 0;
      await for (final chunk in req.timeout(const Duration(seconds: 15))) {
        log?.write('network', 'local.request.chunk', {
          'requestId': id,
          'index': chunkIndex++,
          'elapsedMs': watch.elapsedMilliseconds,
          'body': logBytes(chunk),
        });
        bytes.addAll(chunk);
        if (bytes.length > 16 * 1024 * 1024) {
          _reply(req, 413, {'code': 413, 'message': '题目内容过大'});
          responseWritten = true;
          return;
        }
      }
      log?.write('network', 'local.request.complete', {
        'requestId': id,
        'chunks': chunkIndex,
        'elapsedMs': watch.elapsedMilliseconds,
        'body': logBytes(bytes),
      });
      final host = req.headers.host ?? '';
      if (!RegExp(r'^(127\.0\.0\.1|localhost)(:\d+)?$').hasMatch(host)) {
        _reply(req, 403, {'code': 403, 'message': 'Host 无效'});
        return;
      }
      if (req.method == 'OPTIONS') {
        req.response.statusCode = 204;
        return;
      }
      if (req.method == 'GET' && req.uri.path == '/health') {
        _reply(req, 200, {'status': 'ok', 'app': 'OCS Bridge'});
        return;
      }
      if (!_equal(req.headers.value('X-OCS-Token') ?? '', token)) {
        _reply(req, 401, {'code': 401, 'message': '接入令牌无效'});
        return;
      }
      if (req.uri.path != '/answer') {
        _reply(req, 404, {'code': 404, 'message': '接口不存在'});
        return;
      }
      if (req.method != 'POST') {
        _reply(req, 405, {'code': 405, 'message': '请使用 POST'});
        return;
      }
      if (req.headers.contentType?.mimeType != 'application/json') {
        _reply(req, 415, {'code': 415, 'message': '请使用 JSON'});
        return;
      }
      final dynamic data = jsonDecode(utf8.decode(bytes));
      if (data is! Map<String, dynamic>) {
        throw const FormatException('请求格式无效');
      }
      final q = Question.fromJson(data);
      log?.write('runtime', 'bridge.question.parsed', {
        'requestId': id,
        'question': q.toJson(),
        'active': _active,
      });
      final result = await answer(q);
      _reply(req, 200, {
        'code': 0,
        'question': q.title,
        'answer': result.ocsAnswer,
        'answers': result.answers,
        'explanation': result.explanation,
        'sources': result.sources,
      });
    } on FormatException catch (e, stack) {
      log?.error('bridge.format.error', e, stack, {'requestId': id});
      _reply(req, 400, {'code': 400, 'message': e.message});
    } on TimeoutException catch (error, stack) {
      log?.error('bridge.timeout', error, stack, {'requestId': id});
      _reply(req, 408, {'code': 408, 'message': '请求超时'});
    } catch (error, stack) {
      log?.error('bridge.answer.error', error, stack, {'requestId': id});
      // Detailed errors are available locally; never expose provider configuration.
      _reply(req, 502, {'code': 502, 'message': '答题失败，请查看软件请求记录'});
    } finally {
      if (counted) {
        _active--;
      }
      try {
        if (req.response.statusCode == 204 && !responseWritten) {
          log?.write('network', 'local.response.write', {
            'requestId': id,
            'status': 204,
            'headers': logHeaders(req.response.headers),
            'body': logBytes([]),
          });
        }
        await req.response.close();
        log?.write('network', 'local.response.finished', {
          'requestId': id,
          'status': req.response.statusCode,
          'elapsedMs': watch.elapsedMilliseconds,
        });
      } catch (error, stack) {
        log?.error('bridge.client.disconnected', error, stack, {
          'requestId': id,
        });
      }
    }
  }

  void _reply(HttpRequest req, int status, Map<String, dynamic> data) {
    try {
      req.response.statusCode = status;
      final body = utf8.encode(jsonEncode(data));
      req.response.contentLength = body.length;
      log?.write('network', 'local.response.write', {
        'requestId': _ids[req],
        'status': status,
        'headers': logHeaders(req.response.headers),
        'body': logBytes(body),
      });
      req.response.add(body);
    } catch (error, stack) {
      log?.error('bridge.response.write.error', error, stack, {
        'requestId': _ids[req],
      });
    }
  }

  bool _equal(String a, String b) {
    var diff = a.length ^ b.length;
    for (var i = 0; i < b.length; i++) {
      diff |= (i < a.length ? a.codeUnitAt(i) : 0) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
