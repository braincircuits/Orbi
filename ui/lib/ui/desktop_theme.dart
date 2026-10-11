import 'package:flutter/material.dart';

/// 共用原型的系统字体优先顺序、尺寸与间距，控件结构不随平台改变。
abstract final class DesktopDesign {
  static const fontFamily = '.AppleSystemUIFont';
  static const fontFamilyFallback = ['PingFang SC', 'Segoe UI', 'NotoSansSC'];
  static const bodyFontSize = 13.0;
  static const monoFontFamily = 'RobotoMono';
  static const spacing = 8.0;
  static const controlHeight = 30.0;
  static const overviewControlHeight = 36.0;
  static const overviewToggleWidth = 90.0;
  static const overviewModeWidth = 64.0;
  static const menuWidth = 320.0;
  static const actionIconSize = 17.0;
  static const detailIconSize = 16.0;
  static const navigationIconSize = 16.0;
  static const controlRadius = 6.0;
  static const panelRadius = 9.0;
  static const toolbarHeight = 56.0;
  static const contentMaxWidth = 1200.0;
  static const navigationWidth = 184.0;
  static const applyAction = Color(0xFF1769DA);
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

/// 统一的 Material 3 桌面主题；浅色、深色使用相同的排版和控件尺寸。
ThemeData desktopTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF006BE6),
        brightness: brightness,
      ).copyWith(
        primary: dark ? const Color(0xFF78B5FF) : const Color(0xFF006BE6),
        onPrimary: dark ? const Color(0xFF102B4A) : Colors.white,
        primaryContainer: dark
            ? const Color(0xFF354762)
            : const Color(0xFFDBE7FA),
        onPrimaryContainer: dark
            ? const Color(0xFFBDD8FF)
            : const Color(0xFF006BE6),
        surface: dark ? const Color(0xFF202123) : const Color(0xFFFAFAFA),
        surfaceContainerLowest: dark ? const Color(0xFF2B2C2F) : Colors.white,
        surfaceContainerLow: dark
            ? const Color(0xFF29282D)
            : const Color(0xFFEEEDF0),
        surfaceContainer: dark
            ? const Color(0xFF29282D)
            : const Color(0xFFEEEDF0),
        surfaceContainerHigh: dark
            ? const Color(0xFF303136)
            : const Color(0xFFE9E9ED),
        surfaceContainerHighest: dark
            ? const Color(0xFF38393D)
            : const Color(0xFFE2E2E7),
        onSurface: dark ? const Color(0xFFF0F0F3) : const Color(0xFF242429),
        onSurfaceVariant: dark
            ? const Color(0xFFAEAEB8)
            : const Color(0xFF6D6D76),
        outline: dark ? const Color(0xFF55565D) : const Color(0xFFBDBDC6),
        outlineVariant: dark
            ? const Color(0xFF414247)
            : const Color(0xFFDEDEE3),
        secondaryContainer: dark
            ? const Color(0xFF354762)
            : const Color(0xFFDBE7FA),
        onSecondaryContainer: dark
            ? const Color(0xFFBDD8FF)
            : const Color(0xFF006BE6),
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
    // 固定 Material 桌面组件形态；文本编辑仍使用 Flutter 的宿主键盘映射。
    platform: TargetPlatform.linux,
    brightness: brightness,
    fontFamily: DesktopDesign.fontFamily,
    fontFamilyFallback: DesktopDesign.fontFamilyFallback,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.compact,
    textTheme: TextTheme(
      bodyLarge: TextStyle(
        fontSize: DesktopDesign.bodyFontSize,
        height: 1.5,
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
      labelLarge: TextStyle(
        fontSize: DesktopDesign.bodyFontSize,
        fontWeight: FontWeight.w400,
        color: scheme.onSurface,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: button),
    outlinedButtonTheme: OutlinedButtonThemeData(style: button),
    textButtonTheme: TextButtonThemeData(style: button),
    segmentedButtonTheme: SegmentedButtonThemeData(style: button),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        iconSize: const WidgetStatePropertyAll(DesktopDesign.actionIconSize),
        minimumSize: const WidgetStatePropertyAll(
          Size.square(DesktopDesign.controlHeight),
        ),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
        shape: WidgetStatePropertyAll(shape),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerLowest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
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
      indicatorSize: const Size(164, 34),
      indicatorShape: shape,
      indicatorColor: scheme.primaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: DesktopDesign.fontFamily,
          fontFamilyFallback: DesktopDesign.fontFamilyFallback,
          fontSize: DesktopDesign.bodyFontSize,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w500
              : FontWeight.w400,
          color: states.contains(WidgetState.selected)
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: DesktopDesign.navigationIconSize,
          color: states.contains(WidgetState.selected)
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: TextStyle(
        fontSize: DesktopDesign.bodyFontSize,
        color: scheme.onSurface,
      ),
      inputDecorationTheme: InputDecorationThemeData(
        isDense: true,
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        constraints: const BoxConstraints.tightFor(height: 30),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        suffixIconConstraints: const BoxConstraints.tightFor(
          width: 28,
          height: 30,
        ),
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DesktopDesign.panelRadius),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      width: 440,
      shape: shape,
    ),
  );
}
