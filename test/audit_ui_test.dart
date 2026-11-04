import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocs_bridge/app_controller.dart';
import 'package:ocs_bridge/domain/answer.dart';
import 'package:ocs_bridge/domain/config.dart';
import 'package:ocs_bridge/main.dart';
import 'package:ocs_bridge/services/app_log.dart';
import 'package:ocs_bridge/services/config_store.dart';
import 'package:ocs_bridge/services/export_service.dart';
import 'package:ocs_bridge/services/interaction_audit.dart';
import 'protocol_test.dart' show MemorySecrets;

class MemoryAuditLog extends AppLog {
  final List<Map<String, dynamic>> events = [];
  @override
  void write(
    String channel,
    String event,
    Map<String, dynamic> data, {
    String level = 'debug',
  }) {
    events.add({
      'channel': channel,
      'event': event,
      'data': jsonDecode(jsonEncode(data)),
    });
  }
}

class NoDiskConfig extends ConfigStore {
  NoDiskConfig() : super(Directory.systemTemp);
  @override
  Future<void> save(AppConfig config) async {}
}

void main() {
  testWidgets(
    'pointer, keyboard, password, IME and navigation inputs are captured verbatim',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final log = MemoryAuditLog();
      final app = AppController(
        config: AppConfig.initial(),
        store: NoDiskConfig(),
        secrets: MemorySecrets(),
        log: log,
      );
      final audit = InteractionAudit(log)..start();
      await tester.pumpWidget(BridgeApp(app: app));
      await tester.pumpAndSettle();
      await tester.tap(find.text('供应商').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加供应商'));
      await tester.pumpAndSettle();
      final keyField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'API Key',
      );
      await tester.tap(keyField);
      await tester.pumpAndSettle();
      await tester.enterText(keyField, 'password-original-unredacted');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '中文机密输入',
          selection: TextSelection.collapsed(offset: 6),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('显示密钥'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      final text = log.events
          .where((e) => e['event'] == 'input.text')
          .map((e) => e['data'] as Map)
          .toList();
      expect(
        text.any((e) => e['text'] == 'password-original-unredacted'),
        true,
      );
      expect(
        text.any(
          (e) => e['text'] == '中文机密输入' && (e['composing'] as Map)['end'] == 2,
        ),
        true,
      );
      expect(text.any((e) => e['field'] == 'API Key'), true);
      expect(log.events.any((e) => e['event'] == 'input.pointer'), true);
      expect(
        log.events
            .where((e) => e['event'] == 'input.pointer')
            .any((e) => jsonEncode(e).contains('添加供应商')),
        true,
      );
      expect(log.events.any((e) => e['event'] == 'input.key'), true);
      expect(log.events.any((e) => e['event'] == 'ui.navigation'), true);
      expect(tester.takeException(), isNull);
      audit.dispose();
      app.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'history exports all or single records through the shared format dialog',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <Map>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        AnswerExporter.channel,
        (call) async {
          calls.add(call.arguments as Map);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          AnswerExporter.channel,
          null,
        ),
      );
      final log = MemoryAuditLog();
      final app = AppController(
        config: AppConfig.initial(),
        store: NoDiskConfig(),
        secrets: MemorySecrets(),
        log: log,
      );
      app.records.add(
        RequestRecord(
          id: 'ok',
          question: const Question(title: '可导出题目'),
          model: 'M',
          time: DateTime.now(),
          duration: Duration.zero,
          result: const AnswerResult(answers: ['答案原文'], explanation: '解析'),
        ),
      );
      app.records.add(
        RequestRecord(
          id: 'bad',
          question: const Question(title: '失败题目'),
          model: 'M',
          time: DateTime.now(),
          duration: Duration.zero,
          error: '错误',
        ),
      );
      await tester.pumpWidget(BridgeApp(app: app));
      await tester.pumpAndSettle();
      await tester.tap(find.text('请求记录').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('可导出题目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出').last);
      await tester.pumpAndSettle();
      expect(find.text('1 条记录'), findsOneWidget);
      await tester.tap(find.text('JSON'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CSV').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出').last);
      await tester.pumpAndSettle();
      expect(calls.single['extension'], 'csv');
      await tester.tap(find.byTooltip('关闭').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出'));
      await tester.pumpAndSettle();
      expect(find.text('2 条记录'), findsNWidgets(2));
      await tester.tap(find.text('仅成功答案'));
      await tester.pumpAndSettle();
      expect(find.text('1 条记录'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      app.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
