import Foundation
import AmazonIVSBroadcast
import UIKit
import ReplayKit

protocol StageManagerDelegate: AnyObject {
    func stageManager(_ manager: StageManager, didUpdateParticipants participants: [ParticipantData])
    func stageManager(_ manager: StageManager, didChangeConnectionState state: IVSStageConnectionState)
    func stageManager(_ manager: StageManager, didChangeLocalAudioMuted muted: Bool)
    func stageManager(_ manager: StageManager, didChangeLocalVideoMuted muted: Bool)
    func stageManager(_ manager: StageManager, didChangeBroadcasting broadcasting: Bool)
    func stageManager(_ manager: StageManager, didEncounterError error: Error, source: String?)
    func stageManager(_ manager: StageManager, didChangeScreenShareState sharing: Bool)
}

class StageManager: NSObject {

    static let screenShareParticipantId = "local-screen-share"

    weak var delegate: StageManagerDelegate?
    
    // MARK: - Video Views

    private final class RemoteRenderState {
        var registeredView: UIView?
        var latestVideoStreamUrn: String?
        var attachedVideoStreamUrn: String?
        var pendingRetryWorkItem: DispatchWorkItem?
    }

    private var remoteRenderStates: [String: RemoteRenderState] = [:]
    private var localVideoView: UIView?
    private var aspectMode: String?
    private let remoteAttachRetryDelays: [TimeInterval] = [0, 0.15, 0.35]
    
    // Video mirroring settings
    private var shouldMirrorLocalVideo: Bool = false
    private var shouldMirrorRemoteVideo: Bool = false
    
    // MARK: - Internal State
    
    private let broadcastConfig = IVSPresets.configurations().standardPortrait()
    private let camera: IVSCamera?
    private let microphone: IVSMicrophone?
    private var currentAuthItem: AuthItem?
    
    private var stage: IVSStage?
    private var localUserWantsPublish: Bool = true
    
    private var isVideoMuted = false {
        didSet {
            validateVideoMuteSetting()
            notifyParticipantsUpdate()
        }
    }
    private var isAudioMuted = false {
        didSet {
            validateAudioMuteSetting()
            notifyParticipantsUpdate()
        }
    }
    
    private var localStreams: [IVSLocalStageStream] {
        set {
            let localParticipant = ensureLocalParticipantEntry()
            localParticipant.streams = newValue
            updateBroadcastBindings()
            validateVideoMuteSetting()
            validateAudioMuteSetting()
        }
        get {
            let localParticipant = participantsData.first { $0.isLocal }
            return localParticipant?.streams as? [IVSLocalStageStream] ?? []
        }
    }
    
    private var broadcastSession: IVSBroadcastSession?

    // Screen share state
    private var screenShareBroadcastSession: IVSBroadcastSession?
    private var screenShareCustomSource: IVSCustomImageSource?
    var screenShareStream: IVSLocalStageStream?
    private var screenShareStage: IVSStage?
    private var screenShareStrategy: ScreenShareStageStrategy?
    private(set) var isScreenSharing = false

    private var broadcastSlots: [IVSMixerSlotConfiguration] = [] {
        didSet {
            guard let broadcastSession = broadcastSession else { return }
            let oldSlots = broadcastSession.mixer.slots()
            
            // Removing old slots
            oldSlots.forEach { oldSlot in
                if !broadcastSlots.contains(where: { $0.name == oldSlot.name }) {
                    broadcastSession.mixer.removeSlot(withName: oldSlot.name)
                }
            }
            
            // Adding new slots
            broadcastSlots.forEach { newSlot in
                if !oldSlots.contains(where: { $0.name == newSlot.name }) {
                    broadcastSession.mixer.addSlot(newSlot)
                }
            }
            
            // Update existing slots
            broadcastSlots.forEach { newSlot in
                if oldSlots.contains(where: { $0.name == newSlot.name }) {
                    broadcastSession.mixer.transitionSlot(withName: newSlot.name, toState: newSlot, duration: 0.3)
                }
            }
        }
    }
    
    private var participantsData: [ParticipantData] = [ParticipantData(isLocal: true, participantId: nil)] {
        didSet {
            updateBroadcastSlots()
            notifyParticipantsUpdate()
        }
    }
    
    private var stageConnectionState: IVSStageConnectionState = .disconnected {
        didSet {
            delegate?.stageManager(self, didChangeConnectionState: stageConnectionState)
        }
    }
    
    private var isBroadcasting: Bool = false {
        didSet {
            delegate?.stageManager(self, didChangeBroadcasting: isBroadcasting)
        }
    }
    
    // MARK: - Lifecycle
    
