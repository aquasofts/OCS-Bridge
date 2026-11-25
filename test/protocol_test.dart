import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocs_bridge/app_controller.dart';
import 'package:ocs_bridge/domain/answer.dart';
import 'package:ocs_bridge/domain/config.dart';
import 'package:ocs_bridge/services/app_log.dart';
import 'package:ocs_bridge/services/bridge_server.dart';
import 'package:ocs_bridge/services/calculator.dart';
import 'package:ocs_bridge/services/config_store.dart';
import 'package:ocs_bridge/services/model_gateway.dart';
import 'package:ocs_bridge/services/python_calculator.dart';

class _TestPythonCalculator extends PythonCalculator {
  final batches = <List<String>>[];

  @override
  Future<List<PythonCalculation>> calculateBatch(
    List<String> expressions,
    Duration budget, {
    AppLog? log,
  }) async {
    batches.add(expressions);
    return [
      for (final expression in expressions)
        switch (expression) {
          '1/3' => (value: '1/3', approximation: null),
          'sqrt(2)' => (value: 'sqrt(2)', approximation: '1.414213562373095'),
          '0.1 + 0.2' => (value: '0.3', approximation: null),
          _ => (value: null, approximation: null),
        },
    ];
  }
}

class MemorySecrets implements SecretStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String id) async => values[id];
  @override
  Future<void> write(String id, String value) async {
    values[id] = value;
  }

  @override
  Future<void> delete(String id) async {
    values.remove(id);
  }
}

