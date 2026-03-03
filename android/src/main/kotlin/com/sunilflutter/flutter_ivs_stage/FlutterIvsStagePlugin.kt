package com.sunilflutter.flutter_ivs_stage

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import com.amazonaws.ivs.broadcast.Stage

private const val PERMISSION_REQUEST_CODE = 7891
private const val SCREEN_CAPTURE_REQUEST_CODE = 7892
private const val TAG = "FlutterIvsStagePlugin"

class FlutterIvsStagePlugin : FlutterPlugin, ActivityAware, MethodCallHandler,
    StageManagerDelegate, PluginRegistry.RequestPermissionsResultListener,
    PluginRegistry.ActivityResultListener {

    companion object {
        var shared: FlutterIvsStagePlugin? = null
    }

    var stageManager: StageManager? = null
    private var methodChannel: MethodChannel? = null
    private var activity: Activity? = null
    private var appContext: Context? = null
    private var pendingPermissionResult: Result? = null
    private var pendingScreenShareResult: Result? = null
    private var pendingScreenShareToken: String? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Event sinks
    var participantsEventSink: EventChannel.EventSink? = null
    var connectionStateEventSink: EventChannel.EventSink? = null
    var localAudioMutedEventSink: EventChannel.EventSink? = null
    var localVideoMutedEventSink: EventChannel.EventSink? = null
    var broadcastingEventSink: EventChannel.EventSink? = null
    var errorEventSink: EventChannel.EventSink? = null
    var screenShareEventSink: EventChannel.EventSink? = null

    // Event channels (held to prevent GC)
    private var participantsEventChannel: EventChannel? = null
    private var connectionStateEventChannel: EventChannel? = null
    private var localAudioMutedEventChannel: EventChannel? = null
    private var localVideoMutedEventChannel: EventChannel? = null
    private var broadcastingEventChannel: EventChannel? = null
    private var errorEventChannel: EventChannel? = null
    private var screenShareEventChannel: EventChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        shared = this
        appContext = binding.applicationContext

        val messenger = binding.binaryMessenger

        // Initialize stage manager first so platform views can always resolve
        // the correct manager for this engine instance.
        stageManager = StageManager(binding.applicationContext).also {
            it.delegate = this
        }

        methodChannel = MethodChannel(messenger, "flutter_ivs_stage").also {
            it.setMethodCallHandler(this)
        }

        // Register platform view factory
        binding.platformViewRegistry.registerViewFactory(
            "ivs_video_view",
            IvsVideoViewFactory { stageManager }
        )

        // Setup event channels
        participantsEventChannel = EventChannel(messenger, "flutter_ivs_stage/participants").also {
            it.setStreamHandler(ParticipantsStreamHandler(this))
        }
        connectionStateEventChannel =
            EventChannel(messenger, "flutter_ivs_stage/connection_state").also {
                it.setStreamHandler(ConnectionStateStreamHandler(this))
            }
        localAudioMutedEventChannel =
            EventChannel(messenger, "flutter_ivs_stage/local_audio_muted").also {
                it.setStreamHandler(LocalAudioMutedStreamHandler(this))
            }
        localVideoMutedEventChannel =
            EventChannel(messenger, "flutter_ivs_stage/local_video_muted").also {
                it.setStreamHandler(LocalVideoMutedStreamHandler(this))
            }
        broadcastingEventChannel = EventChannel(messenger, "flutter_ivs_stage/broadcasting").also {
            it.setStreamHandler(BroadcastingStreamHandler(this))
        }
        errorEventChannel = EventChannel(messenger, "flutter_ivs_stage/error").also {
            it.setStreamHandler(ErrorStreamHandler(this))
        }
        screenShareEventChannel = EventChannel(messenger, "flutter_ivs_stage/screen_share").also {
            it.setStreamHandler(ScreenShareStreamHandler(this))
        }

    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null

        participantsEventChannel?.setStreamHandler(null)
        connectionStateEventChannel?.setStreamHandler(null)
        localAudioMutedEventChannel?.setStreamHandler(null)
        localVideoMutedEventChannel?.setStreamHandler(null)
        broadcastingEventChannel?.setStreamHandler(null)
        errorEventChannel?.setStreamHandler(null)
        screenShareEventChannel?.setStreamHandler(null)

        stageManager?.dispose()
        stageManager = null
        shared = null
        appContext = null
    }

    // -------------------------------------------------------------------------
    // ActivityAware
    // -------------------------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    // -------------------------------------------------------------------------
    // MethodCallHandler
    // -------------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: Result) {
        val manager = stageManager
        if (manager == null && call.method != "getPlatformVersion") {
            result.error("NOT_INITIALIZED", "Stage manager not initialized", null)
            return
        }

        when (call.method) {
            "getPlatformVersion" -> {
                result.success("Android ${Build.VERSION.RELEASE}")
            }

            "joinStage" -> {
                val token = call.argument<String>("token")
                if (token.isNullOrEmpty()) {
                    result.error("INVALID_ARGUMENTS", "Token is required", null)
                    return
                }
                manager!!.joinStage(token) { error ->
                    if (error != null) {
                        result.error("JOIN_FAILED", error.localizedMessage, null)
                    } else {
                        result.success(null)
                    }
                }
            }

            "leaveStage" -> {
                manager!!.leaveStage()
                result.success(null)
            }

            "toggleLocalAudioMute" -> {
                manager!!.toggleLocalAudioMute()
                result.success(null)
            }

            "toggleLocalVideoMute" -> {
                manager!!.toggleLocalVideoMute()
                result.success(null)
            }

            "toggleAudioOnlySubscribe" -> {
                val participantId = call.argument<String>("participantId")
                if (participantId.isNullOrEmpty()) {
                    result.error("INVALID_ARGUMENTS", "Participant ID is required", null)
                    return
                }
                manager!!.toggleAudioOnlySubscribe(participantId)
                result.success(null)
            }

            "setBroadcastAuth" -> {
                val endpoint = call.argument<String>("endpoint")
                val streamKey = call.argument<String>("streamKey")
                if (endpoint.isNullOrEmpty() || streamKey.isNullOrEmpty()) {
                    result.error(
                        "INVALID_ARGUMENTS",
                        "Endpoint and stream key are required",
                        null
                    )
                    return
                }
                val success = manager!!.setBroadcastAuth(endpoint, streamKey)
                result.success(success)
            }

            "toggleBroadcasting" -> {
                manager!!.toggleBroadcasting { error ->
                    if (error != null) {
                        result.error("BROADCAST_FAILED", error.localizedMessage, null)
                    } else {
                        result.success(null)
                    }
                }
            }

            "requestPermissions" -> {
                requestPermissions(result)
            }

            "checkPermissions" -> {
                result.success(checkPermissions())
            }

            "dispose" -> {
                manager!!.dispose()
                result.success(null)
            }

            "refreshVideoPreviews" -> {
                manager!!.refreshAllVideoPreviews()
                result.success(null)
            }

            "setVideoMirroring" -> {
                val localVideo = call.argument<Boolean>("localVideo")
                val remoteVideo = call.argument<Boolean>("remoteVideo")
                if (localVideo == null || remoteVideo == null) {
                    result.error(
                        "INVALID_ARGUMENTS",
                        "localVideo and remoteVideo flags are required",
                        null
                    )
                    return
                }
                manager!!.setVideoMirroring(localVideo, remoteVideo)
                result.success(null)
            }

            "initPreview" -> {
                val cameraType = call.argument<String>("cameraType") ?: "front"
                val aspectMode = call.argument<String>("aspectMode") ?: "fill"
                manager!!.initPreview(cameraType, aspectMode) { error ->
                    if (error != null) {
                        result.error("PREVIEW_FAILED", error.localizedMessage, null)
                    } else {
                        result.success(null)
                    }
                }
            }

            "toggleCamera" -> {
                val cameraType = call.argument<String>("cameraType")
                if (cameraType.isNullOrEmpty()) {
                    result.error("INVALID_ARGUMENTS", "Camera type is required", null)
                    return
                }
                manager!!.toggleCamera(cameraType) { error ->
                    if (error != null) {
                        result.error("CAMERA_TOGGLE_FAILED", error.localizedMessage, null)
                    } else {
                        result.success(null)
                    }
                }
            }

            "stopPreview" -> {
                manager!!.stopPreview()
                result.success(null)
            }

            "toggleScreenShare" -> {
                val token = call.argument<String>("token")
                if (manager!!.isScreenSharing) {
                    // Stop screen sharing
                    manager.stopScreenShare()
                    screenShareEventSink?.success(false)
                    result.success(null)
                } else {
                    // Request screen capture permission, passing token for dual-stage mode
                    requestScreenSharePermission(result, token)
                }
            }

            "setSpeakerphoneOn" -> {
                val on = call.argument<Boolean>("on")
                if (on == null) {
                    result.error("INVALID_ARGUMENTS", "'on' boolean is required", null)
                    return
                }
                try {
                    val audioManager = appContext?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                    if (audioManager == null) {
                        result.error("AUDIO_OUTPUT_FAILED", "AudioManager not available", null)
                        return
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        if (on) {
                            val speaker = audioManager.availableCommunicationDevices
                                .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                            if (speaker != null) {
                                audioManager.setCommunicationDevice(speaker)
                            }
                        } else {
                            audioManager.clearCommunicationDevice()
                        }
                    } else {
                        @Suppress("DEPRECATION")
                        audioManager.isSpeakerphoneOn = on
                    }
                    result.success(null)
                } catch (e: Exception) {
                    result.error("AUDIO_OUTPUT_FAILED", e.localizedMessage, null)
                }
            }

            "selectAudioInput" -> {
                val deviceId = call.argument<String>("deviceId")
                if (deviceId.isNullOrEmpty()) {
                    result.error("INVALID_ARGUMENTS", "deviceId is required", null)
                    return
                }
                manager!!.selectAudioInput(deviceId) { error ->
                    if (error != null) {
                        result.error("AUDIO_INPUT_FAILED", error.localizedMessage, null)
                    } else {
                        result.success(null)
                    }
                }
            }

            "selectAudioOutput" -> {
                val deviceId = call.argument<String>("deviceId")
                if (deviceId.isNullOrEmpty()) {
                    result.error("INVALID_ARGUMENTS", "deviceId is required", null)
                    return
                }
                try {
                    val audioManager = appContext?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                    if (audioManager == null) {
                        result.error("AUDIO_OUTPUT_FAILED", "AudioManager not available", null)
                        return
                    }
                    val lowerId = deviceId.trim().lowercase()
                    if (lowerId == "speaker") {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            val speaker = audioManager.availableCommunicationDevices
                                .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                            if (speaker != null) {
                                audioManager.setCommunicationDevice(speaker)
                            }
                        } else {
                            @Suppress("DEPRECATION")
                            audioManager.isSpeakerphoneOn = true
                        }
                    } else {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            // Clear speaker override first
                            audioManager.clearCommunicationDevice()
                            // Try to find matching device by ID or type
                            val devices = audioManager.availableCommunicationDevices
                            val target = devices.firstOrNull { it.id.toString() == deviceId }
                                ?: devices.firstOrNull {
                                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                                    it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                                    it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                                    it.type == AudioDeviceInfo.TYPE_USB_HEADSET ||
                                    it.type == AudioDeviceInfo.TYPE_USB_DEVICE
                                }
                            if (target != null) {
                                audioManager.setCommunicationDevice(target)
                            }
                        } else {
                            @Suppress("DEPRECATION")
                            audioManager.isSpeakerphoneOn = false
                            // For Bluetooth on older APIs
                            if (lowerId.contains("bluetooth") || deviceId.contains("bt_")) {
                                @Suppress("DEPRECATION")
                                audioManager.startBluetoothSco()
                                @Suppress("DEPRECATION")
                                audioManager.isBluetoothScoOn = true
                            }
                        }
                    }
                    result.success(null)
                } catch (e: Exception) {
                    result.error("AUDIO_OUTPUT_FAILED", e.localizedMessage, null)
                }
            }

            else -> result.notImplemented()
        }
    }

    // -------------------------------------------------------------------------
    // Permissions
    // -------------------------------------------------------------------------

    private fun requestPermissions(result: Result) {
        val currentActivity = activity
        if (currentActivity == null) {
            result.success(false)
            return
        }

        val permissions = arrayOf(
            android.Manifest.permission.CAMERA,
            android.Manifest.permission.RECORD_AUDIO
        )

        val allGranted = permissions.all {
            ContextCompat.checkSelfPermission(currentActivity, it) ==
                PackageManager.PERMISSION_GRANTED
        }

        if (allGranted) {
            result.success(true)
            return
        }

        pendingPermissionResult = result
        ActivityCompat.requestPermissions(currentActivity, permissions, PERMISSION_REQUEST_CODE)
    }

    private fun checkPermissions(): Boolean {
        val ctx = activity ?: return false
        return ContextCompat.checkSelfPermission(
            ctx,
            android.Manifest.permission.CAMERA
        ) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(
                ctx,
                android.Manifest.permission.RECORD_AUDIO
            ) == PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false

        val allGranted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        pendingPermissionResult?.success(allGranted)
        pendingPermissionResult = null
        return true
    }

    // -------------------------------------------------------------------------
    // Screen Share Permission
    // -------------------------------------------------------------------------

    private fun requestScreenSharePermission(result: Result, token: String? = null) {
        pendingScreenShareToken = token
        val currentActivity = activity
        if (currentActivity == null) {
            result.error("NO_ACTIVITY", "Activity not available for screen share", null)
            return
        }

        val ctx = appContext ?: currentActivity.applicationContext
        val projectionManager =
            ctx.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
        if (projectionManager == null) {
            result.error("NO_PROJECTION_MANAGER", "MediaProjectionManager not available", null)
            return
        }

        pendingScreenShareResult = result
        val captureIntent = projectionManager.createScreenCaptureIntent()
        currentActivity.startActivityForResult(captureIntent, SCREEN_CAPTURE_REQUEST_CODE)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != SCREEN_CAPTURE_REQUEST_CODE) return false

        val result = pendingScreenShareResult
        if (result == null) {
            Log.w(TAG, "No pending screen share result callback")
            return true
        }

        if (resultCode == Activity.RESULT_OK && data != null) {
            // Start foreground service first (required on Android 10+)
            val ctx = appContext ?: activity?.applicationContext
            if (ctx == null) {
                result.error("NO_CONTEXT", "Application context not available", null)
                pendingScreenShareResult = null
                return true
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val serviceIntent = Intent(ctx, ScreenCaptureService::class.java).apply {
                    action = ScreenCaptureService.ACTION_START
                }
                ctx.startForegroundService(serviceIntent)
                Log.d(TAG, "Started ScreenCaptureService")

                // Give the service a moment to start, then get MediaProjection
                val finalResultCode = resultCode
                val finalData = data
                mainHandler.postDelayed({
                    getMediaProjectionAndStartShare(ctx, finalResultCode, finalData)
                }, 150)
            } else {
                getMediaProjectionAndStartShare(ctx, resultCode, data)
            }
        } else {
            result.error("PERMISSION_DENIED", "Screen share permission denied", null)
            pendingScreenShareResult = null
        }

        return true
    }

    private fun getMediaProjectionAndStartShare(ctx: Context, resultCode: Int, data: Intent) {
        val result = pendingScreenShareResult
        if (result == null) {
            Log.w(TAG, "No pending result in getMediaProjectionAndStartShare")
            return
        }

        try {
            val projectionManager =
                ctx.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
            if (projectionManager == null) {
                result.error("PROJECTION_FAILED", "MediaProjectionManager not available", null)
                pendingScreenShareResult = null
                stopScreenCaptureService()
                return
            }

            val mediaProjection = projectionManager.getMediaProjection(resultCode, data)
            if (mediaProjection == null) {
                result.error("PROJECTION_FAILED", "Failed to get MediaProjection", null)
                pendingScreenShareResult = null
                stopScreenCaptureService()
                return
            }

            Log.d(TAG, "MediaProjection obtained successfully")

            // Start screen share via StageManager
            val token = pendingScreenShareToken
            pendingScreenShareToken = null
            stageManager?.startScreenShare(ctx, mediaProjection, token) { error ->
                if (error != null) {
                    result.error("SCREEN_SHARE_FAILED", error.localizedMessage, null)
                    stopScreenCaptureService()
                } else {
                    screenShareEventSink?.success(true)
                    result.success(null)
                }
                pendingScreenShareResult = null
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error getting MediaProjection", e)
            result.error("PROJECTION_FAILED", e.localizedMessage, null)
            pendingScreenShareResult = null
            stopScreenCaptureService()
        }
    }

    private fun stopScreenCaptureService() {
        val ctx = appContext ?: activity?.applicationContext ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val serviceIntent = Intent(ctx, ScreenCaptureService::class.java).apply {
                action = ScreenCaptureService.ACTION_STOP
            }
            ctx.startService(serviceIntent)
            Log.d(TAG, "Stopped ScreenCaptureService")
        }
    }

    // -------------------------------------------------------------------------
    // StageManagerDelegate
    // -------------------------------------------------------------------------

    override fun onParticipantsUpdated(participants: List<ParticipantData>) {
        val maps = participants.map { it.toMap() }
        participantsEventSink?.success(maps)
    }

    override fun onConnectionStateChanged(state: Stage.ConnectionState) {
        connectionStateEventSink?.success(state.toFlutterString())
    }

    override fun onLocalAudioMutedChanged(muted: Boolean) {
        localAudioMutedEventSink?.success(muted)
    }

    override fun onLocalVideoMutedChanged(muted: Boolean) {
        localVideoMutedEventSink?.success(muted)
    }

    override fun onBroadcastingChanged(broadcasting: Boolean) {
        broadcastingEventSink?.success(broadcasting)
    }

    override fun onError(error: Exception, source: String?) {
        val errorMap = mapOf(
            "title" to "Error",
            "message" to (error.localizedMessage ?: error.toString()),
            "code" to 0,
            "source" to (source ?: "Unknown")
        )
        errorEventSink?.success(errorMap)
    }

    override fun onScreenShareStateChanged(sharing: Boolean) {
        screenShareEventSink?.success(sharing)
        if (!sharing) {
            stopScreenCaptureService()
        }
    }
}