    override init() {
        // Setup default camera and microphone devices
        let devices = IVSDeviceDiscovery().listLocalDevices()
        camera = devices.compactMap({ $0 as? IVSCamera }).first
        microphone = devices.compactMap({ $0 as? IVSMicrophone }).first
        
        // Use `IVSStageAudioManager` to control the underlying AVAudioSession instance
        IVSStageAudioManager.sharedInstance().setPreset(.videoChat)
        IVSStageAudioManager.sharedInstance().isEchoCancellationEnabled = false
        super.init()
        
        camera?.errorDelegate = self
        microphone?.errorDelegate = self
        setupLocalUser()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification,
                                               object: nil)
    }

    private func ensureLocalParticipantEntry() -> ParticipantData {
        if let index = participantsData.firstIndex(where: { $0.isLocal }) {
            if index != 0 {
                let existing = participantsData.remove(at: index)
                participantsData.insert(existing, at: 0)
            }
            return participantsData[0]
        }

        let created = ParticipantData(isLocal: true, participantId: nil)
        participantsData.insert(created, at: 0)
        return created
    }
    
    private func setupLocalUser() {
        _ = ensureLocalParticipantEntry()

        if let camera = camera {
            // Find front camera input source and set it as preferred camera input source
            if let frontSource = camera.listAvailableInputSources().first(where: { $0.position == .front }) {
                camera.setPreferredInputSource(frontSource) { [weak self] in
                    if let error = $0 {
                        self?.displayErrorAlert(error, logSource: "setupLocalUser")
                    }
                }
            }
            let config = IVSLocalStageStreamConfiguration()
            config.audio.enableNoiseSuppression = false
            // Add stream with local image device to localStreams
            var currentStreams = localStreams
            currentStreams.append(IVSLocalStageStream(device: camera, config: config))
            localStreams = currentStreams
        }
        
        if let microphone = microphone {
            // Add stream with local audio device to localStreams
            var currentStreams = localStreams
            currentStreams.append(IVSLocalStageStream(device: microphone))
            localStreams = currentStreams
        }
        
        // Notify UI updates
        notifyParticipantsUpdate()
        
        // Ensure local video preview is set up now that streams are created
        setupLocalVideoPreview()
    }
    
    /// Ensure local streams exist (used for preview functionality)
    private func ensureLocalStreamsExist() {
        _ = ensureLocalParticipantEntry()
        print("Ivsstage: ensureLocalStreamsExist - current streams count: \(localStreams.count)")
        
        // Check if camera stream already exists
        let hasCameraStream = localStreams.contains { $0.device is IVSImageDevice && $0 !== screenShareStream }
        let hasAudioStream = localStreams.contains { $0.device is IVSAudioDevice }
        
        if !hasCameraStream, let camera = camera {
            print("Ivsstage: ensureLocalStreamsExist - creating camera stream")
            let config = IVSLocalStageStreamConfiguration()
            config.audio.enableNoiseSuppression = false
            var currentStreams = localStreams
            currentStreams.append(IVSLocalStageStream(device: camera, config: config))
            localStreams = currentStreams
        }
        
        if !hasAudioStream, let microphone = microphone {
            print("Ivsstage: ensureLocalStreamsExist - creating audio stream")
            var currentStreams = localStreams
            currentStreams.append(IVSLocalStageStream(device: microphone))
            localStreams = currentStreams
        }
        
        // Notify UI updates if streams were added
        if !hasCameraStream || !hasAudioStream {
            notifyParticipantsUpdate()
        }
        
        print("Ivsstage: ensureLocalStreamsExist - final streams count: \(localStreams.count)")
    }
    
    @objc
    private func applicationDidEnterBackground() {
        print("app did enter background")
        let stageState = stageConnectionState
        let connectingOrConnected = (stageState == .connecting) || (stageState == .connected)

        if connectingOrConnected {
            if isScreenSharing {
                // Keep publishing when screen sharing in background
                // RPScreenRecorder continues capturing entire device screen
                // Camera may freeze but screen share stays active
                // Only switch remote participants to audio only
                participantsData
                    .compactMap { $0.participantId }
                    .forEach {
                        mutatingParticipant($0) { data in
                            data.requiresAudioOnly = true
                        }
                    }
                stage?.refreshStrategy()
            } else {
                // Normal background behavior: stop publishing
                localUserWantsPublish = false
                participantsData
                    .compactMap { $0.participantId }
                    .forEach {
                        mutatingParticipant($0) { data in
                            data.requiresAudioOnly = true
                        }
                    }
                stage?.refreshStrategy()
            }
        }
    }
    
    @objc
    private func applicationWillEnterForeground() {
        print("app did resume foreground")
        // Resume publishing when entering foreground
        localUserWantsPublish = true
        
        // Resume other participants from audio only subscribe
        if !participantsData.isEmpty {
            participantsData
                .compactMap { $0.participantId }
                .forEach {
                    mutatingParticipant($0) { data in
                        data.requiresAudioOnly = false
                    }
                }
            
            stage?.refreshStrategy()
        }
    }
    
    // MARK: - Public Methods
    
    func joinStage(token: String, completion: @escaping (Error?) -> Void) {
        UserDefaults.standard.set(token, forKey: "joinToken")
        cancelAllRemoteAttachRetries()
        
        do {
            stage?.leave()
            self.stage = nil
            _ = ensureLocalParticipantEntry()
            ensureLocalStreamsExist()

            let stage = try IVSStage(token: token, strategy: self)
            stage.addRenderer(self)
            try stage.join()
            self.stage = stage
            DispatchQueue.main.async { [weak self] in
                self?.setupLocalVideoPreview()
            }
            completion(nil)
        } catch {
            displayErrorAlert(error, logSource: "JoinStageSession")
            completion(error)
        }
    }
    
    func leaveStage() {
        print("Ivsstage: Leaving stage")
        cancelAllRemoteAttachRetries()
        if isScreenSharing {
            RPScreenRecorder.shared().stopCapture(handler: nil)
            cleanupScreenShare()
        }
        stage?.leave()
        stage = nil
        
        localStreams.removeAll()

        // Clear participants
        participantsData.removeAll()
        
        // Clear all video views
        remoteRenderStates.values.forEach { $0.registeredView?.removeFromSuperview() }
        remoteRenderStates.removeAll()
        
        // Remove local video view
        localVideoView?.removeFromSuperview()
        localVideoView = nil
        
        delegate?.stageManager(self, didUpdateParticipants: [])
        delegate?.stageManager(self, didChangeConnectionState: .disconnected)
        
        print("Ivsstage: Stage left and cleaned up")
    }
    
    
    func toggleLocalVideoMute() {
        isVideoMuted.toggle()
    }
    
    private func validateVideoMuteSetting() {
        localStreams
            .filter { $0.device is IVSImageDevice }
            .forEach {
                $0.setMuted(isVideoMuted)
                delegate?.stageManager(self, didChangeLocalVideoMuted: isVideoMuted)
            }
    }
    
    func toggleLocalAudioMute() {
        isAudioMuted.toggle()
    }
    
    private func validateAudioMuteSetting() {
        localStreams
            .filter { $0.device is IVSAudioDevice }
            .forEach {
                $0.setMuted(isAudioMuted)
                delegate?.stageManager(self, didChangeLocalAudioMuted: isAudioMuted)
            }
    }
    
    func toggleAudioOnlySubscribe(forParticipant participantId: String) {
        mutatingParticipant(participantId) {
            $0.wantsAudioOnly.toggle()
        }
        
        stage?.refreshStrategy()
    }
    
    // MARK: - Video View Management
    
    func setLocalVideoView(_ view: UIView) {
        print("Ivsstage: Registering local video view - current localVideoView: \(localVideoView != nil ? "exists" : "nil")")
        localVideoView = view
        ensureLocalStreamsExist()
        print("Ivsstage: Local video view registered successfully")
        // Don't set up preview immediately - wait for streams to be created
         setupLocalVideoPreview()
    }
    
    func setVideoView(_ view: UIView, for participantId: String) {
        print("Ivsstage: remote view register participant=\(participantId)")
        let state = remoteRenderStates[participantId] ?? RemoteRenderState()
        state.registeredView = view
        remoteRenderStates[participantId] = state
        attachRemoteVideo(for: participantId, attempt: 0, reason: "setVideoView")
    }
    
    func removeVideoView(for participantId: String, view: UIView) {
        // Only remove if the registered view is the same instance being disposed.
        // When Flutter rebuilds the grid, new views register before old ones dispose.
        guard let state = remoteRenderStates[participantId], state.registeredView === view else { return }
        cancelRemoteAttachRetry(for: participantId)
        cleanupVideoStream(for: participantId, view: view)
        state.registeredView = nil
        state.attachedVideoStreamUrn = nil
        pruneRemoteRenderState(for: participantId)
    }

    func removeLocalVideoView(_ view: UIView) {
        // Only clear if the registered local view is the same instance being disposed.
        guard localVideoView === view else { return }
        print("Ivsstage: removeLocalVideoView - removing")
        cleanupLocalVideoPreview(view: view)
        localVideoView = nil
    }
    
    func refreshAllVideoPreviews() {
        print("Ivsstage: refreshAllVideoPreviews - refreshing all video views")
        
        // Only refresh local video preview if it's not already working
        if let localView = localVideoView, localView.subviews.isEmpty {
            print("Ivsstage: refreshAllVideoPreviews - refreshing local video preview")
            setupLocalVideoPreview()
        }
        
        // Refresh all participant video streams
        for participantId in remoteRenderStates.keys {
            attachRemoteVideo(for: participantId, attempt: 0, reason: "refreshAllVideoPreviews")
        }
        
        print("Ivsstage: refreshAllVideoPreviews - completed refreshing \(remoteRenderStates.count) participant views")
    }
    
    func setVideoMirroring(localVideo: Bool, remoteVideo: Bool) {
        print("Ivsstage: setVideoMirroring - local: \(localVideo), remote: \(remoteVideo)")
        
        shouldMirrorLocalVideo = localVideo
        shouldMirrorRemoteVideo = remoteVideo
        
        // Apply mirroring to existing local video view
        if let localView = localVideoView {
            applyMirroring(to: localView, shouldMirror: shouldMirrorLocalVideo)
        }
        
        // Apply mirroring to existing remote video views
        for (participantId, state) in remoteRenderStates {
            guard participantId != StageManager.screenShareParticipantId else { continue }
            if let view = state.registeredView {
                applyMirroring(to: view, shouldMirror: shouldMirrorRemoteVideo)
            }
        }
    }
    
    // MARK: - Camera Preview Methods
    
    /// Initialize camera preview before joining stage
    func initPreview(cameraType: String, aspectMode: String, completion: @escaping (Error?) -> Void) {
        print("Ivsstage: initPreview - cameraType: \(cameraType), aspectMode: \(aspectMode)")
        self.aspectMode = aspectMode
        guard let camera = camera else {
            completion(NSError(domain: "IVSStageError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Camera not available"]))
            return
        }
        
        // Ensure local streams are created for preview
        ensureLocalStreamsExist()
        
        // Set camera input source based on type
        setCameraType(cameraType) { [weak self] error in
            if let error = error {
                completion(error)
                return
            }
            
            // Store aspect mode for preview (could be used in UI implementation)
            // For now, we'll always use 'fill' behavior in the preview view constraints
            completion(nil)
        }
    }
    
    /// Toggle camera between front and back
    func toggleCamera(cameraType: String, completion: @escaping (Error?) -> Void) {
        print("Ivsstage: toggleCamera - switching to: \(cameraType)")
        ensureLocalStreamsExist()
        setCameraType(cameraType, completion: completion)
    }
    
    /// Stop camera preview
    func stopPreview() {
        print("Ivsstage: Stopping camera preview")

        // Remove local video view
        localVideoView?.removeFromSuperview()
        localVideoView = nil

        // Keep local streams intact so stage join can publish immediately.
        _ = ensureLocalParticipantEntry()
        print("Ivsstage: Camera preview stopped")
    }

    // MARK: - Screen Share

    func startScreenShare(token: String? = nil, completion: @escaping (Error?) -> Void) {
        guard !isScreenSharing else {
            completion(nil)
            return
        }

        // 1. Create lightweight BroadcastSession as factory for IVSCustomImageSource
        do {
            let config = IVSPresets.configurations().standardPortrait()
            screenShareBroadcastSession = try IVSBroadcastSession(
                configuration: config,
                descriptors: nil,
                delegate: nil
            )
        } catch {
            completion(error)
            return
        }

        guard let factory = screenShareBroadcastSession else {
            completion(NSError(domain: "IVSStageError", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create broadcast session factory"]))
            return
        }

        // 2. Create custom image source
        let customSource = factory.createImageSource(withName: "screenShare")
        screenShareCustomSource = customSource

        // 3. Start RPScreenRecorder capture (captures entire device screen)
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            cleanupScreenShare()
            completion(NSError(domain: "IVSStageError", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Screen recording is not available"]))
            return
        }

        let screenShareToken = token
        recorder.startCapture(handler: { [weak self] sampleBuffer, sampleBufferType, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async {
                    self.displayErrorAlert(error, logSource: "RPScreenRecorder")
                }
                return
            }
            // Only forward video frames
            if sampleBufferType == .video {
                self.screenShareCustomSource?.onSampleBuffer(sampleBuffer)
            }
        }) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.cleanupScreenShare()
                completion(error)
                return
            }

            let screenStream = IVSLocalStageStream(device: customSource)
            self.screenShareStream = screenStream

            if let token = screenShareToken {
                // Dual-stage mode: join a second Stage dedicated to screen share.
                // The primary stage continues publishing camera + mic unchanged.
                do {
                    let strategy = ScreenShareStageStrategy(manager: self)
                    self.screenShareStrategy = strategy
                    let ssStage = try IVSStage(token: token, strategy: strategy)
                    ssStage.addRenderer(ScreenShareStageRenderer(manager: self))
                    try ssStage.join()
                    self.screenShareStage = ssStage
                    print("Ivsstage: Screen share stage joined (dual-stage mode)")
                } catch {
                    self.cleanupScreenShare()
                    completion(error)
                    return
                }
            } else {
                // Single-stage fallback: add screen share to localStreams alongside camera
                var currentStreams = self.localStreams
                currentStreams.append(screenStream)
                self.localStreams = currentStreams

                self.stage?.refreshStrategy()

                // Add virtual participant so screen share appears as a separate tile
                let screenShareParticipant = ParticipantData(
                    isLocal: false,
                    participantId: StageManager.screenShareParticipantId
                )
                screenShareParticipant.publishState = .published
                screenShareParticipant.subscribeState = .subscribed
                screenShareParticipant.streams = [screenStream]
                self.participantsData.append(screenShareParticipant)
            }

            self.isScreenSharing = true
            self.delegate?.stageManager(self, didChangeScreenShareState: true)
            completion(nil)
        }
    }

    func stopScreenShare() {
        guard isScreenSharing else { return }
        RPScreenRecorder.shared().stopCapture { [weak self] error in
            if let error = error {
                print("Ivsstage: Error stopping screen capture: \(error)")
            }
            self?.cleanupScreenShare()
        }
    }

    private func cleanupScreenShare() {
        let wasDualStage = screenShareStage != nil

        // Leave and destroy screen share stage (dual-stage mode)
        screenShareStage?.leave()
        screenShareStage = nil
        screenShareStrategy = nil

        if !wasDualStage {
            // Single-stage fallback: remove screen share stream from localStreams (keep camera)
            if let screenStream = screenShareStream {
                var currentStreams = localStreams
                currentStreams.removeAll(where: { $0 === screenStream })
                localStreams = currentStreams
            }

            // Remove the virtual screen share participant tile
            participantsData.removeAll { $0.participantId == StageManager.screenShareParticipantId }
        }
        // In dual-stage mode, the primary stage's renderer handles the remote
        // screen share participant lifecycle (participantDidLeave fires automatically)

        screenShareStream = nil
        screenShareCustomSource = nil
        screenShareBroadcastSession = nil

        let wasSharing = isScreenSharing
        isScreenSharing = false

        stage?.refreshStrategy()

        if wasSharing {
            delegate?.stageManager(self, didChangeScreenShareState: false)
        }
    }

    /// Helper method to set camera input source
    private func setCameraType(_ cameraType: String, completion: @escaping (Error?) -> Void) {
        guard let camera = camera else {
            completion(NSError(domain: "IVSStageError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Camera not available"]))
            return
        }
        
        let position: IVSDevicePosition = cameraType == "front" ? .front : .back
        
        if let targetSource = camera.listAvailableInputSources().first(where: { $0.position == position }) {
            camera.setPreferredInputSource(targetSource) { error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("Ivsstage: setCameraType - failed to set camera to \(cameraType): \(error)")
                        completion(error)
                    } else {
                        print("Ivsstage: setCameraType - successfully set camera to \(cameraType)")
                        // The IVSCamera device's existing preview view automatically
                        // updates when the input source changes — no need to remove
                        // and recreate it. Doing so causes the local preview to freeze.
                        completion(nil)
                    }
                }
            }
        } else {
            let error = NSError(domain: "IVSStageError", code: -2, userInfo: [NSLocalizedDescriptionKey: "Camera type '\(cameraType)' not available"])
            completion(error)
        }
    }
    
    /// Refresh local video preview (useful after camera switching)
    private func refreshLocalVideoPreview() {
        guard let localView = localVideoView else { return }
        
        // Clear existing preview
        localView.subviews.forEach { $0.removeFromSuperview() }
        
        // Setup preview again with new camera
        setupLocalVideoPreview()
    }
    
    private func applyMirroring(to view: UIView, shouldMirror: Bool) {
        if shouldMirror {
            // Apply horizontal mirroring
            view.transform = CGAffineTransform(scaleX: -1, y: 1)
        } else {
            // Remove mirroring
            view.transform = CGAffineTransform.identity
        }
    }
    
    func refreshVideoPreview(for participantId: String) {
        print("Ivsstage: refreshVideoPreview - refreshing video for participant: \(participantId)")
        
        if participantId == participantsData.first(where: { $0.isLocal })?.participantId {
            // This is the local participant
            setupLocalVideoPreview()
        } else {
            // This is a remote participant
            attachRemoteVideo(for: participantId, attempt: 0, reason: "refreshVideoPreview")
        }
        
        print("Ivsstage: refreshVideoPreview - completed refreshing for participant: \(participantId)")
    }
    
    private func setupLocalVideoPreview() {
        guard let localView = localVideoView else { 
            print("Ivsstage: setupLocalVideoPreview - no local view registered")
            return 
        }
        
        // Check if preview is already set up and working
        if !localView.subviews.isEmpty {
            print("Ivsstage: setupLocalVideoPreview - local preview already exists, skipping setup")
            return
        }
        
        let cameraStreams = localStreams.filter { $0.device is IVSImageDevice && $0 !== screenShareStream }
        print("Ivsstage: setupLocalVideoPreview - cameraStreams count: \(cameraStreams.count)")

        if let cameraStream = cameraStreams.first,
           let imageDevice = cameraStream.device as? IVSImageDevice {
            print("Ivsstage: setupLocalVideoPreview - setting up camera preview for device: \(imageDevice)")
            
            do {
                let preview = try imageDevice.previewView(
                    with: aspectMode == "fill" ? .fill :  aspectMode == "fit" ? .fit : .none
                )
                print("Ivsstage: setupLocalVideoPreview - created preview view: \(preview)")
                
                // Add the preview view
                preview.translatesAutoresizingMaskIntoConstraints = false
                localView.addSubview(preview)
                localView.backgroundColor = .clear
                
                NSLayoutConstraint.activate([
                    preview.topAnchor.constraint(equalTo: localView.topAnchor),
                    preview.bottomAnchor.constraint(equalTo: localView.bottomAnchor),
                    preview.leadingAnchor.constraint(equalTo: localView.leadingAnchor),
                    preview.trailingAnchor.constraint(equalTo: localView.trailingAnchor),
                ])
                
                // Apply mirroring if enabled
                applyMirroring(to: localView, shouldMirror: shouldMirrorLocalVideo)
                
                print("Ivsstage: setupLocalVideoPreview - successfully set up camera preview")
            } catch {
                print("Ivsstage: setupLocalVideoPreview - failed to create preview view: \(error)")
            }
        } else {
            print("Ivsstage: setupLocalVideoPreview - no camera stream available yet")
        }
    }
    
    private func refreshLatestRemoteVideoUrn(for participantId: String) {
        let latestVideo = participantsData
            .first(where: { $0.participantId == participantId })?
            .streams
            .reversed()
            .first(where: { $0.device is IVSImageDevice })
        let latestUrn = latestVideo?.device.descriptor().urn
        let state = remoteRenderStates[participantId] ?? RemoteRenderState()
        state.latestVideoStreamUrn = (latestUrn?.isEmpty == false) ? latestUrn : nil
        remoteRenderStates[participantId] = state
    }

    private func pruneRemoteRenderState(for participantId: String) {
        guard let state = remoteRenderStates[participantId] else { return }
        let hasView = state.registeredView != nil
        let hasLatest = !(state.latestVideoStreamUrn?.isEmpty ?? true)
        let hasPending = state.pendingRetryWorkItem != nil
        if !hasView && !hasLatest && !hasPending {
            remoteRenderStates.removeValue(forKey: participantId)
        }
    }

    private func cancelRemoteAttachRetry(for participantId: String) {
        guard let state = remoteRenderStates[participantId] else { return }
        state.pendingRetryWorkItem?.cancel()
        state.pendingRetryWorkItem = nil
        print("Ivsstage: remote attach retry canceled participant=\(participantId)")
        pruneRemoteRenderState(for: participantId)
    }

    private func cancelAllRemoteAttachRetries() {
        remoteRenderStates.values.forEach {
            $0.pendingRetryWorkItem?.cancel()
            $0.pendingRetryWorkItem = nil
        }
    }

    private func scheduleRemoteAttachRetry(for participantId: String, attempt: Int, reason: String) {
        let nextAttempt = attempt + 1
        guard nextAttempt < remoteAttachRetryDelays.count else {
            print("Ivsstage: remote attach give-up participant=\(participantId) attempt=\(attempt) reason=\(reason)")
            return
        }

        let state = remoteRenderStates[participantId] ?? RemoteRenderState()
        remoteRenderStates[participantId] = state
        cancelRemoteAttachRetry(for: participantId)
        let delay = remoteAttachRetryDelays[nextAttempt]
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.remoteRenderStates[participantId]?.pendingRetryWorkItem = nil
            self.attachRemoteVideo(for: participantId, attempt: nextAttempt, reason: "retry")
        }
        state.pendingRetryWorkItem = workItem
        print("Ivsstage: remote attach retry scheduled participant=\(participantId) attempt=\(nextAttempt) delay=\(delay)s reason=\(reason)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func attachRemoteVideo(for participantId: String, attempt: Int, reason: String) {
        let maxAttempt = max(0, remoteAttachRetryDelays.count - 1)
        let state = remoteRenderStates[participantId] ?? RemoteRenderState()
        remoteRenderStates[participantId] = state
        refreshLatestRemoteVideoUrn(for: participantId)

        let view = state.registeredView
        let latestUrn = state.latestVideoStreamUrn?.isEmpty == false ? state.latestVideoStreamUrn : nil
        let participantData = participantsData.first(where: { $0.participantId == participantId })
        let videoStreamCount = participantData?.streams.filter({ $0.device is IVSImageDevice }).count ?? 0

        print(
            "Ivsstage: remote attach attempt participant=\(participantId), attempt=\(attempt)/\(maxAttempt), reason=\(reason), viewRegistered=\(view != nil), videoStreams=\(videoStreamCount), latestUrn=\(latestUrn ?? "none"), attachedUrn=\(state.attachedVideoStreamUrn ?? "none")"
        )

        guard let view else {
            scheduleRemoteAttachRetry(for: participantId, attempt: attempt, reason: "view not registered")
            return
        }
        guard let participantData else {
            scheduleRemoteAttachRetry(for: participantId, attempt: attempt, reason: "participant data missing")
            return
        }
        let latestVideoStream: IVSStageStream? = {
            if let latestUrn {
                return participantData.streams.reversed().first {
                    $0.device is IVSImageDevice && $0.device.descriptor().urn == latestUrn
                }
            }
            return participantData.streams.reversed().first {
                $0.device is IVSImageDevice
            }
        }()
        guard let latestVideoStream else {
            scheduleRemoteAttachRetry(for: participantId, attempt: attempt, reason: "video stream missing")
            return
        }
        guard let imageDevice = latestVideoStream.device as? IVSImageDevice else {
            scheduleRemoteAttachRetry(for: participantId, attempt: attempt, reason: "image device unavailable")
            return
        }

        if let latestUrn,
           state.attachedVideoStreamUrn == latestUrn,
           !view.subviews.isEmpty {
            print("Ivsstage: remote attach skip participant=\(participantId) stream unchanged")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            do {
                let preview = try imageDevice.previewView(with: .fill)
                view.subviews.forEach { $0.removeFromSuperview() }
                preview.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(preview)
                view.backgroundColor = .clear

                NSLayoutConstraint.activate([
                    preview.topAnchor.constraint(equalTo: view.topAnchor),
                    preview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                    preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                ])

                self.applyMirroring(to: view, shouldMirror: self.shouldMirrorRemoteVideo)
                state.attachedVideoStreamUrn = latestUrn
                self.cancelRemoteAttachRetry(for: participantId)
                print("Ivsstage: remote attach success participant=\(participantId) streamUrn=\(latestUrn)")
            } catch {
                print("Ivsstage: remote attach failed participant=\(participantId) attempt=\(attempt) reason=\(error.localizedDescription)")
                self.scheduleRemoteAttachRetry(
                    for: participantId,
                    attempt: attempt,
                    reason: "preview attach failed: \(error.localizedDescription)"
                )
            }
        }
    }
    
    
    private func cleanupVideoStream(for participantId: String, view: UIView) {
        // Remove all subviews (IVSImageView instances)
        view.subviews.forEach { $0.removeFromSuperview() }
    }
    
    private func cleanupLocalVideoPreview(view: UIView) {
        // Remove all subviews (IVSImagePreviewView instances)
        view.subviews.forEach { $0.removeFromSuperview() }
    }
    
    func toggleBroadcasting(completion: @escaping (Error?) -> Void) {
        guard let authItem = currentAuthItem, let endpoint = URL(string: authItem.endpoint) else {
            let error = NSError(domain: "InvalidAuth", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Invalid Endpoint or StreamKey"
            ])
            displayErrorAlert(error, logSource: "toggleBroadcasting")
            completion(error)
            return
        }
        
        // Create broadcast session if needed
        guard setupBroadcastSessionIfNeeded() else {
            let error = NSError(domain: "BroadcastSetup", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Failed to setup broadcast session"
            ])
            completion(error)
            return
        }
        
        if isBroadcasting {
            // Stop broadcasting if the broadcast session is running
            broadcastSession?.stop()
            isBroadcasting = false
            completion(nil)
        } else {
            // Start broadcasting
            do {
                try broadcastSession?.start(with: endpoint, streamKey: authItem.streamKey)
                isBroadcasting = true
                completion(nil)
            } catch {
                displayErrorAlert(error, logSource: "StartBroadcast")
                isBroadcasting = false
                broadcastSession = nil
                completion(error)
            }
        }
    }
    
    func setBroadcastAuth(endpoint: String, streamKey: String) -> Bool {
        guard URL(string: endpoint) != nil else {
            let error = NSError(domain: "InvalidAuth", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Invalid Endpoint or StreamKey"
            ])
            displayErrorAlert(error, logSource: "setBroadcastAuth")
            return false
        }
        
        UserDefaults.standard.set(endpoint, forKey: "endpointPath")
        UserDefaults.standard.set(streamKey, forKey: "streamKey")
        let authItem = AuthItem(endpoint: endpoint, streamKey: streamKey)
        currentAuthItem = authItem
        return true
    }
    
    func dispose() {
        cancelAllRemoteAttachRetries()
        // Stop screen share if active
        if isScreenSharing {
            RPScreenRecorder.shared().stopCapture(handler: nil)
            cleanupScreenShare()
        }

        // Clean up video views
        if let localView = localVideoView {
            cleanupLocalVideoPreview(view: localView)
        }
        remoteRenderStates.forEach { (participantId, state) in
            if let view = state.registeredView {
                cleanupVideoStream(for: participantId, view: view)
            }
        }
        remoteRenderStates.removeAll()
        localVideoView = nil

        destroyBroadcastSession()
        leaveStage()
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Private Methods
    
    private func setupBroadcastSessionIfNeeded() -> Bool {
        guard broadcastSession == nil else {
            print("Session not created since it already exists")
            return true
        }
        do {
            self.broadcastSession = try IVSBroadcastSession(configuration: broadcastConfig,
                                                            descriptors: nil,
                                                            delegate: self)
            updateBroadcastSlots()
            return true
        } catch {
            displayErrorAlert(error, logSource: "SetupBroadcastSession")
            return false
        }
    }
    
    private func updateBroadcastSlots() {
        do {
            let participantsToBroadcast = participantsData
            
            broadcastSlots = try StageLayoutCalculator().calculateFrames(participantCount: participantsToBroadcast.count,
                                                                         width: broadcastConfig.video.size.width,
                                                                         height: broadcastConfig.video.size.height,
                                                                         padding: 10)
            .enumerated()
            .map { (index, frame) in
                let slot = IVSMixerSlotConfiguration()
                try slot.setName(participantsToBroadcast[index].broadcastSlotName)
                slot.position = frame.origin
                slot.size = frame.size
                slot.zIndex = Int32(index)
                return slot
            }
            
            updateBroadcastBindings()
            
        } catch {
            let error = NSError(domain: "BroadcastSlots", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "There was an error updating the slots for the Broadcast"
            ])
            displayErrorAlert(error, logSource: "updateBroadcastSlots")
        }
    }
    
    private func updateBroadcastBindings() {
        guard let broadcastSession = broadcastSession else { return }
        
        broadcastSession.awaitDeviceChanges { [weak self] in
            var attachedDevices = broadcastSession.listAttachedDevices()
            
            self?.participantsData.forEach { participant in
                participant.streams.forEach { stream in
                    let slotName = participant.broadcastSlotName
                    if attachedDevices.contains(where: { $0 === stream.device }) {
                        if broadcastSession.mixer.binding(for: stream.device) != slotName {
                            broadcastSession.mixer.bindDevice(stream.device, toSlotWithName: slotName)
                        }
                    } else {
                        broadcastSession.attach(stream.device, toSlotWithName: slotName)
                    }
                    
                    attachedDevices.removeAll(where: { $0 === stream.device })
                }
            }
            
            attachedDevices.forEach {
                broadcastSession.detach($0)
            }
        }
    }
    
    private func destroyBroadcastSession() {
        if isBroadcasting {
            print("Destroying broadcast session")
            broadcastSession?.stop()
            broadcastSession = nil
            isBroadcasting = false
        }
    }
    
    private func dataForParticipant(_ participantId: String) -> ParticipantData? {
        let participant = participantsData.first { $0.participantId == participantId }
        return participant
    }
    
    private func mutatingParticipant(_ participantId: String?, modifier: (inout ParticipantData) -> Void) {
        guard let index = participantsData.firstIndex(where: { $0.participantId == participantId }) else { return }
        
        var participant = participantsData[index]
        modifier(&participant)
        participantsData[index] = participant
    }
    
    private func notifyParticipantsUpdate() {
        delegate?.stageManager(self, didUpdateParticipants: participantsData)
    }
    
    func displayErrorAlert(_ error: Error, logSource: String? = nil) {
        delegate?.stageManager(self, didEncounterError: error, source: logSource)
    }
}

