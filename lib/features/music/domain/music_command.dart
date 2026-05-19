import 'music_event_envelope.dart';
import 'music_runtime_models.dart';
import 'music_models.dart';

enum MusicCommandType {
  play,
  pause,
  resume,
  next,
  previous,
  seek,
  replaceQueue,
  prependToQueue,
  appendToQueue,
  likeTrack,
  unlikeTrack,
}

enum MusicCommandSource { manual, chatAi, system }

MusicCommandType? musicCommandTypeFromName(String value) {
  for (final item in MusicCommandType.values) {
    if (item.name == value) {
      return item;
    }
  }
  return null;
}

MusicCommandSource musicCommandSourceFromName(String value) {
  return MusicCommandSource.values.firstWhere(
    (item) => item.name == value,
    orElse: () => MusicCommandSource.manual,
  );
}

class MusicCommand {
  const MusicCommand({
    required this.type,
    this.source = MusicCommandSource.manual,
    this.queue = const [],
    this.playlist,
    this.targetDeviceId,
    this.requestId,
    this.positionMs,
  });

  final MusicCommandType type;
  final MusicCommandSource source;
  final List<PlaybackQueueItem> queue;
  final MusicPlaylist? playlist;
  final String? targetDeviceId;
  final String? requestId;
  final int? positionMs;

  factory MusicCommand.play({
    required List<PlaybackQueueItem> queue,
    MusicCommandSource source = MusicCommandSource.manual,
    MusicPlaylist? playlist,
  }) {
    return MusicCommand(
      type: MusicCommandType.play,
      source: source,
      queue: queue,
      playlist: playlist,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'type': type.name,
      'source': source.name,
      if (queue.isNotEmpty) 'queue': queue.map((item) => item.toMap()).toList(),
      if (playlist != null) 'playlist': playlist!.toMap(),
      if (targetDeviceId != null && targetDeviceId!.isNotEmpty)
        'targetDeviceId': targetDeviceId,
      if (requestId != null && requestId!.isNotEmpty) 'requestId': requestId,
      if (positionMs != null) 'positionMs': positionMs,
    };
  }

  factory MusicCommand.fromMap(Map<String, dynamic> map) {
    final envelope = MusicEventEnvelope.fromMap(
      map,
      inlinePayloadKeys: const [
        'queue',
        'playlist',
        'targetDeviceId',
        'requestId',
        'positionMs',
      ],
    );
    final rawQueue = ((envelope.payload['queue'] as List<dynamic>?) ?? const [])
        .whereType<Map>()
        .map(
          (item) => PlaybackQueueItem.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
    final playlistMap =
        (envelope.payload['playlist'] as Map?)?.cast<String, dynamic>();
    final type = musicCommandTypeFromName(envelope.type);
    if (type == null) {
      throw FormatException('Unsupported music command type: ${envelope.type}');
    }
    final sourceValue =
        (envelope.source ??
                envelope.payload['source'] ??
                MusicCommandSource.chatAi.name)
            .toString();
    final targetDeviceValue =
        (envelope.payload['targetDeviceId'] ?? '').toString().trim();
    final requestValue =
        (envelope.requestId ?? envelope.payload['requestId'] ?? '')
            .toString()
            .trim();
    final positionRaw = envelope.payload['positionMs'];
    return MusicCommand(
      type: type,
      source: musicCommandSourceFromName(sourceValue),
      queue: rawQueue,
      playlist: playlistMap == null ? null : MusicPlaylist.fromMap(playlistMap),
      targetDeviceId: targetDeviceValue.isEmpty ? null : targetDeviceValue,
      requestId: requestValue.isEmpty ? null : requestValue,
      positionMs:
          positionRaw is num
              ? positionRaw.toInt()
              : int.tryParse('$positionRaw'),
    );
  }
}
