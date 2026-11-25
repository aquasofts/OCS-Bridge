import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocs_bridge/app_controller.dart';
import 'package:ocs_bridge/domain/answer.dart';
import 'package:ocs_bridge/domain/config.dart';
import 'package:ocs_bridge/services/app_log.dart';
import 'package:ocs_bridge/services/config_store.dart';
import 'package:ocs_bridge/services/export_service.dart';
import 'package:ocs_bridge/services/model_gateway.dart';
import 'protocol_test.dart' show MemorySecrets;

class FixedGateway extends ModelGateway {
  @override
  Future<AnswerResult> answer(
    ModelConfig m,
    ProviderConfig p,
    String key,
    Question q, {
    bool allowGuess = false,
    bool agentMode = false,
  }) async => const AnswerResult(
    answers: ['原文，"答案"\n第二行'],
    explanation: '解析原文',
    inputTokens: 8,
    outputTokens: 5,
    searchCalls: 1,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ocs-journal-');
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test(
    'journal keeps unredacted snapshots, bytes, order and full stack traces',
    () async {
      final log = AppLog();
      await log.initialize(Directory('${temp.path}/logs'));
      final payload = {'key': 'unredacted-test-key', 'text': '原始输入'};
      log.write('interaction', 'input.text', payload);
      payload['text'] = 'later edit';
      for (var i = 0; i < 120; i++) {
        log.write('runtime', 'sequence', {'i': i});
      }
      log.error(
        'test.error',
        StateError('raw-secret-error'),
        StackTrace.fromString('full-stack-original'),
      );
      final binary = [0, 255, 128, 10, 34];
      log.write('network', 'bytes', {'body': logBytes(binary)});
      await log.flush();
      final input = (await log.read('interaction')).single;
      expect(input['data'], {'key': 'unredacted-test-key', 'text': '原始输入'});
      final runtime = await log.read('runtime');
      expect(
        runtime
            .where((e) => e['event'] == 'sequence')
            .map((e) => (e['data'] as Map)['i']),
        List.generate(120, (i) => i),
      );
      expect((runtime.last['data'] as Map)['stack'], 'full-stack-original');
      expect(
        (runtime.last['data'] as Map)['error'],
        contains('raw-secret-error'),
      );
      final data = (await log.read('network')).single['data'] as Map;
      expect(base64Decode((data['body'] as Map)['base64'] as String), binary);
      await log.close();
    },
  );

  test(
    'retention prunes whole old files and only expired boundary entries',
    () async {
      var now = DateTime.utc(2026, 11, 4, 12, 0, 10);
      final log = AppLog(clock: () => now);
      final logs = Directory('${temp.path}/logs');
      await log.initialize(logs);
      log.write('runtime', 'expired', {'text': 'expired-sensitive-data'});
      await log.flush();
      now = now.add(const Duration(seconds: 20));
      log.write('runtime', 'survivor', {'text': 'recent-sensitive-data'});
      await log.flush();
      final native = File('${logs.path}/native-old-123.log');
      await native.writeAsString('native old bytes');
      await native.setLastModified(now.subtract(const Duration(hours: 25)));
      now = DateTime.utc(2026, 11, 5, 12, 0, 20);
      await log.prune();
      expect((await log.read('runtime')).map((e) => e['event']), ['survivor']);
      expect(await native.exists(), false);
      final remainingText = await logs
          .list()
          .where((f) => f is File)
          .cast<File>()
          .asyncMap((f) => f.readAsString())
          .join();
      expect(remainingText, isNot(contains('expired-sensitive-data')));
      now = now.add(const Duration(minutes: 2));
      await log.prune();
      expect(await log.read('runtime'), isEmpty);
      await log.close();
    },
  );

  test(
    'failed writes stay queued and can be flushed after storage recovers',
    () async {
      final blocked = File('${temp.path}/blocked');
      await blocked.writeAsString('not a directory');
      final log = AppLog();
      await expectLater(
        log.initialize(Directory(blocked.path)),
        throwsA(isA<FileSystemException>()),
      );
      log.write('runtime', 'kept', {'text': 'recover-original-value'});
      await expectLater(log.flush(), throwsA(isA<FileSystemException>()));
      expect(log.lastError, isNotNull);
      await blocked.delete();
      await Directory(blocked.path).create();
      await log.flush();
      expect(log.lastError, isNull);
      expect(
        ((await log.read('runtime')).single['data'] as Map)['text'],
        'recover-original-value',
      );
      await log.close();
    },
  );

  test(
    'all records survive restart beyond 200 and clearing preserves audit trail',
    () async {
      final directory = Directory('${temp.path}/logs');
      final log = AppLog();
      await log.initialize(directory);
      final secrets = MemorySecrets();
      await secrets.write('openai', 'test-placeholder');
      final config = AppConfig.initial()..cacheEnabled = false;
      config.models.add(
        const ModelConfig(
          id: 'm',
          name: 'M',
          model: 'test-model',
          providerId: 'openai',
        ),
      );
      config.activeModelId = 'm';
      final app = AppController(
        config: config,
        store: ConfigStore(Directory('${temp.path}/config')),
        secrets: secrets,
        gateway: FixedGateway(),
        log: log,
      );
      for (var i = 0; i < 205; i++) {
        await app.answer(Question(title: '题目 $i', type: 'completion'));
      }
      expect(app.records.length, 205);
      await log.flush();
      final restored = AppController(
        config: config,
        store: ConfigStore(Directory('${temp.path}/restored')),
        secrets: secrets,
        gateway: FixedGateway(),
        log: log,
      );
      await restored.restoreRecords();
      expect(restored.records.length, 205);
      expect(restored.records.first.question.title, '题目 204');
      expect(restored.records.first.result!.explanation, '解析原文');
      expect(restored.records.first.modelSettings['model'], 'test-model');
      restored.clearRecords();
      await restored.answer(const Question(title: '清空后', type: 'completion'));
      final events = await log.read('answers');
      expect(events.where((e) => e['event'] == 'answer.record').length, 206);
      final again = AppController(
        config: config,
        store: ConfigStore(Directory('${temp.path}/again')),
        secrets: secrets,
        log: log,
      );
      await again.restoreRecords();
      expect(again.records.single.question.title, '清空后');
      again.dispose();
      restored.dispose();
      app.dispose();
      await log.close();
    },
  );

  RequestRecord sample() => RequestRecord(
    id: 'record-1',
    question: const Question(
      title: '题目，"引号"\n第二行',
      options: '甲\n乙',
      type: 'single',
    ),
    model: '模型原文',
    time: DateTime.utc(2026, 11, 4),
    duration: const Duration(milliseconds: 456),
    modelSettings: const {'model': 'model-id'},
    providerSettings: const {'name': '供应商'},
    result: const AnswerResult(
      answers: ['甲，"引号"\n换行'],
      explanation: '解释原文',
      sources: ['https://example.com'],
      inputTokens: 11,
      outputTokens: 22,
      searchCalls: 1,
      pageReads: 2,
    ),
  );

  test(
    'JSON exports complete records including errors, images, settings and usage',
    () {
      final r = sample();
      final failed = RequestRecord(
        id: 'failed',
        question: const Question(
          title: '图片题',
          images: ['data:image/png;base64,AA=='],
        ),
        model: 'M',
        time: DateTime.now(),
        duration: Duration.zero,
        error: '原始错误',
        errorStack: 'original-stack',
      );
      final data =
          jsonDecode(renderAnswers([r, failed], AnswerExportFormat.json))
              as Map;
      expect(data['count'], 2);
      final rows = data['records'] as List;
      expect(rows.first, r.toJson());
      expect((rows.last as Map)['errorStack'], 'original-stack');
      expect(((rows.last as Map)['question'] as Map)['images'], [
        'data:image/png;base64,AA==',
      ]);
    },
  );

  test(
    'CSV preserves Unicode, quotes and multiline values with an Excel BOM',
    () {
      final csv = renderAnswers([sample()], AnswerExportFormat.csv);
      expect(csv.startsWith('\uFEFF'), true);
      expect(csv, contains('"题目，""引号""\n第二行"'));
      expect(csv, contains('"甲，""引号""\n换行"'));
      expect(csv, contains('"解释原文"'));
      expect(csv.endsWith('\r\n'), true);
    },
  );

  test('TXT and Markdown exports include answers, explanation and sources', () {
    for (final f in [AnswerExportFormat.txt, AnswerExportFormat.markdown]) {
      final text = renderAnswers([sample()], f);
      expect(text, contains('答案：甲，"引号"\n换行'));
      expect(text, contains('解析：解释原文'));
      expect(text, contains('https://example.com'));
    }
  });

  test(
    'export writes an atomic UTF-8 file and logs its full original contents',
    () async {
      final log = AppLog();
      await log.initialize(Directory('${temp.path}/logs'));
      final path = '${temp.path}/answers.json';
      await File(path).writeAsString('previous file');
      final exporter = AnswerExporter(log: log);
      await exporter.write(path, [sample()], AnswerExportFormat.json);
      final file = jsonDecode(await File(path).readAsString()) as Map;
      expect(file['count'], 1);
      expect(
        await temp.list().where((e) => e.path.endsWith('.tmp')).isEmpty,
        true,
      );
      final events = await log.read('runtime');
      final write = events.firstWhere(
        (e) => e['event'] == 'export.write.start',
      );
      expect(
        (((write['data'] as Map)['body'] as Map)['utf8'] as String),
        contains('解释原文'),
      );
      await log.close();
    },
  );
  test(
    'native save selection writes the chosen format to the returned path',
    () async {
      final binding = TestDefaultBinaryMessengerBinding.instance;
      final path = '${temp.path}/selected.csv';
      Map? selection;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        AnswerExporter.channel,
        (call) async {
          selection = call.arguments as Map;
          return path;
        },
      );
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          AnswerExporter.channel,
          null,
        ),
      );
      expect(
        await AnswerExporter().save([sample()], AnswerExportFormat.csv),
        path,
      );
      expect(selection!['extension'], 'csv');
      expect((await File(path).readAsBytes()).take(3), [0xEF, 0xBB, 0xBF]);
    },
  );
}
