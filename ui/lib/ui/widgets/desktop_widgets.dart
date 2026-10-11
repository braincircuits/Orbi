import 'package:flutter/material.dart';

import '../desktop_theme.dart';

import '../../models/proxy_profile.dart';
import '../../view_models/proxy_view_model.dart';

class DesktopWidgets {
  DesktopWidgets(this.context, this.model, {this.compactForms = false});
  final bool compactForms;
  final BuildContext context;
  final ProxyViewModel model;
  Color get ink => Theme.of(context).colorScheme.onSurface;
  Color get muted => Theme.of(context).colorScheme.onSurfaceVariant;
  Color get accent => Theme.of(context).colorScheme.primary;
  Color get line => Theme.of(context).colorScheme.outlineVariant;
  Color get panel => Theme.of(context).colorScheme.surfaceContainerLowest;
  Color get success => DesktopDesign.success(Theme.of(context).brightness);
  Color get warning => DesktopDesign.warning(Theme.of(context).brightness);
  Color get error => Theme.of(context).colorScheme.error;
  Widget dot(bool active, {double size = 7}) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: active ? success : muted.withValues(alpha: .5),
    ),
  );
  Widget card(
    Widget child, {
    EdgeInsets padding = const EdgeInsets.all(DesktopDesign.panelPadding),
  }) => Card(
    child: Padding(padding: padding, child: child),
  );
  Widget notice(String text, IconData icon, {bool warning = false}) =>
      Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: (warning ? this.warning : muted).withValues(alpha: .06),
          borderRadius: BorderRadius.circular(DesktopDesign.controlRadius),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              color: warning ? this.warning : muted,
              size: DesktopDesign.detailIconSize,
            ),
            const SizedBox(width: DesktopDesign.spacing),
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: 12, height: 1.5, color: muted),
              ),
            ),
          ],
        ),
      );
  Widget list(String key, List<Widget> children) => ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
    child: ListView(
      key: PageStorageKey(key),
      padding: EdgeInsets.zero,
      children: children,
    ),
  );
  Widget caption(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, height: 1.5, color: muted),
    ),
  );
  Widget heading(String text) => Padding(
    padding: const EdgeInsets.only(bottom: DesktopDesign.spacing),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
  Widget pageHeading(String title, String subtitle) => Padding(
    padding: const EdgeInsets.only(bottom: DesktopDesign.sectionSpacing),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.headlineSmall!
              .copyWith(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: DesktopDesign.spacing / 2),
        Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
  Widget section(String title, List<Widget> rows, {String? footer}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      heading(title),
      card(
        Column(
          children: [
            for (final item in rows.indexed) ...[
              if (item.$1 > 0) const Divider(),
              item.$2,
            ],
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      ),
      if (footer != null) caption(footer) else const SizedBox(height: 20),
    ],
  );
  Widget formRow(String label, Widget control, {String? help}) => Padding(
    // 隔离输入框滚动位置，避免读取到父级展开项的布尔状态或页面滚动位置。
    key: PageStorageKey('form-row-$label'),
    padding: EdgeInsets.symmetric(vertical: compactForms ? 7 : 9),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final field = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            control,
            if (help != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(help, style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        );
        if (constraints.maxWidth < 420) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: compactForms
                    ? TextStyle(fontSize: 11, color: muted)
                    : Theme.of(context).textTheme.bodyMedium,
              ),
              SizedBox(height: compactForms ? 5 : 8),
              field,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: constraints.maxWidth < 490 ? 108 : 138,
              child: Padding(
                padding: const EdgeInsets.only(top: 7, right: 12),
                child: Text(
                  label,
                  style: TextStyle(
                    color: ink,
                    fontSize: DesktopDesign.bodyFontSize,
                  ),
                ),
              ),
            ),
            Expanded(child: field),
          ],
        );
      },
    ),
  );
  Widget field(String key, {String? hint, String? help}) => formRow(
    ProxyProfile.labels[key]!,
    Semantics(
      label: ProxyProfile.labels[key],
      textField: true,
      child: TextField(
        key: ValueKey('field-$key'),
        controller: model.fields[key],
        onChanged: model.changed,
        style: const TextStyle(fontSize: DesktopDesign.bodyFontSize),
        obscureText: key == 'password' && !model.showPassword,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          hintText: hint,
          suffixIconConstraints: const BoxConstraints(
            minHeight: DesktopDesign.controlHeight,
            minWidth: DesktopDesign.controlHeight,
          ),
          suffixIcon: key == 'password'
              ? IconButton(
                  tooltip: model.showPassword ? '隐藏密码' : '显示密码',
                  onPressed: () => model.update(
                    () => model.showPassword = !model.showPassword,
                  ),
                  icon: Icon(
                    model.showPassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: DesktopDesign.actionIconSize,
                  ),
                )
              : null,
        ),
      ),
    ),
    help: help,
  );
  Widget fileField(
    String label,
    String kind,
    TextEditingController controller,
    String hint,
  ) => formRow(
    label,
    Row(
      children: [
        Expanded(
          child: Semantics(
            label: label,
            textField: true,
            child: TextField(
              controller: controller,
              style: const TextStyle(fontSize: DesktopDesign.bodyFontSize),
              onChanged: kind == 'java' || kind == 'jar'
                  ? (_) => model.update(() {})
                  : model.changed,
              decoration: InputDecoration(hintText: hint),
            ),
          ),
        ),
        const SizedBox(width: DesktopDesign.spacing),
        Tooltip(
          message: '选择$label',
          child: OutlinedButton(
            onPressed: () => model.choose(kind, controller),
            child: const Text('选取…'),
          ),
        ),
      ],
    ),
  );

  Widget detail(String label, String value) => formRow(
    label,
    Padding(
      padding: const EdgeInsets.only(top: 7),
      child: SelectableText(
        value,
        style: TextStyle(fontSize: DesktopDesign.bodyFontSize, color: ink),
      ),
    ),
  );

  Widget empty(IconData icon, String title, String subtitle) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: muted.withValues(alpha: .55), size: 38),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: ink,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: muted, fontSize: 12, height: 1.5),
          ),
        ],
      ),
    ),
  );
}
