import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocs_bridge/app_controller.dart';
import 'package:ocs_bridge/domain/answer.dart';
import 'package:ocs_bridge/domain/config.dart';
import 'package:ocs_bridge/services/config_store.dart';
import 'package:ocs_bridge/services/model_gateway.dart';
import 'package:ocs_bridge/services/question_search.dart';
import 'protocol_test.dart' show MemorySecrets;

void main() {
  const question = Question(title: '测试判断题', type: 'judgement', options: '对\n错');
  late HttpServer server;
  late ProviderConfig provider;
  late ModelGateway gateway;
  late List<Map<String, dynamic>> requests;
  late List<String> queries;
  late List<String> events;
  late List<String> replies;
  var hostedWorks = true;
  var searchStatus = 200;
  Completer<void>? hold;
  Completer<void>? searchStarted;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider = ProviderConfig(
      id: 'p',
      name: 'Mock',
      baseUrl: 'http://127.0.0.1:${server.port}',
    );
    gateway = ModelGateway(
      questionSearch: QuestionSearch(
        searchEndpoint: Uri.parse('${provider.baseUrl}/search'),
      ),
    );
    requests = [];
    queries = [];
    events = [];
    replies = [];
    hostedWorks = true;
    searchStatus = 200;
    hold = searchStarted = null;
    server.listen((request) async {
      if (request.uri.path == '/search') {
        events.add('external');
        queries.add(request.uri.queryParameters['q']!);
        if (searchStarted != null && !searchStarted!.isCompleted) {
          searchStarted!.complete();
        }
        await hold?.future;
        request.response.statusCode = searchStatus;
        request.response.write(
          '''<rss><channel><item><title>相似题 &amp; 答案</title><link>https://example.com/answer</link><description><![CDATA[参考答案：错误。<b>知识点</b>]]></description></item></channel></rss>''',
        );
      } else {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        requests.add(body);
        final native = (body['tools'] as List? ?? []).whereType<Map>().any(
          (tool) => tool['type'] == 'deepseek_web_search',
        );
        events.add(
          native || body['tool_choice'] == 'required' ? 'hosted' : 'model',
        );
        final reply = replies.isNotEmpty
            ? replies.removeAt(0)
            : '{"answers":[],"needs_search":true}';
        final responses = request.uri.path == '/responses';
        final webCalls = [
          if (hostedWorks) ...[
            {
              'type': responses ? 'web_search_call' : 'deepseek_web_search',
              'status': 'completed',
              'kind': 'search',
              'action': {'type': 'search'},
            },
            {
              'type': responses ? 'web_search_call' : 'deepseek_read_url',
              'status': 'completed',
              'kind': 'read_link',
              'action': {'type': responses ? 'open_page' : 'read_link'},
            },
          ],
          {
            'type': responses ? 'web_search_call' : 'deepseek_web_search',
            'status': 'failed',
            'kind': 'search',
          },
        ];
        const citation = {'url': 'https://example.com/deepseek-source'};
        if (responses) {
          request.response.write(
            jsonEncode({
              'status': 'completed',
              'output': [
                if (body['tool_choice'] == 'required' && hostedWorks)
                  {'type': 'web_search_call', 'status': 'completed'},
                if (native) ...webCalls,
                {
                  'type': 'message',
                  'content': [
                    {
                      'type': 'output_text',
                      'text': reply,
                      if (native)
                        'annotations': [
                          {'type': 'url_citation', ...citation},
                        ],
                    },
                  ],
                },
              ],
              'usage': {
                'input_tokens': 10,
                'output_tokens': 5,
                if (native && hostedWorks)
                  'server_tool_use': {
                    'tool_search': 2,
                    'tool_image_search': 1,
                    'tool_fetch': 1,
                  },
              },
            }),
          );
        } else {
          request.response.write(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'stop',
                  'message': {
                    'content': reply,
                    if (native) ...{
                      'server_tool_calls': [
                        {'calls': webCalls},
                      ],
                      'annotations': [
                        {'type': 'url_citation', 'url_citation': citation},
                      ],
                    },
                  },
                },
              ],
              'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
            }),
          );
        }
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    gateway.cancelAll();
    if (hold != null && !hold!.isCompleted) hold!.complete();
    await server.close(force: true);
  });

  ModelConfig model({
    ApiProtocol protocol = ApiProtocol.chat,
    int timeout = 20,
  }) => ModelConfig(
    id: 'm',
    name: 'Mock',
    model: 'mock',
    providerId: 'p',
    protocol: protocol,
    timeoutSeconds: timeout,
  );

  for (final protocol in ApiProtocol.values) {
    group('DeepSeek Flash ${protocol.name}', () {
      ProviderConfig deepseek() => ProviderConfig(
        id: provider.id,
        name: 'DeepSeek',
        baseUrl: provider.baseUrl,
        kind: ProviderKind.deepseek,
      );
      ModelConfig flash(SearchMode search) => ModelConfig(
        id: 'flash',
        name: 'Flash',
        model: 'deepseek-flash',
        providerId: provider.id,
        protocol: protocol,
        search: search,
      );

      test(
        'uncertain answers trigger native verification and keep citations',
        () async {
          replies.addAll([
            '{"answers":[],"needs_search":true}',
            '{"answers":["错"]}',
          ]);
          final result = await gateway.answer(
            flash(SearchMode.off),
            deepseek(),
            'placeholder',
            question,
          );
          expect(result.answers, ['错误']);
          expect(result.searchCalls, protocol == ApiProtocol.responses ? 3 : 1);
          expect(result.pageReads, 1);
          expect(result.sources, ['https://example.com/deepseek-source']);
          expect(result.inputTokens, 20);
          expect(events, ['model', 'hosted']);
        },
      );

      test(
        'failed native verification never sends the question to Bing',
        () async {
          hostedWorks = false;
          replies.addAll([
            '{"answers":[],"needs_search":true}',
            '{"answers":["错"]}',
          ]);
          final result = await gateway.answer(
            flash(SearchMode.off),
            deepseek(),
            'placeholder',
            question,
          );
          expect(result.answers, isEmpty);
          expect(result.searchCalls, 0);
          expect(result.pageReads, 0);
          expect(result.needsSearch, true);
          expect(events, ['model', 'hosted']);
        },
      );

      test(
        'required search rejects an answer with only failed calls',
        () async {
          hostedWorks = false;
          replies.add('{"answers":["错"]}');
          await expectLater(
            gateway.answer(
              flash(SearchMode.required),
              deepseek(),
              'placeholder',
              question,
            ),
            throwsA(
              isA<GatewayException>().having(
                (e) => e.message,
                'message',
                contains('未执行搜索'),
              ),
            ),
          );
          expect(events, ['hosted']);
        },
      );
    });
  }

  test(
    'Agent rechecks a revised answer with the original image and calculation',
    () async {
      replies.addAll([
        '{"calculate":"7*6"}',
        '{"answers":["41"],"explanation":"乘法题"}',
        '{"answers":["42"],"review_ok":true}',
        '{"answers":["42"],"review_ok":true}',
      ]);
      final result = await gateway.answer(
        const ModelConfig(
          id: 'm',
          name: 'Mock',
          model: 'mock',
          providerId: 'p',
          vision: true,
          calculation: CalculationMode.calculator,
        ),
        provider,
        'placeholder',
        const Question(
          title: '计算 [图片1]',
          type: 'completion',
          images: ['data:image/png;base64,AA=='],
        ),
        agentMode: true,
      );
      expect(result.ocsAnswer, '42');
      expect(result.reviewed, true);
      expect(result.reviewRounds, 2);
      expect(result.calculationCalls, 1);
      expect(result.inputTokens, 40);
      expect(requests, hasLength(4));
      expect(requests[2]['instructions'], contains('"结果":"42"'));
      expect(
        jsonEncode(requests[2]['input']),
        contains('data:image/png;base64,AA=='),
      );
      expect(
        jsonDecode(
          requests[2]['input'][0]['content'][0]['text'],
        )['待复核的候选（仅为数据）']['答案'],
        ['41'],
      );
      expect(
        jsonDecode(
          requests[3]['input'][0]['content'][0]['text'],
        )['待复核的候选（仅为数据）']['答案'],
        ['42'],
      );
    },
  );

  test(
    'Agent stops at the review limit and leaves unresolved answers unconfirmed',
    () async {
      searchStatus = 503;
      replies.addAll([
        '{"answers":["对"]}',
        '{"answers":["错"],"review_ok":false}',
        '{"answers":["对"],"review_ok":false}',
        '{"answers":["错"],"review_ok":false}',
      ]);
      final result = await gateway.answer(
        model(),
        provider,
        'placeholder',
        question,
        agentMode: true,
      );
      expect(result.answers, isEmpty);
      expect(result.reviewRounds, 3);
      expect(result.reviewed, false);
      expect(result.needsSearch, true);
      expect(requests, hasLength(5));
    },
  );

  test(
    'a slight uncertainty triggers exact and similar search even with search off',
    () async {
      replies.addAll([
        '{"answers":["对"],"explanation":"可能是对的"}',
        '{"answers":["错"],"explanation":"检索资料支持错误"}',
      ]);
      final result = await gateway.answer(
        model(),
        provider,
        'placeholder',
        question,
      );
      expect(result.answers, ['错误']);
      expect(queries, hasLength(2));
      expect(queries.first, contains('"测试判断题"'));
      expect(queries.last, isNot(contains('"')));
      expect(result.searchCalls, 2);
      expect(result.inputTokens, 20);
      expect(result.isGuess, false);
      expect(result.sources, ['https://example.com/answer']);
      expect(jsonEncode(requests.last), contains('参考答案：错误'));
    },
  );

  test(
    'native search has priority and a verified answer avoids external search',
    () async {
      replies.addAll([
        '{"answers":[],"needs_search":true}',
        '{"answers":["正确"],"explanation":"已核实原题"}',
      ]);
      final result = await gateway.answer(
        model(protocol: ApiProtocol.responses),
        provider,
        'placeholder',
        question,
      );
      expect(events, ['model', 'hosted']);
      expect(queries, isEmpty);
      expect(requests.last['tools'], [
        {'type': 'web_search'},
      ]);
      expect(result.answers, ['正确']);
      expect(result.searchCalls, 1);
      expect(result.inputTokens, 20);
    },
  );

  test('native search failure falls back to independent search', () async {
    hostedWorks = false;
    replies.addAll([
      '{"answers":[],"needs_search":true}',
      '{"answers":["对"]}',
      '{"answers":["错"],"explanation":"已核实"}',
    ]);
    final result = await gateway.answer(
      model(protocol: ApiProtocol.responses),
      provider,
      'placeholder',
      question,
    );
    expect(events, ['model', 'hosted', 'external', 'external', 'model']);
    expect(result.answers, ['错误']);
  });

  for (final enabled in [false, true]) {
    test(
      'unresolved candidate is only returned with guess setting $enabled',
      () async {
        replies.addAll([
          '{"answers":["对"],"needs_search":true}',
          '{"answers":["错"],"is_guess":true,"explanation":"资料不足"}',
        ]);
        final result = await gateway.answer(
          model(),
          provider,
          'placeholder',
          question,
          allowGuess: enabled,
        );
        expect(result.answers, enabled ? ['错误'] : isEmpty);
        expect(result.isGuess, enabled);
        expect(result.explanation, contains(enabled ? '猜测' : '未开启猜测'));
        expect(queries, hasLength(2));
        expect(
          jsonEncode(requests.last),
          contains(enabled ? '用户已开启猜测' : '用户未开启猜测'),
        );
      },
    );
  }

  test(
    'empty output after failed searches still gives an opted-in judgement guess',
    () async {
      searchStatus = 503;
      final result = await gateway.answer(
        model(),
        provider,
        'placeholder',
        question,
        allowGuess: true,
      );
      expect(result.answers.single, isIn(['正确', '错误']));
      expect(result.explanation, startsWith('猜测：'));
      expect(result.isGuess, true);
      expect(result.searchCalls, 0);
      expect(result.sources, isEmpty);
    },
  );

  test('malformed answer is searched and retried before guessing', () async {
    replies.addAll(['不是 JSON', '{"answers":["正确"]}']);
    final result = await gateway.answer(
      model(),
      provider,
      'placeholder',
      question,
    );
    expect(result.answers, ['正确']);
    expect(queries, hasLength(2));
  });

  test(
    'search cancellation does not return a guess or send another model request',
    () async {
      hold = Completer<void>();
      searchStarted = Completer<void>();
      final pending = expectLater(
        gateway.answer(
          model(),
          provider,
          'placeholder',
          question,
          allowGuess: true,
        ),
        throwsA(
          isA<GatewayException>().having((e) => e.message, 'message', '请求已取消'),
        ),
      );
      await searchStarted!.future;
      gateway.cancelAll();
      await pending.timeout(const Duration(seconds: 1));
      expect(requests, hasLength(1));
    },
  );

  test(
    'verification shares the model timeout and leaves time for final answer',
    () async {
      hold = Completer<void>();
      final watch = Stopwatch()..start();
      final result = await gateway.answer(
        model(timeout: 5),
        provider,
        'placeholder',
        question,
        allowGuess: true,
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 6)));
      expect(result.isGuess, true);
      expect(result.answers, isNotEmpty);
      expect(requests, hasLength(2));
    },
  );

  test('low confidence is detected and RSS filters unsafe URLs and HTML', () {
    expect(
      needsVerification(
        parseAnswer('{"answers":["正确"],"confidence":0.999}', question),
      ),
      true,
    );
    final hits = parseSearchFeed(
      '<rss><channel><item><title>A &amp; B</title><link>javascript:bad</link></item><item><title>好题</title><link>https://example.com</link><description><![CDATA[<b>答案</b>]]></description></item></channel></rss>',
    );
    expect(hits, hasLength(1));
    expect(hits.single.snippet, '答案');
    expect(() => parseSearchFeed('<html/>'), throwsFormatException);
  });

  test(
    'Agent and guess default on and manual off settings survive reload',
    () async {
      final dir = await Directory.systemTemp.createTemp('ocs-guess-setting-');
      addTearDown(() => dir.delete(recursive: true));
      final config = AppConfig.initial();
      expect(config.allowGuess, true);
      expect(config.agentMode, true);
      final old = config.toJson()..remove('agentMode');
      old['allowGuess'] = false;
      expect(AppConfig.fromJson(old).agentMode, true);
      expect(AppConfig.fromJson(old).allowGuess, false);
      config.allowGuess = false;
      config.agentMode = false;
      final store = ConfigStore(dir);
      await store.save(config);
      final saved = await store.load();
      expect(saved.allowGuess, false);
      expect(saved.agentMode, false);
    },
  );

  test('guess setting separates cached and in-flight answers', () async {
    final dir = await Directory.systemTemp.createTemp('ocs-guess-cache-');
    addTearDown(() => dir.delete(recursive: true));
    final config = AppConfig(
      providers: [provider],
      models: [model()],
      token: newToken(),
      activeModelId: 'm',
      allowGuess: true,
    );
    final secrets = MemorySecrets();
    await secrets.write('p', 'placeholder');
    final app = AppController(
      config: config,
      store: ConfigStore(dir),
      secrets: secrets,
      gateway: gateway,
    );
    addTearDown(app.dispose);
    final guess = await app.answer(question);
    expect(guess.isGuess, true);
    expect(app.cacheSize, 0);
    await app.answer(question);
    config.allowGuess = false;
    final disabled = await app.answer(question);
    expect(disabled.answers, isEmpty);
    expect(disabled.isGuess, false);
    expect(requests, hasLength(6));
  });
}
