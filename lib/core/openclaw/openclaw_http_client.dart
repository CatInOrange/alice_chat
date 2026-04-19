import 'openclaw_client.dart';
import 'openclaw_config.dart';

class OpenClawHttpClient implements OpenClawClient {
  OpenClawHttpClient(this.config);

  final OpenClawConfig config;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<Map<String, dynamic>>> loadMessages(String sessionId) async {
    return const [];
  }

  @override
  Future<List<Map<String, dynamic>>> loadSessions() async {
    return const [];
  }

  @override
  Future<void> sendMessage({required String sessionId, required String text}) async {}

  @override
  Stream<Map<String, dynamic>> streamEvents(String sessionId) {
    return const Stream.empty();
  }
}
