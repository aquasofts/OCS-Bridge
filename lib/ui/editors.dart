import 'dart:convert';
import 'package:flutter/material.dart';
import '../app_controller.dart';
import '../domain/config.dart';
import 'components.dart';

Future<void> editProvider(
  BuildContext context,
  AppController app, [
  ProviderConfig? original,
]) async {
  app.audit('ui.provider.dialog.open', {'provider': original?.toJson()});
  String key;
  try {
    key = original == null ? '' : await app.secrets.read(original.id) ?? '';
  } catch (error, stack) {
    app.log?.error('ui.provider.read.error', error, stack);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法读取安全存储')));
    }
    return;
  }
  if (!context.mounted) {
    return;
  }
  final name = TextEditingController(text: original?.name ?? '');
  final url = TextEditingController(
    text: original?.baseUrl ?? 'https://api.openai.com/v1',
  );
  final secret = TextEditingController(text: key);
  var kind = original?.kind ?? ProviderKind.compatible;
  var responses = original?.supportsResponses ?? true;
  var visible = false, busy = false;
  String? error;
  final id = original?.id ?? newId();
  ProviderConfig value() => ProviderConfig(
    id: id,
    name: name.text.trim(),
    baseUrl: url.text.trim().replaceAll(RegExp(r'/+$'), ''),
    kind: kind,
    supportsResponses: responses,
  );
  await appDialog<void>(
    context,
    (ctx) => StatefulBuilder(
      builder: (ctx, set) => DialogFrame(
        title: original == null ? '添加供应商' : '供应商设置',
        busy: busy,
        error: error,
        actions: [
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    set(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      final p = value();
                      validateProvider(p);
                      final models = await app.fetchModels(
                        p,
                        key: secret.text.trim(),
                      );
                      if (ctx.mounted) {
                        set(() => error = '已连接 · ${models.length} 个模型');
                      }
                    } catch (e, stack) {
                      app.log?.error('ui.provider.test.error', e, stack);
                      if (ctx.mounted) {
                        set(() => error = errorLabel(e));
                      }
                    } finally {
                      if (ctx.mounted) {
                        set(() => busy = false);
                      }
                    }
                  },
            child: const Text('测试连接'),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    set(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      await app.saveProvider(value(), secret.text);
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                      }
                    } catch (e, stack) {
                      app.log?.error('ui.provider.save.error', e, stack);
                      if (ctx.mounted) {
                        set(() {
                          error = errorLabel(e);
                          busy = false;
                        });
                      }
                    }
                  },
            child: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
        child: FieldColumn(
          children: [
            DropdownButtonFormField<ProviderKind>(
              initialValue: kind,
              decoration: const InputDecoration(labelText: '类型'),
              items: ProviderKind.values
                  .map(
                    (k) => DropdownMenuItem(
                      value: k,
                      child: Text(switch (k) {
                        ProviderKind.openai => 'OpenAI',
                        ProviderKind.deepseek => 'DeepSeek',
                        _ => 'OpenAI 兼容',
                      }),
                    ),
                  )
                  .toList(),
              onChanged: busy
                  ? null
                  : (v) {
                      if (v == null) {
                        return;
                      }
                      set(() {
                        kind = v;
                        if (v == ProviderKind.openai) {
                          name.text = 'OpenAI';
                          url.text = 'https://api.openai.com/v1';
                        } else if (v == ProviderKind.deepseek) {
                          name.text = 'DeepSeek';
                          url.text = 'https://api.deepseek.com';
                        }
                      });
                    },
            ),
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            TextField(
              controller: url,
              decoration: const InputDecoration(labelText: 'Base URL'),
              keyboardType: TextInputType.url,
            ),
            TextField(
              controller: secret,
              obscureText: !visible,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'API Key',
                suffixIcon: IconButton(
                  tooltip: '显示密钥',
                  onPressed: () => set(() => visible = !visible),
                  icon: Icon(
                    visible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 20,
                  ),
                ),
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Responses'),
              value: responses,
              onChanged: busy ? null : (v) => set(() => responses = v),
            ),
          ],
        ),
      ),
    ),
  );
  name.dispose();
  url.dispose();
  secret.dispose();
  app.audit('ui.provider.dialog.closed');
}

