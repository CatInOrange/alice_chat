abstract class OpenClawClient {
  Future<void> connect();
  Future<void> disconnect();

  Future<List<Map<String, dynamic>>> loadSessions();
  Future<List<Map<String, dynamic>>> loadMessages(String sessionId);
  Future<void> sendMessage({
    required String sessionId,
    required String text,
  });

  Stream<Map<String, dynamic>> streamEvents(String sessionId);
}
