import '../../models/kernel_status.dart';

import 'package:flutter/material.dart';

import '../../view_models/proxy_view_model.dart';
import '../widgets/desktop_widgets.dart';
import '../widgets/desktop_select.dart';
import '../desktop_theme.dart';

class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({super.key, required this.model});
  final ProxyViewModel model;
  @override
  Widget build(BuildContext context) =>
      _content(context, DesktopWidgets(context, model));
  Widget _content(BuildContext context, DesktopWidgets ui) {
    const states = {
      'queued': '排队中',
      'running': '执行中',
      'succeeded': '成功',
      'failed': '失败',
      'cancelled': '已取消',
    };
    const stages = {
      'queued': '准备',
      'configuration': '配置校验',
      'dns': '域名解析',
      'tcp': 'TCP 连接',
      'tls': 'TLS 握手',
      'http2_settings': 'HTTP/2 协商',
      'quic_tls': 'QUIC / TLS 握手',
      'connect': 'CONNECT 认证及隧道',
      'routing': '路由匹配',
    };
    // 概览的出口 IP、延迟和网站检测有各自的结果区域，不混入手动连接诊断。
    final diagnostics = model.proxy.operations.values
        .where((job) => job.context['kind'] == null)
        .toList()
        .reversed;
    final selectedId =
        model.proxy.connections.any((c) => c.id == model.testProfileId)
        ? model.testProfileId
        : model.proxy.defaultConnectionId;
    return ui.list('diagnostics', [
      Text('连接诊断', style: Theme.of(context).textTheme.titleLarge),
      ui.caption('使用独立会话测试代理认证及目标 CONNECT'),
      ui.section('检查连接', [
        if (model.proxy.connections.isNotEmpty)
          ui.formRow(
            '测试连接',
            DesktopSelect<String>(
              key: ValueKey('test-$selectedId'),
              value: selectedId,
              options: [
                for (final c in model.proxy.connections)
                  (c.id, '${c.name} · ${c.protocol}'),
              ],
              onSelected: (value) =>
                  model.update(() => model.testProfileId = value),
            ),
          ),
        ui.formRow(
          '测试目标',
          TextField(
            controller: model.target,
            decoration: const InputDecoration(
              hintText: 'www.google.com:443 或 [::1]:443',
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: model.proxy.connected
                      ? () => model.diagnose()
                      : null,
                  child: const Text('查询路由'),
                ),
                FilledButton(
                  onPressed:
                      model.proxy.connected &&
                          model.proxy.defaultConnectionId.isNotEmpty
                      ? () => model.diagnose(profileId: selectedId)
                      : null,
                  child: const Text('测试所选连接'),
                ),
              ],
            ),
          ),
        ),
      ], footer: '使用已应用配置和独立会话，不会切换实际代理。成功表示代理认证及目标 TCP 隧道建立，不代表网站页面可用。'),
      ui.heading('诊断记录'),
      if (diagnostics.isEmpty)
        ui.card(
          ui.empty(Icons.monitor_heart_outlined, '尚无诊断记录', '运行一次测试，查看连接阶段与耗时。'),
        ),
      for (final job in diagnostics)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: ui.card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      job.state == 'succeeded'
                          ? Icons.check_circle
                          : job.state == 'failed'
                          ? Icons.error_outline
                          : Icons.schedule,
                      size: DesktopDesign.detailIconSize,
                      color: job.state == 'succeeded'
                          ? ui.success
                          : job.state == 'failed'
                          ? Theme.of(context).colorScheme.error
                          : ui.accent,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        '${states[job.state] ?? job.state} · ${stages[job.stage] ?? job.stage}',
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                    ),
                    Text(
                      '${job.elapsedMillis} ms',
                      style: TextStyle(color: ui.muted, fontSize: 12),
                    ),
                    if ({'queued', 'running'}.contains(job.state))
                      TextButton(
                        onPressed: () => model.cancelDiagnostic(job.id),
                        child: const Text('取消'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                SelectableText(
                  _diagnosticResult(job),
                  style: TextStyle(fontSize: 12, height: 1.6, color: ui.ink),
                ),
                if (job.stages.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final stage in job.stages)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: ui.muted.withValues(alpha: .08),
                              borderRadius: BorderRadius.circular(
                                DesktopDesign.controlRadius,
                              ),
                            ),
                            child: Text(
                              '${stages[stage.stage] ?? stage.stage} ${stage.elapsedMillis} ms',
                              style: TextStyle(color: ui.muted, fontSize: 11),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
    ]);
  }

  String _diagnosticResult(DiagnosticOperation job) {
    final result = job.result;
    if (result.code != null) {
      return '${result.message}\n错误代码：${result.code}';
    }
    if (result.tunnelEstablished == true) {
      return '代理认证通过，已建立到 ${result.target} 的 TCP 隧道';
    }
    if (result.action != null) {
      const actions = {
        'direct': '直接连接',
        'proxy': '通过代理',
        'unavailable': '暂无可用代理',
      };
      const reasons = {
        'direct_rule': '域名或地址规则',
        'target_rule': '精确目标规则',
        'global_mode': '全局模式',
        'ip_rule': '解析后的 IP 规则',
        'default': '默认路由',
      };
      return '${actions[result.action] ?? result.action} · ${reasons[result.matchedBy] ?? result.matchedBy}${result.resolvedAddress == null ? '' : '\n解析地址：${result.resolvedAddress}'}';
    }
    return switch (job.state) {
      'cancelled' => '诊断已取消',
      'failed' => '诊断失败',
      'succeeded' => '诊断已完成',
      _ => '等待诊断结果',
    };
  }
}
