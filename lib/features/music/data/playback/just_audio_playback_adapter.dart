import 'dart:async';

import 'package:just_audio/just_audio.dart';

import '../../domain/music_models.dart';
import '../../domain/music_runtime_models.dart';
import 'playback_adapter.dart';

class JustAudioPlaybackAdapter implements PlaybackAdapter {
  JustAudioPlaybackAdapter() {
    _state = const PlaybackAdapterState();
    _playerStateSub = _player.playerStateStream.listen((playerState) {
      _setState(
        _state.copyWith(
          isPlaying: playerState.playing,
          isBuffering:
              playerState.processingState == ProcessingState.loading ||
              playerState.processingState == ProcessingState.buffering,
          completed: playerState.processingState == ProcessingState.completed,
          initialized: true,
        ),
      );
    });
    _positionSub = _player.positionStream.listen((position) {
      _setState(_state.copyWith(position: position));
    });
    _durationSub = _player.durationStream.listen((duration) {
      _setState(_state.copyWith(duration: duration));
    });
    _errorSub = null;
  }

  final AudioPlayer _player = AudioPlayer();
  final StreamController<PlaybackAdapterState> _stateController =
      StreamController<PlaybackAdapterState>.broadcast();

  late PlaybackAdapterState _state;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<dynamic>? _errorSub;

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
    final headers = source.headers;
    final audioSource = AudioSource.uri(
      Uri.parse(source.streamUrl),
      tag: track.id,
      headers: headers.isEmpty ? null : headers,
    );
    _setState(
      _state.copyWith(
        currentTrack: track,
        currentSource: source,
        isBuffering: true,
        completed: false,
        position: Duration.zero,
        duration: track.duration,
        clearError: true,
      ),
    );
    try {
      await _player.setAudioSource(audioSource);
      await _player.play();
    } catch (error) {
      _setState(
        _state.copyWith(
          error: error.toString(),
          isPlaying: false,
          isBuffering: false,
        ),
      );
      rethrow;
    }
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.play();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> dispose() async {
    await _playerStateSub?.cancel();
    await _positionSub?.cancel();
    await _durationSub?.cancel();
    await _errorSub?.cancel();
    await _player.dispose();
    await _stateController.close();
  }

  void _setState(PlaybackAdapterState next) {
    _state = next;
    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
  }
}
