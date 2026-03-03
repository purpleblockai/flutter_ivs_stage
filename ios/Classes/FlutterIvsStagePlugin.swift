import Flutter
import UIKit
import AmazonIVSBroadcast
import Foundation
import AVFoundation

public class FlutterIvsStagePlugin: NSObject, FlutterPlugin {
    
    static var shared: FlutterIvsStagePlugin?
    var stageManager: StageManager?
    private var methodChannel: FlutterMethodChannel?
    
    // Event channels
    private var participantsEventChannel: FlutterEventChannel?
    private var connectionStateEventChannel: FlutterEventChannel?
    private var localAudioMutedEventChannel: FlutterEventChannel?
    private var localVideoMutedEventChannel: FlutterEventChannel?
    private var broadcastingEventChannel: FlutterEventChannel?
    private var errorEventChannel: FlutterEventChannel?
    private var screenShareEventChannel: FlutterEventChannel?

    // Event sinks
    public var participantsEventSink: FlutterEventSink?
    public var connectionStateEventSink: FlutterEventSink?
    public var localAudioMutedEventSink: FlutterEventSink?
    public var localVideoMutedEventSink: FlutterEventSink?
    public var broadcastingEventSink: FlutterEventSink?
    public var errorEventSink: FlutterEventSink?
    public var screenShareEventSink: FlutterEventSink?
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(name: "flutter_ivs_stage", binaryMessenger: registrar.messenger())
        let instance = FlutterIvsStagePlugin()
        instance.methodChannel = methodChannel
        
        // Set shared instance for platform view access
        FlutterIvsStagePlugin.shared = instance
        
        // Register platform view factory for video views
        let factory = IvsVideoViewFactory(messenger: registrar.messenger())
        registrar.register(factory, withId: "ivs_video_view")
        
        // Setup event channels
        instance.participantsEventChannel = FlutterEventChannel(name: "flutter_ivs_stage/participants", binaryMessenger: registrar.messenger())
        instance.connectionStateEventChannel = FlutterEventChannel(name: "flutter_ivs_stage/connection_state", binaryMessenger: registrar.messenger())
        instance.localAudioMutedEventChannel = FlutterEventChannel(name: "flutter_ivs_stage/local_audio_muted", binaryMessenger: registrar.messenger())
        instance.localVideoMutedEventChannel = FlutterEventChannel(name: "flutter_ivs_stage/local_video_muted", binaryMessenger: registrar.messenger())
        instance.broadcastingEventChannel = FlutterEventChannel(name: "flutter_ivs_stage/broadcasting", binaryMessenger: registrar.messenger())
        instance.errorEventChannel = FlutterEventChannel(name: "flutter_ivs_stage/error", binaryMessenger: registrar.messenger())
        instance.screenShareEventChannel = FlutterEventChannel(name: "flutter_ivs_stage/screen_share", binaryMessenger: registrar.messenger())

