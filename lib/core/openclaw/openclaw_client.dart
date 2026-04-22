abstract class OpenClawClient {
  Future<String> ensureSession({required String preferredName});

  Future<List<Map<String, dynamic>>> loadMessages(String sessionId);

  Future<String> sendMessage({
    required String sessionId,
    required String text,
    String? clientMessageId,
  });

  Stream<Map<String, dynamic>> subscribeEvents({required String sessionId});
}
