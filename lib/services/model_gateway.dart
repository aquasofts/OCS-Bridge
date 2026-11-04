import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../domain/config.dart';
import '../domain/answer.dart';
import 'app_log.dart';

class GatewayException implements Exception {
  const GatewayException(this.message, {this.retryable = false});
  final String message;
  final bool retryable;
  @override
  String toString() => message;
}

Uri endpoint(ProviderConfig provider, String path) =>
    Uri.parse('${provider.baseUrl.replaceAll(RegExp(r'/+$'), '')}/$path');

Map<String, dynamic> buildRequest(ModelConfig m, ProviderConfig p, Question q) {
  validateModel(m, p);
  if (q.images.isNotEmpty && !m.vision) {
    throw const GatewayException('此模型未启用图片');
  }
  final prompt = jsonEncode({'题型': q.type, '题目': q.title, '选项': q.options});
  final body = <String, dynamic>{...m.extra, 'model': m.model, 'stream': false};
  if (m.protocol == ApiProtocol.responses) {
    body.addAll({
      'instructions': answerInstructions,
      'input': [
        {
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': prompt},
            for (final img in q.images)
              {'type': 'input_image', 'image_url': img},
          ],
        },
      ],
      'max_output_tokens': m.maxTokens,
    });
    if (p.kind != ProviderKind.deepseek) {
      body['store'] = false;
    }
    var effort = m.effort;
    if (p.kind == ProviderKind.deepseek) {
      if (m.thinking == 'disabled') {
        effort = 'none';
      }
      if (m.thinking == 'enabled' && ['default', 'none'].contains(effort)) {
        effort = 'high';
      }
    }
    if (effort != 'default') {
      body['reasoning'] = {'effort': effort};
    }
    if (m.search != SearchMode.off) {
      body['tools'] = [
        {'type': 'web_search'},
      ];
      body['tool_choice'] = m.search == SearchMode.required
          ? 'required'
          : 'auto';
    }
  } else {
    body['messages'] = [
      {'role': 'system', 'content': answerInstructions},
      {
        'role': 'user',
        'content': q.images.isEmpty
            ? prompt
            : [
                {'type': 'text', 'text': prompt},
                for (final img in q.images)
                  {
                    'type': 'image_url',
                    'image_url': {'url': img},
                  },
              ],
      },
    ];
    body[p.kind == ProviderKind.deepseek
            ? 'max_tokens'
            : 'max_completion_tokens'] =
        m.maxTokens;
    if (m.effort != 'default') {
      body['reasoning_effort'] = m.effort;
    }
    if (m.thinking != 'default') {
      body['thinking'] = {'type': m.thinking};
    }
    if (m.search != SearchMode.off) {
      body['web_search_options'] = <String, dynamic>{};
    }
  }
  if (m.temperature != null) {
    body['temperature'] = m.temperature;
  }
  return body;
}

class ModelGateway {
  ModelGateway({this.log});
  AppLog? log;
  final Set<HttpClient> _clients = {};
  final Set<Completer<void>> _pendingRequests = {};
  void cancelAll() {
    log?.write('runtime', 'gateway.cancel', {'clients': _clients.length});
    for (final request in _pendingRequests.toList()) {
      if (!request.isCompleted) request.complete();
    }
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
  }

  Future<Map<String, dynamic>> _json(
    Uri uri,
    String key, {
    Map<String, dynamic>? body,
    int timeout = 30,
  }) async {
    final cancelled = Completer<void>();
    _pendingRequests.add(cancelled);
    final budget = Duration(seconds: timeout);
    final watch = Stopwatch()..start();
    final operationId = newId();
    const maxRetries = 3;
    try {
      for (var attempt = 0; ; attempt++) {
        if (cancelled.isCompleted) throw const GatewayException('请求已取消');
        final remaining = budget - watch.elapsed;
        if (remaining <= Duration.zero) {
          throw const GatewayException('请求超时');
        }
        try {
          final result = await _jsonOnce(
            uri,
            key,
            body: body,
            timeout: remaining,
            operationId: operationId,
            attempt: attempt + 1,
          );
          if (cancelled.isCompleted) throw const GatewayException('请求已取消');
          return result;
        } on GatewayException catch (error) {
          if (cancelled.isCompleted) throw const GatewayException('请求已取消');
          if (!error.retryable) rethrow;
          if (attempt == maxRetries) {
            throw GatewayException('${error.message}（自动重连 $maxRetries 次后仍失败）');
          }
          final delay = Duration(seconds: 1 << attempt);
          if (watch.elapsed + delay >= budget) rethrow;
          log?.write('network', 'upstream.request.retry', {
            'operationId': operationId,
            'nextAttempt': attempt + 2,
            'maxRetries': maxRetries,
            'delayMs': delay.inMilliseconds,
            'elapsedMs': watch.elapsedMilliseconds,
            'reason': error.message,
          });
          final wait = Completer<void>();
          final timer = Timer(delay, wait.complete);
          try {
            await Future.any<void>([wait.future, cancelled.future]);
          } finally {
            timer.cancel();
          }
        }
      }
    } finally {
      _pendingRequests.remove(cancelled);
    }
  }

