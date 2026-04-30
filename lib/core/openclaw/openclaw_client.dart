class MessagePageResult {
  const MessagePageResult({required this.messages, required this.paging});

  final List<Map<String, dynamic>> messages;
  final Map<String, dynamic> paging;
}

class SendMessageResult {
  const SendMessageResult({
    required this.ok,
    required this.status,
    required this.sessionId,
    required this.clientMessageId,
    required this.persistedUserMessageId,
    required this.requestAccepted,
    this.requestId,
  });

  final bool ok;
  final String status;
  final String sessionId;
  final String clientMessageId;
  final String persistedUserMessageId;
  final bool requestAccepted;
  final String? requestId;
}

class DeleteMessageResult {
  const DeleteMessageResult({
    required this.ok,
    required this.sessionId,
    required this.messageId,
    required this.deleted,
    this.deletedAt,
  });

  final bool ok;
  final String sessionId;
  final String messageId;
  final bool deleted;
  final double? deletedAt;
}

class UploadMediaResult {
  const UploadMediaResult({required this.attachment});

  final Map<String, dynamic> attachment;
}

abstract class OpenClawClient {
  Future<String> ensureSession({
    required String sessionId,
    required String preferredName,
  });

  Future<MessagePageResult> loadMessages(
    String sessionId, {
    int? limit,
    String? beforeMessageId,
    String? afterMessageId,
  });

  Future<SendMessageResult> sendMessage({
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

  Future<DeleteMessageResult> deleteMessage({
    required String sessionId,
    required String messageId,
  });

  Stream<Map<String, dynamic>> subscribeEvents({String? sessionId, int? since});

  Future<Map<String, dynamic>> sendClientDebugLog(Map<String, dynamic> payload);

  Future<Map<String, dynamic>> loadLatestClientDebugLogs({int limit = 5});

  Future<Map<String, dynamic>> restartBackend();

  Future<Map<String, dynamic>> restartGateway();

  Future<Map<String, dynamic>> getAdminTask(String taskId);

  Future<Map<String, dynamic>> getMusicState();

  Future<Map<String, dynamic>> getMusicProviders();

  Future<Map<String, dynamic>> getLatestAiPlaylist();

  Future<Map<String, dynamic>> saveLatestAiPlaylist({
    required Map<String, dynamic> payload,
  });

  Future<Map<String, dynamic>> saveMusicState({required Map<String, dynamic> payload});
}
