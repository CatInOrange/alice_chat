import 'dart:async';

import '../../domain/music_models.dart';
import '../../domain/music_runtime_models.dart';
import 'playback_adapter.dart';

class StubPlaybackAdapter implements PlaybackAdapter {
  final StreamController<PlaybackAdapterState> _stateController =
      StreamController<PlaybackAdapterState>.broadcast();
  PlaybackAdapterState _state = const PlaybackAdapterState();

  @override
  PlaybackAdapterState get state => _state;

  @override
  Stream<PlaybackAdapterState> get stateStream => _stateController.stream;

  @override
  Future<void> initialize() async {
    _setState(_state.copyWith(initialized: true, clearError: true));
  }

  @override
  Future<void> play({
    required MusicTrack track,
    required ResolvedPlaybackSource source,
  }) async {
    if (!_state.initialized) {
      await initialize();
    }
    _setState(
      _state.copyWith(
        currentTrack: track,
        currentSource: source,
        isPlaying: true,
        completed: false,
        position: Duration.zero,
        duration: track.duration,
      ),
    );
  }

  @override
  Future<void> pause() async {
    _setState(_state.copyWith(isPlaying: false));
  }

  @override
  Future<void> resume() async {
    if (_state.currentTrack != null && _state.currentSource != null) {
      final restartPosition =
          _state.completed ? Duration.zero : _state.position;
      _setState(
        _state.copyWith(
          isPlaying: true,
          completed: false,
          position: restartPosition,
        ),
      );
    }
  }

  @override
  Future<void> seek(Duration position) async {
    _setState(_state.copyWith(position: position));
  }

  @override
  Future<void> dispose() async {
    _setState(const PlaybackAdapterState());
    await _stateController.close();
  }

  void _setState(PlaybackAdapterState next) {
    _state = next;
    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
  }
}
