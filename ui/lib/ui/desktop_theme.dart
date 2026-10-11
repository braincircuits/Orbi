import 'package:flutter/material.dart';

/// macOS 风格的系统字体优先顺序、尺寸与间距，控件结构不随平台改变。
abstract final class DesktopDesign {
  static const fontFamily = '.AppleSystemUIFont';
  static const fontFamilyFallback = ['PingFang SC', 'Segoe UI', 'NotoSansSC'];
  static const bodyFontSize = 13.0;
  static const monoFontFamily = 'RobotoMono';
  static const spacing = 8.0;
  static const controlHeight = 30.0;
  static const inputPadding = EdgeInsets.symmetric(horizontal: 9, vertical: 5);
  static const inputIconConstraints = BoxConstraints.tightFor(
    width: controlHeight,
    height: controlHeight,
  );
  static const overviewControlHeight = 36.0;
  static const overviewToggleWidth = 90.0;
  static const overviewModeWidth = 64.0;
  static const menuWidth = 320.0;
  static const actionIconSize = 17.0;
  static const detailIconSize = 16.0;
  static const navigationIconSize = 16.0;
  static const controlRadius = 6.0;
  static const panelRadius = 10.0;
  static const toolbarHeight = 56.0;
  static const contentMaxWidth = 1200.0;
  static const navigationWidth = 184.0;
  static const sectionSpacing = spacing * 3;
  static const panelPadding = spacing * 2;
  static double pageInset(double width) => width < 760 ? 18 : 28;
  // 蓝色略深于系统默认强调色，保证白色按钮文字满足 4.5:1 对比度。
  static const applyAction = Color(0xFF006FE6);
  static Color trafficSend(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xFF56CEDC)
      : const Color(0xFF0096AA);
  static Color trafficReceive(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xFFB7A4F4)
      : const Color(0xFF7C69CB);
  static const monoText = TextStyle(
    fontFamily: monoFontFamily,
    fontFamilyFallback: [fontFamily, ...fontFamilyFallback],
    fontSize: 13,
    height: 1.6,
  );
  static Color success(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xFFA0D7B2)
      : const Color(0xFF287548);
  static Color warning(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xFFF0C66F)
      : const Color(0xFF8C6200);
}

