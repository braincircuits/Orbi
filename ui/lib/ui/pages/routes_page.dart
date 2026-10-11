import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../view_models/proxy_view_model.dart';
import '../widgets/desktop_widgets.dart';
import '../desktop_theme.dart';

class RoutesPage extends StatelessWidget {
  const RoutesPage({super.key, required this.model});
  final ProxyViewModel model;
  @override
  Widget build(BuildContext context) =>
      _content(context, DesktopWidgets(context, model));
  Widget _content(BuildContext context, DesktopWidgets ui) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text(
            '规则来源',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: ui.ink,
            ),
          ),
          const Spacer(),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: true,
                label: Text('直接编辑'),
                icon: Icon(Icons.edit_note),
              ),
              ButtonSegment(
                value: false,
                label: Text('规则文件'),
                icon: Icon(Icons.folder_open_outlined),
              ),
            ],
            selected: {model.inlineRules},
            showSelectedIcon: false,
            onSelectionChanged: (values) {
              model.inlineRules = values.single;
              model.changed('');
            },
          ),
        ],
      ),
      const SizedBox(height: 14),
      if (model.inlineRules) ...[
        Expanded(
          child: TextField(
            key: const ValueKey('rules-editor'),
            controller: model.rules,
            onChanged: model.changed,
            expands: true,
            maxLines: null,
            minLines: null,
            textAlignVertical: TextAlignVertical.top,
            autocorrect: false,
            enableSuggestions: false,
            style: DesktopDesign.monoText.copyWith(color: ui.ink),
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.all(16),
              hintText:
                  '# 每行一条域名、IP 或 CIDR\nexample.com\n192.168.0.0/16\n::1/128',
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: () => model.choose('rules', model.rules),
              icon: const Icon(Icons.insert_drive_file_outlined),
              label: const Text('导入规则'),
            ),
            OutlinedButton.icon(
              onPressed: model.validateRules,
              icon: const Icon(Icons.check_circle_outline),
              label: const Text('校验规则'),
            ),
            Text(
              '${model.rules.text.split('\n').where((s) => s.trim().isNotEmpty && !s.trim().startsWith('#')).length} 条规则',
              style: TextStyle(color: ui.muted, fontSize: 11),
            ),
          ],
        ),
      ] else ...[
        ui.card(
          ui.fileField('规则文件', 'rulesPath', model.routesFile, '输入路径或选取文件'),
          padding: const EdgeInsets.symmetric(horizontal: 14),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: model.proxy.connected && !model.dirty
              ? model.reloadRules
              : null,
          child: const Text('重新载入文件规则'),
        ),
        const Spacer(),
      ],
      if (model.proxy.appliedProfile?.targetRoutes.isNotEmpty ?? false) ...[
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => _showTargetRoutes(context),
          icon: const Icon(Icons.alt_route),
          label: Text(
            '查看目标路由（${model.proxy.appliedProfile!.targetRoutes.length}）',
          ),
        ),
      ],
      const SizedBox(height: 14),
      ui.notice(
        '目标路由规则优先；其余目标命中直连规则则直连，否则经过代理。支持 # 注释。应用后断开路由变化的连接，其余连接保持。',
        Icons.info_outline,
      ),
    ],
  );
  Future<void> _showTargetRoutes(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final entries =
            model.proxy.appliedProfile?.targetRoutes.entries.toList() ?? [];
        return AlertDialog(
          title: const Text('目标路由规则'),
          content: SizedBox(
            width: 420,
            height: math.min(260, MediaQuery.sizeOf(context).height / 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('优先于直连规则，精确匹配域名或 IP 的所有端口。'),
                const SizedBox(height: 12),
                Expanded(
                  child: entries.isEmpty
                      ? const Center(child: Text('暂无目标路由规则'))
                      : ListView(
                          children: [
                            for (final entry in entries)
                              SizedBox(
                                height: 44,
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        entry.key,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Text(entry.value == 'direct' ? '直连' : '代理'),
                                    const SizedBox(width: 8),
                                    TextButton(
                                      onPressed:
                                          model.locked || !model.proxy.connected
                                          ? null
                                          : () => model.routeTarget(
                                              '${entry.key.contains(':') ? '[${entry.key}]' : entry.key}:80',
                                              'auto',
                                            ),
                                      child: const Text('恢复自动'),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    ),
  );
}