        // Set event handlers
        instance.participantsEventChannel?.setStreamHandler(ParticipantsStreamHandler(instance))
        instance.connectionStateEventChannel?.setStreamHandler(ConnectionStateStreamHandler(instance))
        instance.localAudioMutedEventChannel?.setStreamHandler(LocalAudioMutedStreamHandler(instance))
        instance.localVideoMutedEventChannel?.setStreamHandler(LocalVideoMutedStreamHandler(instance))
        instance.broadcastingEventChannel?.setStreamHandler(BroadcastingStreamHandler(instance))
        instance.errorEventChannel?.setStreamHandler(ErrorStreamHandler(instance))
        instance.screenShareEventChannel?.setStreamHandler(ScreenShareStreamHandler(instance))

        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        
        // Initialize stage manager
        instance.stageManager = StageManager()
        instance.stageManager?.delegate = instance
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let stageManager = stageManager else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "Stage manager not initialized", details: nil))
            return
        }
        
        switch call.method {
        case "getPlatformVersion":
            result("iOS " + UIDevice.current.systemVersion + " - IVS SDK v" + IVSBroadcastSession.sdkVersion)
            
        case "joinStage":
            if let args = call.arguments as? [String: Any],
               let token = args["token"] as? String {
                stageManager.joinStage(token: token) { error in
                    if let error = error {
                        result(FlutterError(code: "JOIN_FAILED", message: error.localizedDescription, details: nil))
                    } else {
                        result(nil)
                    }
                }
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Token is required", details: nil))
            }
            
        case "leaveStage":
            stageManager.leaveStage()
            result(nil)
            
        case "toggleLocalAudioMute":
            stageManager.toggleLocalAudioMute()
            result(nil)
            
        case "toggleLocalVideoMute":
            stageManager.toggleLocalVideoMute()
            result(nil)
            
        case "toggleAudioOnlySubscribe":
            if let args = call.arguments as? [String: Any],
               let participantId = args["participantId"] as? String {
                stageManager.toggleAudioOnlySubscribe(forParticipant: participantId)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Participant ID is required", details: nil))
            }
            
        case "setBroadcastAuth":
            if let args = call.arguments as? [String: Any],
               let endpoint = args["endpoint"] as? String,
               let streamKey = args["streamKey"] as? String {
                let success = stageManager.setBroadcastAuth(endpoint: endpoint, streamKey: streamKey)
                result(success)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Endpoint and stream key are required", details: nil))
            }
            
        case "toggleBroadcasting":
            stageManager.toggleBroadcasting { error in
                if let error = error {
                    result(FlutterError(code: "BROADCAST_FAILED", message: error.localizedDescription, details: nil))
                } else {
                    result(nil)
                }
            }
            
        case "requestPermissions":
            requestPermissions { granted in
                result(granted)
            }
            
        case "checkPermissions":
            let granted = checkPermissions()
            result(granted)
            
        case "dispose":
            stageManager.dispose()
            result(nil)
            
        case "refreshVideoPreviews":
            stageManager.refreshAllVideoPreviews()
            result(nil)
            
        case "setVideoMirroring":
            if let args = call.arguments as? [String: Any],
               let localVideo = args["localVideo"] as? Bool,
               let remoteVideo = args["remoteVideo"] as? Bool {
                stageManager.setVideoMirroring(localVideo: localVideo, remoteVideo: remoteVideo)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "localVideo and remoteVideo flags are required", details: nil))
            }
            
        case "initPreview":
            if let args = call.arguments as? [String: Any] {
                let cameraType = args["cameraType"] as? String ?? "front"
                let aspectMode = args["aspectMode"] as? String ?? "fill"
                stageManager.initPreview(cameraType: cameraType, aspectMode: aspectMode) { error in
                    if let error = error {
                        result(FlutterError(code: "PREVIEW_FAILED", message: error.localizedDescription, details: nil))
                    } else {
                        result(nil)
                    }
                }
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments for initPreview", details: nil))
            }
            
        case "toggleCamera":
            if let args = call.arguments as? [String: Any],
               let cameraType = args["cameraType"] as? String {
                stageManager.toggleCamera(cameraType: cameraType) { error in
                    if let error = error {
                        result(FlutterError(code: "CAMERA_TOGGLE_FAILED", message: error.localizedDescription, details: nil))
                    } else {
                        result(nil)
                    }
                }
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Camera type is required", details: nil))
            }
            
        case "stopPreview":
            stageManager.stopPreview()
            result(nil)

        case "toggleScreenShare":
            let token = (call.arguments as? [String: Any])?["token"] as? String
            if stageManager.isScreenSharing {
                stageManager.stopScreenShare()
                result(nil)
            } else {
                stageManager.startScreenShare(token: token) { error in
                    if let error = error {
                        result(FlutterError(code: "SCREEN_SHARE_FAILED",
                            message: error.localizedDescription, details: nil))
                    } else {
                        result(nil)
                    }
                }
            }

        case "setSpeakerphoneOn":
            if let args = call.arguments as? [String: Any],
               let on = args["on"] as? Bool {
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.overrideOutputAudioPort(on ? .speaker : .none)
                    result(nil)
                } catch {
                    result(FlutterError(code: "AUDIO_OUTPUT_FAILED",
                        message: error.localizedDescription, details: nil))
                }
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS",
                    message: "'on' boolean is required", details: nil))
            }

        case "selectAudioOutput":
            if let args = call.arguments as? [String: Any],
               let deviceId = args["deviceId"] as? String {
                let session = AVAudioSession.sharedInstance()
                let lowerId = deviceId.lowercased().trimmingCharacters(in: .whitespaces)

                if lowerId == "speaker" {
                    do {
                        try session.overrideOutputAudioPort(.speaker)
                        result(nil)
                    } catch {
                        result(FlutterError(code: "AUDIO_OUTPUT_FAILED",
                            message: error.localizedDescription, details: nil))
                    }
                } else {
                    // Clear speaker override first
                    try? session.overrideOutputAudioPort(.none)

                    // Try to find a matching input port (Bluetooth, headset, etc.)
                    if let availableInputs = session.availableInputs {
                        for port in availableInputs {
                            if port.uid == deviceId || port.portName.lowercased() == lowerId {
                                do {
                                    try session.setPreferredInput(port)
                                    result(nil)
                                    return
                                } catch {
                                    result(FlutterError(code: "AUDIO_OUTPUT_FAILED",
                                        message: error.localizedDescription, details: nil))
                                    return
                                }
                            }
                        }
                    }
                    // No matching port found — clear preferred input (use default)
                    try? session.setPreferredInput(nil)
                    result(nil)
                }
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS",
                    message: "deviceId is required", details: nil))
            }

        case "selectAudioInput":
            if let args = call.arguments as? [String: Any],
               let deviceId = args["deviceId"] as? String {
                let session = AVAudioSession.sharedInstance()
                let lowerId = deviceId.lowercased().trimmingCharacters(in: .whitespaces)

                do {
                    if lowerId.isEmpty || lowerId == "internal-mic" || lowerId == "internal" || lowerId == "default" {
                        try session.setPreferredInput(nil)
                        result(nil)
                        return
                    }

                    guard let availableInputs = session.availableInputs else {
                        result(FlutterError(code: "AUDIO_INPUT_FAILED",
                            message: "No audio input devices available", details: nil))
                        return
                    }

                    let matchedPort = availableInputs.first { port in
                        let uid = port.uid.lowercased()
                        let name = port.portName.lowercased()
                        let type = port.portType.rawValue.lowercased()
                        return uid == lowerId ||
                            name == lowerId ||
                            uid.contains(lowerId) ||
                            name.contains(lowerId) ||
                            type.contains(lowerId) ||
                            lowerId.contains(uid) ||
                            lowerId.contains(name)
                    }

                    guard let inputPort = matchedPort else {
                        result(FlutterError(code: "AUDIO_INPUT_FAILED",
                            message: "Requested audio input is unavailable", details: nil))
                        return
                    }

                    try session.setPreferredInput(inputPort)
                    result(nil)
                } catch {
                    result(FlutterError(code: "AUDIO_INPUT_FAILED",
                        message: error.localizedDescription, details: nil))
                }
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS",
                    message: "deviceId is required", details: nil))
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func requestPermissions(completion: @escaping (Bool) -> Void) {
        checkAVPermissions { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }
    
    private func checkPermissions() -> Bool {
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        return cameraStatus == .authorized && microphoneStatus == .authorized
    }
}

