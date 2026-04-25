class MessagePageResult {
  const MessagePageResult({required this.messages, required this.paging});

  final List<Map<String, dynamic>> messages;
  final Map<String, dynamic> paging;
}

abstract class OpenClawClient {
  Future<String> ensureSession({required String preferredName});

  Future<MessagePageResult> loadMessages(
    String sessionId, {
    int? limit,
    String? beforeMessageId,
    String? afterMessageId,
  });

  Future<String> sendMessage({
    required String sessionId,
    required String text,
    String? clientMessageId,
  });

  Stream<Map<String, dynamic>> subscribeEvents({
    required String sessionId,
    int? since,
  });

  Future<void> sendClientDebugLog(Map<String, dynamic> payload);
}
