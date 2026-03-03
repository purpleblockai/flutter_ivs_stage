package com.sunilflutter.flutter_ivs_stage

import android.content.Context
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.projection.MediaProjection
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import android.view.ViewGroup
import android.widget.FrameLayout
import com.amazonaws.ivs.broadcast.BroadcastConfiguration
import com.amazonaws.ivs.broadcast.BroadcastException
import com.amazonaws.ivs.broadcast.BroadcastSession
import com.amazonaws.ivs.broadcast.Device
import com.amazonaws.ivs.broadcast.DeviceDiscovery
import com.amazonaws.ivs.broadcast.ImageLocalStageStream
import com.amazonaws.ivs.broadcast.AudioLocalStageStream
import com.amazonaws.ivs.broadcast.ImageDevice
import com.amazonaws.ivs.broadcast.ImagePreviewView
import com.amazonaws.ivs.broadcast.LocalStageStream
import com.amazonaws.ivs.broadcast.ParticipantInfo
import com.amazonaws.ivs.broadcast.Stage
import com.amazonaws.ivs.broadcast.StageRenderer
import com.amazonaws.ivs.broadcast.StageStream
import com.amazonaws.ivs.broadcast.SurfaceSource

private const val TAG = "IvsStageManager"

interface StageManagerDelegate {
    fun onParticipantsUpdated(participants: List<ParticipantData>)
    fun onConnectionStateChanged(state: Stage.ConnectionState)
    fun onLocalAudioMutedChanged(muted: Boolean)
    fun onLocalVideoMutedChanged(muted: Boolean)
    fun onBroadcastingChanged(broadcasting: Boolean)
    fun onError(error: Exception, source: String?)
    fun onScreenShareStateChanged(sharing: Boolean)
}

class StageManager(private val context: Context) : Stage.Strategy, StageRenderer {

    companion object {
        const val SCREEN_SHARE_PARTICIPANT_ID = "local-screen-share"
    }

    var delegate: StageManagerDelegate? = null

    private data class RemoteRenderState(
        var registeredView: ViewGroup? = null,
        var latestVideoStream: StageStream? = null,
        var latestVideoStreamUrn: String? = null,
        var attachedVideoStreamUrn: String? = null,
        var pendingRetryRunnable: Runnable? = null
    )

    // Video views
    private val remoteRenderStates = mutableMapOf<String, RemoteRenderState>()
    private var localVideoView: ViewGroup? = null
    private var aspectMode: String? = null
    private val remoteAttachRetryDelaysMs = longArrayOf(0L, 150L, 350L, 700L, 1200L, 2000L, 3500L)

    // Video mirroring
    private var shouldMirrorLocalVideo = false
    private var shouldMirrorRemoteVideo = false

    // Devices
    private val deviceDiscovery = DeviceDiscovery(context)
    private var frontCamera: Device? = null
    private var backCamera: Device? = null
    private var microphone: Device? = null
    private var preferredMicrophoneHint: String? = null

    // Stage
    private var stage: Stage? = null
    private var localUserWantsPublish = true
    private val publishStreams = mutableListOf<LocalStageStream>()

    // Screen share
    private var mediaProjection: MediaProjection? = null
    private var mediaProjectionCallback: MediaProjection.Callback? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var screenSource: SurfaceSource? = null
    private var screenShareBroadcastSession: BroadcastSession? = null
    private var screenShareStream: ImageLocalStageStream? = null
    private var screenShareStage: Stage? = null
    var isScreenSharing = false
        private set

    // Broadcast
    private var broadcastSession: BroadcastSession? = null
    private var broadcastEndpoint: String? = null
    private var broadcastStreamKey: String? = null
    private var isBroadcasting = false
        set(value) {
            field = value
            mainHandler.post { delegate?.onBroadcastingChanged(value) }
        }

    // Mute state
    private var isVideoMuted = false
        set(value) {
            field = value
            validateVideoMuteSetting()
            notifyParticipantsUpdate()
        }
    private var isAudioMuted = false
        set(value) {
            field = value
            validateAudioMuteSetting()
            notifyParticipantsUpdate()
        }

    // Participants
    private val participantsData = mutableListOf(ParticipantData(isLocal = true))

