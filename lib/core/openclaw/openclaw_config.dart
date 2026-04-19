class OpenClawConfig {
  const OpenClawConfig({
    required this.baseUrl,
    this.apiToken,
  });

  final String baseUrl;
  final String? apiToken;
}
