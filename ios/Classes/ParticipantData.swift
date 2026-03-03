import Foundation
import AmazonIVSBroadcast

class ParticipantData {
    let isLocal: Bool
    var participantId: String?
    var publishState: IVSParticipantPublishState = .notPublished
    var subscribeState: IVSParticipantSubscribeState = .notSubscribed
    var streams: [IVSStageStream] = []
    var wantsAudioOnly = false
    var requiresAudioOnly = false
    var attributes: [String: String] = [:]

    var isAudioOnly: Bool {
        return wantsAudioOnly || requiresAudioOnly
    }

    var broadcastSlotName: String {
        if isLocal {
            return "localUser"
        } else {
            guard let participantId = participantId else {
                fatalError("non-local participants must have a participantId")
            }
            return "participant-\(participantId)"
        }
    }

    init(isLocal: Bool, participantId: String?, attributes: [String: String] = [:]) {
        self.isLocal = isLocal
        self.participantId = participantId
        self.attributes = attributes
    }
    
    func toMap() -> [String: Any] {
        let streamMaps = streams.map { stream -> [String: Any] in
            return [
                "deviceId": stream.device.descriptor().urn,
                "type": stream.device is IVSImageDevice ? "video" : "audio",
                "isMuted": stream.isMuted
            ]
        }
        
        return [
            "isLocal": isLocal,
            "participantId": participantId ?? NSNull(),
            "publishState": publishState.description,
            "subscribeState": subscribeState.description,
            "streams": streamMaps,
            "wantsAudioOnly": wantsAudioOnly,
            "requiresAudioOnly": requiresAudioOnly,
            "broadcastSlotName": broadcastSlotName,
            "attributes": attributes
        ]
    }
}
