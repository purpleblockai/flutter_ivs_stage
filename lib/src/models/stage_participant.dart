import 'stage_stream.dart';

/// Represents a participant in a stage
class StageParticipant {
  final bool isLocal;
  final String? participantId;
  final StageParticipantPublishState publishState;
  final StageParticipantSubscribeState subscribeState;
  final List<StageStream> streams;
  final bool wantsAudioOnly;
  final bool requiresAudioOnly;
  final String broadcastSlotName;
  final Map<String, String> attributes;

  const StageParticipant({
    required this.isLocal,
    this.participantId,
    required this.publishState,
    required this.subscribeState,
    required this.streams,
    this.wantsAudioOnly = false,
    this.requiresAudioOnly = false,
    required this.broadcastSlotName,
    this.attributes = const {},
  });

  /// Whether the participant is currently in audio-only mode
  bool get isAudioOnly => wantsAudioOnly || requiresAudioOnly;

  /// Get the video stream for this participant
  StageStream? get videoStream =>
      streams.where((s) => s.type == StageStreamType.video).lastOrNull;

  /// Get the audio stream for this participant
  StageStream? get audioStream =>
      streams.where((s) => s.type == StageStreamType.audio).lastOrNull;

  factory StageParticipant.fromMap(Map<String, dynamic> map) {
    return StageParticipant(
      isLocal: map['isLocal'] ?? false,
      participantId: map['participantId'],
      publishState: StageParticipantPublishState.fromString(
        map['publishState'],
      ),
      subscribeState: StageParticipantSubscribeState.fromString(
        map['subscribeState'],
      ),
      streams:
          (map['streams'] as List<dynamic>?)
              ?.map(
                (s) => StageStream.fromMap(Map<String, dynamic>.from(s as Map)),
              )
              .toList() ??
          [],
      wantsAudioOnly: map['wantsAudioOnly'] ?? false,
      requiresAudioOnly: map['requiresAudioOnly'] ?? false,
      broadcastSlotName: map['broadcastSlotName'] ?? '',
      attributes: (map['attributes'] as Map?)
              ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
          const {},
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'isLocal': isLocal,
      'participantId': participantId,
      'publishState': publishState.name,
      'subscribeState': subscribeState.name,
      'streams': streams.map((s) => s.toMap()).toList(),
      'wantsAudioOnly': wantsAudioOnly,
      'requiresAudioOnly': requiresAudioOnly,
      'broadcastSlotName': broadcastSlotName,
      'attributes': attributes,
    };
  }

  StageParticipant copyWith({
    bool? isLocal,
    String? participantId,
    StageParticipantPublishState? publishState,
    StageParticipantSubscribeState? subscribeState,
    List<StageStream>? streams,
    bool? wantsAudioOnly,
    bool? requiresAudioOnly,
    String? broadcastSlotName,
    Map<String, String>? attributes,
  }) {
    return StageParticipant(
      isLocal: isLocal ?? this.isLocal,
      participantId: participantId ?? this.participantId,
      publishState: publishState ?? this.publishState,
      subscribeState: subscribeState ?? this.subscribeState,
      streams: streams ?? this.streams,
      wantsAudioOnly: wantsAudioOnly ?? this.wantsAudioOnly,
      requiresAudioOnly: requiresAudioOnly ?? this.requiresAudioOnly,
      broadcastSlotName: broadcastSlotName ?? this.broadcastSlotName,
      attributes: attributes ?? this.attributes,
    );
  }

  @override
  String toString() {
    return 'StageParticipant(isLocal: $isLocal, participantId: $participantId, publishState: $publishState, subscribeState: $subscribeState)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is StageParticipant &&
        other.isLocal == isLocal &&
        other.participantId == participantId &&
        other.publishState == publishState &&
        other.subscribeState == subscribeState;
  }

  @override
  int get hashCode {
    return isLocal.hashCode ^
        participantId.hashCode ^
        publishState.hashCode ^
        subscribeState.hashCode;
  }
}

/// Publish states for a participant
enum StageParticipantPublishState {
  notPublished,
  attemptingPublish,
  published;

  static StageParticipantPublishState fromString(String? value) {
    switch (value) {
      case 'notPublished':
        return StageParticipantPublishState.notPublished;
      case 'attemptingPublish':
        return StageParticipantPublishState.attemptingPublish;
      case 'published':
        return StageParticipantPublishState.published;
      default:
        return StageParticipantPublishState.notPublished;
    }
  }
}

/// Subscribe states for a participant
enum StageParticipantSubscribeState {
  notSubscribed,
  attemptingSubscribe,
  subscribed;

  static StageParticipantSubscribeState fromString(String? value) {
    switch (value) {
      case 'notSubscribed':
        return StageParticipantSubscribeState.notSubscribed;
      case 'attemptingSubscribe':
        return StageParticipantSubscribeState.attemptingSubscribe;
      case 'subscribed':
        return StageParticipantSubscribeState.subscribed;
      default:
        return StageParticipantSubscribeState.notSubscribed;
    }
  }
}
