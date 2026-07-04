import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import '../../../../core/debug/native_debug_bridge.dart';
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
      _logPlaybackState(playerState);
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
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _becomingNoisySub;
  StreamSubscription<AudioDevicesChangedEvent>? _devicesChangedSub;
  StreamSubscription<dynamic>? _errorSub;
  bool _audioSessionConfigured = false;

  @override
  PlaybackAdapterState get state => _state;

  @override
  Stream<PlaybackAdapterState> get stateStream => _stateController.stream;

  @override
  Future<void> initialize() async {
    await _configureAudioSession();
    _setState(_state.copyWith(initialized: true, clearError: true));
  }

  @override
  Future<void> play({
    required MusicTrack track,
    required ResolvedPlaybackSource source,
  }) async {
    await _configureAudioSession();
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
    _log(
      'play request track=${track.id} title=${track.title} '
      'provider=${source.providerId} sourceTrack=${source.sourceTrackId}',
    );
    try {
      await _player.setAudioSource(audioSource);
      _startPlayback();
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
  Future<void> pause() {
    _log('pause request track=${_state.currentTrack?.id ?? ''}');
    return _player.pause();
  }

  @override
  Future<void> resume() async {
    await _configureAudioSession();
    _log('resume request track=${_state.currentTrack?.id ?? ''}');
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
    }
    _startPlayback();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> dispose() async {
    await _playerStateSub?.cancel();
    await _positionSub?.cancel();
    await _durationSub?.cancel();
    await _interruptionSub?.cancel();
    await _becomingNoisySub?.cancel();
    await _devicesChangedSub?.cancel();
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

  void _startPlayback() {
    unawaited(
      _player.play().catchError((Object error, StackTrace _) {
        _log('playback failed error=$error', level: 'ERROR');
        _setState(
          _state.copyWith(
            error: error.toString(),
            isPlaying: false,
            isBuffering: false,
          ),
        );
      }),
    );
  }

  Future<void> _configureAudioSession() async {
    if (_audioSessionConfigured) {
      return;
    }
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      _interruptionSub ??= session.interruptionEventStream.listen(
        _handleInterruption,
      );
      _becomingNoisySub ??= session.becomingNoisyEventStream.listen((_) {
        _log('audio session becoming_noisy');
      });
      _devicesChangedSub ??= session.devicesChangedEventStream.listen((event) {
        _log(
          'audio devices changed added=${_describeDevices(event.devicesAdded)} '
          'removed=${_describeDevices(event.devicesRemoved)}',
        );
      });
      _audioSessionConfigured = true;
      _log('audio session configured music/media');
    } catch (error) {
      _log('audio session configure failed error=$error', level: 'ERROR');
    }
  }

  void _handleInterruption(AudioInterruptionEvent event) {
    _log(
      'audio interruption begin=${event.begin} type=${event.type.name} '
      'playing=${_player.playing} processing=${_player.processingState.name}',
      level: event.begin ? 'WARN' : 'INFO',
    );
  }

  void _logPlaybackState(PlayerState playerState) {
    _log(
      'player state playing=${playerState.playing} '
      'processing=${playerState.processingState.name} '
      'positionMs=${_state.position.inMilliseconds} '
      'durationMs=${_state.duration?.inMilliseconds ?? -1} '
      'track=${_state.currentTrack?.id ?? ''}',
    );
  }

  String _describeDevices(Set<AudioDevice> devices) {
    if (devices.isEmpty) {
      return '[]';
    }
    return devices
        .map(
          (device) =>
              '${device.type.name}:${device.name}:'
              '${device.isInput ? 'in' : ''}${device.isOutput ? 'out' : ''}',
        )
        .join(',');
  }

  void _log(String message, {String level = 'INFO'}) {
    unawaited(
      NativeDebugBridge.instance.log('music.playback', message, level: level),
    );
  }
}
