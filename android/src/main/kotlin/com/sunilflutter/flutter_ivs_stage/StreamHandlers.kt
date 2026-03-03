package com.sunilflutter.flutter_ivs_stage

import io.flutter.plugin.common.EventChannel

class ParticipantsStreamHandler(private val plugin: FlutterIvsStagePlugin) : EventChannel.StreamHandler {
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        plugin.participantsEventSink = events
    }
    override fun onCancel(arguments: Any?) {
        plugin.participantsEventSink = null
    }
}

class ConnectionStateStreamHandler(private val plugin: FlutterIvsStagePlugin) : EventChannel.StreamHandler {
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        plugin.connectionStateEventSink = events
    }
    override fun onCancel(arguments: Any?) {
        plugin.connectionStateEventSink = null
    }
}

class LocalAudioMutedStreamHandler(private val plugin: FlutterIvsStagePlugin) : EventChannel.StreamHandler {
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        plugin.localAudioMutedEventSink = events
    }
    override fun onCancel(arguments: Any?) {
        plugin.localAudioMutedEventSink = null
    }
}

class LocalVideoMutedStreamHandler(private val plugin: FlutterIvsStagePlugin) : EventChannel.StreamHandler {
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        plugin.localVideoMutedEventSink = events
    }
    override fun onCancel(arguments: Any?) {
        plugin.localVideoMutedEventSink = null
    }
}

class BroadcastingStreamHandler(private val plugin: FlutterIvsStagePlugin) : EventChannel.StreamHandler {
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        plugin.broadcastingEventSink = events
    }
    override fun onCancel(arguments: Any?) {
        plugin.broadcastingEventSink = null
    }
}

class ErrorStreamHandler(private val plugin: FlutterIvsStagePlugin) : EventChannel.StreamHandler {
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        plugin.errorEventSink = events
    }
    override fun onCancel(arguments: Any?) {
        plugin.errorEventSink = null
    }
}

class ScreenShareStreamHandler(private val plugin: FlutterIvsStagePlugin) : EventChannel.StreamHandler {
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        plugin.screenShareEventSink = events
    }
    override fun onCancel(arguments: Any?) {
        plugin.screenShareEventSink = null
    }
}
