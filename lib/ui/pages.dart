import 'dart:io';
import 'package:flutter/material.dart' hide Badge;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_controller.dart';
import '../domain/config.dart';
import '../domain/answer.dart';
import 'components.dart';
import 'editors.dart';
import '../services/export_service.dart';
import '../services/interaction_audit.dart';

void message(BuildContext context, String text) {
  AuditScope.of(context)?.write('interaction', 'ui.message', {'text': text});
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(text), width: 420));
}

Future<void> guarded(
  BuildContext context,
  Future<void> Function() action,
) async {
  final log = AuditScope.of(context);
  try {
    await action();
  } catch (e, stack) {
    log?.error('ui.action.error', e, stack);
    if (context.mounted) {
      message(context, errorLabel(e));
    }
  }
}

Widget pageScroll(List<Widget> children) => ListView(
  padding: const EdgeInsets.fromLTRB(34, 2, 34, 32),
  children: children,
);

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.app, required this.navigate});
  final AppController app;
  final ValueChanged<int> navigate;
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final active = app.activeModel;
    final success = app.records
        .where((r) => r.result?.answers.isNotEmpty ?? false)
        .length;
    return pageScroll([
      Surface(
        padding: const EdgeInsets.all(30),
        child: Row(
          children: [
            AnimatedContainer(
              duration: motion,
              width: 94,
              height: 94,
              decoration: BoxDecoration(
                color: app.server.running
                    ? c.primaryContainer
                    : c.surfaceContainerLow,
                borderRadius: BorderRadius.circular(30),
              ),
              child: Icon(
                Icons.electric_bolt_rounded,
                size: 44,
                color: app.server.running ? c.primary : c.outline,
              ),
            ),
            const SizedBox(width: 28),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '答题服务',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 9),
                  Text(
                    '127.0.0.1:${app.config.port}',
                    style: TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 13,
                      color: c.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    active?.name ?? '选择一个模型，开始连接',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.primary, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Tooltip(
              message: app.server.running ? '停止服务' : '启动服务',
              child: FilledButton(
                onPressed: app.switching
                    ? null
                    : () => guarded(context, app.toggleServer),
                style: FilledButton.styleFrom(
                  fixedSize: const Size(66, 66),
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(23),
                  ),
                ),
                child: app.switching
                    ? SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: c.onPrimary,
                        ),
                      )
                    : AnimatedRotation(
                        turns: app.server.running ? .5 : 0,
                        duration: motion,
                        child: const Icon(
                          Icons.power_settings_new_rounded,
                          size: 30,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      LayoutBuilder(
        builder: (context, size) => Wrap(
          spacing: 18,
          runSpacing: 18,
          children: [
            metric(
              context,
              '请求',
              '${app.records.length}',
              Icons.swap_vert_rounded,
              (size.maxWidth - 36) / 3,
            ),
            metric(
              context,
              '有答案',
              '$success',
              Icons.check_circle_outline_rounded,
              (size.maxWidth - 36) / 3,
            ),
            metric(
              context,
              '进行中',
              '${app.pending}',
              Icons.timelapse_rounded,
              (size.maxWidth - 36) / 3,
            ),
          ],
        ),
      ),
      SectionHeading(
        '当前模型',
        action: TextButton.icon(
          onPressed: () => editModel(context, app),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('添加'),
        ),
      ),
      if (app.config.models.isEmpty)
        Surface(
          child: EmptyState(
            icon: Icons.hub_outlined,
            label: '添加你的第一个模型',
            action: FilledButton.icon(
              onPressed: () => editModel(context, app),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('添加模型'),
            ),
          ),
        )
      else
        ...app.config.models.map(
          (m) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ModelTile(app: app, model: m),
          ),
        ),
      const SectionHeading('快捷入口'),
      Row(
        children: [
          Expanded(
            child: shortcut(
              context,
              'OCS 接入',
              Icons.link_rounded,
              () => navigate(4),
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: shortcut(
              context,
              '答题调试',
              Icons.science_outlined,
              () => navigate(3),
            ),
          ),
        ],
      ),
    ]);
  }

  Widget metric(
    BuildContext context,
    String label,
    String value,
    IconData icon,
    double width,
  ) => SizedBox(
    width: width,
    child: Surface(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 19,
                color: Theme.of(context).colorScheme.primary,
              ),
              const Spacer(),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          AnimatedSwitcher(
            duration: motion,
            child: Text(
              value,
              key: ValueKey(value),
              style: const TextStyle(
                fontFamily: 'Consolas',
                fontSize: 31,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    ),
  );
  Widget shortcut(
    BuildContext context,
    String title,
    IconData icon,
    VoidCallback tap,
  ) => Surface(
    onTap: tap,
    child: Row(
      children: [
        Icon(icon, size: 22, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 15),
        Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        const Spacer(),
        const Icon(Icons.arrow_forward_rounded, size: 18),
      ],
    ),
  );
}

class ModelTile extends StatelessWidget {
  const ModelTile({super.key, required this.app, required this.model});
  final AppController app;
  final ModelConfig model;
  @override
  Widget build(BuildContext context) {
    final m = model;
    final active = app.config.activeModelId == m.id;
    final c = Theme.of(context).colorScheme;
    return Surface(
      selected: active,
      onTap: () => guarded(context, () => app.selectModel(m.id)),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      child: Row(
        children: [
          AnimatedContainer(
            duration: motion,
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: active ? c.primaryContainer : c.surfaceContainerLow,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              active ? Icons.check_rounded : Icons.auto_awesome_outlined,
              color: c.primary,
              size: 21,
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${app.provider(m.providerId)?.name ?? ""}  /  ${m.model}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: c.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (MediaQuery.sizeOf(context).width > 1080) ...[
            Badge(m.protocol == ApiProtocol.responses ? 'Responses' : 'Chat'),
            const SizedBox(width: 8),
          ],
          if (m.search != SearchMode.off) ...[
            const Tooltip(
              message: '联网搜索',
              child: Icon(Icons.travel_explore_rounded, size: 17),
            ),
            const SizedBox(width: 10),
          ],
          IconButton(
            tooltip: '模型设置',
            onPressed: () => editModel(context, app, original: m),
            icon: const Icon(Icons.tune_rounded, size: 19),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_horiz_rounded, size: 20),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'test', child: Text('测试')),
              const PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
            onSelected: (value) async {
              if (value == 'test') {
                await guarded(context, () async {
                  final r = await app.answer(
                    const Question(
                      title: '1 + 1 等于几？',
                      options: 'A. 1\nB. 2\nC. 3\nD. 4',
                      type: 'single',
                    ),
                    modelId: m.id,
                  );
                  if (context.mounted) {
                    message(
                      context,
                      r.answers.isEmpty ? '未返回答案' : '连接正常 · ${r.ocsAnswer}',
                    );
                  }
                });
              } else if (await confirmAction(context, '删除 ${m.name}？', '删除')) {
                if (context.mounted) {
                  await guarded(context, () => app.deleteModel(m.id));
                }
              }
            },
          ),
        ],
      ),
    );
  }
}

class ProvidersPage extends StatefulWidget {
  const ProvidersPage({super.key, required this.app});
  final AppController app;
  @override
  State<ProvidersPage> createState() => _ProvidersPageState();
}

class _ProvidersPageState extends State<ProvidersPage> {
  bool busy = false;
  Future<void> discover(ProviderConfig p) async {
    if (busy) {
      return;
    }
    setState(() => busy = true);
    try {
      final models = await widget.app.fetchModels(p);
      if (!mounted) {
        return;
      }
      final id = await pickModel(context, models);
      if (id != null && mounted) {
        await editModel(context, widget.app, providerId: p.id, modelId: id);
      }
    } catch (e) {
      if (mounted) {
        message(context, errorLabel(e));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return pageScroll([
      Row(
        children: [
          Text(
            '${app.config.providers.length} 个供应商',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: SizedBox(
                width: 17,
                height: 17,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          FilledButton.icon(
            onPressed: () => editProvider(context, app),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('添加供应商'),
          ),
        ],
      ),
      const SizedBox(height: 22),
      if (app.config.providers.isEmpty)
        const EmptyState(icon: Icons.dns_outlined, label: '暂无供应商'),
      ...app.config.providers.map(
        (p) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        p.kind == ProviderKind.deepseek
                            ? Icons.waves_rounded
                            : p.kind == ProviderKind.openai
                            ? Icons.blur_on_rounded
                            : Icons.cloud_outlined,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.name,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            p.baseUrl,
                            style: TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 11,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '供应商设置',
                      onPressed: () => editProvider(context, app, p),
                      icon: const Icon(Icons.edit_outlined, size: 20),
                    ),
                    IconButton(
                      tooltip: '删除',
                      onPressed: () async {
                        if (await confirmAction(
                              context,
                              '删除 ${p.name}？',
                              '删除',
                            ) &&
                            context.mounted) {
                          await guarded(
                            context,
                            () => app.deleteProvider(p.id),
                          );
                        }
                      },
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 23),
                Row(
                  children: [
                    Badge(
                      '${app.config.models.where((m) => m.providerId == p.id).length} 个模型',
                    ),
                    const SizedBox(width: 8),
                    if (p.supportsResponses)
                      const Badge('Responses', active: true),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: busy ? null : () => discover(p),
                      icon: const Icon(Icons.sync_rounded, size: 17),
                      label: const Text('获取模型'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ]);
  }
}

class ModelsPage extends StatelessWidget {
  const ModelsPage({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => pageScroll([
    Row(
      children: [
        Text(
          '${app.config.models.length} 个模型',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const Spacer(),
        FilledButton.icon(
          onPressed: () => editModel(context, app),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('添加模型'),
        ),
      ],
    ),
    const SizedBox(height: 22),
    if (app.config.models.isEmpty)
      const Surface(
        child: EmptyState(icon: Icons.hub_outlined, label: '暂无模型'),
      ),
    ...app.config.models.map(
      (m) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: ModelTile(app: app, model: m),
      ),
    ),
  ]);
}

class DebugPage extends StatefulWidget {
  const DebugPage({super.key, required this.app});
  final AppController app;
  @override
  State<DebugPage> createState() => _DebugPageState();
}

class _DebugPageState extends State<DebugPage> {
  final title = TextEditingController();
  final options = TextEditingController();
  String type = 'single';
  bool busy = false;
  String? error;
  AnswerResult? result;
  @override
  void dispose() {
    title.dispose();
    options.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => pageScroll([
    Surface(
      child: FieldColumn(
        children: [
          Row(
            children: [
              const Text(
                '题目',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
              ),
              const Spacer(),
              TextButton(
                onPressed: busy
                    ? null
                    : () {
                        title.text = '以下哪些属于编程语言？';
                        options.text =
                            'A. Dart\nB. Flutter\nC. Python\nD. Windows';
                        setState(() => type = 'multiple');
                      },
                child: const Text('示例'),
              ),
            ],
          ),
          DropdownButtonFormField<String>(
            key: ValueKey(type),
            initialValue: type,
            decoration: const InputDecoration(labelText: '题型'),
            items: const [
              DropdownMenuItem(value: 'single', child: Text('单选')),
              DropdownMenuItem(value: 'multiple', child: Text('多选')),
              DropdownMenuItem(value: 'judgement', child: Text('判断')),
              DropdownMenuItem(value: 'completion', child: Text('填空')),
              DropdownMenuItem(value: 'unknown', child: Text('简答')),
            ],
            onChanged: busy ? null : (v) => setState(() => type = v!),
          ),
          TextField(
            controller: title,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(labelText: '题目'),
          ),
          TextField(
            controller: options,
            minLines: 4,
            maxLines: 10,
            decoration: const InputDecoration(
              labelText: '选项',
              hintText: '每行一个选项',
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.app.activeModel?.name ?? '未选择模型',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: busy || widget.app.activeModel == null
                    ? null
                    : submit,
                icon: busy
                    ? const SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow_rounded, size: 20),
                label: Text(busy ? '答题中' : '开始'),
              ),
            ],
          ),
        ],
      ),
    ),
    AnimatedSize(
      duration: motion,
      child: error == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Surface(
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
    ),
    AnimatedSize(
      duration: motion,
      child: result == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Surface(child: ResultView(result: result!)),
            ),
    ),
  ]);
  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
      result = null;
    });
    try {
      final q = Question.fromJson({
        'title': title.text,
        'options': options.text,
        'type': type,
      });
      final r = await widget.app.answer(q);
      if (mounted) {
        setState(() => result = r);
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = errorLabel(e));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }
}

class ResultView extends StatelessWidget {
  const ResultView({super.key, required this.result});
  final AnswerResult result;
  @override
  Widget build(BuildContext context) => FieldColumn(
    children: [
      Text(
        result.answers.isEmpty ? '未找到答案' : '答案',
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17),
      ),
      if (result.answers.isNotEmpty)
        SelectableText(
          result.answers.join('\n'),
          style: TextStyle(
            fontSize: 18,
            height: 1.7,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      if (result.explanation.isNotEmpty)
        SelectableText(
          result.explanation,
          style: TextStyle(
            fontSize: 13,
            height: 1.7,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      if (result.sources.isNotEmpty)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: result.sources
              .map(
                (url) => ActionChip(
                  avatar: const Icon(Icons.open_in_new_rounded, size: 14),
                  label: Text(Uri.parse(url).host),
                  onPressed: () => launchUrl(Uri.parse(url)),
                ),
              )
              .toList(),
        ),
      if (result.searchCalls > 0)
        Badge('搜索 ${result.searchCalls} 次', icon: Icons.travel_explore_rounded),
      if (result.pageReads > 0)
        Badge('读取 ${result.pageReads} 页', icon: Icons.article_outlined),
    ],
  );
}

Future<void> showHelp(BuildContext context) => appDialog<void>(
  context,
  (ctx) => DialogFrame(
    title: '接入帮助',
    actions: [
      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('完成')),
    ],
    child: const FieldColumn(
      children: [
        Text('1. 在供应商中填写 API Key。'),
        Text('2. 添加模型，选择协议和参数。'),
        Text('3. 启动本机服务，复制题库配置。'),
        Text('4. 在 OCS 的题库配置中粘贴并保存。'),
        Text('5. 将 OCS 题库超时调至大于模型超时。'),
        Text('连接失败：允许脚本访问 127.0.0.1，并检查浏览器的本地网络访问权限。'),
        Text('搜索、图片和思考深度需由模型及供应商实际支持。'),
      ],
    ),
  ),
).then((_) {});

class ConnectionPage extends StatelessWidget {
  const ConnectionPage({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => pageScroll([
    Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.link_rounded, size: 26),
              const SizedBox(width: 15),
              const Text(
                '题库配置',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => guarded(context, () async {
                  await Clipboard.setData(ClipboardData(text: app.wrapperJson));
                  if (context.mounted) {
                    message(context, '已复制');
                  }
                }),
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('复制配置'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(17),
            ),
            child: Text(
              'http://127.0.0.1:${app.config.port}/answer',
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 14),
            ),
          ),
          const SizedBox(height: 24),
          const Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Badge('1  复制配置'),
              Icon(Icons.arrow_forward_rounded, size: 15),
              Badge('2  OCS → 题库配置'),
              Icon(Icons.arrow_forward_rounded, size: 15),
              Badge('3  粘贴保存'),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'OCS 题库超时 ≥ ${(app.activeModel?.timeoutSeconds ?? 120) + 15} 秒 · 并发 ≤ 4',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
    const SectionHeading('连接'),
    Surface(
      child: Column(
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.power_settings_new_rounded),
            title: const Text('本机服务'),
            trailing: Switch.adaptive(
              value: app.server.running,
              onChanged: app.switching
                  ? null
                  : (_) => guarded(context, app.toggleServer),
            ),
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.vpn_key_outlined),
            title: const Text('接入令牌'),
            trailing: OutlinedButton(
              onPressed: app.server.running
                  ? null
                  : () async {
                      if (await confirmAction(context, '重置接入令牌？', '重置') &&
                          context.mounted) {
                        await guarded(context, () async {
                          app.config.token = newToken();
                          await app.save();
                          if (context.mounted) {
                            message(context, '已重置，请重新复制配置');
                          }
                        });
                      }
                    },
              child: const Text('重置'),
            ),
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.help_outline_rounded),
            title: const Text('接入帮助'),
            trailing: const Icon(Icons.open_in_new_rounded, size: 18),
            onTap: () => showHelp(context),
          ),
        ],
      ),
    ),
  ]);
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.app});
  final AppController app;
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  AppController get app => widget.app;
  int page = 0;
  @override
  Widget build(BuildContext context) {
    final lastPage = app.records.isEmpty ? 0 : (app.records.length - 1) ~/ 50;
    final currentPage = page > lastPage ? lastPage : page;
    return pageScroll([
      Row(
        children: [
          Text(
            '${app.records.length} 条记录',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: app.records.isEmpty
                ? null
                : () => exportAnswers(context, app, List.of(app.records)),
            icon: const Icon(Icons.file_download_outlined, size: 18),
            label: const Text('导出'),
          ),
          const SizedBox(width: 10),
          TextButton.icon(
            onPressed: app.records.isEmpty
                ? null
                : () async {
                    if (await confirmAction(context, '清空请求记录？', '清空')) {
                      app.clearRecords();
                    }
                  },
            icon: const Icon(Icons.delete_sweep_outlined, size: 18),
            label: const Text('清空'),
          ),
        ],
      ),
      const SizedBox(height: 18),
      if (app.records.isEmpty)
        const Surface(
          child: EmptyState(icon: Icons.receipt_long_outlined, label: '暂无请求'),
        ),
      ...app.records
          .skip(currentPage * 50)
          .take(50)
          .map(
            (r) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Surface(
                onTap: () => showRecord(context, r),
                padding: const EdgeInsets.all(21),
                child: Row(
                  children: [
                    Icon(
                      r.error == null
                          ? r.result!.answers.isEmpty
                                ? Icons.help_outline_rounded
                                : Icons.check_circle_outline_rounded
                          : Icons.error_outline_rounded,
                      color: r.error == null
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.error,
                      size: 22,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.question.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 7),
                          Text(
                            '${r.model}  ·  ${r.time.hour.toString().padLeft(2, '0')}:${r.time.minute.toString().padLeft(2, '0')}:${r.time.second.toString().padLeft(2, '0')}',
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 20),
                    Badge(
                      r.cached
                          ? '缓存'
                          : '${(r.duration.inMilliseconds / 1000).toStringAsFixed(1)}s',
                    ),
                    const SizedBox(width: 14),
                    const Icon(Icons.chevron_right_rounded, size: 19),
                  ],
                ),
              ),
            ),
          ),
      if (lastPage > 0)
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            IconButton(
              tooltip: '上一页',
              onPressed: currentPage == 0
                  ? null
                  : () {
                      app.audit('history.page', {'page': currentPage - 1});
                      setState(() => page = currentPage - 1);
                    },
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            Text('${currentPage + 1} / ${lastPage + 1}'),
            IconButton(
              tooltip: '下一页',
              onPressed: currentPage >= lastPage
                  ? null
                  : () {
                      app.audit('history.page', {'page': currentPage + 1});
                      setState(() => page = currentPage + 1);
                    },
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
    ]);
  }

  Future<void> showRecord(
    BuildContext context,
    RequestRecord r,
  ) => appDialog<void>(
    context,
    (ctx) => DialogFrame(
      title: '请求详情',
      actions: [
        FilledButton.icon(
          onPressed: () => exportAnswers(ctx, app, [r]),
          icon: const Icon(Icons.file_download_outlined, size: 17),
          label: const Text('导出'),
        ),
        const SizedBox(width: 12),
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
      child: FieldColumn(
        children: [
          SelectableText(r.question.title),
          if (r.question.options.isNotEmpty)
            SelectableText(
              r.question.options,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          if (r.error != null)
            Text(
              r.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (r.result != null) ResultView(result: r.result!),
          Text(
            '输入 ${r.result?.inputTokens ?? 0}  /  输出 ${r.result?.outputTokens ?? 0} Token',
            style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
          ),
        ],
      ),
    ),
  ).then((_) {});
}

Future<void> exportAnswers(
  BuildContext context,
  AppController app,
  List<RequestRecord> records,
) async {
  var format = AnswerExportFormat.json;
  var onlyAnswers = false, busy = false;
  String? error;
  app.audit('export.dialog.open', {
    'records': records.map((r) => r.id).toList(),
  });
  final saved = await appDialog<String>(
    context,
    (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final selected = onlyAnswers
            ? records
                  .where(
                    (r) =>
                        r.error == null &&
                        (r.result?.answers.isNotEmpty ?? false),
                  )
                  .toList()
            : records;
        return DialogFrame(
          title: '导出答案',
          busy: busy,
          error: error,
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: busy || selected.isEmpty
                  ? null
                  : () async {
                      set(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        final path = await AnswerExporter(
                          log: app.log,
                        ).save(selected, format);
                        if (ctx.mounted) {
                          if (path != null) {
                            Navigator.pop(ctx, path);
                          } else {
                            set(() => busy = false);
                          }
                        }
                      } catch (failure, stack) {
                        app.log?.error('export.dialog.error', failure, stack);
                        if (ctx.mounted) {
                          set(() {
                            busy = false;
                            error = errorLabel(failure);
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
                  : const Text('导出'),
            ),
          ],
          child: FieldColumn(
            children: [
              DropdownButtonFormField<AnswerExportFormat>(
                initialValue: format,
                decoration: const InputDecoration(labelText: '格式'),
                items: AnswerExportFormat.values
                    .map(
                      (f) => DropdownMenuItem(value: f, child: Text(f.label)),
                    )
                    .toList(),
                onChanged: busy
                    ? null
                    : (v) => set(() {
                        format = v!;
                        app.audit('export.format', {'format': format.name});
                      }),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('仅成功答案'),
                value: onlyAnswers,
                onChanged: busy ? null : (v) => set(() => onlyAnswers = v),
              ),
              Badge('${selected.length} 条记录'),
            ],
          ),
        );
      },
    ),
  );
  if (saved != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('已导出'),
        action: SnackBarAction(
          label: '打开目录',
          onPressed: () => guarded(context, () async {
            await launchUrl(Uri.directory(File(saved).parent.path));
          }),
        ),
      ),
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => pageScroll([
    Surface(
      child: Column(
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.dark_mode_outlined),
            title: const Text('深色模式'),
            value: app.config.darkMode,
            onChanged: (v) => guarded(context, () async {
              app.config.darkMode = v;
              await app.save();
            }),
          ),
          const Divider(),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.play_circle_outline_rounded),
            title: const Text('打开软件时启动服务'),
            value: app.config.autoStart,
            onChanged: (v) => guarded(context, () async {
              app.config.autoStart = v;
              await app.save();
            }),
          ),
          const Divider(),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.cached_rounded),
            title: const Text('答案缓存'),
            value: app.config.cacheEnabled,
            onChanged: (v) => guarded(context, () async {
              app.config.cacheEnabled = v;
              if (!v) {
                app.clearCache();
              }
              await app.save();
            }),
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('清理缓存'),
            trailing: Text('${app.cacheSize}'),
            onTap: () {
              app.clearCache();
              message(context, '已清理');
            },
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.lan_outlined),
            title: const Text('服务端口'),
            trailing: Text('${app.config.port}'),
            onTap: app.server.running
                ? () => message(context, '请先停止服务')
                : () => editPort(context),
          ),
        ],
      ),
    ),
    const SectionHeading('应用'),
    Surface(
      child: Column(
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_outlined),
            title: const Text('配置目录'),
            trailing: const Icon(Icons.open_in_new_rounded, size: 18),
            onTap: () => guarded(context, () async {
              await app.store.directory.create(recursive: true);
              if (!await launchUrl(Uri.directory(app.store.directory.path)) &&
                  context.mounted) {
                message(context, '无法打开目录');
              }
            }),
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.article_outlined),
            title: const Text('日志目录'),
            subtitle: const Text('24 小时 · 原文'),
            trailing: const Icon(Icons.open_in_new_rounded, size: 18),
            onTap: app.log?.directory == null
                ? null
                : () => guarded(context, () async {
                    app.audit('logs.open', {
                      'directory': app.log!.directory!.path,
                    });
                    await app.log!.directory!.create(recursive: true);
                    await launchUrl(Uri.directory(app.log!.directory!.path));
                  }),
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              app.log?.lastError == null
                  ? Icons.task_alt_rounded
                  : Icons.error_outline_rounded,
            ),
            title: const Text('日志状态'),
            trailing: Text(
              app.log == null
                  ? '未启用'
                  : app.log!.lastError == null
                  ? '正常'
                  : '写入失败',
            ),
            onTap: app.log?.lastError == null
                ? null
                : () => appDialog<void>(
                    context,
                    (ctx) => DialogFrame(
                      title: '日志状态',
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('关闭'),
                        ),
                      ],
                      child: SelectableText(app.log!.lastError!),
                    ),
                  ),
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.menu_book_outlined),
            title: const Text('使用帮助'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => showHelp(context),
          ),
          const Divider(),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.bolt_rounded),
            title: Text('OCS Bridge'),
            trailing: Text('0.2.2'),
          ),
        ],
      ),
    ),
  ]);
  Future<void> editPort(BuildContext context) async {
    final port = TextEditingController(text: '${app.config.port}');
    String? error;
    await appDialog<void>(
      context,
      (ctx) => StatefulBuilder(
        builder: (ctx, set) => DialogFrame(
          title: '服务端口',
          error: error,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: () async {
                final value = int.tryParse(port.text);
                if (value == null || value < 1024 || value > 65535) {
                  app.audit('port.validation.failed', {'input': port.text});
                  set(() => error = '端口范围为 1024–65535');
                  return;
                }
                try {
                  app.config.port = value;
                  await app.save();
                  if (ctx.mounted) {
                    Navigator.pop(ctx);
                  }
                } catch (failure, stack) {
                  app.log?.error('ui.port.save.error', failure, stack, {
                    'input': port.text,
                  });
                  if (ctx.mounted) {
                    set(() => error = '保存失败');
                  }
                }
              },
              child: const Text('保存'),
            ),
          ],
          child: TextField(
            controller: port,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '端口'),
          ),
        ),
      ),
    );
    port.dispose();
  }
}
