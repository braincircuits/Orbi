import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/proxy_profile.dart';
import '../../view_models/proxy_view_model.dart';
import '../desktop_theme.dart';
import '../widgets/desktop_widgets.dart';
import '../widgets/configuration_transfer.dart';
import '../widgets/desktop_select.dart';

class ConfigurationPage extends StatefulWidget {
  const ConfigurationPage({super.key, required this.model});
  final ProxyViewModel model;
  @override
  State<ConfigurationPage> createState() => _ConfigurationPageState();
}

class _ConfigurationPageState extends State<ConfigurationPage> {
  final search = TextEditingController();
  final collectionScroll = ScrollController();
  final editorScroll = ScrollController();
  String protocol = 'all';
  bool cards = true;
  bool editorOpen = false;
  int loaded = 12;
  int columns = 1;
  String? switching;
  String? located;
  Timer? locateTimer;
  ProxyViewModel get model => widget.model;
  double get _textScale =>
      math.max(1, MediaQuery.textScalerOf(context).scale(13) / 13);
  double get _cardHeight => 140 * _textScale;
  double get _rowHeight => 64 * _textScale;
  List<ConnectionProfile> get filtered {
    final query = search.text.trim().toLowerCase();
    return model.connectionDrafts
        .where(
          (c) =>
              (protocol == 'all' || c.protocol == protocol) &&
              '${c.name} ${c.endpoint}'.toLowerCase().contains(query),
        )
        .toList();
  }

  @override
  void initState() {
    super.initState();
    collectionScroll.addListener(_loadMore);
  }

  @override
  void dispose() {
    locateTimer?.cancel();
    search.dispose();
    collectionScroll.dispose();
    editorScroll.dispose();
    super.dispose();
  }

  void _loadMore() {
    if (collectionScroll.position.extentAfter < 180 &&
        loaded < filtered.length) {
      setState(() => loaded += 12);
    }
  }

  void _filterChanged() {
    setState(() => loaded = 12);
    if (collectionScroll.hasClients) collectionScroll.jumpTo(0);
  }

  void _edit(String id) {
    model.editConnection(id);
    setState(() => editorOpen = true);
    if (editorScroll.hasClients) editorScroll.jumpTo(0);
  }

  Future<void> _switch(String id) async {
    setState(() => switching = id);
    await model.switchConnection(id);
    if (mounted) setState(() => switching = null);
  }

