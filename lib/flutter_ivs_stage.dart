import 'dart:async';

import 'flutter_ivs_stage_platform_interface.dart';
import 'src/models/models.dart';

export 'src/models/models.dart';
export 'src/widgets/widgets.dart';

class FlutterIvsStage {
  static FlutterIvsStagePlatform get _platform =>
      FlutterIvsStagePlatform.instance;

  /// Get the SDK version
  static Future<String?> getPlatformVersion() {
    return _platform.getPlatformVersion();
  }

  /// Join a stage with the given token
  static Future<void> joinStage(String token) {
    return _platform.joinStage(token);
  }

  /// Leave the current stage
  static Future<void> leaveStage() {
    return _platform.leaveStage();
  }

  /// Toggle local audio mute
  static Future<void> toggleLocalAudioMute() {
    return _platform.toggleLocalAudioMute();
  }

  /// Toggle local video mute
  static Future<void> toggleLocalVideoMute() {
    return _platform.toggleLocalVideoMute();
  }

  /// Toggle audio-only subscription for a participant
  static Future<void> toggleAudioOnlySubscribe(String participantId) {
    return _platform.toggleAudioOnlySubscribe(participantId);
  }

  /// Set broadcast authentication
  static Future<bool> setBroadcastAuth(String endpoint, String streamKey) {
    return _platform.setBroadcastAuth(endpoint, streamKey);
  }

  /// Toggle broadcasting
  static Future<void> toggleBroadcasting() {
    return _platform.toggleBroadcasting();
  }

  /// Request camera and microphone permissions
  static Future<bool> requestPermissions() {
    return _platform.requestPermissions();
  }

  /// Check if permissions are granted
  static Future<bool> checkPermissions() {
    return _platform.checkPermissions();
  }

  /// Stream of participants data
  static Stream<List<StageParticipant>> get participantsStream {
    return _platform.participantsStream;
  }

  /// Stream of stage connection state
  static Stream<StageConnectionState> get connectionStateStream {
    return _platform.connectionStateStream;
  }

  /// Stream of local user audio mute state
  static Stream<bool> get localAudioMutedStream {
    return _platform.localAudioMutedStream;
  }

  /// Stream of local user video mute state
  static Stream<bool> get localVideoMutedStream {
    return _platform.localVideoMutedStream;
  }

  /// Stream of broadcasting state
  static Stream<bool> get broadcastingStream {
    return _platform.broadcastingStream;
  }

  /// Stream of error events
  static Stream<StageError> get errorStream {
    return _platform.errorStream;
  }

  /// Dispose resources
  static Future<void> dispose() {
    return _platform.dispose();
  }

  /// Refresh all video previews (useful when switching views)
  static Future<void> refreshVideoPreviews() {
    return _platform.refreshVideoPreviews();
  }

  /// Set video mirroring for local and/or remote video streams
  ///
  /// [localVideo] - Mirror the local camera preview (useful for front camera)
  /// [remoteVideo] - Mirror remote participants' video streams
  static Future<void> setVideoMirroring({
    required bool localVideo,
    required bool remoteVideo,
  }) {
    return _platform.setVideoMirroring(
      localVideo: localVideo,
      remoteVideo: remoteVideo,
    );
  }

  /// Initialize camera preview before joining stage
  ///
  /// This allows users to see their camera feed before joining the stage.
  ///
  /// [cameraType] - Camera to use: 'front' (default) or 'back'
  /// [aspectMode] - How to display the preview: 'fill' (default) or 'fit'
  ///
  /// Example:
  /// ```dart
  /// // Initialize front camera with fill aspect mode
  /// await FlutterIvsStage.initPreview();
  ///
  /// // Initialize back camera with fit aspect mode
  /// await FlutterIvsStage.initPreview(
  ///   cameraType: 'back',
  ///   aspectMode: 'fit',
  /// );
  /// ```
  static Future<void> initPreview({
    String cameraType = 'front',
    String aspectMode = 'fill',
  }) {
    return _platform.initPreview(
      cameraType: cameraType,
      aspectMode: aspectMode,
    );
  }

  /// Toggle between front and back camera
  ///
  /// [cameraType] - Camera to switch to: 'front' or 'back'
  ///
  /// Example:
  /// ```dart
  /// // Switch to back camera
  /// await FlutterIvsStage.toggleCamera('back');
  ///
  /// // Switch to front camera
  /// await FlutterIvsStage.toggleCamera('front');
  /// ```
  static Future<void> toggleCamera(String cameraType) {
    return _platform.toggleCamera(cameraType);
  }

  /// Stop camera preview
  ///
  /// This stops the camera preview that was started with [initPreview].
  /// Usually called when leaving the preview screen or joining the stage.
  static Future<void> stopPreview() {
    return _platform.stopPreview();
  }

  /// Toggle screen share on/off
  ///
  /// [token] - Optional stage token for dual-stage screen share.
  /// When provided, creates a second Stage connection dedicated to screen share.
  /// When null, falls back to single-stage behavior.
  static Future<void> toggleScreenShare({String? token}) {
    return _platform.toggleScreenShare(token: token);
  }

  /// Stream of screen share state
  static Stream<bool> get screenShareStream {
    return _platform.screenShareStream;
  }

  /// Set speakerphone on or off for audio output routing.
  ///
  /// When [on] is true, audio is routed to the device speaker.
  /// When [on] is false, audio is routed to the earpiece (or default device).
  static Future<void> setSpeakerphoneOn(bool on) {
    return _platform.setSpeakerphoneOn(on);
  }

  /// Select a specific audio output device by its device ID.
  ///
  /// Use this for Bluetooth, wired headset, or other external audio devices.
  /// For speaker/earpiece switching, prefer [setSpeakerphoneOn].
  static Future<void> selectAudioOutput(String deviceId) {
    return _platform.selectAudioOutput(deviceId);
  }

  /// Select a specific audio input device by its device ID.
  static Future<void> selectAudioInput(String deviceId) {
    return _platform.selectAudioInput(deviceId);
  }

  /// Local participant object representing the user
  static StageParticipant? get localParticipant {
    return StageParticipant(
      isLocal: true,
      participantId: 'preview_local_user',
      publishState: StageParticipantPublishState.published,
      subscribeState: StageParticipantSubscribeState.subscribed,
      streams: [
        StageStream(
          deviceId: 'preview_camera_front',
          type: StageStreamType.video,
          isMuted: false,
        ),
        const StageStream(
          deviceId: 'preview_microphone',
          type: StageStreamType.audio,
          isMuted: true,
        ),
      ],
      broadcastSlotName: 'preview',
    );
  }
}
