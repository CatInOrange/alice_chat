class ChatSession {
  const ChatSession({
    required this.id,
    required this.title,
    required this.subtitle,
    this.avatarAssetPath,
    this.backendSessionId,
    this.contactId,
    this.isGatewayBacked = false,
  });

  final String id;
  final String title;
  final String subtitle;
  final String? avatarAssetPath;
  final String? backendSessionId;
  final String? contactId;
  final bool isGatewayBacked;
}