// MARK: - IVSStageStrategy

extension StageManager: IVSStageStrategy {
    
    func stage(_ stage: IVSStage, shouldSubscribeToParticipant participant: IVSParticipantInfo) -> IVSStageSubscribeType {
        guard let data = dataForParticipant(participant.participantId) else { return .none }
        let subType: IVSStageSubscribeType = data.isAudioOnly ? .audioOnly : .audioVideo
        return subType
    }
    
    func stage(_ stage: IVSStage, shouldPublishParticipant participant: IVSParticipantInfo) -> Bool {
        return localUserWantsPublish
    }
    
    func stage(_ stage: IVSStage, streamsToPublishForParticipant participant: IVSParticipantInfo) -> [IVSLocalStageStream] {
        let localParticipant = ensureLocalParticipantEntry()
        if localParticipant.participantId == nil {
            localParticipant.participantId = participant.participantId
        } else if localParticipant.participantId != participant.participantId {
            return []
        }
        // Dual-stage mode: primary stage publishes camera + mic only.
        // Screen share is published via the separate screenShareStage.
        if screenShareStage != nil {
            return localStreams.filter { $0 !== screenShareStream }
        }
        // Single-stage fallback: only one video stream can be published.
        // Keep microphone and publish screen share video when active.
        if isScreenSharing, let screenShareStream = screenShareStream {
            return localStreams.filter { !($0.device is IVSImageDevice) || $0 === screenShareStream }
        }
        return localStreams
    }
}

