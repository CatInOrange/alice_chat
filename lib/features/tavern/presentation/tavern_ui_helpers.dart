import 'dart:io';

import 'package:flutter/material.dart';

Widget buildTavernAvatar({
  required String avatarPath,
  String? serverBaseUrl,
  double radius = 20,
  IconData fallbackIcon = Icons.person_outline,
}) {
  final trimmed = avatarPath.trim();
  if (trimmed.isEmpty) {
    return CircleAvatar(radius: radius, child: Icon(fallbackIcon));
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
  return CircleAvatar(radius: radius, child: Icon(fallbackIcon));
}