Future<void> editModel(
  BuildContext context,
  AppController app, {
  ModelConfig? original,
  String? providerId,
  String? modelId,
}) async {
  app.audit('ui.model.dialog.open', {
    'model': original?.toJson(),
    'providerId': providerId,
    'modelId': modelId,
  });
  if (app.config.providers.isEmpty) {
    await editProvider(context, app);
    if (!context.mounted || app.config.providers.isEmpty) {
      return;
    }
  }
  var provider =
      original?.providerId ?? providerId ?? app.config.providers.first.id;
  var protocol =
      original?.protocol ??
      (app.provider(provider)!.supportsResponses
          ? ApiProtocol.responses
          : ApiProtocol.chat);
  var search = original?.search ?? SearchMode.off;
  var effort = original?.effort ?? 'default',
      thinking = original?.thinking ?? 'default';
  var vision = original?.vision ?? false;
  var calculation = original?.calculation ?? CalculationMode.off;
  CalculationMode selectedCalculation() =>
      calculation == CalculationMode.hostedPython &&
          !supportsHostedPython(protocol, app.provider(provider)!)
      ? CalculationMode.off
      : calculation;
  var busy = false;
  String? error;
  final name = TextEditingController(text: original?.name ?? modelId ?? '');
  final model = TextEditingController(text: original?.model ?? modelId ?? '');
  final tokens = TextEditingController(text: '${original?.maxTokens ?? 8192}');
  final timeout = TextEditingController(
    text: '${original?.timeoutSeconds ?? 120}',
  );
  final temperature = TextEditingController(
    text: original?.temperature?.toString() ?? '',
  );
  final extra = TextEditingController(
    text: original == null || original.extra.isEmpty
        ? ''
        : const JsonEncoder.withIndent('  ').convert(original.extra),
  );
  final id = original?.id ?? newId();
  if (!context.mounted) {
    return;
  }
  await appDialog<void>(
    context,
    (ctx) => StatefulBuilder(
      builder: (ctx, set) => DialogFrame(
        title: original == null ? '添加模型' : '模型设置',
        busy: busy,
        error: error,
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    set(() {
                      error = null;
                      busy = true;
                    });
                    try {
                      final dynamic ext = extra.text.trim().isEmpty
                          ? <String, dynamic>{}
                          : jsonDecode(extra.text);
                      if (ext is! Map<String, dynamic>) {
                        throw const FormatException('扩展参数需为 JSON 对象');
                      }
                      final t = temperature.text.trim();
                      final temp = t.isEmpty ? null : double.tryParse(t);
                      if (t.isNotEmpty && (temp == null || !temp.isFinite)) {
                        throw const FormatException('温度格式无效');
                      }
                      await app.saveModel(
                        ModelConfig(
                          id: id,
                          name: name.text.trim(),
                          model: model.text.trim(),
                          providerId: provider,
                          protocol: protocol,
                          search: search,
                          effort: effort,
                          thinking: thinking,
                          vision: vision,
                          calculation: selectedCalculation(),
                          maxTokens: int.tryParse(tokens.text) ?? 0,
                          timeoutSeconds: int.tryParse(timeout.text) ?? 0,
                          temperature: temp,
                          extra: ext,
                        ),
                      );
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                      }
                    } catch (e, stack) {
                      app.log?.error('ui.model.save.error', e, stack);
                      if (ctx.mounted) {
                        set(() {
                          error = errorLabel(e);
                          busy = false;
                        });
                      }
                    }
                  },
            child: const Text('保存'),
          ),
        ],
        child: FieldColumn(
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            DropdownButtonFormField<String>(
              initialValue: provider,
              decoration: const InputDecoration(labelText: '供应商'),
              items: app.config.providers
                  .map(
                    (p) => DropdownMenuItem(value: p.id, child: Text(p.name)),
                  )
                  .toList(),
              onChanged: (v) => set(() {
                provider = v!;
                if (!app.provider(provider)!.supportsResponses) {
                  protocol = ApiProtocol.chat;
                }
              }),
            ),
            TextField(
              controller: model,
              decoration: const InputDecoration(
                labelText: '模型 ID',
                hintText: '供应商返回的模型 ID',
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<ApiProtocol>(
                    isExpanded: true,
                    key: ValueKey('protocol-$provider-$protocol'),
                    initialValue: protocol,
                    decoration: const InputDecoration(labelText: '协议'),
                    items: [
                      const DropdownMenuItem(
                        value: ApiProtocol.chat,
                        child: Text(
                          'Chat Completions',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (app.provider(provider)!.supportsResponses)
                        const DropdownMenuItem(
                          value: ApiProtocol.responses,
                          child: Text('Responses'),
                        ),
                    ],
                    onChanged: (v) => set(() => protocol = v!),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: DropdownButtonFormField<SearchMode>(
                    initialValue: search,
                    decoration: const InputDecoration(labelText: '联网搜索'),
                    items: SearchMode.values
                        .map(
                          (v) => DropdownMenuItem(
                            value: v,
                            child: Text(switch (v) {
                              SearchMode.off => '不确定时搜索',
                              SearchMode.auto => '自动搜索',
                              SearchMode.required => '每题强制搜索',
                            }),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => set(() => search = v!),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: thinking,
                    decoration: const InputDecoration(labelText: '思考模式'),
                    items: const [
                      DropdownMenuItem(value: 'default', child: Text('默认')),
                      DropdownMenuItem(value: 'enabled', child: Text('开启')),
                      DropdownMenuItem(value: 'disabled', child: Text('关闭')),
                    ],
                    onChanged: (v) => set(() => thinking = v!),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: effort,
                    decoration: const InputDecoration(labelText: '思考深度'),
                    items:
                        [
                              'default',
                              'none',
                              'minimal',
                              'low',
                              'medium',
                              'high',
                              'xhigh',
                              'max',
                              'ultra',
                            ]
                            .map(
                              (v) => DropdownMenuItem(
                                value: v,
                                child: Text(v == 'default' ? '默认' : v),
                              ),
                            )
                            .toList(),
                    onChanged: (v) => set(() => effort = v!),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: tokens,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '输出 Token'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextField(
                    controller: timeout,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '超时 / 秒'),
                  ),
                ),
              ],
            ),
            TextField(
              controller: temperature,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '温度',
                hintText: '默认',
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('图片输入'),
              subtitle: const Text('读取 OCS 发送的题干和选项图片'),
              value: vision,
              onChanged: (v) => set(() => vision = v),
            ),
            DropdownButtonFormField<CalculationMode>(
              key: ValueKey(selectedCalculation()),
              initialValue: selectedCalculation(),
              decoration: InputDecoration(
                labelText: '计算工具',
                helperText: switch (selectedCalculation()) {
                  CalculationMode.localPython => '使用发行包自带的 Python，无需安装',
                  CalculationMode.calculator => '适合基础数值运算',
                  CalculationMode.hostedPython =>
                    '需要 Responses 接口支持 Code Interpreter',
                  CalculationMode.off => null,
                },
              ),
              items: [
                const DropdownMenuItem(
                  value: CalculationMode.off,
                  child: Text('关闭'),
                ),
                const DropdownMenuItem(
                  value: CalculationMode.localPython,
                  child: Text('本机 Python 3'),
                ),
                const DropdownMenuItem(
                  value: CalculationMode.calculator,
                  child: Text('内置计算器'),
                ),
                DropdownMenuItem(
                  value: CalculationMode.hostedPython,
                  enabled: supportsHostedPython(
                    protocol,
                    app.provider(provider)!,
                  ),
                  child: const Text('供应商托管 Python'),
                ),
              ],
              onChanged: (v) => set(() => calculation = v!),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('扩展参数', style: TextStyle(fontSize: 14)),
              children: [
                TextField(
                  controller: extra,
                  minLines: 3,
                  maxLines: 8,
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                  decoration: const InputDecoration(hintText: '{}'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
    width: 620,
  );
  for (final c in [name, model, tokens, timeout, temperature, extra]) {
    c.dispose();
  }
  app.audit('ui.model.dialog.closed');
}

Future<bool> confirmAction(
  BuildContext context,
  String title,
  String action,
) async =>
    await appDialog<bool>(
      context,
      (ctx) => DialogFrame(
        title: title,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
        child: const SizedBox.shrink(),
      ),
    ) ??
    false;

Future<String?> pickModel(BuildContext context, List<String> models) async {
  var query = '';
  return appDialog<String>(
    context,
    (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final filtered = models
            .where((m) => m.toLowerCase().contains(query.toLowerCase()))
            .toList();
        return DialogFrame(
          title: '模型列表',
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                autofocus: true,
                onChanged: (v) => set(() => query = v),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded),
                  hintText: '搜索模型',
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 330,
                child: filtered.isEmpty
                    ? const EmptyState(
                        icon: Icons.search_off_rounded,
                        label: '暂无模型',
                      )
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (ctx, i) => ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          title: Text(
                            filtered[i],
                            style: const TextStyle(fontSize: 13),
                          ),
                          trailing: const Icon(Icons.add_rounded, size: 18),
                          onTap: () => Navigator.pop(ctx, filtered[i]),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