// MARK: - IVSStageRenderer

extension StageManager: IVSStageRenderer {
    
    func stage(_ stage: IVSStage, participantDidJoin participant: IVSParticipantInfo) {
        print("[IVSStageRenderer] participantDidJoin - \(participant.participantId)")
        let attrs = participant.attributes as? [String: String] ?? [:]
        if participant.isLocal {
            let localParticipant = ensureLocalParticipantEntry()
            localParticipant.participantId = participant.participantId
            localParticipant.attributes = attrs
            // Ensure local video preview is set up after local participant joins
            DispatchQueue.main.async { [weak self] in
                self?.setupLocalVideoPreview()
            }
        } else {
            participantsData.append(ParticipantData(isLocal: false, participantId: participant.participantId, attributes: attrs))
        }
    }
    
    func stage(_ stage: IVSStage, participantDidLeave participant: IVSParticipantInfo) {
        print("[IVSStageRenderer] participantDidLeave - \(participant.participantId)")
        if participant.isLocal {
            print("[IVSStageRenderer] Local participant left - preserving local video view")
            ensureLocalParticipantEntry().participantId = nil
            // Don't clear local video view when local participant leaves
            // as it may reconnect and we want to keep the preview stable
        } else {
            cancelRemoteAttachRetry(for: participant.participantId)
            if let index = participantsData.firstIndex(where: { $0.participantId == participant.participantId }) {
                participantsData.remove(at: index)
            }
            if let view = remoteRenderStates.removeValue(forKey: participant.participantId)?.registeredView {
                cleanupVideoStream(for: participant.participantId, view: view)
            }
        }
    }
    
