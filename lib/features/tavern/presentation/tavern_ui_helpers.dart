import 'dart:io';

import 'package:flutter/material.dart';

const String tavernDefaultAvatarAssetPath =
    'assets/avatars/tavern_default.png';

Widget buildTavernAvatar({
  required String avatarPath,
  String? serverBaseUrl,
  double radius = 20,
  IconData fallbackIcon = Icons.person_outline,
  bool useDefaultAssetFallback = false,
}) {
  final trimmed = avatarPath.trim();
  if (trimmed.isEmpty) {
    return _buildFallbackAvatar(
      radius: radius,
      fallbackIcon: fallbackIcon,
      useDefaultAssetFallback: useDefaultAssetFallback,
    );
  }
  if (trimmed.startsWith('/uploads/')) {
    final url =
        serverBaseUrl == null || serverBaseUrl.trim().isEmpty
            ? null
            : '${serverBaseUrl.trim()}$trimmed';
    if (url != null) {
      return CircleAvatar(
        radius: radius,
        backgroundImage: NetworkImage(url),
        onBackgroundImageError: (_, __) {},
      );
    }
  }
  final file = File(trimmed);
  if (file.existsSync()) {
    return CircleAvatar(radius: radius, backgroundImage: FileImage(file));
  }
  return _buildFallbackAvatar(
    radius: radius,
    fallbackIcon: fallbackIcon,
    useDefaultAssetFallback: useDefaultAssetFallback,
  );
}

Widget _buildFallbackAvatar({
  required double radius,
  required IconData fallbackIcon,
  required bool useDefaultAssetFallback,
}) {
  if (useDefaultAssetFallback) {
    return CircleAvatar(
      radius: radius,
      backgroundImage: const AssetImage(tavernDefaultAvatarAssetPath),
    );
  }
  return CircleAvatar(radius: radius, child: Icon(fallbackIcon));
}
