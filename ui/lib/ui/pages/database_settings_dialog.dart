import 'package:flutter/material.dart';

import '../../models/database_settings.dart';
import '../../view_models/proxy_view_model.dart';
import '../widgets/desktop_select.dart';

/// 数据库启动设置独立保存，不参与代理配置的“应用并保存”。
class DatabaseSettingsDialog extends StatefulWidget {
  const DatabaseSettingsDialog({super.key, required this.model});
  final ProxyViewModel model;
  @override
  State<DatabaseSettingsDialog> createState() => _DatabaseSettingsDialogState();
}

class _DatabaseSettingsDialogState extends State<DatabaseSettingsDialog> {
  final _fields = <String, TextEditingController>{};
  late String _type;
  late bool _verifyTls;
  bool _showPassword = false;
  String _error = '';
  @override
  void initState() {
    super.initState();
    final value = widget.model.proxy.databaseSettings;
    _type = value.type;
    _verifyTls = value.verifyTls;
    final fields = {
      'path': value.path.isEmpty ? widget.model.proxy.configPath : value.path,
      'host': value.host,
      'port': value.port,
      'database': value.database,
      'username': value.username,
      'password': value.password,
    };
    for (final entry in fields.entries) {
      _fields[entry.key] = TextEditingController(text: entry.value);
    }
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  DatabaseSettings _settings() => DatabaseSettings(
    type: _type,
    path: _fields['path']!.text.trim(),
    host: _fields['host']!.text.trim(),
    port: _fields['port']!.text.trim(),
    database: _fields['database']!.text.trim(),
    username: _fields['username']!.text.trim(),
    password: _fields['password']!.text,
    verifyTls: _verifyTls,
  );
  Future<void> _save() async {
    try {
      final settings = _settings();
      settings.validate();
      setState(() => _error = '');
      await widget.model.changeDatabase(settings);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  Widget _field(
    String key,
    String label, {
    String? hint,
    bool password = false,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextFormField(
      key: ValueKey('database-$key'),
      controller: _fields[key],
      enabled: !widget.model.locked,
      obscureText: password && !_showPassword,
      autocorrect: false,
      enableSuggestions: !password,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixIcon: password
            ? IconButton(
                tooltip: _showPassword ? '隐藏密码' : '显示密码',
                onPressed: widget.model.locked
                    ? null
                    : () => setState(() => _showPassword = !_showPassword),
                icon: Icon(
                  _showPassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 18,
                ),
              )
            : null,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final model = widget.model;
      final block = model.proxy.tunEnabled
          ? '请先关闭虚拟网卡，再切换数据库。'
          : model.dirty && model.proxy.connected
          ? '请先应用或放弃代理配置草稿，再切换数据库。'
          : '';
      return Dialog(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 660),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '数据库',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭数据库设置',
                    onPressed: model.locked
                        ? null
                        : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        model.proxy.connected
                            ? '当前使用：${DatabaseSettings.labels[model.proxy.storageBackend] ?? '未确认'}'
                            : '内核未连接，可修改数据库设置后重试',
                      ),
                      const SizedBox(height: 12),
                      DesktopSelect<String>(
                        key: const ValueKey('database-type'),
                        value: _type,
                        options: DatabaseSettings.labels.entries
                            .map((e) => (e.key, e.value))
                            .toList(),
                        onSelected: model.locked
                            ? null
                            : (value) {
                                if (value == null) return;
                                setState(() {
                                  _type = value;
                                  if (value != 'sqlite') {
                                    _fields['port']!.text = value == 'mysql'
                                        ? '3306'
                                        : '5432';
                                  }
                                  _error = '';
                                });
                              },
                      ),
                      if (_type == 'sqlite')
                        _field(
                          'path',
                          'SQLite 文件路径',
                          hint: model.proxy.configPath,
                        )
                      else ...[
                        _field('host', '数据库地址', hint: '例如 10.0.0.10'),
                        _field('port', '端口'),
                        _field('database', '数据库名称'),
                        _field('username', '用户名'),
                        _field('password', '密码', password: true),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('使用 TLS 并验证服务器证书'),
                          value: _verifyTls,
                          onChanged: model.locked
                              ? null
                              : (value) =>
                                    setState(() => _verifyTls = value ?? true),
                        ),
                        Text(
                          '请提前创建独立数据库。密码保存在仅当前用户可访问的本机启动配置文件中。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 14),
                      const Text(
                        '保存将重启内核并断开现有连接。连接配置、凭据、路由和访问记录会整体使用所选数据库；新库从空配置开始，原数据库的数据保留，不自动迁移。',
                      ),
                      if (block.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            block,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_error.isNotEmpty)
                Text(
                  _error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              StreamBuilder<UiMessage>(
                stream: model.messages.stream,
                builder: (context, snapshot) {
                  final message = snapshot.data;
                  if (message == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      message.text,
                      style: TextStyle(
                        color: message.failure
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  );
                },
              ),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const ValueKey('save-database'),
                  onPressed: model.locked || block.isNotEmpty ? null : _save,
                  child: Text(model.working ? '正在重启内核…' : '保存并重启内核'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