    // Connection state
    private var stageConnectionState: Stage.ConnectionState = Stage.ConnectionState.DISCONNECTED
        set(value) {
            field = value
            mainHandler.post { delegate?.onConnectionStateChanged(value) }
        }

    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        setupLocalDevices()
    }

    private fun ensureLocalParticipantEntry(): ParticipantData {
        val existingLocal = participantsData.firstOrNull { it.isLocal }
        if (existingLocal != null) {
            if (participantsData.firstOrNull() !== existingLocal) {
                participantsData.remove(existingLocal)
                participantsData.add(0, existingLocal)
            }
            return existingLocal
        }
        val created = ParticipantData(isLocal = true)
        participantsData.add(0, created)
        return created
    }

    private fun refreshLocalDeviceHandles() {
        val devices = deviceDiscovery.listLocalDevices()
        val cameraDevices = devices.filter {
            it.descriptor.type == Device.Descriptor.DeviceType.CAMERA
        }
        val microphoneDevices = devices.filter {
            it.descriptor.type == Device.Descriptor.DeviceType.MICROPHONE
        }

        frontCamera = devices.firstOrNull {
            it.descriptor.type == Device.Descriptor.DeviceType.CAMERA &&
                it.descriptor.position == Device.Descriptor.Position.FRONT
        }
        backCamera = devices.firstOrNull {
            it.descriptor.type == Device.Descriptor.DeviceType.CAMERA &&
                it.descriptor.position == Device.Descriptor.Position.BACK
        }
        if (frontCamera == null) {
            frontCamera = cameraDevices.firstOrNull()
        }
        if (backCamera == null) {
            backCamera = cameraDevices.firstOrNull { it != frontCamera } ?: frontCamera
        }
        val preferredMic = preferredMicrophoneHint?.let { hint ->
            resolvePreferredMicrophone(microphoneDevices, hint)
        }
        microphone = preferredMic ?: microphoneDevices.firstOrNull()
        Log.d(
            TAG,
            "refreshLocalDeviceHandles: cameras=${cameraDevices.size}, front=${frontCamera != null}, back=${backCamera != null}, mic=${microphone != null}"
        )
    }

    private fun normalizeAudioDeviceHint(value: String): String {
        return value.trim().lowercase()
    }

    private fun matchesAudioDeviceHint(device: Device, normalizedHint: String): Boolean {
        if (normalizedHint.isEmpty()) return false
        val descriptorText = device.descriptor.toString().lowercase()
        val deviceText = device.toString().lowercase()
        if (descriptorText.contains(normalizedHint) || deviceText.contains(normalizedHint)) {
            return true
        }

        val isBluetoothHint = containsAnyToken(normalizedHint, listOf(
            "bluetooth",
            "airpods",
            "airpod",
            "bt",
        ))
        if (isBluetoothHint && containsAnyToken(descriptorText + " " + deviceText, listOf(
                "bluetooth",
                "airpods",
                "airpod",
                "bt",
            ))) {
            return true
        }

        val isWiredHint = containsAnyToken(normalizedHint, listOf(
            "wired",
            "headset",
            "headphone",
            "earphone",
            "usb",
        ))
        if (isWiredHint && containsAnyToken(descriptorText + " " + deviceText, listOf(
                "wired",
                "headset",
                "headphone",
                "earphone",
                "usb",
            ))) {
            return true
        }

        if (normalizedHint == "internal-mic" || normalizedHint == "internal" || normalizedHint == "default") {
            return !containsAnyToken(descriptorText + " " + deviceText, listOf(
                "bluetooth",
                "wired",
                "headset",
                "headphone",
                "usb",
                "airpods",
                "airpod",
            ))
        }

        return false
    }

    private fun containsAnyToken(text: String, tokens: List<String>): Boolean {
        for (token in tokens) {
            if (text.contains(token)) {
                return true
            }
        }
        return false
    }

    private fun resolvePreferredMicrophone(candidates: List<Device>, hint: String): Device? {
        if (candidates.isEmpty()) return null
        val normalizedHint = normalizeAudioDeviceHint(hint)
        return candidates.firstOrNull { matchesAudioDeviceHint(it, normalizedHint) }
    }

    private fun setupLocalDevices() {
        refreshLocalDeviceHandles()

        // Rebuild local camera/mic streams while preserving screen-share stream (if any).
        publishStreams.removeAll { stream ->
            stream is AudioLocalStageStream ||
                (stream is ImageLocalStageStream && stream != screenShareStream)
        }

        val selectedCamera = frontCamera ?: backCamera
        selectedCamera?.let { camera ->
            publishStreams.add(ImageLocalStageStream(camera))
        }
        microphone?.let { mic ->
            publishStreams.add(AudioLocalStageStream(mic))
        }
        // Explicitly apply mute flags to newly created streams. Some devices
        // report default muted=true until setMuted is invoked once.
        publishStreams.filterIsInstance<ImageLocalStageStream>().forEach {
            if (it != screenShareStream) {
                it.setMuted(isVideoMuted)
            }
        }
        publishStreams.filterIsInstance<AudioLocalStageStream>().forEach {
            it.setMuted(isAudioMuted)
        }

        val localData = ensureLocalParticipantEntry()
        localData.streams = publishStreams.map { it as StageStream }.toMutableList()
        notifyParticipantsUpdate()
        setupLocalVideoPreview()
    }

    private fun ensureLocalStreamsExist() {
        val localData = ensureLocalParticipantEntry()
        refreshLocalDeviceHandles()

        val hasCameraStream = publishStreams.any { it is ImageLocalStageStream && it != screenShareStream }
        val hasAudioStream = publishStreams.any { it is AudioLocalStageStream }

        if (!hasCameraStream) {
            val selectedCamera = frontCamera ?: backCamera
            selectedCamera?.let { camera ->
                publishStreams.add(ImageLocalStageStream(camera))
            }
        }
        if (!hasAudioStream) {
            microphone?.let { mic ->
                publishStreams.add(AudioLocalStageStream(mic))
            }
        }
        // Keep restored streams aligned with current local mute flags.
        publishStreams.filterIsInstance<ImageLocalStageStream>().forEach {
            if (it != screenShareStream) {
                it.setMuted(isVideoMuted)
            }
        }
        publishStreams.filterIsInstance<AudioLocalStageStream>().forEach {
            it.setMuted(isAudioMuted)
        }

        if (!hasCameraStream && frontCamera == null && backCamera == null) {
            Log.w(TAG, "ensureLocalStreamsExist: no camera device available")
        }
        if (!hasAudioStream && microphone == null) {
            Log.w(TAG, "ensureLocalStreamsExist: no microphone device available")
        }

        localData.streams = publishStreams.map { it as StageStream }.toMutableList()

        if (!hasCameraStream || !hasAudioStream) {
            notifyParticipantsUpdate()
        }
    }

    // -------------------------------------------------------------------------
    // Public Methods
    // -------------------------------------------------------------------------

    fun joinStage(token: String, completion: (Exception?) -> Unit) {
        try {
            cancelAllRemoteAttachRetries()
            stage?.leave()
            stage = null

            // Re-initialize local participant and devices if needed
            ensureLocalParticipantEntry()
            ensureLocalStreamsExist()
            if (publishStreams.isEmpty()) {
                setupLocalDevices()
            }

            val newStage = Stage(context, token, this)
            newStage.addRenderer(this)
            newStage.join()
            stage = newStage
            mainHandler.post { setupLocalVideoPreview() }
            completion(null)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to join stage", e)
            displayError(e, "JoinStageSession")
            completion(e)
        }
    }

    fun leaveStage() {
        Log.d(TAG, "Leaving stage")
        screenShareStage?.leave()
        screenShareStage = null
        stage?.leave()
        stage = null
        cancelAllRemoteAttachRetries()

        participantsData.clear()

        // Clear video views
        mainHandler.post {
            remoteRenderStates.values.forEach { state ->
                state.registeredView?.removeAllViews()
            }
            remoteRenderStates.clear()

            localVideoView?.let { (it as? ViewGroup)?.removeAllViews() }
            localVideoView = null
        }

        publishStreams.clear()

        delegate?.onParticipantsUpdated(emptyList())
        delegate?.onConnectionStateChanged(Stage.ConnectionState.DISCONNECTED)

        Log.d(TAG, "Stage left and cleaned up")
    }

    fun toggleLocalVideoMute() {
        isVideoMuted = !isVideoMuted
        Log.d(TAG, "toggleLocalVideoMute -> muted=$isVideoMuted")
    }

    fun toggleLocalAudioMute() {
        isAudioMuted = !isAudioMuted
        Log.d(TAG, "toggleLocalAudioMute -> muted=$isAudioMuted")
    }

    fun toggleAudioOnlySubscribe(participantId: String) {
        mutatingParticipant(participantId) {
            it.wantsAudioOnly = !it.wantsAudioOnly
        }
        stage?.refreshStrategy()
    }

    fun selectAudioInput(deviceId: String, completion: (Exception?) -> Unit) {
        try {
            val normalizedHint = normalizeAudioDeviceHint(deviceId)
            if (normalizedHint.isEmpty()) {
                completion(Exception("Audio input device id is required"))
                return
            }

            preferredMicrophoneHint = normalizedHint
            val micDevices = deviceDiscovery.listLocalDevices().filter {
                it.descriptor.type == Device.Descriptor.DeviceType.MICROPHONE
            }
            val targetMic = resolvePreferredMicrophone(micDevices, normalizedHint)
                ?: micDevices.firstOrNull()
                ?: throw Exception("No microphone device available")

            microphone = targetMic
            publishStreams.removeAll { it is AudioLocalStageStream }
            val audioStream = AudioLocalStageStream(targetMic)
            audioStream.setMuted(isAudioMuted)
            publishStreams.add(audioStream)

            val localData = ensureLocalParticipantEntry()
            localData.streams = publishStreams.map { it as StageStream }.toMutableList()
            stage?.refreshStrategy()
            notifyParticipantsUpdate()
            completion(null)
        } catch (e: Exception) {
            Log.e(TAG, "selectAudioInput failed for deviceId=$deviceId", e)
            completion(e)
        }
    }

    // -------------------------------------------------------------------------
    // Video View Management
    // -------------------------------------------------------------------------

    fun setLocalVideoView(view: ViewGroup) {
        Log.d(TAG, "Registering local video view")
        localVideoView = view
        ensureLocalStreamsExist()
        val hasCameraStream = publishStreams.any { it is ImageLocalStageStream && it != screenShareStream }
        if (!hasCameraStream) {
            setupLocalDevices()
        }
        setupLocalVideoPreview()
    }

    fun setVideoView(view: ViewGroup, participantId: String) {
        Log.i(TAG, "remote view register participant=$participantId")
        val state = remoteRenderStates.getOrPut(participantId) { RemoteRenderState() }
        state.registeredView = view
        attachRemoteVideo(participantId, attempt = 0, reason = "setVideoView")
    }

    fun removeVideoView(participantId: String, view: ViewGroup) {
        val state = remoteRenderStates[participantId] ?: return
        // Only remove if disposing view is still the active registered instance.
        if (state.registeredView !== view) return
        Log.i(TAG, "remote view dispose participant=$participantId")
        cancelRemoteAttachRetry(participantId)
        mainHandler.post { view.removeAllViews() }
        state.registeredView = null
        state.attachedVideoStreamUrn = null
        pruneRemoteRenderState(participantId)
    }

    fun removeLocalVideoView(view: ViewGroup) {
        Log.d(TAG, "Removing local video view")
        // Only clear if the registered local view is the same instance being disposed.
        if (localVideoView === view) {
            mainHandler.post { (view as? ViewGroup)?.removeAllViews() }
            localVideoView = null
        }
    }

    fun refreshAllVideoPreviews() {
        Log.d(TAG, "Refreshing all video previews")
        refreshLocalVideoPreview()
        for (participantId in remoteRenderStates.keys) {
            attachRemoteVideo(participantId, attempt = 0, reason = "refreshAllVideoPreviews")
        }
    }

    fun setVideoMirroring(localVideo: Boolean, remoteVideo: Boolean) {
        shouldMirrorLocalVideo = localVideo
        shouldMirrorRemoteVideo = remoteVideo

        mainHandler.post {
            localVideoView?.let { applyMirroring(it, shouldMirrorLocalVideo) }
            for ((participantId, state) in remoteRenderStates) {
                if (participantId == SCREEN_SHARE_PARTICIPANT_ID) continue
                state.registeredView?.let { applyMirroring(it, shouldMirrorRemoteVideo) }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Camera Preview
    // -------------------------------------------------------------------------

    fun initPreview(cameraType: String, aspectMode: String, completion: (Exception?) -> Unit) {
        Log.d(TAG, "initPreview - cameraType: $cameraType, aspectMode: $aspectMode")
        this.aspectMode = aspectMode

        ensureLocalStreamsExist()

        val targetCamera = if (cameraType == "back") {
            backCamera ?: frontCamera
        } else {
            frontCamera ?: backCamera
        }
        if (targetCamera == null) {
            completion(Exception("Camera not available"))
            return
        }

        // Switch camera device in publish streams if needed
        switchCameraDevice(targetCamera)
        mainHandler.post {
            refreshLocalVideoPreview()
            completion(null)
        }
    }

    fun toggleCamera(cameraType: String, completion: (Exception?) -> Unit) {
        Log.d(TAG, "toggleCamera - switching to: $cameraType")
        ensureLocalStreamsExist()
        val targetCamera = if (cameraType == "back") {
            backCamera ?: frontCamera
        } else {
            frontCamera ?: backCamera
        }
        if (targetCamera == null) {
            completion(Exception("Camera type '$cameraType' not available"))
            return
        }

        switchCameraDevice(targetCamera)
        mainHandler.post {
            refreshLocalVideoPreview()
            completion(null)
        }
    }

    fun stopPreview() {
        Log.d(TAG, "Stopping camera preview")
        mainHandler.post {
            Log.d(TAG, "stopPreview: clearing local video view")
            localVideoView?.let { (it as? ViewGroup)?.removeAllViews() }
            localVideoView = null
        }
        // Keep local streams intact so stage join can publish immediately without
        // depending on a new device-discovery cycle.
        participantsData.firstOrNull { it.isLocal }?.streams =
            publishStreams.map { it as StageStream }.toMutableList()
    }

    // -------------------------------------------------------------------------
    // Broadcasting
    // -------------------------------------------------------------------------

    fun setBroadcastAuth(endpoint: String, streamKey: String): Boolean {
        broadcastEndpoint = endpoint
        broadcastStreamKey = streamKey
        return true
    }

    fun toggleBroadcasting(completion: (Exception?) -> Unit) {
        val endpoint = broadcastEndpoint
        val streamKey = broadcastStreamKey
        if (endpoint == null || streamKey == null) {
            val error = Exception("Invalid Endpoint or StreamKey")
            displayError(error, "toggleBroadcasting")
            completion(error)
            return
        }

        if (isBroadcasting) {
            broadcastSession?.stop()
            isBroadcasting = false
            completion(null)
        } else {
            try {
                if (broadcastSession == null) {
                    setupBroadcastSession()
                }
                broadcastSession?.start(endpoint, streamKey)
                isBroadcasting = true
                completion(null)
            } catch (e: Exception) {
                displayError(e, "StartBroadcast")
                isBroadcasting = false
                broadcastSession?.release()
                broadcastSession = null
                completion(e)
            }
        }
    }

    // -------------------------------------------------------------------------
    // Screen Share
    // -------------------------------------------------------------------------

    fun startScreenShare(
        ctx: Context,
        projection: MediaProjection,
        token: String? = null,
        completion: (Exception?) -> Unit
    ) {
        if (isScreenSharing) {
            completion(null)
            return
        }

        try {
            val metrics = ctx.resources.displayMetrics
            val width = 720
            val height = 1280
            val dpi = metrics.densityDpi

            Log.d(TAG, "Screen share dimensions: ${width}x${height} @ ${dpi}dpi, dual-stage: ${token != null}")

            mediaProjection = projection

            // Register MediaProjection callback (required on Android 14+)
            mediaProjectionCallback = object : MediaProjection.Callback() {
                override fun onStop() {
                    Log.d(TAG, "MediaProjection stopped via callback")
                    mainHandler.post {
                        if (isScreenSharing) {
                            cleanupScreenShare()
                            mainHandler.post {
                                delegate?.onScreenShareStateChanged(false)
                            }
                        }
                    }
                }
            }
            projection.registerCallback(mediaProjectionCallback!!, mainHandler)

            // Create a lightweight BroadcastSession just for the SurfaceSource factory
            if (screenShareBroadcastSession == null) {
                val config = BroadcastConfiguration().apply {
                    video.setSize(width, height)
                }
                screenShareBroadcastSession = BroadcastSession(ctx, null, config, emptyArray())
            }

            // Create SurfaceSource for screen capture
            @Suppress("UNCHECKED_CAST")
            val source = screenShareBroadcastSession!!.createImageInputSource() as SurfaceSource
            screenSource = source
            val screenSurface: Surface = source.inputSurface
                ?: throw Exception("Failed to get input surface from screen source")

            Log.d(TAG, "Screen source created with surface: $screenSurface")

            // Create VirtualDisplay to capture screen
            virtualDisplay = projection.createVirtualDisplay(
                "IVSStageScreenShare",
                width,
                height,
                dpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                screenSurface,
                null,
                mainHandler
            )

            if (virtualDisplay == null) {
                throw Exception("Failed to create VirtualDisplay")
            }
            Log.d(TAG, "VirtualDisplay created: $virtualDisplay")

            // Create the screen share stream
            screenShareStream = ImageLocalStageStream(screenSource!!)

            if (token != null) {
                // Dual-stage mode: join a second Stage dedicated to screen share.
                // The primary stage continues publishing camera + mic unchanged.
                // Other participants see screen share as a separate remote participant.
                val ssStage = Stage(ctx, token, ScreenShareStrategy())
                ssStage.addRenderer(ScreenShareRenderer())
                ssStage.join()
                screenShareStage = ssStage
                Log.d(TAG, "Screen share stage joined (dual-stage mode)")
            } else {
                // Single-stage fallback: add screen share to primary publishStreams.
                // stageStreamsToPublishForParticipant filters to one video stream for the SDK.
                publishStreams.add(0, screenShareStream!!)

                // Update local participant streams
                val localData = ensureLocalParticipantEntry()
                localData.streams = publishStreams.map { it as StageStream }.toMutableList()

                // Add a virtual participant so screen share appears as a separate tile
                val screenShareParticipant = ParticipantData(
                    isLocal = false,
                    participantId = SCREEN_SHARE_PARTICIPANT_ID
                )
                screenShareParticipant.publishState = Stage.PublishState.PUBLISHED
                screenShareParticipant.subscribeState = Stage.SubscribeState.SUBSCRIBED
                screenShareParticipant.streams = mutableListOf(screenShareStream!! as StageStream)
                participantsData.add(screenShareParticipant)

                // Tell the stage to refresh its strategy
                stage?.refreshStrategy()
                notifyParticipantsUpdate()
            }

            isScreenSharing = true
            Log.d(TAG, "Screen sharing started successfully")
            completion(null)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start screen share", e)
            cleanupScreenShare()
            completion(e)
        }
    }

    fun stopScreenShare() {
        if (!isScreenSharing) return

        Log.d(TAG, "Stopping screen share")
        cleanupScreenShare()
        mainHandler.post {
            delegate?.onScreenShareStateChanged(false)
        }
    }

    private fun cleanupScreenShare() {
        val wasDualStage = screenShareStage != null

        // Leave and destroy screen share stage (dual-stage mode)
        screenShareStage?.leave()
        screenShareStage = null

        // Remove screen share stream from primary publish streams (single-stage mode)
        screenShareStream?.let { publishStreams.remove(it) }
        screenShareStream = null

        // Release screen source (don't unbind from mixer - we're using stages, not broadcast)
        screenSource = null

        // Release VirtualDisplay
        virtualDisplay?.release()
        virtualDisplay = null

        // Unregister callback and stop MediaProjection
        mediaProjection?.let { projection ->
            mediaProjectionCallback?.let { callback ->
                try {
                    projection.unregisterCallback(callback)
                } catch (e: Exception) {
                    Log.w(TAG, "Error unregistering MediaProjection callback", e)
                }
            }
            projection.stop()
        }
        mediaProjection = null
        mediaProjectionCallback = null

        // Release the screen share broadcast session
        screenShareBroadcastSession?.release()
        screenShareBroadcastSession = null

        if (!wasDualStage) {
            // Single-stage mode: remove the virtual screen share participant tile
            participantsData.removeAll { it.participantId == SCREEN_SHARE_PARTICIPANT_ID }
            mainHandler.post {
                remoteRenderStates.remove(SCREEN_SHARE_PARTICIPANT_ID)?.registeredView?.removeAllViews()
            }
        }
        // In dual-stage mode, the primary stage's renderer handles the remote
        // screen share participant lifecycle (onParticipantLeft fires automatically)

        // Update local participant streams
        val localData = ensureLocalParticipantEntry()
        localData.streams = publishStreams.map { it as StageStream }.toMutableList()

        // Refresh the stage strategy
        stage?.refreshStrategy()
        notifyParticipantsUpdate()

        // Refresh local video preview to show camera
        mainHandler.post { refreshLocalVideoPreview() }

        isScreenSharing = false
        Log.d(TAG, "Screen share cleaned up (dual-stage: $wasDualStage)")
    }

    fun dispose() {
        cancelAllRemoteAttachRetries()
        mainHandler.post {
            localVideoView?.let { (it as? ViewGroup)?.removeAllViews() }
            remoteRenderStates.values.forEach { it.registeredView?.removeAllViews() }
            remoteRenderStates.clear()
            localVideoView = null
        }

        if (isScreenSharing) {
            stopScreenShare()
        }

        if (isBroadcasting) {
            broadcastSession?.stop()
            broadcastSession?.release()
            broadcastSession = null
            isBroadcasting = false
        }

        leaveStage()
    }

    // -------------------------------------------------------------------------
    // Stage.Strategy
    // -------------------------------------------------------------------------

    override fun shouldSubscribeToParticipant(stage: Stage, info: ParticipantInfo): Stage.SubscribeType {
        val data = dataForParticipant(info.participantId)
        return if (data?.isAudioOnly == true) Stage.SubscribeType.AUDIO_ONLY
        else Stage.SubscribeType.AUDIO_VIDEO
    }

    override fun shouldPublishFromParticipant(stage: Stage, info: ParticipantInfo): Boolean {
        return localUserWantsPublish
    }

    override fun stageStreamsToPublishForParticipant(
        stage: Stage,
        info: ParticipantInfo
    ): List<LocalStageStream> {
        val localData = participantsData.firstOrNull { it.isLocal } ?: return emptyList()
        if (localData.participantId.isNullOrEmpty()) {
            localData.participantId = info.participantId
        } else if (localData.participantId != info.participantId) {
            return emptyList()
        }

        // Dual-stage mode: primary stage always publishes camera + mic only.
        // Screen share is published via the separate screenShareStage.
        if (screenShareStage != null) {
            return publishStreams.filter { it !== screenShareStream }
        }
        // Single-stage fallback: screen share replaces camera for publishing.
        // Camera stays in publishStreams for local preview rendering.
        if (isScreenSharing && screenShareStream != null) {
            return publishStreams.filter { it !is ImageLocalStageStream || it === screenShareStream }
        }
        return publishStreams
    }

    // -------------------------------------------------------------------------
    // StageRenderer
    // -------------------------------------------------------------------------

    override fun onError(exception: BroadcastException) {
        val message = exception.message ?: ""
        // Filter out non-critical IVS SDK warnings (e.g. transient WebRTC subscribe state)
        if (message.contains("No audio packets are received") ||
            message.contains("No video packets are received") ||
            message.contains("multiple audio input devices", ignoreCase = true)) {
            Log.w(TAG, "Stage warning (suppressed): $message")
            return
        }
        Log.e(TAG, "Stage error: $message")
        displayError(exception, "StageRenderer")
    }

    override fun onParticipantJoined(stage: Stage, info: ParticipantInfo) {
        Log.d(TAG, "participantDidJoin - ${info.participantId}")
        val attrs = info.attributes?.mapValues { it.value.toString() } ?: emptyMap()
        if (info.isLocal) {
            val localData = ensureLocalParticipantEntry()
            localData.participantId = info.participantId
            localData.attributes = attrs
            ensureLocalStreamsExist()
            mainHandler.post { setupLocalVideoPreview() }
        } else {
            val existing = participantsData.firstOrNull {
                !it.isLocal && it.participantId == info.participantId
            }
            if (existing != null) {
                existing.attributes = attrs
            } else {
                participantsData.add(
                    ParticipantData(
                        isLocal = false,
                        participantId = info.participantId,
                        attributes = attrs
                    )
                )
            }
            attachRemoteVideo(info.participantId, attempt = 0, reason = "onParticipantJoined")
        }
        notifyParticipantsUpdate()
    }

    override fun onParticipantLeft(stage: Stage, info: ParticipantInfo) {
        Log.i(TAG, "participantDidLeave - ${info.participantId}")
        if (info.isLocal) {
            participantsData.firstOrNull { it.isLocal }?.participantId = null
        } else {
            cancelRemoteAttachRetry(info.participantId)
            participantsData.removeAll { it.participantId == info.participantId }
            mainHandler.post { remoteRenderStates.remove(info.participantId)?.registeredView?.removeAllViews() }
        }
        notifyParticipantsUpdate()
    }

    override fun onParticipantPublishStateChanged(
        stage: Stage,
        info: ParticipantInfo,
        publishState: Stage.PublishState
    ) {
        Log.d(TAG, "participant ${info.participantId} didChangePublishState to $publishState")
        if (info.isLocal) {
            val localData = ensureLocalParticipantEntry()
            localData.publishState = publishState
        } else {
            val remote = upsertRemoteParticipant(info.participantId)
            remote.publishState = publishState
            if (publishState == Stage.PublishState.PUBLISHED) {
                attachRemoteVideo(info.participantId, attempt = 0, reason = "onPublishStateChanged")
            }
        }
        notifyParticipantsUpdate()
    }

    override fun onParticipantSubscribeStateChanged(
        stage: Stage,
        info: ParticipantInfo,
        subscribeState: Stage.SubscribeState
    ) {
        Log.d(TAG, "participant ${info.participantId} didChangeSubscribeState to $subscribeState")
        if (info.isLocal) {
            val localData = ensureLocalParticipantEntry()
            localData.subscribeState = subscribeState
        } else {
            val remote = upsertRemoteParticipant(info.participantId)
            remote.subscribeState = subscribeState
            if (subscribeState == Stage.SubscribeState.SUBSCRIBED ||
                subscribeState == Stage.SubscribeState.ATTEMPTING_SUBSCRIBE
            ) {
                attachRemoteVideo(
                    info.participantId,
                    attempt = 0,
                    reason = "onSubscribeStateChanged"
                )
            }
        }
        notifyParticipantsUpdate()
    }

    override fun onStreamsAdded(stage: Stage, info: ParticipantInfo, streams: List<StageStream>) {
        Log.i(TAG, "participant (${info.participantId}) didAdd ${streams.size} streams")
        if (info.isLocal) return

        val data = upsertRemoteParticipant(info.participantId)
        val state = remoteRenderStates.getOrPut(info.participantId) { RemoteRenderState() }
        for (stream in streams) {
            val urn = stream.device?.descriptor?.urn?.takeIf { it.isNotBlank() }
            if (urn != null) {
                data.streams.removeAll { existing ->
                    existing.streamType == stream.streamType &&
                        existing.device?.descriptor?.urn == urn
                }
            } else {
                // Some devices provide blank/null URNs for remote streams.
                // Keep one latest stream per type in this case.
                data.streams.removeAll { existing ->
                    existing.streamType == stream.streamType &&
                        existing.device?.descriptor?.urn.isNullOrBlank()
                }
            }
            data.streams.add(stream)
            if (stream.streamType == StageStream.Type.VIDEO) {
                state.latestVideoStream = stream
                state.latestVideoStreamUrn = urn
            }
        }
        notifyParticipantsUpdate()

        refreshLatestRemoteVideoUrn(info.participantId)
        attachRemoteVideo(info.participantId, attempt = 0, reason = "onStreamsAdded")
    }

    override fun onStreamsRemoved(stage: Stage, info: ParticipantInfo, streams: List<StageStream>) {
        Log.i(TAG, "participant (${info.participantId}) didRemove ${streams.size} streams")
        if (info.isLocal) return

        val data = upsertRemoteParticipant(info.participantId)
        val removedUrns = streams.mapNotNull { it.device?.descriptor?.urn }.toSet()
        if (removedUrns.isNotEmpty()) {
            data.streams.removeAll { stream ->
                stream.device?.descriptor?.urn in removedUrns
            }
        } else {
            // Some SDK callbacks can report removals with blank URNs during
            // transient transitions. Avoid clearing by type here because it can
            // drop active remote video unexpectedly and cause black tiles.
            Log.w(
                TAG,
                "onStreamsRemoved without URN for participant=${info.participantId}; keeping existing streams"
            )
        }
        notifyParticipantsUpdate()

        val state = remoteRenderStates[info.participantId]
        val hasRemainingVideo = participantsData
            .firstOrNull { it.participantId == info.participantId }
            ?.streams
            ?.any { it.streamType == StageStream.Type.VIDEO } == true
        val attachedUrn = state?.attachedVideoStreamUrn
        val shouldClearAttachedView =
            (attachedUrn != null && removedUrns.contains(attachedUrn)) ||
                (attachedUrn.isNullOrEmpty() && !hasRemainingVideo)
        if (shouldClearAttachedView) {
            state?.registeredView?.let { view ->
                mainHandler.post { view.removeAllViews() }
            }
            state?.attachedVideoStreamUrn = null
        }
        if (removedUrns.isNotEmpty()) {
            val latestUrn = state?.latestVideoStreamUrn
            if (latestUrn != null && removedUrns.contains(latestUrn)) {
                state?.latestVideoStream = null
                state?.latestVideoStreamUrn = null
            }
        }
        refreshLatestRemoteVideoUrn(info.participantId)
        attachRemoteVideo(info.participantId, attempt = 0, reason = "onStreamsRemoved")
    }

    override fun onStreamsMutedChanged(
        stage: Stage,
        info: ParticipantInfo,
        streams: List<StageStream>
    ) {
        Log.d(TAG, "participant (${info.participantId}) didChangeMutedStreams")
        if (info.isLocal) return
        refreshLatestRemoteVideoUrn(info.participantId)
        attachRemoteVideo(info.participantId, attempt = 0, reason = "onStreamsMutedChanged")
        notifyParticipantsUpdate()
    }

    override fun onConnectionStateChanged(
        stage: Stage,
        state: Stage.ConnectionState,
        exception: BroadcastException?
    ) {
        Log.d(TAG, "didChangeConnectionState to $state")
        stageConnectionState = state
        if (exception != null) {
            displayError(exception, "StageConnectionState")
        }
    }

    // -------------------------------------------------------------------------
    // Private Helpers
    // -------------------------------------------------------------------------

    private fun setupLocalVideoPreview(attempt: Int = 0) {
        val localView = localVideoView ?: run {
            Log.d(TAG, "setupLocalVideoPreview - no local view registered")
            return
        }

        var cameraStream = publishStreams.filterIsInstance<ImageLocalStageStream>()
            .firstOrNull { it != screenShareStream }
        if (cameraStream == null) {
            ensureLocalStreamsExist()
            cameraStream = publishStreams.filterIsInstance<ImageLocalStageStream>()
                .firstOrNull { it != screenShareStream }
        }
        if (cameraStream == null && attempt == 0) {
            setupLocalDevices()
            cameraStream = publishStreams.filterIsInstance<ImageLocalStageStream>()
                .firstOrNull { it != screenShareStream }
        }
        if (cameraStream == null) {
            val retryAttempt = attempt + 1
            if (retryAttempt <= 20) {
                val delayMs = when {
                    retryAttempt <= 3 -> 180L
                    retryAttempt <= 8 -> 350L
                    else -> 800L
                }
                Log.w(
                    TAG,
                    "setupLocalVideoPreview - no camera stream available, retry=$retryAttempt delayMs=$delayMs"
                )
                mainHandler.postDelayed({ setupLocalVideoPreview(retryAttempt) }, delayMs)
            } else {
                Log.w(TAG, "setupLocalVideoPreview - no camera stream available after retries")
            }
            return
        }

        val imageDevice = cameraStream.device as? ImageDevice ?: return
        mainHandler.post {
            try {
                val preview: ImagePreviewView = imageDevice.previewView
                val parent = preview.parent
                if (parent is ViewGroup) {
                    parent.removeView(preview)
                }
                (localView as? ViewGroup)?.removeAllViews()
                localView.addView(
                    preview,
                    FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT
                    )
                )
                applyMirroring(localView, shouldMirrorLocalVideo)
                Log.d(TAG, "setupLocalVideoPreview - successfully set up camera preview")
            } catch (e: Exception) {
                Log.e(TAG, "setupLocalVideoPreview - failed", e)
                val retryAttempt = attempt + 1
                if (retryAttempt <= 20) {
                    val delayMs = when {
                        retryAttempt <= 3 -> 180L
                        retryAttempt <= 8 -> 350L
                        else -> 800L
                    }
                    mainHandler.postDelayed({ setupLocalVideoPreview(retryAttempt) }, delayMs)
                }
            }
        }
    }

    private fun refreshLatestRemoteVideoUrn(participantId: String) {
        val state = remoteRenderStates.getOrPut(participantId) { RemoteRenderState() }
        val latestVideo = participantsData
            .firstOrNull { it.participantId == participantId }
            ?.streams
            ?.asReversed()
            ?.firstOrNull { it.streamType == StageStream.Type.VIDEO }
        if (latestVideo != null) {
            state.latestVideoStream = latestVideo
        }
        val latestUrn = (latestVideo ?: state.latestVideoStream)
            ?.device
            ?.descriptor
            ?.urn
            ?.takeIf { it.isNotBlank() }
        state.latestVideoStreamUrn = latestUrn
    }

    private fun pruneRemoteRenderState(participantId: String) {
        val state = remoteRenderStates[participantId] ?: return
        val hasView = state.registeredView != null
        val hasLatest = !state.latestVideoStreamUrn.isNullOrEmpty()
        val hasPending = state.pendingRetryRunnable != null
        if (!hasView && !hasLatest && !hasPending) {
            remoteRenderStates.remove(participantId)
        }
    }

    private fun cancelRemoteAttachRetry(participantId: String) {
        val state = remoteRenderStates[participantId] ?: return
        state.pendingRetryRunnable?.let { pending ->
            mainHandler.removeCallbacks(pending)
            state.pendingRetryRunnable = null
            Log.i(TAG, "remote attach retry canceled participant=$participantId")
        }
        pruneRemoteRenderState(participantId)
    }

    private fun cancelAllRemoteAttachRetries() {
        remoteRenderStates.values.forEach { state ->
            state.pendingRetryRunnable?.let { mainHandler.removeCallbacks(it) }
            state.pendingRetryRunnable = null
        }
    }

    private fun scheduleRemoteAttachRetry(participantId: String, attempt: Int, reason: String) {
        val state = remoteRenderStates[participantId] ?: return
        if (state.registeredView == null) {
            Log.i(
                TAG,
                "remote attach retry skipped participant=$participantId reason=no registered view"
            )
            return
        }
        val rawNextAttempt = attempt + 1
        val maxAttemptIndex = remoteAttachRetryDelaysMs.size - 1
        if (rawNextAttempt > maxAttemptIndex) {
            Log.w(
                TAG,
                "remote attach give-up participant=$participantId attempt=$attempt reason=$reason"
            )
            return
        }
        val nextAttempt = rawNextAttempt

        cancelRemoteAttachRetry(participantId)
        val delay = remoteAttachRetryDelaysMs[nextAttempt]
        val runnable = Runnable {
            val currentState = remoteRenderStates[participantId] ?: return@Runnable
            currentState.pendingRetryRunnable = null
            attachRemoteVideo(participantId, attempt = nextAttempt, reason = "retry")
        }
        state.pendingRetryRunnable = runnable
        Log.i(
            TAG,
            "remote attach retry scheduled participant=$participantId attempt=$nextAttempt delayMs=$delay reason=$reason"
        )
        mainHandler.postDelayed(runnable, delay)
    }

    private fun attachRemoteVideo(participantId: String, attempt: Int, reason: String) {
        val maxAttempt = remoteAttachRetryDelaysMs.size - 1
        val state = remoteRenderStates.getOrPut(participantId) { RemoteRenderState() }
        refreshLatestRemoteVideoUrn(participantId)

        val view = state.registeredView
        val latestUrn = state.latestVideoStreamUrn?.takeIf { it.isNotBlank() }
        val participantData = participantsData.firstOrNull { it.participantId == participantId }
        val videoStreamCount = participantData?.streams?.count {
            it.streamType == StageStream.Type.VIDEO
        } ?: if (state.latestVideoStream != null) 1 else 0

        Log.i(
            TAG,
            "remote attach attempt participant=$participantId attempt=$attempt/$maxAttempt reason=$reason viewRegistered=${view != null} videoStreams=$videoStreamCount latestUrn=${latestUrn ?: "none"} attachedUrn=${state.attachedVideoStreamUrn ?: "none"}"
        )

        if (view == null) {
            cancelRemoteAttachRetry(participantId)
            return
        }
        val latestVideoStream = if (latestUrn != null) {
            participantData?.streams?.asReversed()?.firstOrNull {
                it.streamType == StageStream.Type.VIDEO &&
                    it.device?.descriptor?.urn == latestUrn
            } ?: state.latestVideoStream
        } else {
            participantData?.streams?.asReversed()?.firstOrNull {
                it.streamType == StageStream.Type.VIDEO
            } ?: state.latestVideoStream
        }
        if (latestVideoStream == null) {
            scheduleRemoteAttachRetry(participantId, attempt, "video stream missing")
            return
        }
        val imageDevice = latestVideoStream.device as? ImageDevice
        if (imageDevice == null) {
            scheduleRemoteAttachRetry(participantId, attempt, "image device unavailable")
            return
        }

        if (latestUrn != null &&
            state.attachedVideoStreamUrn == latestUrn &&
            view.childCount > 0
        ) {
            Log.i(TAG, "remote attach skip participant=$participantId stream unchanged")
            return
        }

        mainHandler.post {
            try {
                val preview: ImagePreviewView = imageDevice.previewView
                (preview.parent as? ViewGroup)?.removeView(preview)
                view.removeAllViews()
                view.addView(
                    preview,
                    FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT
                    )
                )
                val shouldMirror = participantId != SCREEN_SHARE_PARTICIPANT_ID && shouldMirrorRemoteVideo
                applyMirroring(view, shouldMirror)
                state.attachedVideoStreamUrn = latestUrn
                cancelRemoteAttachRetry(participantId)
                Log.i(TAG, "remote attach success participant=$participantId streamUrn=$latestUrn")
            } catch (e: Exception) {
                Log.w(
                    TAG,
                    "remote attach failed participant=$participantId attempt=$attempt reason=${e.message ?: "unknown"}"
                )
                scheduleRemoteAttachRetry(
                    participantId,
                    attempt,
                    "preview attach failed: ${e.message ?: "unknown"}"
                )
            }
        }
    }

    private fun refreshLocalVideoPreview() {
        localVideoView?.let { view ->
            (view as? ViewGroup)?.removeAllViews()
            setupLocalVideoPreview(attempt = 0)
        }
    }

    private fun switchCameraDevice(targetCamera: Device) {
        val existingIndex = publishStreams.indexOfFirst {
            it is ImageLocalStageStream && it != screenShareStream
        }
        if (existingIndex >= 0) {
            publishStreams.removeAt(existingIndex)
        }
        val insertIndex = if (screenShareStream != null) {
            // Insert camera after screen share
            val ssIndex = publishStreams.indexOf(screenShareStream as LocalStageStream)
            if (ssIndex >= 0) ssIndex + 1 else 0
        } else 0
        publishStreams.add(insertIndex, ImageLocalStageStream(targetCamera))
        publishStreams.filterIsInstance<ImageLocalStageStream>().forEach {
            if (it != screenShareStream) {
                it.setMuted(isVideoMuted)
            }
        }
        val localData = ensureLocalParticipantEntry()
        localData.streams = publishStreams.map { it as StageStream }.toMutableList()
        stage?.refreshStrategy()
    }

    private fun validateVideoMuteSetting() {
        publishStreams.filterIsInstance<ImageLocalStageStream>().forEach {
            if (it != screenShareStream) {
                it.setMuted(isVideoMuted)
            }
        }
        mainHandler.post { delegate?.onLocalVideoMutedChanged(isVideoMuted) }
    }

    private fun validateAudioMuteSetting() {
        publishStreams.filterIsInstance<AudioLocalStageStream>().forEach {
            it.setMuted(isAudioMuted)
        }
        mainHandler.post { delegate?.onLocalAudioMutedChanged(isAudioMuted) }
    }

    private fun applyMirroring(view: ViewGroup, shouldMirror: Boolean) {
        view.scaleX = if (shouldMirror) -1f else 1f
    }

    private fun dataForParticipant(participantId: String): ParticipantData? {
        return participantsData.firstOrNull { it.participantId == participantId }
    }

    private fun upsertRemoteParticipant(participantId: String): ParticipantData {
        val existing = participantsData.firstOrNull {
            !it.isLocal && it.participantId == participantId
        }
        if (existing != null) return existing
        val created = ParticipantData(isLocal = false, participantId = participantId)
        participantsData.add(created)
        return created
    }

    private fun mutatingParticipant(participantId: String?, modifier: (ParticipantData) -> Unit) {
        val participant = participantsData.firstOrNull { it.participantId == participantId }
            ?: return
        modifier(participant)
        notifyParticipantsUpdate()
    }

    private fun notifyParticipantsUpdate() {
        mainHandler.post {
            delegate?.onParticipantsUpdated(participantsData.toList())
        }
    }

    private fun displayError(error: Exception, source: String? = null) {
        mainHandler.post {
            delegate?.onError(error, source)
        }
    }

    private fun setupBroadcastSession() {
        try {
            val config = BroadcastConfiguration().apply {
                video.setSize(720, 1280)
                video.setMaxBitrate(3500000)
                video.setMinBitrate(500000)
                video.setInitialBitrate(1500000)
            }
            broadcastSession = BroadcastSession(context, null, config, emptyArray())
        } catch (e: Exception) {
            displayError(e, "SetupBroadcastSession")
        }
    }

    // -------------------------------------------------------------------------
    // Screen Share Stage (dual-stage mode)
    // -------------------------------------------------------------------------

    private inner class ScreenShareStrategy : Stage.Strategy {
        override fun shouldSubscribeToParticipant(
            stage: Stage,
            info: ParticipantInfo
        ): Stage.SubscribeType = Stage.SubscribeType.NONE

        override fun shouldPublishFromParticipant(
            stage: Stage,
            info: ParticipantInfo
        ): Boolean = true

        override fun stageStreamsToPublishForParticipant(
            stage: Stage,
            info: ParticipantInfo
        ): List<LocalStageStream> {
            return listOfNotNull(screenShareStream)
        }
    }

    private inner class ScreenShareRenderer : StageRenderer {
        override fun onError(exception: BroadcastException) {
            val message = exception.message ?: ""
            if (message.contains("No audio packets are received") ||
                message.contains("No video packets are received")) {
                Log.w(TAG, "Screen share stage warning (suppressed): $message")
                return
            }
            Log.e(TAG, "Screen share stage error: $message")
            displayError(exception, "ScreenShareStage")
        }

        override fun onConnectionStateChanged(
            stage: Stage,
            state: Stage.ConnectionState,
            exception: BroadcastException?
        ) {
            Log.d(TAG, "Screen share stage connection state: $state")
            if (exception != null) {
                displayError(exception, "ScreenShareStageConnection")
            }
        }

        override fun onParticipantJoined(stage: Stage, info: ParticipantInfo) {
            Log.d(TAG, "Screen share stage: participant joined ${info.participantId}")
        }

        override fun onParticipantLeft(stage: Stage, info: ParticipantInfo) {
            Log.d(TAG, "Screen share stage: participant left ${info.participantId}")
        }

        override fun onParticipantPublishStateChanged(
            stage: Stage, info: ParticipantInfo, publishState: Stage.PublishState
        ) {
            Log.d(TAG, "Screen share stage: publish state changed to $publishState")
        }

        override fun onParticipantSubscribeStateChanged(
            stage: Stage, info: ParticipantInfo, subscribeState: Stage.SubscribeState
        ) {}

        override fun onStreamsAdded(stage: Stage, info: ParticipantInfo, streams: List<StageStream>) {}
        override fun onStreamsRemoved(stage: Stage, info: ParticipantInfo, streams: List<StageStream>) {}
        override fun onStreamsMutedChanged(stage: Stage, info: ParticipantInfo, streams: List<StageStream>) {}
    }
}
