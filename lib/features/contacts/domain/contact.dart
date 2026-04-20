class Contact {
  final String id;
  final String name;
  final String? subtitle;
  final String? avatarAssetPath;
  final String? backendSessionId;
  final bool isGatewayBacked;

  const Contact({
    required this.id,
    required this.name,
    this.subtitle,
    this.avatarAssetPath,
    this.backendSessionId,
    this.isGatewayBacked = false,
  });
}
