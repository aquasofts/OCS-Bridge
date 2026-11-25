import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocs_bridge/app_controller.dart';
import 'package:ocs_bridge/domain/config.dart';
import 'package:ocs_bridge/main.dart';
import 'package:ocs_bridge/services/config_store.dart';
import 'protocol_test.dart' show MemorySecrets;

class MemoryConfigStore extends ConfigStore {
  MemoryConfigStore() : super(Directory.systemTemp);
  @override
  Future<void> save(AppConfig config) async {}
}

void main() {
  late AppController app;
  setUp(() {
    app = AppController(
      config: AppConfig.initial(),
      store: MemoryConfigStore(),
      secrets: MemorySecrets(),
    );
  });
  tearDown(() => app.dispose());
  testWidgets('settings offers a guess switch defaulting off', (tester) async {
    tester.view.physicalSize = const Size(1180, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(BridgeApp(app: app));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    final agent = find.widgetWithText(SwitchListTile, 'Agent 模式');
    final guess = find.widgetWithText(SwitchListTile, '猜测模式');
    expect(tester.widget<SwitchListTile>(agent).value, true);
    expect(tester.widget<SwitchListTile>(guess).value, true);
    await tester.ensureVisible(agent);
    await tester.tap(agent);
    await tester.pumpAndSettle();
    await tester.ensureVisible(guess);
    await tester.tap(guess);
    await tester.pumpAndSettle();
    expect(app.config.agentMode, false);
    expect(app.config.allowGuess, false);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'first-run provider and model can be saved through their dialogs',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      await tester.pumpWidget(BridgeApp(app: app));
      await tester.pumpAndSettle();
      await tester.tap(find.text('供应商').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加供应商'));
      await tester.pumpAndSettle();
      await tester.enterText(field('名称'), 'My Provider');
      await tester.enterText(field('Base URL'), 'https://example.com/v1');
      await tester.enterText(field('API Key'), 'test-placeholder');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(app.config.providers.length, 3);
      expect(find.text('My Provider'), findsOneWidget);
      expect(find.text('保存'), findsNothing);
      await tester.tap(find.text('模型').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加模型'));
      await tester.pumpAndSettle();
      await tester.enterText(field('名称'), 'First Model');
      await tester.enterText(field('模型 ID'), 'test-model');
      final calculation = find.byType(DropdownButtonFormField<CalculationMode>);
      await tester.ensureVisible(calculation);
      await tester.tap(calculation);
      await tester.pumpAndSettle();
      await tester.tap(find.text('本机 Python 3').last);
      await tester.pumpAndSettle();
      expect(find.text('使用发行包自带的 Python，无需安装'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(app.config.models.single.model, 'test-model');
      expect(app.config.models.single.calculation, CalculationMode.localPython);
      expect(app.config.activeModelId, app.config.models.single.id);
      expect(find.text('First Model'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('all pages and the shared model dialog render at desktop width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1180, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(BridgeApp(app: app));
    await tester.pumpAndSettle();
    expect(find.text('答题服务'), findsOneWidget);
    for (final label in ['供应商', '模型', '答题调试', 'OCS 接入', '请求记录', '设置']) {
      await tester.tap(find.text(label).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: label);
    }
    await tester.tap(find.text('模型').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加模型'));
    await tester.pumpAndSettle();
    expect(find.text('模型 ID'), findsOneWidget);
    expect(find.text('联网搜索'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请填写模型名称和 ID'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'compact layout, provider dialog and dark theme have no overflow',
    (tester) async {
      tester.view.physicalSize = const Size(900, 660);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(BridgeApp(app: app));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('供应商'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加供应商'));
      await tester.pumpAndSettle();
      expect(find.text('API Key'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('切换主题'));
      await tester.pumpAndSettle();
      expect(app.config.darkMode, true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
