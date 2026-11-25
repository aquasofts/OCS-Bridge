import 'package:flutter/material.dart' hide Badge;
import '../app_controller.dart';
import 'components.dart';
import 'pages.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.app});
  final AppController app;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int page = 0;
  static const titles = ['概览', '供应商', '模型', '答题调试', 'OCS 接入', '请求记录', '设置'];
  static const icons = [
    Icons.space_dashboard_outlined,
    Icons.dns_outlined,
    Icons.hub_outlined,
    Icons.science_outlined,
    Icons.link_rounded,
    Icons.receipt_long_outlined,
    Icons.tune_rounded,
  ];
  void navigate(int index) {
    widget.app.audit('ui.navigation', {
      'from': titles[page],
      'to': titles[index],
    });
    setState(() => page = index);
  }

  @override
  void initState() {
    super.initState();
    if (widget.app.config.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          await widget.app.toggleServer();
        } catch (e) {
          if (mounted) {
            message(context, errorLabel(e));
          }
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final c = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width > 1000;
    return Scaffold(
      body: Row(
        children: [
          AnimatedContainer(
            duration: motion,
            width: wide ? 204 : 88,
            padding: EdgeInsets.symmetric(
              horizontal: wide ? 16 : 10,
              vertical: 24,
            ),
            decoration: BoxDecoration(
              color: c.surface,
              border: Border(
                right: BorderSide(
                  color: c.outlineVariant.withValues(alpha: .3),
                ),
              ),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 34),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: c.primary,
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Icon(
                          Icons.bolt_rounded,
                          color: c.onPrimary,
                          size: 27,
                        ),
                      ),
                      if (wide) ...[
                        const SizedBox(width: 11),
                        const Expanded(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'OCS Bridge',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 17,
                                letterSpacing: -.4,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                for (var i = 0; i < titles.length; i++) ...[
                  if (i == 6) const Spacer(),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Tooltip(
                      message: wide ? '' : titles[i],
                      child: AnimatedContainer(
                        duration: motion,
                        curve: ease,
                        decoration: BoxDecoration(
                          color: page == i
                              ? c.primaryContainer
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(17),
                        ),
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(17),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => navigate(i),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 17,
                                vertical: 15,
                              ),
                              child: Row(
                                mainAxisAlignment: wide
                                    ? MainAxisAlignment.start
                                    : MainAxisAlignment.center,
                                children: [
                                  AnimatedSwitcher(
                                    duration: motion,
                                    child: Icon(
                                      icons[i],
                                      key: ValueKey(page == i),
                                      size: 22,
                                      color: page == i
                                          ? c.primary
                                          : c.onSurfaceVariant,
                                    ),
                                  ),
                                  if (wide) ...[
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Text(
                                        titles[i],
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: page == i
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                          color: page == i
                                              ? c.primary
                                              : c.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                if (wide)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Text(
                      'WINDOWS  /  0.2.3',
                      style: TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 10,
                        letterSpacing: 1.2,
                        color: c.outline,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(34, 25, 34, 22),
                  child: Row(
                    children: [
                      AnimatedSwitcher(
                        duration: motion,
                        child: Text(
                          titles[page],
                          key: ValueKey(page),
                          style: const TextStyle(
                            fontSize: 27,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -.8,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Badge(
                        app.server.running ? '服务运行中' : '服务已停止',
                        active: app.server.running,
                        icon: Icons.circle,
                      ),
                      const SizedBox(width: 14),
                      IconButton(
                        tooltip: '切换主题',
                        onPressed: () => guarded(context, () async {
                          app.config.darkMode = !app.config.darkMode;
                          app.audit('ui.theme', {'dark': app.config.darkMode});
                          await app.save();
                        }),
                        icon: AnimatedSwitcher(
                          duration: motion,
                          transitionBuilder: (child, a) => RotationTransition(
                            turns: Tween<double>(begin: .8, end: 1).animate(a),
                            child: FadeTransition(opacity: a, child: child),
                          ),
                          child: Icon(
                            app.config.darkMode
                                ? Icons.light_mode_outlined
                                : Icons.dark_mode_outlined,
                            key: ValueKey(app.config.darkMode),
                            size: 21,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: motion,
                    switchInCurve: ease,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, a) => FadeTransition(
                      opacity: a,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, .025),
                          end: Offset.zero,
                        ).animate(a),
                        child: child,
                      ),
                    ),
                    child: KeyedSubtree(
                      key: ValueKey(page),
                      child: switch (page) {
                        0 => DashboardPage(app: app, navigate: navigate),
                        1 => ProvidersPage(app: app),
                        2 => ModelsPage(app: app),
                        3 => DebugPage(app: app),
                        4 => ConnectionPage(app: app),
                        5 => HistoryPage(app: app),
                        _ => SettingsPage(app: app),
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
