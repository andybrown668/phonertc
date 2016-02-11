import Foundation

class PCObserver : NSObject, RTCPeerConnectionDelegate {
    var session: Session
    
    init(session: Session) {
        self.session = session
    }
    
    func peerConnection(peerConnection: RTCPeerConnection!,
        addedStream stream: RTCMediaStream!) {
        print("PCO onAddStream.")
            
        dispatch_async(dispatch_get_main_queue()) {
            if stream.videoTracks.count > 0 {
                self.session.addVideoTrack(stream.videoTracks[0] as! RTCVideoTrack)
            }
        }
        
        self.session.sendMessage(
            "{\"type\": \"__answered\"}".dataUsingEncoding(NSUTF8StringEncoding)!)
    }
    
    func peerConnection(peerConnection: RTCPeerConnection!,
        removedStream stream: RTCMediaStream!) {
        print("PCO onRemoveStream.")
        /*
        dispatch_async(dispatch_get_main_queue()) {
            if stream.videoTracks.count > 0 {
                self.session.removeVideoTrack(stream.videoTracks[0] as RTCVideoTrack)
            }
        }*/
    }
    
    func peerConnection(peerConnection: RTCPeerConnection!,
        iceGatheringChanged newState: RTCICEGatheringState) {
        print("PCO onIceGatheringChange. \(newState)")
        
    }
    
    func peerConnection(peerConnection: RTCPeerConnection!,
        iceConnectionChanged newState: RTCICEConnectionState) {
        //if the new ice connection state is 'disconnected' then the peer disappeared (ie didn't say 'bye')
        //so tear down this session and inform the plugin
        switch newState.rawValue{
        case RTCICEConnectionDisconnected.rawValue:
            print("ice connection is closed")
            self.session.disconnect(false);
        default:
            print("PCO onIceConnectionChange. \(newState)")
        }
        
        //send a string literal for the current ice state to the plugin
        var state = ""
        switch newState.rawValue{
        case RTCICEConnectionNew.rawValue: state="new"
        case RTCICEConnectionChecking.rawValue: state="checking"
        case RTCICEConnectionConnected.rawValue: state="connected"
        case RTCICEConnectionCompleted.rawValue: state="completed"
        case RTCICEConnectionFailed.rawValue: state="failed"
        case RTCICEConnectionDisconnected.rawValue: state="disconnected"
        case RTCICEConnectionClosed.rawValue: state="closed"
        default: state="unexpected\(newState.rawValue)"
        }
        self.session.sendMessage(
            "{\"type\": \"__iceConnectionStateChange\", \"state\": \"\(state)\"}".dataUsingEncoding(NSUTF8StringEncoding)!)
    }
    
    func peerConnection(peerConnection: RTCPeerConnection!,
        gotICECandidate candidate: RTCICECandidate!) {
        print("PCO onICECandidate.\n  Mid[\(candidate.sdpMid)] Index[\(candidate.sdpMLineIndex)] Sdp[\(candidate.sdp)]")
            
        let json: AnyObject = [
            "type": "candidate",
            "label": candidate.sdpMLineIndex,
            "id": candidate.sdpMid,
            "candidate": candidate.sdp
        ]
            
        do{
            let data = try NSJSONSerialization.dataWithJSONObject(json, options: NSJSONWritingOptions())
            self.session.sendMessage(data)
        }
        catch let error as NSError{
            print(error.localizedDescription)
        }
    }
    
    func peerConnection(peerConnection: RTCPeerConnection!,
        signalingStateChanged stateChanged: RTCSignalingState) {
        print("PCO onSignalingStateChange: \(stateChanged)")
    }
    
    func peerConnection(peerConnection: RTCPeerConnection!,
        didOpenDataChannel dataChannel: RTCDataChannel!) {
        print("PCO didOpenDataChannel.")
    }
    
    func peerConnectionOnError(peerConnection: RTCPeerConnection!) {
        print("PCO onError.")
    }
    
    func peerConnectionOnRenegotiationNeeded(peerConnection: RTCPeerConnection!) {
        print("PCO onRenegotiationNeeded.")
        // TODO: Handle this
    }
}