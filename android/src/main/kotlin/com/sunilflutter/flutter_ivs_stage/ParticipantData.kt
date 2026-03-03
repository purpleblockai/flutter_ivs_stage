package com.sunilflutter.flutter_ivs_stage

import com.amazonaws.ivs.broadcast.ParticipantInfo
import com.amazonaws.ivs.broadcast.Stage
import com.amazonaws.ivs.broadcast.StageStream

class ParticipantData(
    val isLocal: Boolean,
    var participantId: String? = null,
    var attributes: Map<String, String> = emptyMap()
) {
    var publishState: Stage.PublishState = Stage.PublishState.NOT_PUBLISHED
    var subscribeState: Stage.SubscribeState = Stage.SubscribeState.NOT_SUBSCRIBED
    var streams: MutableList<StageStream> = mutableListOf()
    var wantsAudioOnly: Boolean = false
    var requiresAudioOnly: Boolean = false

    val isAudioOnly: Boolean
        get() = wantsAudioOnly || requiresAudioOnly

    val broadcastSlotName: String
        get() = if (isLocal) {
            "localUser"
        } else {
            val id = participantId
                ?: throw IllegalStateException("non-local participants must have a participantId")
            "participant-$id"
        }

    fun toMap(): Map<String, Any?> {
        val streamMaps = streams.map { stream ->
            mapOf(
                "deviceId" to (stream.device?.descriptor?.urn ?: ""),
                "type" to if (stream.streamType == StageStream.Type.VIDEO) "video" else "audio",
                "isMuted" to stream.muted
            )
        }
        return mapOf(
            "isLocal" to isLocal,
            "participantId" to participantId,
            "publishState" to publishState.toFlutterString(),
            "subscribeState" to subscribeState.toFlutterString(),
            "streams" to streamMaps,
            "wantsAudioOnly" to wantsAudioOnly,
            "requiresAudioOnly" to requiresAudioOnly,
            "broadcastSlotName" to broadcastSlotName,
            "attributes" to attributes
        )
    }
}

// Extension functions to match the iOS string format exactly
fun Stage.PublishState.toFlutterString(): String = when (this) {
    Stage.PublishState.NOT_PUBLISHED -> "notPublished"
    Stage.PublishState.ATTEMPTING_PUBLISH -> "attemptingPublish"
    Stage.PublishState.PUBLISHED -> "published"
}

fun Stage.SubscribeState.toFlutterString(): String = when (this) {
    Stage.SubscribeState.NOT_SUBSCRIBED -> "notSubscribed"
    Stage.SubscribeState.ATTEMPTING_SUBSCRIBE -> "attemptingSubscribe"
    Stage.SubscribeState.SUBSCRIBED -> "subscribed"
}

fun Stage.ConnectionState.toFlutterString(): String = when (this) {
    Stage.ConnectionState.DISCONNECTED -> "disconnected"
    Stage.ConnectionState.CONNECTING -> "connecting"
    Stage.ConnectionState.CONNECTED -> "connected"
}
