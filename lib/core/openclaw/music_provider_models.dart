class MusicProviderInfo {
  const MusicProviderInfo({
    required this.providerId,
    required this.displayName,
    required this.authMode,
    required this.supportedAuthMethods,
    required this.supportsSearch,
    required this.supportsLyrics,
    required this.supportsResolve,
    required this.supportsPlaylistLookup,
    required this.supportsUserLibrary,
    required this.notes,
  });

  final String providerId;
  final String displayName;
  final String authMode;
  final List<String> supportedAuthMethods;
  final bool supportsSearch;
  final bool supportsLyrics;
  final bool supportsResolve;
  final bool supportsPlaylistLookup;
  final bool supportsUserLibrary;
  final String notes;

  factory MusicProviderInfo.fromMap(Map<String, dynamic> map) {
    return MusicProviderInfo(
      providerId: (map['providerId'] ?? '').toString(),
      displayName: (map['displayName'] ?? '').toString(),
      authMode: (map['authMode'] ?? 'client').toString(),
      supportedAuthMethods: ((map['supportedAuthMethods'] as List<dynamic>?) ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
      supportsSearch: map['supportsSearch'] != false,
      supportsLyrics: map['supportsLyrics'] != false,
      supportsResolve: map['supportsResolve'] != false,
      supportsPlaylistLookup: map['supportsPlaylistLookup'] == true,
      supportsUserLibrary: map['supportsUserLibrary'] == true,
      notes: (map['notes'] ?? '').toString(),
    );
  }
}
