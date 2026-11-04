import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocs_bridge/app_controller.dart';
import 'package:ocs_bridge/domain/config.dart';
import 'package:ocs_bridge/domain/answer.dart';
import 'package:ocs_bridge/services/app_log.dart';
import 'package:ocs_bridge/services/config_store.dart';
import 'package:ocs_bridge/services/model_gateway.dart';
import 'protocol_test.dart' show MemorySecrets;

void main() {
  test(
    'all application HTTP headers, bodies, chunks and errors are logged without redaction',
    () async {
      final temp = await Directory.systemTemp.createTemp('ocs-network-log-');
      final log = AppLog();
      await log.initialize(Directory('${temp.path}/logs'));
      final vendor = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      const key = 'unredacted-network-test-key';
      final explanation = List.filled(8000, '完整原文').join();
      final responseText = jsonEncode({
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {
              'content': jsonEncode({
                'answers': ['B'],
                'explanation': explanation,
              }),
            },
          },
        ],
        'usage': {'prompt_tokens': 7, 'completion_tokens': 9},
      });
      vendor.listen((req) async {
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        req.response.headers.contentType = ContentType.json;
        req.response.headers.set('X-Raw-Header', 'original-header-value');
        if (body['model'] == 'denied') {
          req.response.statusCode = 401;
          req.response.write(
            jsonEncode({'error': '$key original vendor error'}),
          );
        } else {
          final bytes = utf8.encode(responseText);
          req.response.add(bytes.sublist(0, 10001));
          await req.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 3));
          req.response.add(bytes.sublist(10001));
        }
        await req.response.close();
      });
      final provider = ProviderConfig(
        id: 'local',
        name: 'Local',
        baseUrl: 'http://127.0.0.1:${vendor.port}',
      );
      const model = ModelConfig(
        id: 'm',
        name: 'M',
        model: 'test',
        providerId: 'local',
        protocol: ApiProtocol.chat,
      );
      final config = AppConfig(
        providers: [provider],
        models: [model],
        activeModelId: 'm',
        token: newToken(),
      );
      final secrets = AuditedSecrets(MemorySecrets(), log);
      await secrets.write('local', key);
      final app = AppController(
        config: config,
        store: ConfigStore(Directory('${temp.path}/config')),
        secrets: secrets,
        log: log,
      );
      await app.server.start(port: 0, token: config.token, answer: app.answer);
      final client = HttpClient();
      try {
        Future<HttpClientResponse> request(String token, String body) async {
          final req = await client.postUrl(
            Uri.parse('http://127.0.0.1:${app.server.port}/answer'),
          );
          req.headers.contentType = ContentType.json;
          req.headers.set('X-OCS-Token', token);
          req.write(body);
          return req.close();
        }

        final question = jsonEncode({
          'title': '1 + 1 = ?',
          'options': 'A. 1\nB. 2',
          'type': 'single',
        });
        final response = await request(config.token, question);
        final result =
            jsonDecode(await utf8.decoder.bind(response).join()) as Map;
        expect(result['answer'], '2');
        expect(result['explanation'], explanation);
        final denied = await request(
          'bad-token-unredacted',
          'unauthorized-original-body',
        );
        expect(denied.statusCode, 401);
        await denied.drain<void>();
        await expectLater(
          app.gateway.answer(
            const ModelConfig(
              id: 'bad',
              name: 'Bad',
              model: 'denied',
              providerId: 'local',
              protocol: ApiProtocol.chat,
            ),
            provider,
            key,
            const Question(title: 'bad'),
          ),
          throwsA(isA<GatewayException>()),
        );
        await log.flush();
        final network = await log.read('network');
        final start = network.firstWhere(
          (e) => e['event'] == 'upstream.request.start',
        );
        expect(((start['data'] as Map)['headers'] as Map)['Authorization'], [
          'Bearer $key',
        ]);
        final complete = network.firstWhere(
          (e) => e['event'] == 'upstream.response.complete',
        );
        expect(
          ((complete['data'] as Map)['body'] as Map)['utf8'],
          responseText,
        );
        final upstreamId = (complete['data'] as Map)['requestId'];
        final chunks = network
            .where(
              (e) =>
                  e['event'] == 'upstream.response.chunk' &&
                  (e['data'] as Map)['requestId'] == upstreamId,
            )
            .toList();
        expect(chunks.length, greaterThan(1));
        final bytes = chunks
            .expand(
              (e) => base64Decode(
                (((e['data'] as Map)['body'] as Map)['base64']) as String,
              ),
            )
            .toList();
        expect(utf8.decode(bytes), responseText);
        expect(
          network
              .where((e) => e['event'] == 'local.request.complete')
              .any(
                (e) =>
                    ((e['data'] as Map)['body'] as Map)['utf8'] ==
                    'unauthorized-original-body',
              ),
          true,
        );
        expect(
          network
              .where((e) => e['event'] == 'upstream.response.complete')
              .any(
                (e) => (((e['data'] as Map)['body'] as Map)['utf8'] as String)
                    .contains('$key original vendor error'),
              ),
          true,
        );
        expect(start['traceId'], app.records.single.id);
        expect(
          network
              .where((e) => e['event'] == 'local.request.headers')
              .first['traceId'],
          start['traceId'],
        );
        final runtime = await log.read('runtime');
        expect(
          runtime.any(
            (e) =>
                e['event'] == 'gateway.error' &&
                ((e['data'] as Map)['stack'] as String).isNotEmpty,
          ),
          true,
        );
        expect(
          runtime.any(
            (e) =>
                e['event'] == 'vault.read.complete' &&
                (e['data'] as Map)['value'] == key,
          ),
          true,
        );
      } finally {
        client.close(force: true);
        await app.shutdown();
        app.dispose();
        await vendor.close(force: true);
        await log.close();
        await temp.delete(recursive: true);
      }
    },
  );
}
