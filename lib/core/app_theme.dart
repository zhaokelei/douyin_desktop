import 'package:flutter/material.dart';

import 'platform_style.dart';

/// Windows 用 Fluent 观感（深色层叠、细描边、Segoe UI），
/// macOS 用更圆润的原生观感（加宽圆角、半透明侧栏），
/// Linux 跟随 Adwaita 的深色中性灰。三者共享同一套语义色。
class AppTheme {
  static const brand = Color(0xFFFF2C55);

  static ThemeData build(DesktopFlavor flavor) {
    final radius = switch (flavor) {
      DesktopFlavor.windows => 6.0,
      DesktopFlavor.macOS => 10.0,
      DesktopFlavor.linux => 8.0,
    };

    final scheme = const ColorScheme.dark(
      primary: brand,
      onPrimary: Colors.white,
      secondary: Color(0xFF4CC2FF),
      surface: Color(0xFF1C1C1C),
      onSurface: Color(0xFFF3F3F3),
      surfaceContainerHighest: Color(0xFF2C2C2C),
      outline: Color(0xFF3F3F3F),
    );

    final fontFamily = switch (flavor) {
      DesktopFlavor.windows => 'Segoe UI',
      DesktopFlavor.macOS => 'PingFang SC',
      DesktopFlavor.linux => 'Noto Sans CJK SC',
    };

    final textTheme = Typography.material2021(colorScheme: scheme)
        .white
        .apply(
          fontFamily: fontFamily,
          fontFamilyFallback: const [
            'Microsoft YaHei UI',
            'PingFang SC',
            'Noto Sans CJK SC',
            'Segoe UI',
          ],
          bodyColor: const Color(0xFFEDEDED),
          displayColor: const Color(0xFFF7F7F7),
        );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      fontFamily: fontFamily,
      textTheme: textTheme,
      scaffoldBackgroundColor: const Color(0xFF141414),
      canvasColor: const Color(0xFF141414),
      splashFactory: InkSparkle.splashFactory,
      cardTheme: CardThemeData(
        color: const Color(0xFF1F1F1F),
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: Color(0xFF333333)),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF2F2F2F),
        thickness: 1,
        space: 1,
      ),
      iconTheme: const IconThemeData(color: Color(0xFFEDEDED), size: 18),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: const Color(0xFF2B2B2B),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: const Color(0xFF414141)),
        ),
        textStyle: const TextStyle(color: Color(0xFFEFEFEF), fontSize: 12),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(6),
        radius: const Radius.circular(3),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? const Color(0xFF7A7A7A)
              : const Color(0xFF4A4A4A),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFFEDEDED),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: brand,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius + 2),
          side: const BorderSide(color: Color(0xFF3A3A3A)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: const Color(0xFF232323),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: Color(0xFF3A3A3A)),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF141414),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Color(0xFFF2F2F2),
        ),
      ),
    );
  }
}

/// 卡片阴影只在悬浮时出现，避免静态列表出现大片阴影拖慢滚动帧率。
const kCardShadow = [
  BoxShadow(
    color: Color(0x55000000),
    blurRadius: 18,
    offset: Offset(0, 8),
  ),
];
