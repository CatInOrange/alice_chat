import 'dart:io';

import 'package:flutter/material.dart';

String? _desktopFontFamily() {
  if (Platform.isWindows) return 'Microsoft YaHei UI';
  if (Platform.isMacOS) return 'PingFang SC';
  if (Platform.isLinux) return 'Noto Sans CJK SC';
  return null;
}

String? _desktopMonospaceFontFamily() {
  if (Platform.isWindows) return 'Cascadia Mono';
  if (Platform.isMacOS) return 'Menlo';
  if (Platform.isLinux) return 'Noto Sans Mono';
  return 'monospace';
}

ThemeData buildAliceChatTheme() {
  const seed = Color(0xFF7C4DFF);
  final colorScheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: Brightness.light,
  );
  final fontFamily = _desktopFontFamily();
  final monoFontFamily = _desktopMonospaceFontFamily();

  return ThemeData(
    colorScheme: colorScheme,
    useMaterial3: true,
    fontFamily: fontFamily,
    extensions: <ThemeExtension<dynamic>>[
      AliceChatFontScheme(monospaceFontFamily: monoFontFamily),
    ],
    scaffoldBackgroundColor: const Color(0xFFF6F7FB),
    appBarTheme: AppBarTheme(
      backgroundColor: const Color(0xFFF6F7FB),
      foregroundColor: const Color(0xFF1F2430),
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: const TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: Color(0xFF1F2430),
      ),
    ),
    dividerColor: const Color(0xFFE7EAF3),
    cardColor: Colors.white,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide(
          color: colorScheme.primary.withValues(alpha: 0.18),
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      hintStyle: const TextStyle(color: Color(0xFF98A1B3), fontSize: 15),
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(
        color: Color(0xFF1F2430),
        fontSize: 15,
        height: 1.45,
      ),
      bodyMedium: TextStyle(
        color: Color(0xFF465065),
        fontSize: 14,
        height: 1.4,
      ),
      bodySmall: TextStyle(color: Color(0xFF98A1B3), fontSize: 12, height: 1.3),
      titleLarge: TextStyle(
        color: Color(0xFF1F2430),
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
      titleMedium: TextStyle(
        color: Color(0xFF1F2430),
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class AliceChatFontScheme extends ThemeExtension<AliceChatFontScheme> {
  const AliceChatFontScheme({required this.monospaceFontFamily});

  final String? monospaceFontFamily;

  @override
  AliceChatFontScheme copyWith({String? monospaceFontFamily}) {
    return AliceChatFontScheme(
      monospaceFontFamily: monospaceFontFamily ?? this.monospaceFontFamily,
    );
  }

  @override
  AliceChatFontScheme lerp(
    covariant ThemeExtension<AliceChatFontScheme>? other,
    double t,
  ) {
    if (other is! AliceChatFontScheme) return this;
    return t < 0.5 ? this : other;
  }
}
