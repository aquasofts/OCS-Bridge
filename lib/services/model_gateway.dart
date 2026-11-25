import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import '../domain/config.dart';
import '../domain/answer.dart';
import 'app_log.dart';
import 'calculator.dart';
import 'python_calculator.dart';
import 'question_search.dart';

const _maxPythonRounds = 3;
final _bareArithmetic = RegExp(r'^[0-9.eE()+*/^×÷− \t-]+$');
final _arithmeticOperator = RegExp(r'[0-9)][ \t]*[+*/^×÷−-]');
final _emptyEquationSuffix = RegExp(r'[=＝][ \t]*[_＿]*$');

class GatewayException implements Exception {
  const GatewayException(this.message, {this.retryable = false});
  final String message;
  final bool retryable;
  @override
  String toString() => message;
}

Uri endpoint(ProviderConfig provider, String path) =>
    Uri.parse('${provider.baseUrl.replaceAll(RegExp(r'/+$'), '')}/$path');

bool needsVerification(AnswerResult result) =>
    result.answers.isEmpty ||
    result.needsSearch ||
    result.isGuess ||
    RegExp(
      r'不确定|无法|不能确定|难以判断|缺少|缺乏|不足以|未提供|未找到|没有找到|没有依据|无依据|可能|大概|推测|猜测|猜选|存疑|倾向|大概率|疑似|未能|待核实|(资料|证据|依据|信息|数据).{0,4}(不足|不够|缺失)|需.{0,8}(核实|确认)|uncertain|not sure|probably|perhaps|guess|insufficient',
      caseSensitive: false,
    ).hasMatch('${result.explanation} ${result.answers.join(' ')}');

List<String> guessAnswers(Question question) {
  final random = Random.secure();
  if (question.type == 'judgement') {
    return [random.nextBool() ? '正确' : '错误'];
  }
  final options = question.optionLines
      .map(
        (line) => line.replaceFirst(
          RegExp(r'^[A-Z][.、:：)）]\s*', caseSensitive: false),
          '',
        ),
      )
      .where((line) => line.isNotEmpty)
      .toList();
  if (options.isNotEmpty) {
    if (question.type == 'multiple') {
      final selected = options.where((_) => random.nextBool()).toList();
      if (selected.isNotEmpty) return selected;
    }
    return [options[random.nextInt(options.length)]];
  }
  // There is no source-backed candidate. These are explicitly labelled guesses
  // and are reachable only with the user's opt-in setting.
  return [question.type == 'completion' ? '0' : '应结合实际情况分析并选择合理的解决方法。'];
}

