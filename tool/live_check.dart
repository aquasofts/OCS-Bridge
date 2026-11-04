import 'dart:convert';
import 'dart:io';

import 'package:ocs_bridge/domain/answer.dart';
import 'package:ocs_bridge/domain/config.dart';
import 'package:ocs_bridge/services/bridge_server.dart';
import 'package:ocs_bridge/services/model_gateway.dart';

// Opt-in live verification. Credentials are accepted only through the process
// environment and are never printed or written to a file.
Future<void> main() async {
  final env = Platform.environment;
  final key = env['OCS_TEST_API_KEY'] ?? '';
  final base = env['OCS_TEST_BASE_URL'] ?? '';
  final modelId = env['OCS_TEST_MODEL'] ?? '';
  if (key.isEmpty || base.isEmpty || modelId.isEmpty) {
    stderr.writeln('Set OCS_TEST_API_KEY, OCS_TEST_BASE_URL, OCS_TEST_MODEL.');
    exitCode = 64;
    return;
  }
  final gateway = ModelGateway();
  final provider = ProviderConfig(
    id: 'live',
    name: 'Live',
    baseUrl: base,
    kind: ProviderKind.values.byName(
      env['OCS_TEST_PROVIDER_KIND'] ?? 'compatible',
    ),
  );
  final mode = env['OCS_TEST_MODE'] ?? 'responses';
  final model = ModelConfig(
    id: 'live',
    name: modelId,
    model: modelId,
    providerId: provider.id,
    protocol: mode == 'chat' ? ApiProtocol.chat : ApiProtocol.responses,
    search: mode == 'search' ? SearchMode.required : SearchMode.off,
    effort: env['OCS_TEST_EFFORT'] ?? 'low',
    thinking: env['OCS_TEST_THINKING'] ?? 'default',
    maxTokens: 2048,
    timeoutSeconds: 120,
  );
  final server = BridgeServer();
  final client = HttpClient();
  final token = newToken();
  final watch = Stopwatch()..start();
  try {
    validateProvider(provider);
    final models = await gateway.listModels(provider, key);
    if (!models.contains(modelId)) {
      throw const GatewayException('Requested model absent from model list');
    }
    AnswerResult? result;
    Object? answerError;
    await server.start(
      port: 0,
      token: token,
      answer: (question) async {
        try {
          result = await gateway.answer(model, provider, key, question);
          return result!;
        } catch (error) {
          answerError = error;
          rethrow;
        }
      },
    );
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${server.port}/answer'),
    );
    request.headers.contentType = ContentType.json;
    request.headers.set('X-OCS-Token', token);
    request.write(
      jsonEncode({
        'title': mode == 'search'
            ? '请联网查看 Flutter 官方文档，Flutter 是由哪家公司发起的？'
            : '1 + 1 = ？',
        'options': mode == 'search'
            ? 'A. Google\nB. Apple'
            : 'A. 1\nB. 2\nC. 3',
        'type': 'single',
      }),
    );
    final response = await request.close();
    final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
    if (response.statusCode != 200 || body['code'] != 0 || result == null) {
      if (answerError is GatewayException) {
        throw answerError!;
      }
      throw const GatewayException('Bridge did not return an answer');
    }
    final expected = mode == 'search' ? 'Google' : '2';
    if (body['answer'] != expected) {
      throw const GatewayException('Unexpected answer');
    }
    if (mode == 'search' && result!.searchCalls + result!.pageReads < 1) {
      throw const GatewayException(
        'Provider did not confirm a completed search',
      );
    }
    stdout.writeln(
      jsonEncode({
        'mode': mode,
        'effort': model.effort,
        'model': modelId,
        'status': 'passed',
        'answer': body['answer'],
        'sources': result!.sources.length,
        'searchCalls': result!.searchCalls,
        'pageReads': result!.pageReads,
        'inputTokens': result!.inputTokens,
        'outputTokens': result!.outputTokens,
        'elapsedMs': watch.elapsedMilliseconds,
      }),
    );
  } catch (error) {
    // GatewayException contains only app-authored errors, never upstream bodies.
    stdout.writeln(
      jsonEncode({
        'mode': mode,
        'effort': model.effort,
        'status': 'failed',
        'error': error is GatewayException
            ? error.message
            : 'Live check failed',
        'elapsedMs': watch.elapsedMilliseconds,
      }),
    );
    exitCode = 1;
  } finally {
    client.close(force: true);
    await server.stop();
    gateway.cancelAll();
  }
}