    func stage(_ stage: IVSStage, participant: IVSParticipantInfo, didChange publishState: IVSParticipantPublishState) {
        print("[IVSStageRenderer] participant \(participant.participantId) didChangePublishState to \(publishState.description)")
        mutatingParticipant(participant.participantId) { data in
            data.publishState = publishState
        }
    }
    
    func stage(_ stage: IVSStage, participant: IVSParticipantInfo, didChange subscribeState: IVSParticipantSubscribeState) {
        print("[IVSStageRenderer] participant \(participant.participantId) didChangeSubscribeState to \(subscribeState.description)")
        mutatingParticipant(participant.participantId) { data in
            data.subscribeState = subscribeState
        }
    }
    
    func stage(_ stage: IVSStage, participant: IVSParticipantInfo, didAdd streams: [IVSStageStream]) {
        print("[IVSStageRenderer] participant (\(participant.participantId)) didAdd \(streams.count) streams")
        
        for (index, stream) in streams.enumerated() {
            print("[IVSStageRenderer] Stream \(index): device type = \(type(of: stream.device)), urn = \(stream.device.descriptor().urn)")
        }
        
        if participant.isLocal {
            // Local streams are handled by the localStreams setter
            return
        }
        
        mutatingParticipant(participant.participantId) { data in
            for stream in streams {
                let urn = stream.device.descriptor().urn
                let isVideo = stream.device is IVSImageDevice
                data.streams.removeAll { existing in
                    (existing.device is IVSImageDevice) == isVideo &&
                        existing.device.descriptor().urn == urn
                }
                data.streams.append(stream)
            }
        }
        
        // Set up video stream for this participant if we have a view for them
        print("[IVSStageRenderer] Setting up video stream for participant: \(participant.participantId)")
        refreshLatestRemoteVideoUrn(for: participant.participantId)
        attachRemoteVideo(for: participant.participantId, attempt: 0, reason: "didAddStreams")
    }
    