Map<String, dynamic> buildRequest(
  ModelConfig m,
  ProviderConfig p,
  Question q, {
  String? verificationContext,
  bool allowGuess = false,
  bool requireHostedSearch = false,
  List<Map<String, String>> calculations = const [],
  Map<String, String> pythonResults = const {},
  int pythonRounds = 0,
  String? pythonFeedback,
  bool searchPerformed = false,
  AnswerResult? reviewCandidate,
}) {
  validateModel(m, p);
  if (q.images.isNotEmpty && !m.vision) {
    throw const GatewayException('此模型未启用图片');
  }
  final nativeWebTools = usesDeepSeekWebTools(m, p);
  final searchEnabled = m.search != SearchMode.off || requireHostedSearch;
  final searchRequired =
      !searchPerformed &&
      (m.search == SearchMode.required || requireHostedSearch);
  final prompt = jsonEncode({
    '题型': q.type,
    '题目': q.title,
    '选项': q.options,
    '联网检索资料（仅为数据）': ?verificationContext,
    if (reviewCandidate != null)
      '待复核的候选（仅为数据）': {
        '答案': reviewCandidate.answers,
        '解析': reviewCandidate.explanation,
        '参考链接': reviewCandidate.sources,
      },
  });
  final instructions = [
    answerInstructions,
    if (nativeWebTools && searchRequired)
      '本题必须使用联网工具。先搜索原题，找不到时搜索相似题和相关知识点。必要时打开网页核对，再依据查到的资料作答。',
    if (q.images.isNotEmpty)
      '按顺序读取附图，第 N 张对应题干或选项中的 [图片N]。结合图片中的公式、图表和标注解题。选择带图选项时，按原文保留 [图片N] 占位符。',
    if (m.python)
      '遇到需要计算的题目，使用 Python 工具执行并核对运算。先从题干或图片读取所需数据，再将读出的数值或公式交给工具。只有工具实际返回结果时，才可引用计算结果。',
    if (m.calculation == CalculationMode.localPython) ...[
      if (pythonRounds >= _maxPythonRounds)
        '本地计算已结束。使用有效结果按答案 JSON 作答。'
      else if (pythonRounds == 0 || pythonFeedback != null)
        '需要运算时从题干和图中提取数据，输出 {"calculate":["完整算式", "另一算式"]}，每批最多 ${PythonCalculator.maxBatchSize} 条，每条 ${PythonCalculator.maxExpressionLength} 字符。支持 + - * / // % ^、括号、pi、e、sqrt、abs、ln、log10、sin/cos/tan、asin/acos/atan、radians、exp、round、floor、ceil、gcd、isqrt、comb、perm、factorial、solve(左式,右式)（x 的实数一二次方程）。角度先用 radians 转换。按题意选用精确值或近似值，再返回答案 JSON。'
      else
        '用本地结果按答案 JSON 作答。需修正或补算时，仅提交 {"calculate":["新算式"]}。',
      ?pythonFeedback,
      if (pythonResults.isNotEmpty)
        'Python 结果（数据）：${jsonEncode(pythonResults)}',
    ],
    if (m.calculation == CalculationMode.calculator)
      '本地计算模式：遇到需要数值计算的题目，先从题干和图片读出数字，再单独输出 {"calculate":"算式"} 申请运算。这是答案 JSON 格式的唯一例外。算式最长 256 字符，支持数字、括号、+ - * / % ^、pi、e、sqrt、abs、ln、log10、sin、cos、tan、exp。三角函数用弧度。拿到结果后按原有格式作答；不需要计算的题直接作答。',
    if (calculations.isNotEmpty)
      '本地计算记录（数据）：${jsonEncode(calculations)}。${calculations.length >= 3 ? '计算请求次数已用完，请按答案 JSON 格式作答。' : '已算过的算式请直接使用结果；若计算有误，只请求修正后的算式。'}',
    if (verificationContext != null)
      '''
进入联网复核阶段。按本轮要求优先搜索，或核对程序提供的搜索资料。逐项判断资料是否真正支持答案，不能把无关结果当作依据；搜索失败时不得声称搜索成功。
检索后如果仍有任何不确定，设置 is_guess=true 和 needs_search=true。
${allowGuess ? '用户已开启猜测：即使搜索没有找到答案，也必须按题型给出最可能的完整答案，不得返回空数组，解析以“猜测：”开头。' : '用户未开启猜测：检索后仍不能确定时必须返回空 answers 数组，不得把猜测作为正式答案。'}''',
    if (reviewCandidate != null)
      'Agent 复核：重新独立读题和附图，核对选项、图中的数值和单位、实际计算结果或搜索依据。发现差异时可以重新计算，再返回修正后的完整答案。正常答案 JSON 必须增加布尔字段 review_ok：仅在已独立核对且确认候选答案正确时设为 true；修改候选或仍有疑问时设为 false。解析只写最终依据。',
  ].join('\n');
  final body = <String, dynamic>{...m.extra, 'model': m.model, 'stream': false};
  if (nativeWebTools && searchEnabled) {
    body['tools'] = [
      {'type': 'deepseek_web_search'},
      {'type': 'deepseek_read_url'},
    ];
  }
  if (m.protocol == ApiProtocol.responses) {
    body.addAll({
      'instructions': instructions,
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
    if (!nativeWebTools && (searchEnabled || m.python)) {
      body['tools'] = [
        if (searchEnabled) {'type': 'web_search'},
        if (m.python)
          {
            'type': 'code_interpreter',
            'container': {'type': 'auto'},
          },
      ];
      body['tool_choice'] = switch ((searchRequired, m.python)) {
        (true, true) => {'type': 'web_search'},
        (true, false) => 'required',
        _ => 'auto',
      };
    }
  } else {
    body['messages'] = [
      {'role': 'system', 'content': instructions},
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
    if (searchEnabled && !nativeWebTools) {
      body['web_search_options'] = <String, dynamic>{};
    }
  }
  if (m.temperature != null) {
    body['temperature'] = m.temperature;
  }
  return body;
}

class ModelGateway {
  ModelGateway({
    AppLog? log,
    QuestionSearch? questionSearch,
    PythonCalculator? python,
  }) : questionSearch = questionSearch ?? QuestionSearch(),
       _python = python ?? PythonCalculator() {
    if (log != null) this.log = log;
  }
  AppLog? _log;
  AppLog? get log => _log;
  set log(AppLog? value) {
    _log = value;
    questionSearch.log = value;
  }

  final QuestionSearch questionSearch;
  final PythonCalculator _python;
  int _generation = 0;
  final Set<HttpClient> _clients = {};
  final Set<Completer<void>> _pendingRequests = {};
  void cancelAll() {
    _generation++;
    questionSearch.cancelAll();
    _python.cancelAll();
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
    Duration? requestBudget,
  }) async {
    final cancelled = Completer<void>();
    _pendingRequests.add(cancelled);
    final budget = requestBudget ?? Duration(seconds: timeout);
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
        log?.write('network', 'upstream.response.headers', {
          'requestId': requestId,
          'elapsedMs': watch.elapsedMilliseconds,
          ...logResponseMetadata(response),
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
    Question q, {
    bool allowGuess = false,
    bool agentMode = false,
  }) async {
    validateModel(m, p);
    final generation = _generation;
    final watch = Stopwatch()..start();
    final total = Duration(seconds: m.timeoutSeconds);
    Duration remaining() => total - watch.elapsed;
    void checkCancelled() {
      if (generation != _generation) throw const GatewayException('请求已取消');
    }

    final expression = q.title
        .trim()
        .replaceFirst(_emptyEquationSuffix, '')
        .trimRight();
    if (m.calculation == CalculationMode.localPython &&
        m.search == SearchMode.off &&
        !agentMode &&
        q.type == 'completion' &&
        q.options.trim().isEmpty &&
        q.images.isEmpty &&
        expression.length <= PythonCalculator.maxExpressionLength &&
        _bareArithmetic.hasMatch(expression) &&
        _arithmeticOperator.hasMatch(expression) &&
        !expression.contains('//')) {
      try {
        final result = (await _python.calculateBatch(
          [expression],
          remaining(),
          log: log,
        )).single;
        checkCancelled();
        if (result.value case final String value
            when result.approximation == null) {
          final answer = AnswerResult(
            answers: [value],
            explanation: '本机 Python 计算。',
            pythonCalls: 1,
          );
          log?.write('runtime', 'gateway.answer.local', {
            'question': q.toJson(),
            'result': answer.toJson(),
          });
          return answer;
        }
      } on PythonUnavailable catch (error) {
        checkCancelled();
        throw GatewayException(error.message);
      }
    }

    AnswerResult? first;
    try {
      first = await _answerOnce(
        m,
        p,
        key,
        q,
        requestBudget: remaining(),
        agentMode: agentMode,
      );
    } on FormatException catch (error, stack) {
      log?.error('gateway.answer.invalid', error, stack);
    }
    checkCancelled();
    if (first != null && !needsVerification(first)) return first;

    final nativeWebTools = usesDeepSeekWebTools(m, p);
    var searched = const QuestionSearchResult([]);
    AnswerResult? verified;
    AnswerResult? hosted;
    var failure = '';
    if (supportsHostedSearch(m, p) && remaining() > Duration.zero) {
      try {
        hosted = await _answerOnce(
          m,
          p,
          key,
          q,
          requestBudget: nativeWebTools ? remaining() : remaining() ~/ 2,
          verificationContext: nativeWebTools
              ? '核对本题答案及其依据。'
              : '优先使用模型自带的联网工具，必须现在搜索原题；找不到就搜索相似题与知识点，再核对答案。不要仅凭已有知识回答。',
          allowGuess: nativeWebTools && allowGuess,
          requireHostedSearch: true,
          agentMode: agentMode,
        );
        checkCancelled();
        if (hosted.searchCalls + hosted.pageReads > 0 ||
            hosted.sources.isNotEmpty) {
          if (!needsVerification(hosted)) {
            return AnswerResult(
              answers: hosted.answers,
              explanation: hosted.explanation,
              sources: {...?first?.sources, ...hosted.sources}.toList(),
              inputTokens: (first?.inputTokens ?? 0) + hosted.inputTokens,
              outputTokens: (first?.outputTokens ?? 0) + hosted.outputTokens,
              searchCalls: (first?.searchCalls ?? 0) + hosted.searchCalls,
              pageReads: (first?.pageReads ?? 0) + hosted.pageReads,
              pythonCalls: (first?.pythonCalls ?? 0) + hosted.pythonCalls,
              calculationCalls:
                  (first?.calculationCalls ?? 0) + hosted.calculationCalls,
              reviewRounds: (first?.reviewRounds ?? 0) + hosted.reviewRounds,
              reviewed: hosted.reviewed,
            );
          }
        }
      } catch (error, stack) {
        checkCancelled();
        log?.error('gateway.answer.hosted_search.error', error, stack);
      }
    }
    if (!nativeWebTools) {
      try {
        if (remaining() > Duration.zero) {
          final searchBudget = remaining() ~/ 3;
          searched = await questionSearch.search(
            q,
            searchBudget < const Duration(seconds: 16)
                ? searchBudget
                : const Duration(seconds: 16),
          );
        }
        checkCancelled();
        final context = jsonEncode({
          '搜索完成次数': searched.calls,
          '搜索状态': searched.calls == 0 ? '搜索未成功，不能声称已查到资料' : '已搜索原题和相似题',
          '结果': searched.hits.map((hit) => hit.toJson()).toList(),
          if (first != null) '待核实候选（不是依据）': first.toJson(),
        });
        if (remaining() > Duration.zero) {
          verified = await _answerOnce(
            m,
            p,
            key,
            q,
            requestBudget: remaining(),
            verificationContext: context,
            allowGuess: allowGuess,
            agentMode: agentMode,
          );
        }
      } catch (error, stack) {
        checkCancelled();
        failure = '检索或复核未完成';
        log?.error('gateway.answer.verification.error', error, stack);
      }
    }
    checkCancelled();
    final hasSearchEvidence =
        searched.hits.isNotEmpty ||
        (hosted?.searchCalls ?? 0) + (hosted?.pageReads ?? 0) > 0 ||
        (verified?.searchCalls ?? 0) + (verified?.pageReads ?? 0) > 0;
    final searchCompleted =
        hasSearchEvidence ||
        searched.calls > 0 ||
        (first?.searchCalls ?? 0) + (first?.pageReads ?? 0) > 0;
    final uncertain =
        verified == null || needsVerification(verified) || !hasSearchEvidence;
    final candidate = verified?.answers.isNotEmpty == true
        ? verified
        : hosted?.answers.isNotEmpty == true
        ? hosted
        : first;
    final answers = !uncertain
        ? verified.answers
        : allowGuess
        ? (candidate?.answers.isNotEmpty == true
              ? candidate!.answers
              : guessAnswers(q))
        : <String>[];
    final result = AnswerResult(
      answers: answers,
      explanation: !uncertain
          ? verified.explanation
          : allowGuess
          ? '猜测：${candidate?.explanation.isNotEmpty == true ? candidate!.explanation : '缺少可靠依据，按题型给出兜底答案。'}${failure.isEmpty ? '' : '（$failure）'}'
          : '${failure.isNotEmpty
                ? failure
                : searchCompleted
                ? '联网复核后仍无法确定答案'
                : '联网搜索未成功'}；未开启猜测。',
      sources: {
        ...?first?.sources,
        ...?verified?.sources,
        ...?hosted?.sources,
        for (final hit in searched.hits) hit.url,
      }.toList(),
      inputTokens:
          (first?.inputTokens ?? 0) +
          (verified?.inputTokens ?? 0) +
          (hosted?.inputTokens ?? 0),
      outputTokens:
          (first?.outputTokens ?? 0) +
          (verified?.outputTokens ?? 0) +
          (hosted?.outputTokens ?? 0),
      searchCalls:
          (first?.searchCalls ?? 0) +
          (verified?.searchCalls ?? 0) +
          (hosted?.searchCalls ?? 0) +
          searched.calls,
      pageReads:
          (first?.pageReads ?? 0) +
          (verified?.pageReads ?? 0) +
          (hosted?.pageReads ?? 0),
      pythonCalls:
          (first?.pythonCalls ?? 0) +
          (verified?.pythonCalls ?? 0) +
          (hosted?.pythonCalls ?? 0),
      calculationCalls:
          (first?.calculationCalls ?? 0) +
          (verified?.calculationCalls ?? 0) +
          (hosted?.calculationCalls ?? 0),
      reviewRounds:
          (first?.reviewRounds ?? 0) +
          (verified?.reviewRounds ?? 0) +
          (hosted?.reviewRounds ?? 0),
      reviewed: !uncertain && verified.reviewed,
      needsSearch: uncertain,
      isGuess: uncertain && allowGuess,
    );
    log?.write('runtime', 'gateway.answer.verified', {
      'allowGuess': allowGuess,
      'result': result.toJson(),
    });
    return result;
  }

  Future<AnswerResult> _answerOnce(
    ModelConfig m,
    ProviderConfig p,
    String key,
    Question q, {
    required Duration requestBudget,
    String? verificationContext,
    bool allowGuess = false,
    bool requireHostedSearch = false,
    bool agentMode = false,
  }) async {
    log?.write('runtime', 'gateway.answer.start', {
      'model': m.toJson(),
      'provider': p.toJson(),
      'question': q.toJson(),
    });
    final nativeWebTools = usesDeepSeekWebTools(m, p);
    final generation = _generation;
    final watch = Stopwatch()..start();
    final uri = endpoint(
      p,
      m.protocol == ApiProtocol.responses ? 'responses' : 'chat/completions',
    );
    final calculations = <Map<String, String>>[];
    final pythonResults = <String, String>{};
    var pythonRounds = 0;
    String? pythonFeedback;
    var calculationCalls = 0;
    var inputTokens = 0;
    var outputTokens = 0;
    var searchCalls = 0;
    var pageReads = 0;
    var pythonCalls = 0;
    var reviewRounds = 0;
    AnswerResult? reviewCandidate;
    final sources = <String>{};
    while (true) {
      if (generation != _generation) throw const GatewayException('请求已取消');
      final Map<String, dynamic> data;
      try {
        data = await _json(
          uri,
          key,
          body: buildRequest(
            m,
            p,
            q,
            verificationContext: verificationContext,
            allowGuess: allowGuess,
            requireHostedSearch: requireHostedSearch,
            calculations: calculations,
            pythonResults: pythonResults,
            pythonRounds: pythonRounds,
            pythonFeedback: pythonFeedback,
            searchPerformed: searchCalls + pageReads > 0,
            reviewCandidate: reviewCandidate,
          ),
          requestBudget: requestBudget - watch.elapsed,
        );
      } on GatewayException catch (error, stack) {
        if (reviewCandidate == null || generation != _generation) rethrow;
        log?.error('gateway.agent.review.error', error, stack);
        return reviewCandidate.withReview(reviewRounds, confirmed: false);
      }
      String content = '';
      var roundSearchCalls = 0;
      var roundPageReads = 0;
      void recordWebCall(Map call) {
        if (call['status'] != 'completed') return;
        final action = call['action'];
        final actionType = action is Map ? action['type'] : null;
        if (call['kind'] == 'read_link' ||
            actionType == 'read_link' ||
            actionType == 'open_page' ||
            actionType == 'find_in_page') {
          roundPageReads++;
        } else {
          final results =
              call['sources'] ?? (action is Map ? action['sources'] : null);
          if (nativeWebTools && results is List && results.isEmpty) return;
          roundSearchCalls++;
        }
      }

      if (data['error'] != null) {
        throw const GatewayException('模型输出未完成，请调整 Token 或参数');
      }
      if (m.protocol == ApiProtocol.responses) {
        if (data['status'] == 'incomplete' || data['status'] == 'failed') {
          throw const GatewayException('模型输出未完成，请调整 Token 或参数');
        }
        for (final item in (data['output'] as List? ?? []).whereType<Map>()) {
          if (item['type'] == 'code_interpreter_call' &&
              item['status'] == 'completed') {
            pythonCalls++;
          }
          if (item['type'] == 'web_search_call') {
            recordWebCall(item);
          }
          if (item['type'] != 'message') {
            continue;
          }
          for (final part
              in (item['content'] as List? ?? []).whereType<Map>()) {
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
        if (nativeWebTools) {
          for (final step
              in (message['server_tool_calls'] as List? ?? [])
                  .whereType<Map>()) {
            for (final call
                in (step['calls'] as List? ?? []).whereType<Map>()) {
              if (call['type'] == 'deepseek_web_search' ||
                  call['type'] == 'deepseek_read_url') {
                recordWebCall(call);
              }
            }
          }
        }
        for (final a
            in (message['annotations'] as List? ?? []).whereType<Map>()) {
          final c = a['url_citation'];
          if (c is Map && c['url'] is String) {
            sources.add(c['url'] as String);
          }
        }
      }
      if (content.trim().isEmpty) {
        throw const FormatException('模型返回了空答案');
      }
      final usage = data['usage'] as Map? ?? {};
      inputTokens +=
          (usage['input_tokens'] ?? usage['prompt_tokens'] ?? 0) as int;
      outputTokens +=
          (usage['output_tokens'] ?? usage['completion_tokens'] ?? 0) as int;
      final toolUsage = usage['server_tool_use'];
      if (p.kind == ProviderKind.deepseek && toolUsage is Map) {
        final searches = (toolUsage['tool_search'] as num?)?.toInt();
        final imageSearches = (toolUsage['tool_image_search'] as num?)?.toInt();
        if (searches != null || imageSearches != null) {
          roundSearchCalls = (searches ?? 0) + (imageSearches ?? 0);
        }
        roundPageReads =
            (toolUsage['tool_fetch'] as num?)?.toInt() ?? roundPageReads;
      }
      searchCalls += roundSearchCalls;
      pageReads += roundPageReads;
      if (m.usesLocalCalculation) {
        final request = decodeAnswerObject(content);
        final expression = request['calculate'];
        if (request.length == 1 &&
            request.containsKey('calculate') &&
            m.calculation == CalculationMode.localPython) {
          if (pythonRounds >= _maxPythonRounds) {
            throw const GatewayException('模型达到本地计算次数上限');
          }
          pythonRounds++;
          final batch = expression is String ? [expression] : expression;
          if (batch is! List ||
              batch.isEmpty ||
              batch.length > PythonCalculator.maxBatchSize ||
              batch.any(
                (e) =>
                    e is! String ||
                    e.trim().isEmpty ||
                    e.length > PythonCalculator.maxExpressionLength,
              )) {
            pythonFeedback = '计算请求格式有误，请按指定格式提交。';
            continue;
          }
          final pending = batch
              .cast<String>()
              .map((e) => e.trim())
              .toSet()
              .difference(pythonResults.keys.toSet())
              .toList();
          if (pending.isEmpty) {
            pythonFeedback = '这些算式已有结果，请直接使用。';
            continue;
          }
          try {
            final results = await _python.calculateBatch(
              pending,
              requestBudget - watch.elapsed,
              log: log,
            );
            if (generation != _generation) {
              throw const GatewayException('请求已取消');
            }
            for (var i = 0; i < pending.length; i++) {
              final result = results[i];
              final exact = result.value;
              final approximation = result.approximation;
              final value = exact == null
                  ? PythonCalculator.invalidExpression
                  : approximation == null
                  ? exact
                  : '$exact ≈ $approximation';
              pythonResults[pending[i]] = value;
              if (exact != null) pythonCalls++;
              log?.write('runtime', 'gateway.calculator', {
                'mode': m.calculation.name,
                '算式': pending[i],
                exact == null ? '错误' : '结果': value,
              });
            }
            pythonFeedback = null;
          } on PythonUnavailable catch (error) {
            throw GatewayException(error.message);
          }
          continue;
        }
        if (m.calculation == CalculationMode.calculator &&
            request.length == 1 &&
            expression is String) {
          if (calculations.length == 3) {
            throw const GatewayException('模型达到本地计算次数上限');
          }
          try {
            final value = calculate(expression);
            calculations.add({'算式': expression, '结果': value});
            calculationCalls++;
          } on FormatException catch (error) {
            calculations.add({'错误': error.message});
          }
          log?.write('runtime', 'gateway.calculator', {
            'mode': m.calculation.name,
            ...calculations.last,
          });
          continue;
        }
      }
      if ((m.search == SearchMode.required || requireHostedSearch) &&
          (m.protocol == ApiProtocol.responses || nativeWebTools) &&
          searchCalls + pageReads == 0) {
        throw const GatewayException('供应商未执行搜索，请检查模型能力');
      }
      var result = parseAnswer(
        content,
        q,
        sources: sources
            .where(
              (x) =>
                  Uri.tryParse(x)?.scheme == 'https' ||
                  Uri.tryParse(x)?.scheme == 'http',
            )
            .toList(),
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        searchCalls: searchCalls,
        pageReads: pageReads,
        pythonCalls: pythonCalls,
        calculationCalls: calculationCalls,
      );
      if (reviewCandidate != null) {
        reviewRounds++;
        List<String> normalized(List<String> answers) =>
            q.type == 'multiple' ? (answers.toList()..sort()) : answers;
        final confirmed =
            !needsVerification(result) &&
            decodeAnswerObject(content)['review_ok'] == true &&
            jsonEncode(normalized(result.answers)) ==
                jsonEncode(normalized(reviewCandidate.answers));
        log?.write('runtime', 'gateway.agent.review', {
          'round': reviewRounds,
          'confirmed': confirmed,
          'answers': result.answers,
        });
        if (confirmed || reviewRounds >= 3 || needsVerification(result)) {
          result = result.withReview(reviewRounds, confirmed: confirmed);
        } else {
          reviewCandidate = result;
          continue;
        }
      } else if (agentMode && !needsVerification(result)) {
        reviewCandidate = result;
        continue;
      }
      log?.write('runtime', 'gateway.answer.parsed', {
        'model': m.toJson(),
        'result': result.toJson(),
      });
      return result;
    }
  }
}