/// 基于 Material 组件的 macOS 风格桌面主题；浅色、深色使用相同的排版和控件尺寸。
ThemeData desktopTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF006FE6),
        brightness: brightness,
      ).copyWith(
        primary: dark ? const Color(0xFF64A9FF) : const Color(0xFF006FE6),
        onPrimary: dark ? const Color(0xFF08294F) : Colors.white,
        primaryContainer: dark
            ? const Color(0xFF34465E)
            : const Color(0xFFE5EFFF),
        onPrimaryContainer: dark
            ? const Color(0xFFBDD8FF)
            : const Color(0xFF006FE6),
        surface: dark ? const Color(0xFF202020) : const Color(0xFFF5F5F5),
        surfaceContainerLowest: dark ? const Color(0xFF2B2B2B) : Colors.white,
        surfaceContainerLow: dark
            ? const Color(0xFF292929)
            : const Color(0xFFEDEDEC),
        surfaceContainer: dark
            ? const Color(0xFF292929)
            : const Color(0xFFEDEDEC),
        surfaceContainerHigh: dark
            ? const Color(0xFF383838)
            : const Color(0xFFE5E5E5),
        surfaceContainerHighest: dark
            ? const Color(0xFF424242)
            : const Color(0xFFDCDCDC),
        onSurface: dark ? const Color(0xFFF2F2F2) : const Color(0xFF242424),
        onSurfaceVariant: dark
            ? const Color(0xFFB0B0B0)
            : const Color(0xFF6B6B6B),
        outline: dark ? const Color(0xFF606060) : const Color(0xFFBEBEBE),
        outlineVariant: dark
            ? const Color(0xFF414141)
            : const Color(0xFFDDDDDD),
        secondaryContainer: dark
            ? const Color(0xFF34465E)
            : const Color(0xFFE5EFFF),
        onSecondaryContainer: dark
            ? const Color(0xFFBDD8FF)
            : const Color(0xFF006FE6),
      );
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(DesktopDesign.controlRadius),
  );
  final button = ButtonStyle(
    iconSize: const WidgetStatePropertyAll(DesktopDesign.actionIconSize),
    minimumSize: const WidgetStatePropertyAll(
      Size(0, DesktopDesign.controlHeight),
    ),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 11, vertical: 5),
    ),
    shape: WidgetStatePropertyAll(shape),
    textStyle: const WidgetStatePropertyAll(
      TextStyle(
        fontFamily: DesktopDesign.fontFamily,
        fontFamilyFallback: DesktopDesign.fontFamilyFallback,
        fontSize: DesktopDesign.bodyFontSize,
        fontWeight: FontWeight.w400,
      ),
    ),
    visualDensity: VisualDensity.standard,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
  OutlineInputBorder inputBorder(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(DesktopDesign.controlRadius),
        borderSide: BorderSide(color: color, width: width),
      );
  final menuStyle = MenuStyle(
    backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLowest),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: const WidgetStatePropertyAll(2),
    shadowColor: WidgetStatePropertyAll(Colors.black.withValues(alpha: .16)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
    shape: WidgetStatePropertyAll(shape),
    side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
  );
  return ThemeData(
    useMaterial3: true,
    // 通过组件主题统一视觉，保留真实宿主的文本编辑与键盘行为。
    brightness: brightness,
    fontFamily: DesktopDesign.fontFamily,
    fontFamilyFallback: DesktopDesign.fontFamilyFallback,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.compact,
    splashFactory: NoSplash.splashFactory,
    focusColor: scheme.primary.withValues(alpha: .16),
    hoverColor: scheme.primary.withValues(alpha: .06),
    textTheme: TextTheme(
      headlineSmall: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      headlineMedium: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      bodyLarge: TextStyle(
        fontSize: DesktopDesign.bodyFontSize,
        height: 20 / DesktopDesign.bodyFontSize,
        color: scheme.onSurface,
      ),
      bodyMedium: TextStyle(
        fontSize: DesktopDesign.bodyFontSize,
        height: 1.5,
        color: scheme.onSurface,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        height: 1.5,
        color: scheme.onSurfaceVariant,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      labelSmall: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      labelLarge: TextStyle(
        fontSize: DesktopDesign.bodyFontSize,
        fontWeight: FontWeight.w400,
        color: scheme.onSurface,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: button),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: button.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? scheme.surfaceContainerLow
              : scheme.surfaceContainerLowest,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? scheme.onSurface.withValues(alpha: .38)
              : scheme.onSurface,
        ),
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.disabled)
                ? scheme.outlineVariant.withValues(alpha: .5)
                : scheme.outlineVariant,
          ),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: button),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: button.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? dark
                    ? scheme.outline
                    : scheme.surfaceContainerLowest
              : scheme.surfaceContainerHigh,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? scheme.onSurface.withValues(alpha: .38)
              : scheme.onSurface,
        ),
        // SegmentedButton 内部最小高度为 40，通过共享密度统一到桌面控件高度。
        visualDensity: const VisualDensity(vertical: -2.5),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 11),
        ),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        iconSize: const WidgetStatePropertyAll(DesktopDesign.actionIconSize),
        minimumSize: const WidgetStatePropertyAll(
          Size.square(DesktopDesign.controlHeight),
        ),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
        shape: WidgetStatePropertyAll(shape),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      visualDensity: VisualDensity.standard,
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerLowest,
      constraints: const BoxConstraints(minHeight: DesktopDesign.controlHeight),
      contentPadding: DesktopDesign.inputPadding,
      prefixIconConstraints: DesktopDesign.inputIconConstraints,
      suffixIconConstraints: DesktopDesign.inputIconConstraints,
      prefixIconColor: scheme.onSurfaceVariant,
      suffixIconColor: scheme.onSurfaceVariant,
      border: inputBorder(scheme.outlineVariant),
      enabledBorder: inputBorder(scheme.outlineVariant),
      focusedBorder: inputBorder(scheme.primary, 2),
      errorBorder: inputBorder(scheme.error),
      focusedErrorBorder: inputBorder(scheme.error, 2),
      hintStyle: TextStyle(
        fontSize: DesktopDesign.bodyFontSize,
        color: scheme.onSurfaceVariant,
      ),
      helperMaxLines: 3,
    ),
    cardTheme: CardThemeData(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DesktopDesign.panelRadius),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    drawerTheme: const DrawerThemeData(shape: RoundedRectangleBorder()),
    navigationDrawerTheme: NavigationDrawerThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      tileHeight: 34,
      indicatorSize: const Size(164, 32),
      indicatorShape: shape,
      indicatorColor: scheme.onSurface.withValues(alpha: dark ? .10 : .08),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: DesktopDesign.fontFamily,
          fontFamilyFallback: DesktopDesign.fontFamilyFallback,
          fontSize: DesktopDesign.bodyFontSize,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w500
              : FontWeight.w400,
          color: scheme.onSurface,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: DesktopDesign.navigationIconSize,
          color: scheme.primary,
        ),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: .5,
      space: 1,
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: TextStyle(
        fontSize: DesktopDesign.bodyFontSize,
        color: scheme.onSurface,
      ),
      inputDecorationTheme: InputDecorationThemeData(
        visualDensity: VisualDensity.standard,
        isDense: true,
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        constraints: const BoxConstraints(
          minHeight: DesktopDesign.controlHeight,
        ),
        contentPadding: DesktopDesign.inputPadding,
        suffixIconConstraints: DesktopDesign.inputIconConstraints,
        suffixIconColor: scheme.onSurfaceVariant,
        border: inputBorder(scheme.outlineVariant),
        enabledBorder: inputBorder(scheme.outlineVariant),
        focusedBorder: inputBorder(scheme.primary, 2),
      ),
      menuStyle: menuStyle,
    ),
    menuTheme: MenuThemeData(style: menuStyle),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
        maximumSize: const WidgetStatePropertyAll(Size(double.infinity, 36)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12),
        ),
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontFamily: DesktopDesign.fontFamily,
            fontFamilyFallback: DesktopDesign.fontFamilyFallback,
            fontSize: DesktopDesign.bodyFontSize,
          ),
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? scheme.onSurface.withValues(alpha: .38)
              : scheme.onSurface,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.focused)
              ? scheme.primary.withValues(alpha: .06)
              : Colors.transparent,
        ),
        overlayColor: WidgetStatePropertyAll(
          scheme.primary.withValues(alpha: .06),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainer,
      textStyle: TextStyle(
        fontFamily: DesktopDesign.fontFamily,
        fontFamilyFallback: DesktopDesign.fontFamilyFallback,
        fontSize: DesktopDesign.bodyFontSize,
        color: scheme.onSurface,
      ),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 400),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbVisibility: const WidgetStatePropertyAll(true),
      thickness: const WidgetStatePropertyAll(8),
      radius: const Radius.circular(DesktopDesign.controlRadius),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => scheme.onSurfaceVariant.withValues(
          alpha:
              states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.dragged)
              ? .65
              : .35,
        ),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: scheme.primary,
      selectionColor: scheme.primary.withValues(alpha: .25),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DesktopDesign.panelRadius),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.surfaceContainerLowest,
      contentTextStyle: TextStyle(
        fontFamily: DesktopDesign.fontFamily,
        fontFamilyFallback: DesktopDesign.fontFamilyFallback,
        color: scheme.onSurface,
        fontSize: DesktopDesign.bodyFontSize,
        height: 1.5,
      ),
      closeIconColor: scheme.onSurfaceVariant,
      showCloseIcon: true,
      elevation: 3,
      shape: shape,
    ),
  );
}
