import 'package:flutter/material.dart';

ThemeData buildAliceChatTheme() {
  const seed = Color(0xFF7C4DFF);

  return ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: seed),
    useMaterial3: true,
  );
}
