import 'package:flutter/material.dart';

import '../../models/direct_rule_entry.dart';
import '../../view_models/proxy_view_model.dart';
import '../desktop_theme.dart';
import '../widgets/desktop_select.dart';
import '../widgets/desktop_widgets.dart';

class RoutesPage extends StatefulWidget {
  const RoutesPage({super.key, required this.model});
  final ProxyViewModel model;
  @override
  State<RoutesPage> createState() => _RoutesPageState();
}

class _RoutesPageState extends State<RoutesPage> {
  final _search = TextEditingController();
  final _query = TextEditingController();
  final _host = TextEditingController();
  final _note = TextEditingController();
  final _hostFocus = FocusNode();
  final _formKey = GlobalKey();
  bool _targets = false, _bulk = false, _editing = false;
  int? _editingLine;
  String? _editingTarget;
  String _route = 'proxy', _formError = '';
  String _editSource = '';
  ProxyViewModel get model => widget.model;

  @override
  void dispose() {
    for (final controller in [_search, _query, _host, _note]) {
      controller.dispose();
    }
    _hostFocus.dispose();
    super.dispose();
  }

  void _open({DirectRuleEntry? entry, String? target, String? route}) {
    setState(() {
      _editing = true;
      _editingLine = entry?.line;
      _editingTarget = target;
      _editSource = model.rules.text;
      _host.text = entry?.target ?? target ?? '';
      _note.text = entry?.note ?? '';
      _route = route ?? 'proxy';
      _formError = '';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_editing) return;
      final form = _formKey.currentContext;
      if (form != null) Scrollable.ensureVisible(form);
      _hostFocus.requestFocus();
    });
  }

  Future<void> _save() async {
    if (model.showBlockingProgress) return;
    final host = _host.text.trim();
    if (host.isEmpty ||
        RegExp(r'[\s#]').hasMatch(host) ||
        (_targets && host.contains('/'))) {
      setState(
        () => _formError = '请填写单个域名或 IP${_targets ? '' : ' / CIDR 网段'}，不包含注释',
      );
      return;
    }
    if (!_targets && model.rules.text != _editSource) {
      setState(() => _formError = '规则草稿已变化，请取消后重新选择要编辑的规则');
      return;
    }
    if (_targets) {
      final routes = model.proxy.appliedProfile?.targetRoutes ?? {};
      if (_editingTarget == null &&
          routes.keys.any(
            (key) =>
                DirectRuleEntry.hostKey(key) == DirectRuleEntry.hostKey(host),
          )) {
        setState(() => _formError = '该目标已有指定规则，请在列表中编辑');
        return;
      }
      // 目标保持不变，只修改走向，避免先删后增造成中间路由状态。
      final success = await model.routeTarget(
        DirectRuleEntry.authority(host),
        _route,
      );
      if (!mounted) return;
      if (success) setState(() => _editing = false);
    } else {
      if (DirectRuleEntry.parse(model.rules.text).any(
        (entry) =>
            entry.line != _editingLine &&
            DirectRuleEntry.hostKey(entry.target) ==
                DirectRuleEntry.hostKey(host),
      )) {
        setState(() => _formError = '这条规则已经存在，请搜索后编辑');
        return;
      }
      if (!await model.validateRuleDraft(host) || !mounted) return;
      // 校验期间外部配置可能更新，不能将旧行号应用到新的文本。
      if (model.rules.text != _editSource) {
        setState(() => _formError = '规则草稿已变化，请取消后重新编辑');
        return;
      }
      final note = _note.text.trim();
      final line = '$host${note.isEmpty ? '' : ' # $note'}';
      model.editRules(
        _editingLine == null
            ? '${model.rules.text}${model.rules.text.isEmpty ? '' : '\n\n# 新增规则\n'}$line'
            : DirectRuleEntry.replace(model.rules.text, _editingLine!, line),
      );
      setState(() => _editing = false);
    }
  }

  Future<void> _confirmDiscard({bool reload = false}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(reload ? '重新读取内核配置' : '放弃直连规则修改'),
        content: Text(
          reload
              ? '当前连接、规则和本地代理的未应用草稿将被丢弃，并读取内核最新配置。'
              : '恢复已应用的直连规则，其他页面的草稿保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留草稿'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(reload ? '丢弃并读取' : '放弃修改'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (reload) {
      await model.reload();
    } else {
      model.discardRules();
    }
    if (mounted) setState(() => _editing = false);
  }

  Future<void> _import() async {
    final text = await model.readRulesFile();
    if (text == null || !mounted) return;
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入直连列表'),
        scrollable: true,
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${DirectRuleEntry.parse(text).length} 条规则；导入后先进入草稿，原文件后续变化不会自动同步。',
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: SelectableText(text, style: DesktopDesign.monoText),
                ),
              ),
              const SizedBox(height: 12),
              const Text('替换会覆盖当前直连规则草稿，指定目标规则保留。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('替换草稿'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('追加到草稿'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (!await model.validateRuleDraft(text) || !mounted) return;
    model.editRules(
      choice && model.rules.text.isNotEmpty
          ? '${model.rules.text}\n\n$text'
          : text,
    );
    setState(() {
      _bulk = true;
      _editing = false;
    });
  }

  Future<void> _queryRoute() async {
    final host = _query.text.trim();
    if (host.isEmpty || RegExp(r'[\s/#]').hasMatch(host)) {
      model.message('请填写域名或 IP，不包含协议、路径或端口', failure: true);
      return;
    }
    await model.queryRoute(DirectRuleEntry.authority(host));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final ui = DesktopWidgets(context, model);
      final entries = DirectRuleEntry.parse(model.rules.text);
      final targets =
          (model.proxy.appliedProfile?.targetRoutes.entries.toList() ?? [])
            ..sort((a, b) => a.key.compareTo(b.key));
      final query = _search.text.trim().toLowerCase();
      final filteredRules = entries
          .where(
            (e) => '${e.target} ${e.note} ${e.group}'.toLowerCase().contains(
              query,
            ),
          )
          .toList();
      final filteredTargets = targets
          .where((e) => e.key.toLowerCase().contains(query))
          .toList();
      final count = _targets ? filteredTargets.length : filteredRules.length;
      // 模式切换仍阻止重复提交，但无关控件保持原有外观。
      return AbsorbPointer(
        absorbing: model.locked,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context)
                    .copyWith(scrollbars: false),
                child: CustomScrollView(
                  key: const PageStorageKey('routes'),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              SegmentedButton<String>(
                                segments: const [
                                  ButtonSegment(
                                    value: 'rules',
                                    label: Text('按规则'),
                                  ),
                                  ButtonSegment(
                                    value: 'direct',
                                    label: Text('全部直连'),
                                  ),
                                  ButtonSegment(
                                    value: 'proxy',
                                    label: Text('全部代理'),
                                  ),
                                ],
                                selected: {model.proxy.routingMode},
                                showSelectedIcon: false,
                                onSelectionChanged:
                                    model.showBlockingProgress ||
                                        !model.proxy.connected ||
                                        model.routesConflict
                                    ? null
                                    : (values) =>
                                          model.setRoutingMode(values.single),
                              ),
                              Text(
                                '默认代理：${model.activeConnection?.name ?? '未配置'}',
                                style: TextStyle(color: ui.muted, fontSize: 12),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (model.routesConflict) ...[
                            ui.notice(
                              '内核配置已变化，草稿已保留。请核对并重新读取配置后再应用。',
                              Icons.warning_amber,
                              warning: true,
                            ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                onPressed: model.showBlockingProgress
                                    ? null
                                    : () => _confirmDiscard(reload: true),
                                child: const Text('重新读取配置'),
                              ),
                            ),
                          ],
                          ListenableBuilder(
                            listenable: model.operationChanges,
                            builder: (context, _) => _queryCard(ui),
                          ),
                          const SizedBox(height: 18),
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              SegmentedButton<bool>(
                                segments: [
                                  ButtonSegment(
                                    value: false,
                                    label: Text('直连规则 ${entries.length}'),
                                  ),
                                  ButtonSegment(
                                    value: true,
                                    label: Text('指定目标 ${targets.length}'),
                                  ),
                                ],
                                selected: {_targets},
                                showSelectedIcon: false,
                                onSelectionChanged: (values) => setState(() {
                                  _targets = values.single;
                                  _editing = false;
                                  _search.clear();
                                }),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          LayoutBuilder(
                            builder: (context, constraints) => Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                if (_targets || !_bulk)
                                  SizedBox(
                                    width: constraints.maxWidth < 460
                                        ? constraints.maxWidth
                                        : 220,
                                    child: TextField(
                                      key: const ValueKey('route-search'),
                                      controller: _search,
                                      onChanged: (_) => setState(() {}),
                                      decoration: const InputDecoration(
                                        hintText: '搜索目标或备注',
                                        prefixIcon: Icon(Icons.search),
                                      ),
                                    ),
                                  ),
                                if (!_targets) ...[
                                  OutlinedButton(
                                    onPressed: () => setState(() {
                                      _bulk = !_bulk;
                                      _editing = false;
                                    }),
                                    child: Text(_bulk ? '返回列表' : '批量编辑'),
                                  ),
                                  OutlinedButton(
                                    onPressed:
                                        model.showBlockingProgress ||
                                            !model.proxy.connected
                                        ? null
                                        : _import,
                                    child: const Text('导入规则'),
                                  ),
                                ],
                                FilledButton.icon(
                                  key: const ValueKey('add-route'),
                                  onPressed:
                                      model.showBlockingProgress ||
                                          !model.proxy.connected ||
                                          model.routesConflict
                                      ? null
                                      : () => _open(),
                                  icon: const Icon(Icons.add),
                                  label: Text(_targets ? '指定目标' : '添加直连规则'),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (_editing) ...[
                            KeyedSubtree(key: _formKey, child: _editor(ui)),
                            const SizedBox(height: 12),
                          ],
                          if (!_targets && _bulk)
                            SizedBox(
                              height: 320,
                              child: TextField(
                                key: const ValueKey('rules-editor'),
                                controller: model.rules,
                                onChanged: model.editRules,
                                expands: true,
                                maxLines: null,
                                minLines: null,
                                textAlignVertical: TextAlignVertical.top,
                                autocorrect: false,
                                enableSuggestions: false,
                                style: DesktopDesign.monoText.copyWith(
                                  color: ui.ink,
                                ),
                                decoration: const InputDecoration(
                                  contentPadding: EdgeInsets.all(16),
                                  hintText: '# 每行一条直连域名、IP 或 CIDR\nexample.com\n192.168.1.0/24\n::1/128',
                                ),
                              ),
                            ),
                          if ((_targets || !_bulk) && count == 0)
                            Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                query.isNotEmpty
                                    ? '没有匹配的规则'
                                    : _targets
                                    ? '暂无指定目标，为个别域名或 IP 指定直连或代理。'
                                    : '暂无直连规则，未指定的目标使用默认代理。',
                                style: TextStyle(color: ui.muted),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (_targets || !_bulk)
                      SliverList.builder(
                        itemCount: count,
                        itemBuilder: (context, index) => _targets
                            ? _ruleRow(
                                ui,
                                target: filteredTargets[index].key,
                                description: '精确匹配 · 所有端口',
                                route: filteredTargets[index].value,
                                onEdit: () => _open(
                                  target: filteredTargets[index].key,
                                  route: filteredTargets[index].value,
                                ),
                                onRemove: () => model.routeTarget(
                                  DirectRuleEntry.authority(
                                    filteredTargets[index].key,
                                  ),
                                  'auto',
                                ),
                              )
                            : _ruleRow(
                                ui,
                                target: filteredRules[index].target,
                                description:
                                    '${filteredRules[index].scope}${(filteredRules[index].note.isNotEmpty ? filteredRules[index].note : filteredRules[index].group).isEmpty ? '' : ' · ${filteredRules[index].note.isNotEmpty ? filteredRules[index].note : filteredRules[index].group}'}',
                                onEdit: () =>
                                    _open(entry: filteredRules[index]),
                                onRemove: () {
                                  model.editRules(
                                    DirectRuleEntry.replace(
                                      model.rules.text,
                                      filteredRules[index].line,
                                      null,
                                    ),
                                  );
                                  setState(() => _editing = false);
                                },
                              ),
                      ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 8),
                        child: Text(
                          _targets
                              ? '指定目标优先于直连规则；移除后按直连规则和默认代理决定。'
                              : '域名包含所有子域名；规则不按顺序覆盖。支持 # 注释，格式以内核校验为准。',
                          style: TextStyle(color: ui.muted, fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (!_targets && model.rulesError.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 75),
                child: SingleChildScrollView(
                  child: SelectableText(
                    model.rulesError,
                    style: TextStyle(color: ui.error, fontSize: 12),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                Text(
                  _targets
                      ? '保存后立即应用'
                      : model.rulesDirty
                      ? '● 有未应用修改'
                      : '✓ 直连规则已应用',
                  style: TextStyle(
                    fontSize: 12,
                    color: model.rulesDirty && !_targets
                        ? ui.warning
                        : ui.muted,
                  ),
                ),
                if (!_targets)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed:
                            model.showBlockingProgress || !model.rulesDirty
                            ? null
                            : () => _confirmDiscard(),
                        child: const Text('放弃修改'),
                      ),
                      FilledButton(
                        key: const ValueKey('apply-rules'),
                        onPressed:
                            model.showBlockingProgress ||
                                !model.rulesDirty ||
                                !model.proxy.connected ||
                                model.routesConflict
                            ? null
                            : model.applyRules,
                        child: const Text('应用直连规则'),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );

  Widget _queryCard(DesktopWidgets ui) {
    final job = model.routeQuery;
    final result = job?.result;
    final busy = job != null && !job.finished && !model.routeQueryStale;
    final description = switch (result?.matchedBy) {
      'global_mode' => '由全局模式决定，覆盖所有路由规则',
      'target_rule' => '命中精确目标规则，优先于直连规则',
      'direct_rule' => '命中域名或地址直连规则',
      'ip_rule' => '解析后的 IP 命中直连规则',
      'default' => '未命中规则，使用默认代理',
      _ => '',
    };
    return ui.card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 8,
            runSpacing: 4,
            children: [
              const Text(
                '这个目标会怎么走？',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              Text('依据已应用规则', style: TextStyle(color: ui.muted, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('route-query'),
                  controller: _query,
                  onSubmitted: (_) {
                    if (!model.locked && model.proxy.connected && !busy) {
                      _queryRoute();
                    }
                  },
                  decoration: const InputDecoration(hintText: '输入域名或 IP'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed:
                    model.showBlockingProgress || !model.proxy.connected || busy
                    ? null
                    : _queryRoute,
                child: Text(busy ? '查询中…' : '查询路由'),
              ),
            ],
          ),
          if (job != null) ...[
            const SizedBox(height: 10),
            Text(
              '查询目标：${model.routeQueryTarget}',
              style: TextStyle(color: ui.muted, fontSize: 12),
            ),
            if (model.routeQueryStale)
              Text('配置或内核状态已变化，请重新查询。', style: TextStyle(color: ui.warning))
            else if (busy)
              const Text('正在查询路由，可能需要解析 DNS…')
            else if (job.state == 'failed' || result?.code != null)
              Text(
                result?.message ?? '查询失败，请重试',
                style: TextStyle(color: ui.error),
              )
            else if (job.state == 'cancelled')
              const Text('查询已取消')
            else ...[
              SelectableText(
                '${switch (result?.action) {
                  'direct' => '直接连接',
                  'proxy' => '通过代理',
                  'unavailable' => '暂无可用代理',
                  _ => '未返回路由结果',
                }} · $description',
              ),
              if (result?.resolvedAddress != null)
                Text(
                  '解析地址：${result!.resolvedAddress}',
                  style: TextStyle(color: ui.muted, fontSize: 12),
                ),
            ],
          ],
          const SizedBox(height: 8),
          Text(
            model.rulesDirty ? '有未应用草稿；查询仍使用已应用规则。' : '路由结果不代表目标一定可访问。',
            style: TextStyle(color: ui.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _editor(DesktopWidgets ui) => ui.card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${_editingLine != null || _editingTarget != null ? '编辑' : '添加'}${_targets ? '指定目标' : '直连规则'}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('route-host'),
          controller: _host,
          focusNode: _hostFocus,
          readOnly: _targets && _editingTarget != null,
          decoration: const InputDecoration(
            labelText: '目标',
            hintText: '例如 example.com',
          ),
        ),
        const SizedBox(height: 12),
        if (_targets)
          DesktopSelect<String>(
            value: _route,
            options: const [('proxy', '通过代理'), ('direct', '直接连接')],
            onSelected: model.showBlockingProgress
                ? null
                : (value) => setState(() => _route = value!),
          )
        else
          TextField(
            key: const ValueKey('route-note'),
            controller: _note,
            decoration: const InputDecoration(labelText: '备注（可选）'),
          ),
        const SizedBox(height: 8),
        Text(
          _targets
              ? '精确匹配此域名或 IP 的所有端口，不包含子域名。编辑时只修改连接方式。'
              : '域名包含所有子域名；支持 IPv4、IPv6 地址和 CIDR 网段。',
          style: TextStyle(fontSize: 12, color: ui.muted),
        ),
        if (_formError.isNotEmpty)
          Text(_formError, style: TextStyle(color: ui.error)),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton(
              onPressed: () => setState(() => _editing = false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('save-route'),
              onPressed: model.showBlockingProgress ? null : _save,
              child: Text(_targets ? '保存并应用' : '保存到草稿'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _ruleRow(
    DesktopWidgets ui, {
    required String target,
    required String description,
    String? route,
    required VoidCallback onEdit,
    required VoidCallback onRemove,
  }) => Container(
    decoration: BoxDecoration(
      color: ui.panel,
      border: Border(bottom: BorderSide(color: ui.line)),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final text = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              target,
              style: DesktopDesign.monoText.copyWith(color: ui.ink),
            ),
            const SizedBox(height: 3),
            Text(description, style: TextStyle(color: ui.muted, fontSize: 12)),
          ],
        );
        final actionStyle = route == null
            ? const ButtonStyle(animationDuration: Duration.zero)
            : null;
        final actions = Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: [
            if (route != null)
              Text(
                route == 'direct' ? '直连' : '代理',
                style: TextStyle(fontSize: 12, color: ui.muted),
              ),
            TextButton(
              style: actionStyle,
              onPressed: model.showBlockingProgress || model.routesConflict
                  ? null
                  : onEdit,
              child: const Text('编辑'),
            ),
            TextButton(
              style: actionStyle,
              onPressed:
                  model.showBlockingProgress ||
                      model.routesConflict ||
                      route != null && !model.proxy.connected
                  ? null
                  : onRemove,
              child: Text(route == null ? '删除' : '移除指定'),
            ),
          ],
        );
        if (constraints.maxWidth < 420) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              text,
              Align(alignment: Alignment.centerRight, child: actions),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: text),
            const SizedBox(width: 8),
            actions,
          ],
        );
      },
    ),
  );
}
