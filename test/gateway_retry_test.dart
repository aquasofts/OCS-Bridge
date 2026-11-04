import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocs_bridge/domain/answer.dart';
import 'package:ocs_bridge/domain/config.dart';
import 'package:ocs_bridge/services/model_gateway.dart';

// Inject transport failures while successful attempts use a real local server.
class FaultClient extends Fake implements HttpClient {
  FaultClient(this.inner, this.openRequest);
  final HttpClient inner;
  final Future<HttpClientRequest> Function(String, Uri) openRequest;
  bool closed = false;

  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      openRequest(method, url);

  @override
  void close({bool force = false}) {
    closed = true;
    inner.close(force: force);
  }
}

class FaultOverrides extends HttpOverrides {
  FaultOverrides(this.wrap);
  final HttpClient Function(HttpClient) wrap;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      wrap(super.createHttpClient(context));
}

void main() {
  late HttpServer server;
  late ProviderConfig provider;
  late ModelGateway gateway;
  late List<FaultClient> clients;
  var attempts = 0;
  var received = 0;
  var status = 200;
  var responseBody = '{"data":[{"id":"reconnected"}]}';
  Object? Function(int)? fault;
  Completer<void>? opened;
  Completer<void>? receivedSignal;
  Completer<void>? holdResponse;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider = ProviderConfig(
      id: 'local',
      name: 'Local',
      baseUrl: 'http://127.0.0.1:${server.port}',
    );
    gateway = ModelGateway();
    clients = [];
    attempts = received = 0;
    status = 200;
    responseBody = '{"data":[{"id":"reconnected"}]}';
    fault = null;
    opened = receivedSignal = holdResponse = null;
    server.listen((request) async {
      received++;
      await request.drain<void>();
      if (receivedSignal != null && !receivedSignal!.isCompleted) {
        receivedSignal!.complete();
      }
      await holdResponse?.future;
      request.response.statusCode = status;
      request.response.write(responseBody);
      await request.response.close();
    });
  });

  tearDown(() async {
    gateway.cancelAll();
    if (holdResponse != null && !holdResponse!.isCompleted) {
      holdResponse!.complete();
    }
    await server.close(force: true);
  });

  Future<void> withTransport(Future<void> Function() action) async {
    await HttpOverrides.runWithHttpOverrides(
      action,
      FaultOverrides((inner) {
        final client = FaultClient(inner, (method, uri) async {
          attempts++;
          final error = fault?.call(attempts);
          if (opened != null && !opened!.isCompleted) opened!.complete();
          if (error != null) throw error;
          return inner.openUrl(method, uri);
        });
        clients.add(client);
        return client;
      }),
    );
  }

  for (final error in <Object>[
    const HandshakeException('temporary TLS failure'),
    const SocketException('connection reset'),
    const HttpException('connection closed'),
  ]) {
    test('${error.runtimeType} reconnects with a fresh client', () async {
      fault = (attempt) => attempt == 1 ? error : null;
      await withTransport(() async {
        expect(await gateway.listModels(provider, 'placeholder'), [
          'reconnected',
        ]);
      });
      expect(attempts, 2);
      expect(received, 1);
      expect(clients, hasLength(2));
      expect(clients.every((client) => client.closed), isTrue);
    });
  }

  test('persistent TLS failure stops after three reconnections', () async {
    fault = (_) => const HandshakeException('persistent TLS failure');
    await withTransport(() async {
      await expectLater(
        gateway.listModels(provider, 'placeholder'),
        throwsA(
          isA<GatewayException>().having(
            (error) => error.message,
            'message',
            'TLS 连接失败（自动重连 3 次后仍失败）',
          ),
        ),
      );
    });
    expect(attempts, 4);
    expect(clients.every((client) => client.closed), isTrue);
  });

  test(
    'cancel during backoff stops retries and allows later requests',
    () async {
      opened = Completer<void>();
      fault = (_) => const HandshakeException('temporary TLS failure');
      await withTransport(() async {
        final pending = gateway.listModels(provider, 'placeholder');
        final check = expectLater(
          pending,
          throwsA(
            isA<GatewayException>().having(
              (error) => error.message,
              'message',
              '请求已取消',
            ),
          ),
        );
        await opened!.future;
        await Future<void>.delayed(Duration.zero);
        gateway.cancelAll();
        await check.timeout(const Duration(milliseconds: 500));
        expect(attempts, 1);
        fault = null;
        expect(await gateway.listModels(provider, 'placeholder'), [
          'reconnected',
        ]);
        expect(attempts, 2);
      });
    },
  );

  test('cancel during an active connection does not reconnect', () async {
    receivedSignal = Completer<void>();
    holdResponse = Completer<void>();
    await withTransport(() async {
      final check = expectLater(
        gateway.listModels(provider, 'placeholder'),
        throwsA(
          isA<GatewayException>().having(
            (error) => error.message,
            'message',
            '请求已取消',
          ),
        ),
      );
      await receivedSignal!.future;
      gateway.cancelAll();
      await check.timeout(const Duration(seconds: 1));
      expect(attempts, 1);
    });
  });

  test('reconnections share the model timeout budget', () async {
    fault = (attempt) =>
        attempt <= 2 ? const HandshakeException('temporary TLS failure') : null;
    holdResponse = Completer<void>();
    final watch = Stopwatch()..start();
    await withTransport(() async {
      await expectLater(
        gateway.answer(
          const ModelConfig(
            id: 'model',
            name: 'Model',
            model: 'model',
            providerId: 'local',
            timeoutSeconds: 5,
          ),
          provider,
          'placeholder',
          const Question(title: 'test'),
        ),
        throwsA(
          isA<GatewayException>().having(
            (error) => error.message,
            'message',
            '请求超时',
          ),
        ),
      );
    });
    expect(attempts, 3);
    expect(watch.elapsed, lessThan(const Duration(seconds: 7)));
    expect(clients.every((client) => client.closed), isTrue);
  });

  test('authentication and malformed responses are not retried', () async {
    await withTransport(() async {
      status = 401;
      await expectLater(
        gateway.listModels(provider, 'placeholder'),
        throwsA(isA<GatewayException>()),
      );
      expect(attempts, 1);
      status = 200;
      responseBody = 'invalid JSON';
      await expectLater(
        gateway.listModels(provider, 'placeholder'),
        throwsA(isA<GatewayException>()),
      );
      expect(attempts, 2);
    });
  });
}