// MARK: - StageManagerDelegate

extension FlutterIvsStagePlugin: StageManagerDelegate {
    func stageManager(_ manager: StageManager, didUpdateParticipants participants: [ParticipantData]) {
        let participantMaps = participants.map { $0.toMap() }
        participantsEventSink?(participantMaps)
    }
    
    func stageManager(_ manager: StageManager, didChangeConnectionState state: IVSStageConnectionState) {
        let stateString = state.description
        connectionStateEventSink?(stateString)
    }
    
    func stageManager(_ manager: StageManager, didChangeLocalAudioMuted muted: Bool) {
        localAudioMutedEventSink?(muted)
    }
    
    func stageManager(_ manager: StageManager, didChangeLocalVideoMuted muted: Bool) {
        localVideoMutedEventSink?(muted)
    }
    
    func stageManager(_ manager: StageManager, didChangeBroadcasting broadcasting: Bool) {
        broadcastingEventSink?(broadcasting)
    }
    
    func stageManager(_ manager: StageManager, didEncounterError error: Error, source: String?) {
        let errorMap: [String: Any] = [
            "title": "Error",
            "message": error.localizedDescription,
            "code": (error as NSError).code,
            "source": source ?? "Unknown"
        ]
        errorEventSink?(errorMap)
    }

    func stageManager(_ manager: StageManager, didChangeScreenShareState sharing: Bool) {
        screenShareEventSink?(sharing)
    }
}

// MARK: - Stream Handlers

class ParticipantsStreamHandler: NSObject, FlutterStreamHandler {
    private weak var plugin: FlutterIvsStagePlugin?
    
    init(_ plugin: FlutterIvsStagePlugin) {
        self.plugin = plugin
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.participantsEventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.participantsEventSink = nil
        return nil
    }
}

class ConnectionStateStreamHandler: NSObject, FlutterStreamHandler {
    private weak var plugin: FlutterIvsStagePlugin?
    
    init(_ plugin: FlutterIvsStagePlugin) {
        self.plugin = plugin
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.connectionStateEventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.connectionStateEventSink = nil
        return nil
    }
}

class LocalAudioMutedStreamHandler: NSObject, FlutterStreamHandler {
    private weak var plugin: FlutterIvsStagePlugin?
    
    init(_ plugin: FlutterIvsStagePlugin) {
        self.plugin = plugin
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.localAudioMutedEventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.localAudioMutedEventSink = nil
        return nil
    }
}

class LocalVideoMutedStreamHandler: NSObject, FlutterStreamHandler {
    private weak var plugin: FlutterIvsStagePlugin?
    
    init(_ plugin: FlutterIvsStagePlugin) {
        self.plugin = plugin
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.localVideoMutedEventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.localVideoMutedEventSink = nil
        return nil
    }
}

class BroadcastingStreamHandler: NSObject, FlutterStreamHandler {
    private weak var plugin: FlutterIvsStagePlugin?
    
    init(_ plugin: FlutterIvsStagePlugin) {
        self.plugin = plugin
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.broadcastingEventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.broadcastingEventSink = nil
        return nil
    }
}

class ErrorStreamHandler: NSObject, FlutterStreamHandler {
    private weak var plugin: FlutterIvsStagePlugin?

    init(_ plugin: FlutterIvsStagePlugin) {
        self.plugin = plugin
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.errorEventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.errorEventSink = nil
        return nil
    }
}

class ScreenShareStreamHandler: NSObject, FlutterStreamHandler {
    private weak var plugin: FlutterIvsStagePlugin?

    init(_ plugin: FlutterIvsStagePlugin) {
        self.plugin = plugin
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.screenShareEventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.screenShareEventSink = nil
        return nil
    }
}
