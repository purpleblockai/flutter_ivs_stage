import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_ivs_stage_platform_interface.dart';
import 'src/models/models.dart';

/// An implementation of [FlutterIvsStagePlatform] that uses method channels.
class MethodChannelFlutterIvsStage extends FlutterIvsStagePlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_ivs_stage');

  /// Event channels for streaming data
  final _participantsEventChannel = const EventChannel(
    'flutter_ivs_stage/participants',
  );
  final _connectionStateEventChannel = const EventChannel(
    'flutter_ivs_stage/connection_state',
  );
  final _localAudioMutedEventChannel = const EventChannel(
    'flutter_ivs_stage/local_audio_muted',
  );
  final _localVideoMutedEventChannel = const EventChannel(
    'flutter_ivs_stage/local_video_muted',
  );
  final _broadcastingEventChannel = const EventChannel(
    'flutter_ivs_stage/broadcasting',
  );
  final _errorEventChannel = const EventChannel('flutter_ivs_stage/error');
  final _screenShareEventChannel = const EventChannel(
    'flutter_ivs_stage/screen_share',
  );

  Stream<List<StageParticipant>>? _participantsStream;
  Stream<StageConnectionState>? _connectionStateStream;
  Stream<bool>? _localAudioMutedStream;
  Stream<bool>? _localVideoMutedStream;
  Stream<bool>? _broadcastingStream;
  Stream<StageError>? _errorStream;
  Stream<bool>? _screenShareStream;

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }

  @override
  Future<void> joinStage(String token) async {
    await methodChannel.invokeMethod('joinStage', {'token': token});
  }

  @override
  Future<void> leaveStage() async {
    await methodChannel.invokeMethod('leaveStage');
  }

  @override
  Future<void> toggleLocalAudioMute() async {
    await methodChannel.invokeMethod('toggleLocalAudioMute');
  }

  @override
  Future<void> toggleLocalVideoMute() async {
    await methodChannel.invokeMethod('toggleLocalVideoMute');
  }

  @override
  Future<void> toggleAudioOnlySubscribe(String participantId) async {
    await methodChannel.invokeMethod('toggleAudioOnlySubscribe', {
      'participantId': participantId,
    });
  }

  @override
  Future<bool> setBroadcastAuth(String endpoint, String streamKey) async {
    final result = await methodChannel.invokeMethod<bool>('setBroadcastAuth', {
      'endpoint': endpoint,
      'streamKey': streamKey,
    });
    return result ?? false;
  }

  @override
  Future<void> toggleBroadcasting() async {
    await methodChannel.invokeMethod('toggleBroadcasting');
  }

  @override
  Future<bool> requestPermissions() async {
    final result = await methodChannel.invokeMethod<bool>('requestPermissions');
    return result ?? false;
  }

  @override
  Future<bool> checkPermissions() async {
    final result = await methodChannel.invokeMethod<bool>('checkPermissions');
    return result ?? false;
  }

  @override
  Stream<List<StageParticipant>> get participantsStream {
    _participantsStream ??= _participantsEventChannel
        .receiveBroadcastStream()
        .map<List<StageParticipant>>((data) {
          if (data is List) {
            return data
                .map<StageParticipant>(
                  (item) =>
                      StageParticipant.fromMap(Map<String, dynamic>.from(item)),
                )
                .toList();
          }
          return <StageParticipant>[];
        });
    return _participantsStream!;
  }

  @override
  Stream<StageConnectionState> get connectionStateStream {
    _connectionStateStream ??= _connectionStateEventChannel
        .receiveBroadcastStream()
        .map<StageConnectionState>(
          (data) => StageConnectionState.fromString(data.toString()),
        );
    return _connectionStateStream!;
  }

  @override
  Stream<bool> get localAudioMutedStream {
    _localAudioMutedStream ??= _localAudioMutedEventChannel
        .receiveBroadcastStream()
        .map<bool>((data) => data == true);
    return _localAudioMutedStream!;
  }

  @override
  Stream<bool> get localVideoMutedStream {
    _localVideoMutedStream ??= _localVideoMutedEventChannel
        .receiveBroadcastStream()
        .map<bool>((data) => data == true);
    return _localVideoMutedStream!;
  }

  @override
  Stream<bool> get broadcastingStream {
    _broadcastingStream ??= _broadcastingEventChannel
        .receiveBroadcastStream()
        .map<bool>((data) => data == true);
    return _broadcastingStream!;
  }

  @override
  Stream<StageError> get errorStream {
    _errorStream ??= _errorEventChannel
        .receiveBroadcastStream()
        .map<StageError>(
          (data) => StageError.fromMap(Map<String, dynamic>.from(data)),
        );
    return _errorStream!;
  }

  @override
  Future<void> dispose() async {
    await methodChannel.invokeMethod('dispose');
    _participantsStream = null;
    _connectionStateStream = null;
    _localAudioMutedStream = null;
    _localVideoMutedStream = null;
    _broadcastingStream = null;
    _errorStream = null;
    _screenShareStream = null;
  }

  @override
  Future<void> refreshVideoPreviews() async {
    await methodChannel.invokeMethod('refreshVideoPreviews');
  }

  @override
  Future<void> setVideoMirroring({
    required bool localVideo,
    required bool remoteVideo,
  }) async {
    await methodChannel.invokeMethod('setVideoMirroring', {
      'localVideo': localVideo,
      'remoteVideo': remoteVideo,
    });
  }

  @override
  Future<void> initPreview({
    String cameraType = 'front',
    String aspectMode = 'fill',
  }) async {
    await methodChannel.invokeMethod('initPreview', {
      'cameraType': cameraType,
      'aspectMode': aspectMode,
    });
  }

  @override
  Future<void> toggleCamera(String cameraType) async {
    await methodChannel.invokeMethod('toggleCamera', {
      'cameraType': cameraType,
    });
  }

  @override
  Future<void> stopPreview() async {
    await methodChannel.invokeMethod('stopPreview');
  }

  @override
  Future<void> toggleScreenShare({String? token}) async {
    await methodChannel.invokeMethod('toggleScreenShare', {
      if (token != null) 'token': token,
    });
  }

  @override
  Stream<bool> get screenShareStream {
    _screenShareStream ??= _screenShareEventChannel
        .receiveBroadcastStream()
        .map<bool>((data) => data == true);
    return _screenShareStream!;
  }

  @override
  Future<void> setSpeakerphoneOn(bool on) async {
    await methodChannel.invokeMethod('setSpeakerphoneOn', {'on': on});
  }

  @override
  Future<void> selectAudioOutput(String deviceId) async {
    await methodChannel.invokeMethod('selectAudioOutput', {
      'deviceId': deviceId,
    });
  }

  @override
  Future<void> selectAudioInput(String deviceId) async {
    await methodChannel.invokeMethod('selectAudioInput', {
      'deviceId': deviceId,
    });
  }
}
