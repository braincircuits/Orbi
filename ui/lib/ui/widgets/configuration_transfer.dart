import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/connection_document.dart';
import '../../models/direct_rule_entry.dart';
import '../../view_models/proxy_view_model.dart';

/// 文件选择和持久化由视图模型执行，此处仅管理预览、选择及确认。
class ConfigurationTransfer extends StatelessWidget {
  const ConfigurationTransfer({
    super.key,
    required this.model,
    required this.routes,
  });
  final ProxyViewModel model;
  final bool routes;

  Future<void> _import(BuildContext context) async {
    try {
      final document = await model.readConfigurationDocument();
      if (document == null || !context.mounted) return;
      if (routes) {
        final strategy = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('导入路由规则'),
            content: const Text(
              '合并会保留现有直连规则，同一指定目标以文件中的走向为准；整体替换会替换全部直连及指定目标规则。当前模式和默认连接保持不变。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              OutlinedButton(
                onPressed: () => Navigator.pop(context, 'replace'),
                child: const Text('整体替换'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, 'merge'),
                child: const Text('合并'),
              ),
            ],
          ),
        );
        if (strategy == null || !context.mounted) return;
        final revision = model.proxy.configurationRevision;
        final preview = await model.previewRoutingImport(
          document,
          strategy,
          revision,
        );
        if (preview == null || !context.mounted) return;
        final direct = preview['directRules'] as String;
        final targets = preview['targetRoutes'] as Map<String, dynamic>;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('${strategy == 'merge' ? '合并' : '整体替换'}预览'),
            scrollable: true,
            content: SizedBox(
              width: 560,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '导入后：${DirectRuleEntry.parse(direct).length} 条直连规则，${targets.length} 条指定目标规则',
                  ),
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        '$direct\n\n${targets.entries.map((e) => '${e.key} → ${e.value == 'direct' ? '直连' : '代理'}').join('\n')}',
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('确认后立即保存并生效，路由变化的连接需要重新建立。'),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认导入'),
              ),
            ],
          ),
        );
        if (confirmed == true && context.mounted) {
          await model.importRoutingDocument(document, strategy, revision);
        }
      } else {
        final incoming = ConnectionDocument.parse(document);
        final before = jsonEncode(model.draftProfile().runtimeConfiguration);
        final replacements = List<String?>.filled(incoming.length, null);
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setState) => AlertDialog(
              title: Text('导入 ${incoming.length} 个连接'),
              scrollable: true,
              content: SizedBox(
                width: 560,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '导入到草稿后核对并应用。同名连接可选择覆盖；新增时自动区分名称。未包含密码的新连接需补填密码，证书文件需在本机存在。',
                    ),
                    for (final (index, item) in incoming.indexed)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${item.name} · ${item.protocol.toUpperCase()} · ${item.endpoint}',
                            ),
                            Text(
                              item.values['password']!.isEmpty
                                  ? '文件未包含密码'
                                  : '文件包含密码',
                            ),
                            DropdownButton<String>(
                              isExpanded: true,
                              value: replacements[index] ?? '',
                              items: [
                                const DropdownMenuItem(
                                  value: '',
                                  child: Text('作为新连接'),
                                ),
                                for (final current
                                    in model.connectionDrafts.where(
                                      (c) => c.name == item.name,
                                    ))
                                  DropdownMenuItem(
                                    value: current.id,
                                    child: Text(
                                      '覆盖 ${current.name} · ${current.endpoint}',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (value) => setState(
                                () => replacements[index] = value == ''
                                    ? null
                                    : value,
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
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('导入草稿'),
                ),
              ],
            ),
          ),
        );
        if (confirmed != true || !context.mounted) return;
        if (before != jsonEncode(model.draftProfile().runtimeConfiguration)) {
          throw StateError('预览期间配置已变化，请重新导入');
        }
        model.importConnectionDrafts(incoming, replacements);
      }
    } catch (error) {
      model.message(model.proxy.redact('$error'), failure: true);
    }
  }

  Future<void> _export(BuildContext context) async {
    if (routes) {
      await model.exportRoutingDocument();
      return;
    }
    final profiles = model.proxy.appliedProfile?.connections ?? [];
    final ids = profiles.map((c) => c.id).toSet();
    var includePassword = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('导出连接配置'),
          scrollable: true,
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('导出已保存的连接；可选择单个、多个或全部。未应用的草稿不包含在文件中。'),
                CheckboxListTile(
                  title: const Text('全部连接'),
                  value: ids.length == profiles.length,
                  onChanged: (value) => setState(() {
                    ids.clear();
                    if (value == true) ids.addAll(profiles.map((c) => c.id));
                  }),
                ),
                for (final profile in profiles)
                  CheckboxListTile(
                    title: Text(profile.name),
                    subtitle: Text(profile.endpoint),
                    value: ids.contains(profile.id),
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        ids.add(profile.id);
                      } else {
                        ids.remove(profile.id);
                      }
                    }),
                  ),
                const Divider(),
                CheckboxListTile(
                  title: const Text('包含密码'),
                  subtitle: const Text('勾选后文件包含明文密码，请妥善保管。'),
                  value: includePassword,
                  onChanged: (value) =>
                      setState(() => includePassword = value ?? false),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: ids.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('导出文件'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true && context.mounted) {
      await model.exportConnectionDocument(ids.toList(), includePassword);
    }
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      OutlinedButton.icon(
        onPressed:
            model.locked || !model.proxy.connected || routes && model.dirty
            ? null
            : () => _import(context),
        icon: const Icon(Icons.file_open_outlined),
        label: Text(routes ? '导入路由文件' : '导入连接'),
      ),
      OutlinedButton.icon(
        onPressed: model.locked || !model.proxy.connected
            ? null
            : () => _export(context),
        icon: const Icon(Icons.save_alt),
        label: Text(routes ? '导出路由文件' : '导出连接'),
      ),
    ],
  );
}
