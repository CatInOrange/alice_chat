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

MusicCommandType musicCommandTypeFromName(String value) {
  return MusicCommandType.values.firstWhere(
    (item) => item.name == value,
    orElse: () => MusicCommandType.play,
  );
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
  }) {
    return MusicCommand(
      type: MusicCommandType.play,
      source: source,
      queue: queue,
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
    final payload = (map['payload'] as Map?)?.cast<String, dynamic>();
    final rawQueue = ((map['queue'] as List<dynamic>?) ?? const [])
        .whereType<Map>()
        .map(
          (item) => PlaybackQueueItem.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
    final payloadQueue = ((payload?['queue'] as List<dynamic>?) ?? const [])
        .whereType<Map>()
        .map(
          (item) => PlaybackQueueItem.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
    final resolvedQueue = payloadQueue.isNotEmpty ? payloadQueue : rawQueue;
    final playlistMap =
        (map['playlist'] as Map?)?.cast<String, dynamic>() ??
        (payload?['playlist'] as Map?)?.cast<String, dynamic>();
    final typeValue =
        (map['type'] ?? payload?['type'] ?? MusicCommandType.play.name)
            .toString();
    final sourceValue =
        (map['source'] ?? payload?['source'] ?? MusicCommandSource.chatAi.name)
            .toString();
    final targetDeviceValue =
        (map['targetDeviceId'] ?? payload?['targetDeviceId'] ?? '')
            .toString()
            .trim();
    final requestValue =
        (map['requestId'] ?? payload?['requestId'] ?? '').toString().trim();
    final positionRaw = map['positionMs'] ?? payload?['positionMs'];
    return MusicCommand(
      type: musicCommandTypeFromName(typeValue),
      source: musicCommandSourceFromName(sourceValue),
      queue: resolvedQueue,
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
