import 'music_source_provider.dart';

class MusicSourceRegistry {
  MusicSourceRegistry({required List<MusicSourceProvider> providers})
      : _providers = List<MusicSourceProvider>.unmodifiable(providers);

  final List<MusicSourceProvider> _providers;

  List<MusicSourceProvider> get providers => _providers;

  MusicSourceProvider? providerById(String id) {
    for (final provider in _providers) {
      if (provider.id == id) {
        return provider;
      }
    }
    return null;
  }
}