    func stage(_ stage: IVSStage, participant: IVSParticipantInfo, didRemove streams: [IVSStageStream]) {
        print("[IVSStageRenderer] participant (\(participant.participantId)) didRemove \(streams.count) streams")
        if participant.isLocal { return }
        
        mutatingParticipant(participant.participantId) { data in
            let oldUrns = streams.map { $0.device.descriptor().urn }
            data.streams.removeAll(where: { stream in
                return oldUrns.contains(stream.device.descriptor().urn)
            })
        }
        
        let removedUrns = Set(streams.map { $0.device.descriptor().urn })
        let hasRemainingVideo = participantsData
            .first(where: { $0.participantId == participant.participantId })?
            .streams
            .contains(where: { $0.device is IVSImageDevice }) ?? false
        if let state = remoteRenderStates[participant.participantId] {
            let attachedUrn = state.attachedVideoStreamUrn
            let hasAttachedUrn = attachedUrn?.isEmpty == false
            let removedAttachedUrn = (attachedUrn.map { removedUrns.contains($0) } ?? false)
            let shouldClearAttachedView =
                (hasAttachedUrn && removedAttachedUrn) ||
                (!hasAttachedUrn && !hasRemainingVideo)
            if shouldClearAttachedView {
                if let view = state.registeredView {
                    cleanupVideoStream(for: participant.participantId, view: view)
                }
                state.attachedVideoStreamUrn = nil
            }
        }
        refreshLatestRemoteVideoUrn(for: participant.participantId)
        attachRemoteVideo(for: participant.participantId, attempt: 0, reason: "didRemoveStreams")
    }
    
    
    func stage(_ stage: IVSStage, participant: IVSParticipantInfo, didChangeMutedStreams streams: [IVSStageStream]) {
        print("[IVSStageRenderer] participant (\(participant.participantId)) didChangeMutedStreams")
        if participant.isLocal { return }
        if participantsData.contains(where: { $0.participantId == participant.participantId }) {
            // Notify update since stream mute states have changed.
            notifyParticipantsUpdate()
        }
    }
    
