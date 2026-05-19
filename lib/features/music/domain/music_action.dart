import 'music_command.dart';
import 'music_event_envelope.dart';
import 'music_models.dart';

enum MusicActionType {
  playTrack,
  playPlaylist,
  queueNext,
  queueAppend,
  pauseResume,
  skip,
  saveAiPlaylist,
}

MusicActionType? musicActionTypeFromName(String value) {
  return switch (value) {
    'play_track' => MusicActionType.playTrack,
    'play_playlist' => MusicActionType.playPlaylist,
    'queue_next' => MusicActionType.queueNext,
    'queue_append' => MusicActionType.queueAppend,
    'pause_resume' => MusicActionType.pauseResume,
    'skip' => MusicActionType.skip,
    'save_ai_playlist' => MusicActionType.saveAiPlaylist,
    _ => null,
  };
}

class MusicAction {
  const MusicAction({
    required this.type,
    required this.payload,
    this.source = MusicCommandSource.chatAi,
    this.requestId,
  });

  final MusicActionType type;
  final Map<String, dynamic> payload;
  final MusicCommandSource source;
  final String? requestId;

  factory MusicAction.fromMap(Map<String, dynamic> map) {
    final envelope = MusicEventEnvelope.fromMap(
      map,
      inlinePayloadKeys: const [
        'track',
        'tracks',
        'playlist',
        'playlistDraft',
        'startIndex',
        'mode',
      ],
    );
    final type = musicActionTypeFromName(envelope.type);
    if (type == null) {
      throw FormatException('Unsupported music action type: ${envelope.type}');
    }
    final sourceValue =
        (envelope.source ??
                envelope.payload['source'] ??
                MusicCommandSource.chatAi.name)
            .toString();
    final requestValue =
        (envelope.requestId ?? envelope.payload['requestId'] ?? '')
            .toString()
            .trim();
    return MusicAction(
      type: type,
      payload: Map<String, dynamic>.from(envelope.payload),
      source: musicCommandSourceFromName(sourceValue),
      requestId: requestValue.isEmpty ? null : requestValue,
    );
  }

  MusicTrack? get track {
    final map = (payload['track'] as Map?)?.cast<String, dynamic>();
    if (map == null) return null;
    return MusicTrack.fromMap(Map<String, dynamic>.from(map));
  }

  List<MusicTrack> get tracks {
    final many = ((payload['tracks'] as List<dynamic>?) ?? const [])
        .whereType<Map>()
        .map(
          (item) => MusicTrack.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
    if (many.isNotEmpty) {
      return many;
    }
    final single = track;
    return single == null ? const [] : [single];
  }

  MusicPlaylist? get playlist {
    final map = (payload['playlist'] as Map?)?.cast<String, dynamic>();
    if (map == null) return null;
    return MusicPlaylist.fromMap(Map<String, dynamic>.from(map));
  }

  MusicAiPlaylistDraft? get playlistDraft {
    final map = (payload['playlistDraft'] as Map?)?.cast<String, dynamic>();
    if (map == null) return null;
    return MusicAiPlaylistDraft.fromMap(Map<String, dynamic>.from(map));
  }

  int get startIndex {
    final raw = payload['startIndex'];
    if (raw is num) {
      return raw.toInt();
    }
    return int.tryParse('$raw') ?? 0;
  }

  String? get mode {
    final value = (payload['mode'] ?? '').toString().trim();
    return value.isEmpty ? null : value;
  }
}
