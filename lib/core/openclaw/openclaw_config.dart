class OpenClawConfig {
  const OpenClawConfig({
    required this.baseUrl,
    required this.modelId,
    required this.providerId,
    required this.agent,
    required this.sessionName,
    this.bridgeUrl,
    this.apiToken,
  });

  final String baseUrl;
  final String modelId;
  final String providerId;
  final String agent;
  final String sessionName;
  final String? bridgeUrl;
  final String? apiToken;

  OpenClawConfig copyWith({
    String? baseUrl,
    String? modelId,
    String? providerId,
    String? agent,
    String? sessionName,
    String? bridgeUrl,
    String? apiToken,
  }) {
    return OpenClawConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      modelId: modelId ?? this.modelId,
      providerId: providerId ?? this.providerId,
      agent: agent ?? this.agent,
      sessionName: sessionName ?? this.sessionName,
      bridgeUrl: bridgeUrl ?? this.bridgeUrl,
      apiToken: apiToken ?? this.apiToken,
    );
  }
}