  Future<Map<String, dynamic>> _jsonOnce(
    Uri uri,
    String key, {
    Map<String, dynamic>? body,
    required Duration timeout,
    required String operationId,
    required int attempt,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    final requestId = newId();
    final watch = Stopwatch()..start();
    final payload = body == null ? <int>[] : utf8.encode(jsonEncode(body));
    var receivedBytes = 0;
    var chunks = 0;
    log?.write('network', 'upstream.request.start', {
      'requestId': requestId,
      'operationId': operationId,
      'attempt': attempt,
      'method': body == null ? 'GET' : 'POST',
      'url': uri.toString(),
      'timeoutSeconds': timeout.inMilliseconds / 1000,
      'headers': {
        'Authorization': ['Bearer $key'],
        'Accept': ['application/json'],
        if (body != null) 'Content-Type': ['application/json; charset=utf-8'],
      },
      'body': logBytes(payload),
    });
    _clients.add(client);
    try {
      return await (() async {
        final req = await client.openUrl(body == null ? 'GET' : 'POST', uri);
        req.followRedirects = false;
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
        req.headers.set(HttpHeaders.acceptHeader, 'application/json');
        if (body != null) {
          req.headers.contentType = ContentType.json;
          req.contentLength = payload.length;
          req.add(payload);
        }
        log?.write('network', 'upstream.request.ready', {
          'requestId': requestId,
          'headers': logHeaders(req.headers),
          'elapsedMs': watch.elapsedMilliseconds,
          'connection': logConnection(req.connectionInfo),
        });
        final response = await req.close();
        final certificate = response.certificate;
        log?.write('network', 'upstream.response.headers', {
          'requestId': requestId,
          'status': response.statusCode,
          'reason': response.reasonPhrase,
          'headers': logHeaders(response.headers),
          'elapsedMs': watch.elapsedMilliseconds,
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
              'startValidity': certificate.startValidity
                  .toUtc()
                  .toIso8601String(),
              'endValidity': certificate.endValidity.toUtc().toIso8601String(),
              'pem': certificate.pem,
              'der': base64Encode(certificate.der),
            },
        });
        final bytes = <int>[];
        await for (final chunk in response) {
          receivedBytes += chunk.length;
          log?.write('network', 'upstream.response.chunk', {
            'requestId': requestId,
            'index': chunks++,
            'elapsedMs': watch.elapsedMilliseconds,
            'body': logBytes(chunk),
          });
          bytes.addAll(chunk);
          if (bytes.length > 8 * 1024 * 1024) {
            throw const GatewayException('供应商响应过大');
          }
        }
        log?.write('network', 'upstream.response.complete', {
          'requestId': requestId,
          'status': response.statusCode,
          'elapsedMs': watch.elapsedMilliseconds,
          'chunks': chunks,
          'body': logBytes(bytes),
        });
        final text = utf8.decode(bytes);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          // Do not surface upstream response bodies: gateways can echo API keys.
          final label = switch (response.statusCode) {
            401 || 403 => '鉴权失败，请检查 API Key',
            404 => '接口或模型不存在',
            429 => '额度不足或请求过快',
            >= 500 => '供应商暂时不可用',
            _ => '请检查模型能力和请求参数',
          };
          throw GatewayException('HTTP ${response.statusCode} · $label');
        }
        final dynamic data;
        try {
          data = jsonDecode(text);
        } catch (_) {
          throw const GatewayException('供应商未返回 JSON');
        }
        if (data is! Map<String, dynamic>) {
          throw const GatewayException('供应商响应格式错误');
        }
        log?.write('runtime', 'gateway.json.parsed', {
          'requestId': requestId,
          'data': data,
        });
        return data;
      })().timeout(timeout);
    } on TimeoutException catch (error, stack) {
      log?.error('gateway.timeout', error, stack, {
        'requestId': requestId,
        'elapsedMs': watch.elapsedMilliseconds,
        'receivedBytes': receivedBytes,
      });
      throw const GatewayException('请求超时');
    } on SocketException catch (error, stack) {
      log?.error('gateway.socket.error', error, stack, {
        'requestId': requestId,
        'address': error.address?.address,
        'port': error.port,
        'osError': error.osError?.toString(),
      });
      throw const GatewayException('网络连接失败', retryable: true);
    } on HandshakeException catch (error, stack) {
      log?.error('gateway.tls.error', error, stack, {'requestId': requestId});
      throw const GatewayException('TLS 连接失败', retryable: true);
    } on HttpException catch (error, stack) {
      log?.error('gateway.http.error', error, stack, {'requestId': requestId});
      throw const GatewayException('连接中断', retryable: true);
    } catch (error, stack) {
      log?.error('gateway.error', error, stack, {'requestId': requestId});
      rethrow;
    } finally {
      client.close(force: true);
      _clients.remove(client);
      log?.write('network', 'upstream.request.finished', {
        'requestId': requestId,
        'elapsedMs': watch.elapsedMilliseconds,
        'receivedBytes': receivedBytes,
        'chunks': chunks,
      });
    }
  }

  Future<List<String>> listModels(ProviderConfig p, String key) async {
    log?.write('runtime', 'gateway.models.start', {'provider': p.toJson()});
    final data = await _json(endpoint(p, 'models'), key);
    if (data['data'] is! List) {
      throw const GatewayException('未返回模型列表');
    }
    return (data['data'] as List)
        .whereType<Map>()
        .map((x) => x['id'])
        .whereType<String>()
        .toSet()
        .toList()
      ..sort();
  }

  Future<AnswerResult> answer(
    ModelConfig m,
    ProviderConfig p,
    String key,
    Question q,
  ) async {
    log?.write('runtime', 'gateway.answer.start', {
      'model': m.toJson(),
      'provider': p.toJson(),
      'question': q.toJson(),
    });
    final data = await _json(
      endpoint(
        p,
        m.protocol == ApiProtocol.responses ? 'responses' : 'chat/completions',
      ),
      key,
      body: buildRequest(m, p, q),
      timeout: m.timeoutSeconds,
    );
    String content = '';
    var searchCalls = 0;
    var pageReads = 0;
    final sources = <String>{};
    if (m.protocol == ApiProtocol.responses) {
      if (data['status'] == 'incomplete' ||
          data['status'] == 'failed' ||
          data['error'] != null) {
        throw const GatewayException('模型输出未完成，请调整 Token 或参数');
      }
      for (final item in (data['output'] as List? ?? []).whereType<Map>()) {
        if (item['type'] == 'web_search_call' &&
            item['status'] == 'completed') {
          final action = item['action'];
          if (action is Map &&
              ['open_page', 'find_in_page'].contains(action['type'])) {
            pageReads++;
          } else {
            searchCalls++;
          }
        }
        if (item['type'] != 'message') {
          continue;
        }
        for (final part in (item['content'] as List? ?? []).whereType<Map>()) {
          if (part['type'] == 'output_text') {
            content += part['text'] as String? ?? '';
          }
          for (final a
              in (part['annotations'] as List? ?? []).whereType<Map>()) {
            if (a['type'] == 'url_citation' && a['url'] is String) {
              sources.add(a['url'] as String);
            }
          }
        }
      }
    } else {
      final choices = data['choices'] as List? ?? [];
      if (choices.isEmpty) {
        throw const GatewayException('模型未返回答案');
      }
      final choice = choices.first as Map;
      if (choice['finish_reason'] != null &&
          choice['finish_reason'] != 'stop') {
        throw const GatewayException('模型输出未完成，请调整 Token 或参数');
      }
      final message = choice['message'] as Map? ?? {};
      content = message['content'] as String? ?? '';
      for (final a
          in (message['annotations'] as List? ?? []).whereType<Map>()) {
        final c = a['url_citation'];
        if (c is Map && c['url'] is String) {
          sources.add(c['url'] as String);
        }
      }
    }
    if (content.trim().isEmpty) {
      throw const GatewayException('模型返回了空答案');
    }
    final usage = data['usage'] as Map? ?? {};
    final toolUsage = usage['server_tool_use'];
    if (p.kind == ProviderKind.deepseek && toolUsage is Map) {
      searchCalls = (toolUsage['tool_search'] as num?)?.toInt() ?? searchCalls;
      pageReads = (toolUsage['tool_fetch'] as num?)?.toInt() ?? pageReads;
    }
    if (m.search == SearchMode.required && searchCalls + pageReads == 0) {
      throw const GatewayException('供应商未执行搜索，请检查模型能力');
    }
    final result = parseAnswer(
      content,
      q,
      sources: sources
          .where(
            (x) =>
                Uri.tryParse(x)?.scheme == 'https' ||
                Uri.tryParse(x)?.scheme == 'http',
          )
          .toList(),
      inputTokens:
          (usage['input_tokens'] ?? usage['prompt_tokens'] ?? 0) as int,
      outputTokens:
          (usage['output_tokens'] ?? usage['completion_tokens'] ?? 0) as int,
      searchCalls: searchCalls,
      pageReads: pageReads,
    );
    log?.write('runtime', 'gateway.answer.parsed', {
      'model': m.toJson(),
      'result': result.toJson(),
    });
    return result;
  }
}
