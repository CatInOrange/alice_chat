class MusicEventEnvelope {
  const MusicEventEnvelope({
    required this.type,
    required this.payload,
    this.source,
    this.requestId,
    this.transportEvent,
  });

  final String type;
  final Map<String, dynamic> payload;
  final String? source;
  final String? requestId;
  final String? transportEvent;

  factory MusicEventEnvelope.fromMap(
    Map<String, dynamic> map, {
    required List<String> inlinePayloadKeys,
  }) {
    final nestedPayload = _asMapOrNull(map['payload']);
    final payload =
        nestedPayload != null
            ? Map<String, dynamic>.from(nestedPayload)
            : _deriveInlinePayload(map, inlinePayloadKeys);
    final type = _firstNonBlank([
      map['type'],
      map['transportEvent'],
      nestedPayload?['type'],
    ]);
    if (type == null) {
      throw const FormatException('Missing music event type');
    }
    final source = _firstNonBlank([map['source'], payload['source']]);
    final requestId = _firstNonBlank([map['requestId'], payload['requestId']]);
    final transportEvent = _firstNonBlank([map['transportEvent']]);
    return MusicEventEnvelope(
      type: type,
      payload: payload,
      source: source,
      requestId: requestId,
      transportEvent: transportEvent,
    );
  }
}

Map<String, dynamic>? _asMapOrNull(Object? value) {
  if (value is! Map) {
    return null;
  }
  return Map<String, dynamic>.from(value.cast<String, dynamic>());
}

Map<String, dynamic> _deriveInlinePayload(
  Map<String, dynamic> map,
  List<String> inlinePayloadKeys,
) {
  final payload = <String, dynamic>{};
  for (final key in inlinePayloadKeys) {
    if (map.containsKey(key)) {
      payload[key] = map[key];
    }
  }
  return payload;
}

String? _firstNonBlank(List<Object?> values) {
  for (final value in values) {
    final text = value?.toString().trim() ?? '';
    if (text.isNotEmpty) {
      return text;
    }
  }
  return null;
}