void main() {
  const openai = ProviderConfig(
    id: 'p',
    name: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    kind: ProviderKind.openai,
  );
  const deepseek = ProviderConfig(
    id: 'd',
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    kind: ProviderKind.deepseek,
  );
  const question = Question(
    title: '编程语言？',
    options: 'A. Dart\nB. Windows\nC. Python',
    type: 'multiple',
  );

  test('legacy Python settings keep their original hosted mode', () {
    const model = ModelConfig(
      id: 'm',
      name: 'Test',
      model: 'm',
      providerId: 'p',
    );
    final previous = model.toJson()..remove('calculation');
    expect(ModelConfig.fromJson(previous).calculation, CalculationMode.off);
    previous['python'] = true;
    final migrated = ModelConfig.fromJson(previous);
    expect(migrated.calculation, CalculationMode.hostedPython);
    expect(
      ModelConfig.fromJson(migrated.toJson()).calculation,
      migrated.calculation,
    );
  });
  test('built-in fallback rejects undefined intermediate results', () {
    expect(calculate('-(2+3)^2 + sqrt(9)'), '-22');
    expect(() => calculate('1/(1/0)'), throwsFormatException);
    expect(() => calculate('sqrt(-1)^0'), throwsFormatException);
    expect(() => calculate('print(1)'), throwsFormatException);
  });

  test('Responses uses instructions, reasoning and required hosted search', () {
    const m = ModelConfig(
      id: 'm',
      name: 'test',
      model: 'test-model',
      providerId: 'p',
      search: SearchMode.required,
      effort: 'high',
    );
    final request = buildRequest(m, openai, question);
    expect(request['reasoning'], {'effort': 'high'});
    expect(request['tools'], [
      {'type': 'web_search'},
    ]);
    expect(request['tool_choice'], 'required');
    expect(request['store'], false);
    expect(request, isNot(contains('messages')));
    expect(
      endpoint(openai, 'responses').toString(),
      'https://api.openai.com/v1/responses',
    );
  });
  test('DeepSeek chat uses thinking and max_tokens', () {
    const m = ModelConfig(
      id: 'm',
      name: 'test',
      model: 'deepseek-flash',
      providerId: 'd',
      protocol: ApiProtocol.chat,
      effort: 'max',
      thinking: 'enabled',
    );
    final request = buildRequest(m, deepseek, question);
    expect(request['thinking'], {'type': 'enabled'});
    expect(request['reasoning_effort'], 'max');
    expect(request['max_tokens'], 8192);
    expect(request, isNot(contains('tools')));
    expect(request, isNot(contains('temperature')));
  });
  test('DeepSeek Responses maps thinking off into reasoning none', () {
    const m = ModelConfig(
      id: 'm',
      name: 'test',
      model: 'deepseek-flash',
      providerId: 'd',
      thinking: 'disabled',
    );
    final request = buildRequest(m, deepseek, question);
    expect(request['reasoning'], {'effort': 'none'});
    expect(request, isNot(contains('thinking')));
    expect(request, isNot(contains('store')));
  });
  test('DeepSeek V4 Pro keeps legacy search on Responses', () {
    const pro = ModelConfig(
      id: 'pro',
      name: 'Pro',
      model: 'deepseek-v4-pro',
      providerId: 'd',
      search: SearchMode.required,
      effort: 'none',
    );
    expect(buildRequest(pro, deepseek, question)['tools'], [
      {'type': 'web_search'},
    ]);
    expect(buildRequest(pro, deepseek, question)['tool_choice'], 'required');
  });
  for (final protocol in ApiProtocol.values) {
    test('DeepSeek Flash declares native web tools on ${protocol.name}', () {
      Map<String, dynamic> request(SearchMode search, {bool verify = false}) =>
          buildRequest(
            ModelConfig(
              id: 'f',
              name: 'Flash',
              model: 'deepseek-flash',
              providerId: 'd',
              protocol: protocol,
              search: search,
              thinking: 'enabled',
            ),
            deepseek,
            question,
            requireHostedSearch: verify,
          );

      expect(request(SearchMode.off), isNot(contains('tools')));
      for (final body in [
        request(SearchMode.auto),
        request(SearchMode.required),
        request(SearchMode.off, verify: true),
      ]) {
        expect(body['tools'], [
          {'type': 'deepseek_web_search'},
          {'type': 'deepseek_read_url'},
        ]);
        expect(body, isNot(contains('web_search_options')));
        expect(body, isNot(contains('tool_choice')));
        if (protocol == ApiProtocol.chat) {
          expect(body['thinking'], {'type': 'enabled'});
        } else {
          expect(body['reasoning'], {'effort': 'high'});
        }
      }
      expect(jsonEncode(request(SearchMode.required)), contains('本题必须使用联网工具'));
    });
  }
  test(
    'incompatible search, capabilities and override attempts fail explicitly',
    () {
      expect(
        () => buildRequest(
          const ModelConfig(
            id: 'm',
            name: 'test',
            model: 'm',
            providerId: 'd',
            protocol: ApiProtocol.chat,
            search: SearchMode.auto,
          ),
          deepseek,
          question,
        ),
        throwsFormatException,
      );
      expect(
        () => buildRequest(
          const ModelConfig(
            id: 'm',
            name: 'test',
            model: 'm',
            providerId: 'p',
            extra: {'messages': []},
          ),
          openai,
          question,
        ),
        throwsFormatException,
      );
      expect(
        () => validateProvider(
          const ProviderConfig(
            id: 'x',
            name: 'x',
            baseUrl: 'http://example.com',
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => buildRequest(
          const ModelConfig(id: 'm', name: 'test', model: 'm', providerId: 'p'),
          openai,
          const Question(title: '图片', images: ['data:image/png;base64,AA==']),
        ),
        throwsA(isA<GatewayException>()),
      );
    },
  );
  test('answers map labels to text and preserve blank order', () {
    final r = parseAnswer(
      '```json\n{"answers":["A", "C"],"explanation":"test"}\n```',
      question,
    );
    expect(r.ocsAnswer, 'Dart#Python');
    expect(
      parseAnswer(
        '{"answers":["甲","乙"]}',
        const Question(title: '填空', type: 'completion'),
      ).ocsAnswer,
      '甲#乙',
    );
    expect(
      parseAnswer(
        '{"answers":["true"]}',
        const Question(title: '判断', type: 'judgement'),
      ).ocsAnswer,
      '正确',
    );
    expect(() => parseAnswer('我猜是 A', question), throwsFormatException);
    expect(
      () => parseAnswer(
        '{"answers":["a","b"]}',
        const Question(title: '单选', type: 'single'),
      ),
      throwsFormatException,
    );
    expect(parseAnswer('{"answers":[]}', question).answers, isEmpty);
  });
  test('OCS request validates payload and inline images', () {
    expect(Question.fromJson({'title': '题目', 'images': '[]'}).images, isEmpty);
    expect(
      () => Question.fromJson({'title': ' ', 'options': ''}),
      throwsFormatException,
    );
    expect(
      () => Question.fromJson({
        'title': '题目',
        'images': ['https://external.test/private'],
      }),
      throwsFormatException,
    );
  });
  test(
    'configuration saves serially and never stores provider API keys',
    () async {
      final dir = await Directory.systemTemp.createTemp('ocs-config-');
      addTearDown(() => dir.delete(recursive: true));
      final store = ConfigStore(dir);
      final config = AppConfig.initial();
      await store.save(config);
      config.darkMode = true;
      final first = store.save(config);
      config.port = 15319;
      final second = store.save(config);
      await Future.wait([first, second]);
      final loaded = await store.load();
      expect(loaded.port, 15319);
      expect(loaded.darkMode, true);
      expect(loaded.token, config.token);
      expect(await store.file.readAsString(), isNot(contains('apiKey')));
      await store.file.writeAsString('{broken');
      await expectLater(store.load(), throwsFormatException);
    },
  );
  test(
    'first-run provider and model CRUD survives a configuration reload',
    () async {
      final dir = await Directory.systemTemp.createTemp('ocs-first-run-');
      addTearDown(() => dir.delete(recursive: true));
      final store = ConfigStore(dir);
      final secrets = MemorySecrets();
      final app = AppController(
        config: AppConfig.initial(),
        store: store,
        secrets: secrets,
      );
      addTearDown(app.dispose);
      const p = ProviderConfig(
        id: 'custom',
        name: 'Custom',
        baseUrl: 'https://example.com/v1',
      );
      await app.saveProvider(p, 'test-placeholder');
      const m = ModelConfig(
        id: 'custom-model',
        name: 'Custom Model',
        model: 'test-model',
        providerId: 'custom',
      );
      await app.saveModel(m);
      await app.saveProvider(
        const ProviderConfig(
          id: 'openai',
          name: 'Edited',
          baseUrl: 'https://api.openai.com/v1',
          kind: ProviderKind.openai,
        ),
        '',
      );
      final loaded = await store.load();
      expect(loaded.providers.length, 3);
      expect(loaded.providers.first.name, 'Edited');
      expect(loaded.models.single.id, m.id);
      expect(loaded.activeModelId, m.id);
      expect(
        await store.file.readAsString(),
        isNot(contains('test-placeholder')),
      );
      await app.deleteModel(m.id);
      await app.deleteProvider(p.id);
      expect((await store.load()).models, isEmpty);
      expect((await store.load()).providers.length, 2);
      expect(await secrets.read(p.id), isNull);
    },
  );

  group('real local HTTP integration', () {
    const pythonModel = ModelConfig(
      id: 'local-python',
      name: 'Local Python',
      model: 'local-python',
      providerId: 'local',
      calculation: CalculationMode.localPython,
    );
    late HttpServer upstream;
    late ProviderConfig provider;
    late ModelGateway gateway;
    late _TestPythonCalculator python;
    var calls = 0;
    late List<Map<String, dynamic>> requests;
    setUp(() async {
      calls = 0;
      requests = [];
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      provider = ProviderConfig(
        id: 'local',
        name: 'Mock',
        baseUrl: 'http://127.0.0.1:${upstream.port}/v1',
      );
      python = _TestPythonCalculator();
      gateway = ModelGateway(python: python);
      upstream.listen((req) async {
        calls++;
        expect(req.headers.value('Authorization'), 'Bearer test-secret');
        req.response.headers.contentType = ContentType.json;
        if (req.uri.path.endsWith('/models')) {
          req.response.write(
            jsonEncode({
              'data': [
                {'id': 'b'},
                {'id': 'a'},
                {'id': 'a'},
              ],
            }),
          );
        } else {
          final body =
              jsonDecode(await utf8.decoder.bind(req).join())
                  as Map<String, dynamic>;
          requests.add(body);
          if (body['model'] == 'denied') {
            req.response.statusCode = 401;
            req.response.write('{"error":"test-secret should not appear"}');
          } else if (req.uri.path.endsWith('/responses')) {
            final calculation = body['model'] == 'local-calculation';
            final hasResult = (body['instructions'] as String).contains(
              '"结果":"4280995423"',
            );
            final hasPythonResult = (body['instructions'] as String).contains(
              '"sqrt(2)":"sqrt(2) ≈ 1.414213562373095"',
            );
            req.response.write(
              jsonEncode({
                'status': 'completed',
                'output': [
                  {'type': 'reasoning', 'summary': []},
                  if (body['model'] != 'no-search')
                    {'type': 'web_search_call', 'status': 'completed'},
                  {'type': 'web_search_call', 'status': 'failed'},
                  if (body['model'] == 'vision-python') ...[
                    {'type': 'code_interpreter_call', 'status': 'completed'},
                    {'type': 'code_interpreter_call', 'status': 'failed'},
                  ],
                  {
                    'type': 'message',
                    'content': [
                      {
                        'type': 'output_text',
                        'text': switch (body['model']) {
                          'vision-python' =>
                            '{"answers":["[图片3]"],"explanation":"计算得 6"}',
                          'local-python' when !hasPythonResult =>
                            '{"calculate":["1/3","sqrt(2)","1/0"," 1/3 "]}',
                          'local-python' => '{"answers":["1/3","sqrt(2)"]}',
                          _ when calculation && !hasResult =>
                            '{"calculate":"73649 * 58127"}',
                          _ when calculation => '{"answers":["4280995423"]}',
                          _ => '{"answers":["A","C"],"explanation":"已验证"}',
                        },
                        'annotations': [
                          {
                            'type': 'url_citation',
                            'url': 'https://dart.dev',
                            'title': 'Dart',
                          },
                        ],
                      },
                    ],
                  },
                ],
                'usage': {
                  'input_tokens': 10,
                  'output_tokens': 12,
                  if (body['model'] == 'deepseek-v4-pro')
                    'server_tool_use': {'tool_search': 2, 'tool_fetch': 1},
                },
              }),
            );
          } else {
            req.response.write(
              jsonEncode({
                'choices': [
                  {
                    'finish_reason': 'stop',
                    'message': {
                      'content': '{"answers":["A","C"]}',
                      'reasoning_content': 'Never interpret this as an answer',
                    },
                  },
                ],
                'usage': {'prompt_tokens': 11, 'completion_tokens': 13},
              }),
            );
          }
        }
        await req.response.close();
      });
    });
    tearDown(() async {
      gateway.cancelAll();
      await upstream.close(force: true);
    });
    test(
      'lists remote models, parses Responses and Chat independently',
      () async {
        expect(await gateway.listModels(provider, 'test-secret'), ['a', 'b']);
        final responses = await gateway.answer(
          const ModelConfig(
            id: 'r',
            name: 'r',
            model: 'r',
            providerId: 'local',
          ),
          provider,
          'test-secret',
          question,
        );
        expect(responses.ocsAnswer, 'Dart#Python');
        expect(responses.sources, ['https://dart.dev']);
        expect(responses.inputTokens, 10);
        expect(responses.searchCalls, 1);
        final chat = await gateway.answer(
          const ModelConfig(
            id: 'c',
            name: 'c',
            model: 'c',
            providerId: 'local',
            protocol: ApiProtocol.chat,
          ),
          provider,
          'test-secret',
          question,
        );
        expect(chat.ocsAnswer, 'Dart#Python');
        expect(chat.outputTokens, 13);
        expect(chat.searchCalls, 0);
        expect(requests.last, contains('messages'));
      },
    );
    test(
      'DeepSeek tool usage is counted and required search cannot be silently ignored',
      () async {
        final ds = ProviderConfig(
          id: 'local',
          name: 'DeepSeek',
          baseUrl: provider.baseUrl,
          kind: ProviderKind.deepseek,
        );
        final result = await gateway.answer(
          const ModelConfig(
            id: 'ds',
            name: 'Pro',
            model: 'deepseek-v4-pro',
            providerId: 'local',
            search: SearchMode.required,
          ),
          ds,
          'test-secret',
          question,
        );
        expect(result.searchCalls, 2);
        expect(result.pageReads, 1);
        await expectLater(
          gateway.answer(
            const ModelConfig(
              id: 'no',
              name: 'No Search',
              model: 'no-search',
              providerId: 'local',
              search: SearchMode.required,
            ),
            provider,
            'test-secret',
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
      },
    );
    test('upstream error bodies never expose API keys', () async {
      try {
        await gateway.answer(
          const ModelConfig(
            id: 'd',
            name: 'denied',
            model: 'denied',
            providerId: 'local',
          ),
          provider,
          'test-secret',
          question,
        );
        fail('Expected failure');
      } on GatewayException catch (e) {
        expect(e.message, contains('401'));
        expect(e.message, isNot(contains('test-secret')));
      }
    });
    test(
      'local calculator returns real results without upstream tools',
      () async {
        final result = await gateway.answer(
          const ModelConfig(
            id: 'calc',
            name: 'Calc',
            model: 'local-calculation',
            providerId: 'local',
            calculation: CalculationMode.calculator,
          ),
          provider,
          'test-secret',
          const Question(title: '73649 × 58127', type: 'completion'),
        );
        expect(result.ocsAnswer, (73649 * 58127).toString());
        expect(result.calculationCalls, 1);
        expect(result.pythonCalls, 0);
        expect(result.inputTokens, 20);
        expect(requests, hasLength(2));
        expect(requests.every((body) => !body.containsKey('tools')), isTrue);
      },
    );
    test(
      'local Python sends a deduplicated batch and finishes in two requests',
      () async {
        final result = await gateway.answer(
          pythonModel,
          provider,
          'test-secret',
          const Question(title: '分别计算三分之一和 2 的平方根', type: 'completion'),
        );
        expect(result.answers, ['1/3', 'sqrt(2)']);
        expect(result.pythonCalls, 2);
        expect(result.inputTokens, 20);
        expect(requests, hasLength(2));
        expect(python.batches, [
          ['1/3', 'sqrt(2)', '1/0'],
        ]);
        expect(requests.last['instructions'], contains('"1/3":"1/3"'));
        expect(
          requests.last['instructions'],
          contains(PythonCalculator.invalidExpression),
        );
      },
    );
    test(
      'bare arithmetic completion is answered without a model request',
      () async {
        final result = await gateway.answer(
          pythonModel,
          provider,
          'test-secret',
          const Question(title: '0.1 + 0.2 = ___', type: 'completion'),
        );
        expect(result.answers, ['0.3']);
        expect(result.pythonCalls, 1);
        expect(result.inputTokens + result.outputTokens, 0);
        expect(requests, isEmpty);
        expect(python.batches, [
          ['0.1 + 0.2'],
        ]);
      },
    );
    test(
      'OCS to bridge to model returns answer, auth failures and cache behavior',
      () async {
        final dir = await Directory.systemTemp.createTemp('ocs-integration-');
        addTearDown(() => dir.delete(recursive: true));
        final secrets = MemorySecrets();
        await secrets.write('local', 'test-secret');
        final config = AppConfig(
          providers: [provider],
          models: [
            const ModelConfig(
              id: 'r',
              name: 'R',
              model: 'r',
              providerId: 'local',
            ),
          ],
          activeModelId: 'r',
          token: newToken(),
          agentMode: false,
        );
        final app = AppController(
          config: config,
          store: ConfigStore(dir),
          secrets: secrets,
          gateway: gateway,
        );
        final bridge = BridgeServer();
        await bridge.start(
          port: 0,
          token: config.token,
          answer: (q) => app.answer(q),
        );
        final client = HttpClient();
        addTearDown(() async {
          client.close(force: true);
          await bridge.stop();
          app.dispose();
        });
        Future<(int, Map<String, dynamic>)> post(
          String? token,
          Object payload,
        ) async {
          final req = await client.postUrl(
            Uri.parse('http://127.0.0.1:${bridge.port}/answer'),
          );
          req.headers.contentType = ContentType.json;
          if (token != null) {
            req.headers.set('X-OCS-Token', token);
          }
          req.write(jsonEncode(payload));
          final response = await req.close();
          return (
            response.statusCode,
            jsonDecode(await utf8.decoder.bind(response).join())
                as Map<String, dynamic>,
          );
        }

        expect((await post(null, question.toJson())).$1, 401);
        expect((await post('wrong', question.toJson())).$1, 401);
        expect((await post(config.token, {'title': ''})).$1, 400);
        final result = await post(config.token, question.toJson());
        expect(result.$1, 200);
        expect(result.$2['answer'], 'Dart#Python');
        await post(config.token, question.toJson());
        expect(calls, 1);
        expect(app.records.first.cached, true);
        config.models.add(
          const ModelConfig(
            id: 'c',
            name: 'C',
            model: 'c',
            providerId: 'local',
            protocol: ApiProtocol.chat,
          ),
        );
        config.activeModelId = 'c';
        await post(config.token, question.toJson());
        expect(calls, 2);
        expect(requests.last, contains('messages'));
        final wrappers = ocsWrappers(bridge.port, config.token);
        expect(wrappers.first['headers']['X-OCS-Token'], config.token);
        expect(jsonEncode(wrappers), isNot(contains('test-secret')));

        const vision = ModelConfig(
          id: 'visual',
          name: 'Vision & Python',
          model: 'vision-python',
          providerId: 'local',
          vision: true,
          calculation: CalculationMode.hostedPython,
        );
        config.models.add(ModelConfig.fromJson(vision.toJson()));
        config.activeModelId = vision.id;
        const pictured = Question(
          title: '计算 [图片1] 的结果',
          options: 'A. [图片2]\nB. [图片3]',
          type: 'single',
          images: [
            'data:image/png;base64,AA==',
            'data:image/png;base64,AQ==',
            'data:image/png;base64,Ag==',
          ],
        );
        final visualResult = await post(config.token, pictured.toJson());
        expect(visualResult.$1, 200);
        expect(visualResult.$2['answer'], '[图片3]');
        expect(visualResult.$2['pythonCalls'], 1);
        expect(requests.last['tools'], [
          {
            'type': 'code_interpreter',
            'container': {'type': 'auto'},
          },
        ]);
        final parts =
            (requests.last['input'] as List).single['content'] as List;
        expect(
          jsonDecode(parts.first['text'] as String)['选项'],
          pictured.options,
        );
        expect(parts.skip(1).map((part) => part['image_url']), pictured.images);
        final forcedSearch = buildRequest(
          vision,
          provider,
          pictured,
          requireHostedSearch: true,
        );
        expect(forcedSearch['tool_choice'], {'type': 'web_search'});
        expect(forcedSearch['tools'], hasLength(2));
      },
    );
  });
}