    func stage(_ stage: IVSStage, didChange connectionState: IVSStageConnectionState, withError error: Error?) {
        print("[IVSStageRenderer] didChangeConnectionStateWithError to \(connectionState.description)")
        stageConnectionState = connectionState
        if let error = error {
            displayErrorAlert(error, logSource: "StageConnectionState")
        }
    }
}

// MARK: - IVSBroadcastSession.Delegate

extension StageManager: IVSBroadcastSession.Delegate {
    
    func broadcastSession(_ session: IVSBroadcastSession, didChange state: IVSBroadcastSession.State) {
        print("[IVSBroadcastSession] state changed to \(state.description)")
        switch state {
        case .invalid, .disconnected, .error:
            isBroadcasting = false
            broadcastSession = nil
        case .connecting, .connected:
            isBroadcasting = true
        default:
            return
        }
    }
    
    func broadcastSession(_ session: IVSBroadcastSession, didEmitError error: Error) {
        print("[IVSBroadcastSession] did emit error \(error.localizedDescription)")
        DispatchQueue.main.async {
            self.displayErrorAlert(error, logSource: "IVSBroadcastSession")
        }
    }
}

// MARK: - IVSErrorDelegate

extension StageManager: IVSErrorDelegate {
    
    func source(_ source: IVSErrorSource, didEmitError error: Error) {
        print("[IVSErrorDelegate] did emit error \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            self?.displayErrorAlert(error, logSource: "\(source)")
        }
    }
}

