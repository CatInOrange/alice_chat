class MessagePageResult {
  const MessagePageResult({required this.messages, required this.paging});

  final List<Map<String, dynamic>> messages;
  final Map<String, dynamic> paging;
}

class UploadMediaResult {
  const UploadMediaResult({required this.attachment});

  final Map<String, dynamic> attachment;
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
    List<Map<String, dynamic>> attachments = const [],
    String? contactId,
    String? userId,
    String? clientMessageId,
  });

  Future<UploadMediaResult> uploadMedia({
    required String filePath,
    String? filename,
  });

  Stream<Map<String, dynamic>> subscribeEvents({String? sessionId, int? since});

  Future<Map<String, dynamic>> sendClientDebugLog(Map<String, dynamic> payload);

  Future<Map<String, dynamic>> loadLatestClientDebugLogs({int limit = 5});
}
