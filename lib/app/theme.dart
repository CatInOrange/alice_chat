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

double desktopAdjustedFontSize(double size) {
  if (Platform.isWindows) {
    final adjusted = size <= 14 ? size + 1 : size;
    return adjusted.roundToDouble();
  }
  return size;
}

double desktopContentFontSize(double size) {
  if (Platform.isWindows) {
    final adjusted = size <= 16 ? size + 1 : size;
    return adjusted.roundToDouble();
  }
  return size;
}

ThemeData buildAliceChatTheme({Brightness brightness = Brightness.light}) {
  const seed = Color(0xFF7C4DFF);
  final isDark = brightness == Brightness.dark;
  final colorScheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
  );
  final fontFamily = _desktopFontFamily();
  final monoFontFamily = _desktopMonospaceFontFamily();
  final appColors = isDark ? AliceChatColors.dark() : AliceChatColors.light();

  return ThemeData(
    colorScheme: colorScheme,
    useMaterial3: true,
    fontFamily: fontFamily,
    brightness: brightness,
    extensions: <ThemeExtension<dynamic>>[
      AliceChatFontScheme(monospaceFontFamily: monoFontFamily),
      appColors,
    ],
    scaffoldBackgroundColor: appColors.background,
    appBarTheme: AppBarTheme(
      backgroundColor: appColors.background,
      foregroundColor: appColors.text,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: appColors.text,
      ),
    ),
    dividerColor: appColors.border,
    cardColor: appColors.surface,
    iconTheme: IconThemeData(color: appColors.icon),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: appColors.inputBackground,
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
      hintStyle: TextStyle(color: appColors.textMuted, fontSize: 15),
    ),
    textTheme: TextTheme(
      bodyLarge: TextStyle(
        color: appColors.text,
        fontSize: desktopContentFontSize(15),
        height: 1.45,
      ),
      bodyMedium: TextStyle(
        color: appColors.textSubtle,
        fontSize: desktopAdjustedFontSize(14),
        height: 1.4,
      ),
      bodySmall: TextStyle(
        color: appColors.textMuted,
        fontSize: desktopAdjustedFontSize(12),
        height: 1.3,
      ),
      titleLarge: TextStyle(
        color: appColors.text,
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
      titleMedium: TextStyle(
        color: appColors.text,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

extension AliceChatThemeX on BuildContext {
  AliceChatColors get aliceColors =>
      Theme.of(this).extension<AliceChatColors>() ?? AliceChatColors.light();
}

class AliceChatColors extends ThemeExtension<AliceChatColors> {
  const AliceChatColors({
    required this.background,
    required this.surface,
    required this.surfaceElevated,
    required this.surfaceSoft,
    required this.inputBackground,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.textSubtle,
    required this.textMuted,
    required this.icon,
    required this.userBubble,
    required this.userBubbleText,
    required this.assistantBubble,
    required this.assistantBubbleText,
    required this.codeBackground,
    required this.quoteBackground,
    required this.narrationBackground,
    required this.narrationText,
    required this.dialogueText,
    required this.shadow,
    required this.overlay,
  });

  factory AliceChatColors.light() {
    return const AliceChatColors(
      background: Color(0xFFF6F7FB),
      surface: Colors.white,
      surfaceElevated: Colors.white,
      surfaceSoft: Color(0xFFF3F5FA),
      inputBackground: Colors.white,
      border: Color(0xFFE7EAF3),
      borderStrong: Color(0xFFD9DEEA),
      text: Color(0xFF1F2430),
      textSubtle: Color(0xFF465065),
      textMuted: Color(0xFF98A1B3),
      icon: Color(0xFF667085),
      userBubble: Color(0xFF6D4AFF),
      userBubbleText: Colors.white,
      assistantBubble: Colors.white,
      assistantBubbleText: Color(0xFF1F2430),
      codeBackground: Color(0xFFF7F8FC),
      quoteBackground: Color(0xFFF1EEFF),
      narrationBackground: Color(0xFFF6F1FF),
      narrationText: Color(0xFF7B6D9D),
      dialogueText: Color(0xFF8D4F68),
      shadow: Color(0x121F2430),
      overlay: Color(0xEAF6F7FB),
    );
  }

  factory AliceChatColors.dark() {
    return const AliceChatColors(
      background: Color(0xFF111318),
      surface: Color(0xFF1A1D24),
      surfaceElevated: Color(0xFF222633),
      surfaceSoft: Color(0xFF252A35),
      inputBackground: Color(0xFF20242D),
      border: Color(0xFF303644),
      borderStrong: Color(0xFF424A5D),
      text: Color(0xFFE8ECF5),
      textSubtle: Color(0xFFC4CAD8),
      textMuted: Color(0xFF8C94A6),
      icon: Color(0xFFAAB2C2),
      userBubble: Color(0xFF5C4BCB),
      userBubbleText: Color(0xFFF8F7FF),
      assistantBubble: Color(0xFF20242D),
      assistantBubbleText: Color(0xFFE8ECF5),
      codeBackground: Color(0xFF171A21),
      quoteBackground: Color(0xFF25213A),
      narrationBackground: Color(0xFF241F34),
      narrationText: Color(0xFFC2B6E8),
      dialogueText: Color(0xFFE4B4C9),
      shadow: Color(0x66000000),
      overlay: Color(0xE6111318),
    );
  }

  final Color background;
  final Color surface;
  final Color surfaceElevated;
  final Color surfaceSoft;
  final Color inputBackground;
  final Color border;
  final Color borderStrong;
  final Color text;
  final Color textSubtle;
  final Color textMuted;
  final Color icon;
  final Color userBubble;
  final Color userBubbleText;
  final Color assistantBubble;
  final Color assistantBubbleText;
  final Color codeBackground;
  final Color quoteBackground;
  final Color narrationBackground;
  final Color narrationText;
  final Color dialogueText;
  final Color shadow;
  final Color overlay;

  @override
  AliceChatColors copyWith({
    Color? background,
    Color? surface,
    Color? surfaceElevated,
    Color? surfaceSoft,
    Color? inputBackground,
    Color? border,
    Color? borderStrong,
    Color? text,
    Color? textSubtle,
    Color? textMuted,
    Color? icon,
    Color? userBubble,
    Color? userBubbleText,
    Color? assistantBubble,
    Color? assistantBubbleText,
    Color? codeBackground,
    Color? quoteBackground,
    Color? narrationBackground,
    Color? narrationText,
    Color? dialogueText,
    Color? shadow,
    Color? overlay,
  }) {
    return AliceChatColors(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      surfaceSoft: surfaceSoft ?? this.surfaceSoft,
      inputBackground: inputBackground ?? this.inputBackground,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      text: text ?? this.text,
      textSubtle: textSubtle ?? this.textSubtle,
      textMuted: textMuted ?? this.textMuted,
      icon: icon ?? this.icon,
      userBubble: userBubble ?? this.userBubble,
      userBubbleText: userBubbleText ?? this.userBubbleText,
      assistantBubble: assistantBubble ?? this.assistantBubble,
      assistantBubbleText: assistantBubbleText ?? this.assistantBubbleText,
      codeBackground: codeBackground ?? this.codeBackground,
      quoteBackground: quoteBackground ?? this.quoteBackground,
      narrationBackground: narrationBackground ?? this.narrationBackground,
      narrationText: narrationText ?? this.narrationText,
      dialogueText: dialogueText ?? this.dialogueText,
      shadow: shadow ?? this.shadow,
      overlay: overlay ?? this.overlay,
    );
  }

  @override
  AliceChatColors lerp(
    covariant ThemeExtension<AliceChatColors>? other,
    double t,
  ) {
    if (other is! AliceChatColors) return this;
    return AliceChatColors(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      surfaceSoft: Color.lerp(surfaceSoft, other.surfaceSoft, t)!,
      inputBackground: Color.lerp(inputBackground, other.inputBackground, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      text: Color.lerp(text, other.text, t)!,
      textSubtle: Color.lerp(textSubtle, other.textSubtle, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      icon: Color.lerp(icon, other.icon, t)!,
      userBubble: Color.lerp(userBubble, other.userBubble, t)!,
      userBubbleText: Color.lerp(userBubbleText, other.userBubbleText, t)!,
      assistantBubble: Color.lerp(assistantBubble, other.assistantBubble, t)!,
      assistantBubbleText:
          Color.lerp(assistantBubbleText, other.assistantBubbleText, t)!,
      codeBackground: Color.lerp(codeBackground, other.codeBackground, t)!,
      quoteBackground: Color.lerp(quoteBackground, other.quoteBackground, t)!,
      narrationBackground:
          Color.lerp(narrationBackground, other.narrationBackground, t)!,
      narrationText: Color.lerp(narrationText, other.narrationText, t)!,
      dialogueText: Color.lerp(dialogueText, other.dialogueText, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      overlay: Color.lerp(overlay, other.overlay, t)!,
    );
  }
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