  void _locate() {
    final id = model.proxy.defaultConnectionId;
    final index = model.connectionDrafts.indexWhere((c) => c.id == id);
    if (index < 0) {
      model.message('当前连接已从草稿移除，撤销修改后可定位', failure: true);
      return;
    }
    model.editConnection(id);
    search.clear();
    setState(() {
      protocol = 'all';
      editorOpen = true;
      loaded = math.max(12, ((index + 1) / 12).ceil() * 12);
      located = id;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !collectionScroll.hasClients) return;
      final offset = cards
          ? (index ~/ columns) * (_cardHeight + 10)
          : index * _rowHeight;
      // 惰性列表的最大范围可能尚未更新，按目标行跳转后由布局校正边界。
      collectionScroll.jumpTo(offset);
    });
    locateTimer?.cancel();
    locateTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => located = null);
    });
  }

  Future<bool> _confirm(String title, String text, String action) async =>
      await showDialog<bool>(
        animationStyle: AnimationStyle.noAnimation,
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final ui = DesktopWidgets(context, model);
    final editing = editorOpen && model.connectionDrafts.isNotEmpty;
    return ui.list('configuration', [
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '连接配置',
                  style: Theme.of(context).textTheme.headlineSmall!
                      .copyWith(fontSize: 22, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  '${model.connectionDrafts.length} 个连接 · 点击卡片切换，点击编辑修改配置',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (model.dirty)
            TextButton(
              onPressed: model.locked
                  ? null
                  : () async {
                      if (await _confirm(
                        '撤销未应用的修改？',
                        '恢复已应用配置，连接、规则和本地代理草稿将被丢弃。当前代理连接不变。',
                        '撤销修改',
                      )) {
                        model.discardDrafts();
                      }
                    },
              child: const Text('撤销修改'),
            ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: model.locked || model.connectionDrafts.length >= 128
                ? null
                : () {
                    model.addConnection();
                    setState(() => editorOpen = true);
                    if (editorScroll.hasClients) editorScroll.jumpTo(0);
                  },
            icon: const Icon(Icons.add),
            label: const Text('添加连接'),
          ),
        ],
      ),
      const SizedBox(height: 12),
      ConfigurationTransfer(model: model, routes: false),
      const SizedBox(height: 18),
      LayoutBuilder(
        builder: (context, constraints) {
          final searchField = KeyedSubtree(
            key: const PageStorageKey('connection-search-scroll'),
            child: TextField(
              key: const ValueKey('connection-search'),
              controller: search,
              style: const TextStyle(fontSize: 13),
              onChanged: (_) => _filterChanged(),
              decoration: InputDecoration(
                hintText: '搜索名称或服务器',
                prefixIcon: const Icon(
                  Icons.search,
                  size: DesktopDesign.actionIconSize,
                ),
                suffixIcon: search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除搜索',
                        onPressed: () {
                          search.clear();
                          _filterChanged();
                        },
                        icon: const Icon(
                          Icons.close,
                          size: DesktopDesign.actionIconSize,
                        ),
                      ),
              ),
            ),
          );
          final controls = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                key: const PageStorageKey('connection-protocol-scroll'),
                width: 108,
                child: DesktopSelect<String>(
                  key: ValueKey('connection-filter-$protocol'),
                  value: protocol,
                  options: const [
                    ('all', '全部协议'),
                    ('http2', 'HTTP/2'),
                    ('http3', 'HTTP/3'),
                  ],
                  onSelected: (value) {
                    protocol = value ?? 'all';
                    _filterChanged();
                  },
                ),
              ),
              const SizedBox(width: 8),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.grid_view, size: 16),
                    label: Text('卡片'),
                  ),
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.view_list_outlined, size: 16),
                    label: Text('列表'),
                  ),
                ],
                selected: {cards},
                showSelectedIcon: false,
                onSelectionChanged: (value) =>
                    setState(() => cards = value.single),
              ),
            ],
          );
          return constraints.maxWidth < 520
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [searchField, const SizedBox(height: 10), controls],
                )
              : Row(
                  children: [
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 260),
                        child: searchField,
                      ),
                    ),
                    const SizedBox(width: 10),
                    controls,
                  ],
                );
        },
      ),
      const SizedBox(height: 14),
      LayoutBuilder(
        builder: (context, constraints) {
          final height = (MediaQuery.sizeOf(context).height - 300).clamp(
            300.0,
            480.0,
          );
          final collection = SizedBox(height: height, child: _browser(ui));
          if (!editing) return collection;
          final editor = SizedBox(height: height, child: _editor(ui));
          if (constraints.maxWidth < 540) {
            return Column(
              children: [collection, const SizedBox(height: 14), editor],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: collection),
              const SizedBox(width: 14),
              SizedBox(
                width: MediaQuery.sizeOf(context).width <= 920 ? 230 : 264,
                child: editor,
              ),
            ],
          );
        },
      ),
    ]);
  }

  Widget _browser(DesktopWidgets ui) => ui.card(
    Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(DesktopDesign.panelRadius),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.hub_outlined, size: 22, color: ui.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '当前连接 · ${model.activeConnection?.name ?? '尚未配置'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Tooltip(
                      message: model.activeConnection?.endpoint ?? '应用连接后在此显示',
                      child: Text(
                        model.activeConnection?.endpoint ?? '应用连接后在此显示',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: model.proxy.defaultConnectionId.isEmpty
                    ? null
                    : _locate,
                icon: const Icon(Icons.my_location_outlined, size: 15),
                label: const Text('定位当前'),
              ),
            ],
          ),
        ),
        const Divider(),
        if (!cards)
          Container(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '连接 / 服务器',
                    style: TextStyle(fontSize: 11, color: ui.muted),
                  ),
                ),
                SizedBox(
                  width: 70,
                  child: Text(
                    '协议',
                    style: TextStyle(fontSize: 11, color: ui.muted),
                  ),
                ),
                SizedBox(
                  width: 38,
                  child: Text(
                    '状态',
                    style: TextStyle(fontSize: 11, color: ui.muted),
                  ),
                ),
              ],
            ),
          ),
        Expanded(child: _collection(ui)),
      ],
    ),
    padding: EdgeInsets.zero,
  );

  Widget _tag(String protocol) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      protocol == 'http2' ? 'HTTP/2' : 'HTTP/3',
      style: TextStyle(
        fontSize: 11,
        color: Theme.of(context).colorScheme.onPrimaryContainer,
      ),
    ),
  );

  Widget _collection(DesktopWidgets ui) {
    final items = filtered;
    if (items.isEmpty) {
      return ui.empty(
        Icons.language,
        model.connectionDrafts.isEmpty ? '添加你的第一个连接' : '没有匹配的连接',
        model.connectionDrafts.isEmpty
            ? '新增连接并填写服务端信息后应用配置。'
            : '换个名称、服务器地址或协议试试。',
      );
    }
    final count = math.min(loaded, items.length);
    return LayoutBuilder(
      builder: (context, constraints) {
        columns = math.max(
          1,
          math.min(
            3,
            ((constraints.maxWidth - 14) / (184 * _textScale)).floor(),
          ),
        );
        return Scrollbar(
          controller: collectionScroll,
          thickness: 4,
          child: CustomScrollView(
            key: const PageStorageKey('connection-collection'),
            controller: collectionScroll,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.all(cards ? 10 : 0),
                sliver: cards
                    ? SliverGrid(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => _connectionCard(ui, items[index]),
                          childCount: count,
                        ),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisExtent: _cardHeight,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                        ),
                      )
                    : SliverFixedExtentList(
                        itemExtent: _rowHeight,
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => Padding(
                            padding: EdgeInsets.zero,
                            child: _connectionCard(ui, items[index]),
                          ),
                          childCount: count,
                        ),
                      ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Text(
                    count < items.length
                        ? '已显示 $count / ${items.length} 个 · 继续向下滚动'
                        : '已显示全部 ${items.length} 个连接',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _connectionCard(DesktopWidgets ui, ConnectionProfile connection) {
    final applied = model.proxy.appliedProfile?.connections
        .where((c) => c.id == connection.id)
        .firstOrNull;
    final pending =
        applied == null ||
        applied.name != connection.name ||
        !mapEquals(applied.values, connection.values);
    final current = connection.id == model.proxy.defaultConnectionId;
    final selected = connection.id == model.editingId;
    final canSwitch =
        !model.locked && switching == null && !current && applied != null;
    final identity = _connectionIdentity(ui, connection, pending);
    return Material(
      key: ValueKey('connection-${connection.id}'),
      clipBehavior: Clip.antiAlias,
      color: current
          ? Color.alphaBlend(ui.accent.withValues(alpha: .07), ui.panel)
          : ui.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(
          cards ? DesktopDesign.panelRadius : 0,
        ),
        side: BorderSide(
          color: current || selected || located == connection.id
              ? ui.accent
              : ui.line,
          width: current || located == connection.id ? 2 : 1,
        ),
      ),
      child: cards
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: InkWell(
                    key: ValueKey('card-body-${connection.id}'),
                    onTap: canSwitch ? () => _switch(connection.id) : null,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              _tag(connection.protocol),
                              const Spacer(),
                              if (current) ...[
                                Icon(Icons.check, size: 14, color: ui.success),
                                const SizedBox(width: 3),
                                Text(
                                  '使用中',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: ui.success,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 10),
                          identity,
                        ],
                      ),
                    ),
                  ),
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: current
                            ? Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Text(
                                  '当前连接',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: ui.muted,
                                  ),
                                ),
                              )
                            : TextButton(
                                key: ValueKey('card-switch-${connection.id}'),
                                onPressed: canSwitch
                                    ? () => _switch(connection.id)
                                    : null,
                                style: TextButton.styleFrom(
                                  alignment: Alignment.centerLeft,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                ),
                                child: Text(
                                  switching == connection.id
                                      ? '切换中…'
                                      : applied == null
                                      ? '待应用'
                                      : '设为当前',
                                ),
                              ),
                      ),
                      TextButton.icon(
                        key: ValueKey('edit-${connection.id}'),
                        onPressed: model.locked
                            ? null
                            : () => _edit(connection.id),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                        ),
                        icon: const Icon(Icons.edit_outlined, size: 15),
                        label: const Text('编辑'),
                      ),
                    ],
                  ),
                ),
              ],
            )
          : Semantics(
              button: true,
              selected: selected,
              label: '编辑 ${connection.name}${current ? '，当前默认连接' : ''}',
              child: InkWell(
                key: ValueKey('edit-${connection.id}'),
                onTap: model.locked ? null : () => _edit(connection.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Expanded(child: identity),
                      const SizedBox(width: 8),
                      _tag(connection.protocol),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 38,
                        child: Text(
                          current ? '当前' : '空闲',
                          style: TextStyle(
                            fontSize: 11,
                            color: current ? ui.success : ui.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _connectionIdentity(
    DesktopWidgets ui,
    ConnectionProfile connection,
    bool pending,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Text(
        '${connection.name}${pending ? ' •' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontWeight: cards ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        connection.values['server.host']!.isEmpty
            ? '尚未填写服务端'
            : connection.endpoint,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: ui.muted),
      ),
    ],
  );

  Widget _editor(DesktopWidgets ui) {
    if (model.connectionDrafts.isEmpty) return const SizedBox.shrink();
    final canRemove =
        model.editingId != model.proxy.defaultConnectionId &&
        !(model.editingId == model.defaultId &&
            (model.connectionDrafts.length > 1 || model.proxy.running));
    final fields = DesktopWidgets(context, model, compactForms: true);
    return ui.card(
      Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        model.editingConnection.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '连接详情',
                        style: TextStyle(fontSize: 11, color: ui.muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '收起编辑面板（保留草稿）',
                  onPressed: () => setState(() => editorOpen = false),
                  icon: const Icon(Icons.last_page, size: 17),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: Scrollbar(
              controller: editorScroll,
              thickness: 4,
              child: SingleChildScrollView(
                key: const PageStorageKey('connection-editor'),
                controller: editorScroll,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ..._editorFields(fields),
                    Wrap(
                      spacing: 4,
                      children: [
                        TextButton(
                          key: ValueKey('switch-${model.editingId}'),
                          onPressed:
                              model.locked ||
                                  switching != null ||
                                  model.editingId ==
                                      model.proxy.defaultConnectionId ||
                                  !(model.proxy.appliedProfile?.connections.any(
                                        (c) => c.id == model.editingId,
                                      ) ??
                                      false)
                              ? null
                              : () => _switch(model.editingId),
                          child: Text(
                            switching != null
                                ? '切换中…'
                                : model.editingId ==
                                      model.proxy.defaultConnectionId
                                ? '✓ 当前默认'
                                : '设为默认连接',
                          ),
                        ),
                        TextButton(
                          onPressed: model.locked
                              ? null
                              : () => model.navigate(5),
                          child: const Text('诊断'),
                        ),
                        TextButton(
                          onPressed: !canRemove || model.locked
                              ? null
                              : () async {
                                  if (await _confirm(
                                    '移除连接？',
                                    '仅从草稿移除，应用配置后生效。',
                                    '移除连接',
                                  )) {
                                    model.removeConnection();
                                  }
                                },
                          style: TextButton.styleFrom(
                            foregroundColor: ui.error,
                          ),
                          child: const Text('删除'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  model.dirty ? '有未应用的编辑' : '已保存',
                  style: TextStyle(
                    fontSize: 11,
                    color: model.dirty ? ui.warning : ui.muted,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton(
                      onPressed: !model.dirty || model.locked
                          ? null
                          : () async {
                              if (await _confirm(
                                '撤销未应用的修改？',
                                '恢复已应用配置，连接、规则和本地代理草稿将被丢弃。当前代理连接不变。',
                                '撤销修改',
                              )) {
                                model.discardDrafts();
                              }
                            },
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        minimumSize: const Size(
                          32,
                          DesktopDesign.controlHeight,
                        ),
                      ),
                      child: const Text('还原'),
                    ),
                    const Spacer(),
                    OutlinedButton(
                      onPressed: model.locked
                          ? null
                          : model.validateConfiguration,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(
                          40,
                          DesktopDesign.controlHeight,
                        ),
                      ),
                      child: const Text('校验'),
                    ),
                    const SizedBox(width: 5),
                    FilledButton(
                      onPressed: model.locked ? null : model.apply,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: const Text('应用并保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      padding: EdgeInsets.zero,
    );
  }

  List<Widget> _editorFields(DesktopWidgets ui) => [
    ui.formRow(
      '连接名称',
      TextField(
        key: const ValueKey('connection-name'),
        controller: model.connectionName,
        onChanged: model.changed,
        decoration: const InputDecoration(hintText: '给连接起一个名称'),
      ),
    ),
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ui.formRow(
            '传输协议',
            DesktopSelect<String>(
              key: const ValueKey('protocol-selector'),
              value: model.fields['protocol']!.text,
              options: const [('http2', 'HTTP/2'), ('http3', 'HTTP/3')],
              onSelected: (value) {
                if (value == null) return;
                model.fields['protocol']!.text = value;
                model.changed(value);
              },
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: ui.field('server.port')),
      ],
    ),
    ui.field('server.host', hint: 'proxy.example.com'),
    ui.field('username', hint: '共享密码模式可留空'),
    ui.field(
      'password',
      hint: model.editingConnection.hasPassword ? '已设置，留空保留原密码' : '输入代理密码',
    ),

    Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Text(
        '密码留空保留已设置的密码。',
        style: TextStyle(fontSize: 11, color: ui.muted),
      ),
    ),
    ui.field('tls.serverName', hint: '留空时使用服务端地址', help: '填写证书 SAN 中的名称'),
    ui.fileField(
      '信任证书',
      'certificate',
      model.fields['tls.ca']!,
      '使用 Java 默认信任链',
    ),
    ExpansionTile(
      key: const PageStorageKey('connection-parameters'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      shape: const Border(),
      collapsedShape: const Border(),
      title: const Text('连接参数', style: TextStyle(fontSize: 13)),
      children: [
        ui.field('connectTimeoutMillis'),
        ui.field('idleTimeoutSeconds'),
        ui.field('maxStreams'),
      ],
    ),
  ];
}