// MARK: - Screen Share Stage (dual-stage mode)

class ScreenShareStageStrategy: NSObject, IVSStageStrategy {
    weak var manager: StageManager?

    init(manager: StageManager) {
        self.manager = manager
    }

    func stage(_ stage: IVSStage, shouldSubscribeToParticipant participant: IVSParticipantInfo) -> IVSStageSubscribeType {
        return .none
    }

    func stage(_ stage: IVSStage, shouldPublishParticipant participant: IVSParticipantInfo) -> Bool {
        return true
    }

    func stage(_ stage: IVSStage, streamsToPublishForParticipant participant: IVSParticipantInfo) -> [IVSLocalStageStream] {
        guard let stream = manager?.screenShareStream else { return [] }
        return [stream]
    }
}

class ScreenShareStageRenderer: NSObject, IVSStageRenderer {
    weak var manager: StageManager?

    init(manager: StageManager) {
        self.manager = manager
    }

    func stage(_ stage: IVSStage, didChange connectionState: IVSStageConnectionState, withError error: Error?) {
        print("Ivsstage: Screen share stage connection state: \(connectionState.description)")
        if let error = error {
            manager?.displayErrorAlert(error, logSource: "ScreenShareStageConnection")
        }
    }

    func stage(_ stage: IVSStage, participantDidJoin participant: IVSParticipantInfo) {
        print("Ivsstage: Screen share stage: participant joined \(participant.participantId)")
    }

    func stage(_ stage: IVSStage, participantDidLeave participant: IVSParticipantInfo) {
        print("Ivsstage: Screen share stage: participant left \(participant.participantId)")
    }

    func stage(_ stage: IVSStage, participant: IVSParticipantInfo, didChange publishState: IVSParticipantPublishState) {
        print("Ivsstage: Screen share stage: publish state changed to \(publishState.description)")
    }

    func stage(_ stage: IVSStage, participant: IVSParticipantInfo, didChange subscribeState: IVSParticipantSubscribeState) {}
    func stage(_ stage: IVSStage, participant: IVSParticipantInfo, didAdd streams: [IVSStageStream]) {}
    func stage(_ stage: IVSStage, participant: IVSParticipantInfo, didRemove streams: [IVSStageStream]) {}
    func stage(_ stage: IVSStage, participant: IVSParticipantInfo, didChangeMutedStreams streams: [IVSStageStream]) {}
}

// MARK: - Supporting Types

struct AuthItem {
    let endpoint: String
    let streamKey: String
}

// MARK: - Extensions

extension IVSBroadcastSession.State {
    var description: String {
        switch self {
        case .invalid: return "Invalid"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .error: return "Error"
        @unknown default: return "Unknown"
        }
    }
}

extension IVSStageConnectionState {
    var description: String {
        switch self {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        @unknown default: return "unknown"
        }
    }
}

extension IVSParticipantPublishState {
    var description: String {
        switch self {
        case .notPublished: return "notPublished"
        case .attemptingPublish: return "attemptingPublish"
        case .published: return "published"
        @unknown default: return "unknown"
        }
    }
}

extension IVSParticipantSubscribeState {
    var description: String {
        switch self {
        case .notSubscribed: return "notSubscribed"
        case .attemptingSubscribe: return "attemptingSubscribe"
        case .subscribed: return "subscribed"
        @unknown default: return "unknown"
        }
    }
}
