import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../view_models/proxy_view_model.dart';
import '../widgets/desktop_widgets.dart';

/// 独立设置面板与主窗口共享草稿，关闭面板不会丢弃未应用的编辑。
class SettingsDialog extends StatelessWidget {
  const SettingsDialog({super.key, required this.model});
  final ProxyViewModel model;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final ui = DesktopWidgets(context, model);
      return CallbackShortcuts(
        bindings: {
          for (final meta in [true, false])
            SingleActivator(
              LogicalKeyboardKey.keyS,
              meta: meta,
              control: !meta,
            ): () {
              if (!model.locked) model.apply();
            },
        },
        child: Dialog(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '设置',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭设置（保留草稿）',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: AbsorbPointer(
                    absorbing: model.locked,
                    child: ui.list('settings', _settings(ui)),
                  ),
                ),
                StreamBuilder<UiMessage>(
                  stream: model.messages.stream,
                  builder: (context, snapshot) {
                    final message = snapshot.data;
                    if (message == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          message.text,
                          style: TextStyle(
                            fontSize: 12,
                            color: message.failure ? ui.error : ui.success,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const Divider(),
                const SizedBox(height: 12),
                Text(
                  '应用会同时保存连接、路由和本地代理的配置草稿。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        model.locked
                            ? '正在处理…'
                            : model.dirty
                            ? '草稿未应用'
                            : '所有配置已保存',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    FilledButton(
                      onPressed: model.locked ? null : model.apply,
                      child: const Text('应用并保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  List<Widget> _settings(DesktopWidgets ui) => [
    ui.section('本地代理', [
      ui.field('bind'),
      ui.field('port', help: '填 0 时自动分配可用端口'),
      ui.field('local.connectTimeoutMillis'),
    ], footer: '监听地址或端口修改后立即重建监听，已有连接会断开。'),
    ui.section('高级设置', [
      ExpansionTile(
        key: const PageStorageKey('kernel-runtime'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        shape: const Border(),
        collapsedShape: const Border(),
        title: const Text('内核运行环境', style: TextStyle(fontSize: 13)),
        children: [
          if (model.usesNativeKernel)
            ui.caption('当前使用应用内置内核，无需配置外部运行环境。')
          else ...[
            ui.fileField('Java', 'java', model.java, '自动使用系统 Java 25'),
            ui.fileField('内核 JAR', 'jar', model.jar, '选择开发用的内核 JAR'),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton(
                  onPressed: model.saveRuntime,
                  child: const Text('保存启动路径'),
                ),
              ),
            ),
            ui.caption('下次启动内核时生效；更改后先退出内核，再重新连接。'),
          ],
        ],
      ),
    ]),
  ];
}
