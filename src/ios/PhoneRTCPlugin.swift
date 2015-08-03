//version
import Foundation
import AVFoundation

@objc(PhoneRTCPlugin)
class PhoneRTCPlugin : CDVPlugin {
    var sessions: [String: Session] = [:]
    var peerConnectionFactory: RTCPeerConnectionFactory
    
    var videoConfig: VideoConfig?
    var videoCapturer: RTCVideoCapturer?
    var videoSource: RTCVideoSource?
    var localVideoView: RTCEAGLVideoView?
    var remoteVideoViews: [VideoTrackViewPair] = []
    
    var localVideoTrack: RTCVideoTrack?
    var localAudioTrack: RTCAudioTrack?
    
    override init(webView: UIWebView) {
        peerConnectionFactory = RTCPeerConnectionFactory()
        RTCPeerConnectionFactory.initializeSSL()
        super.init(webView: webView)
    }
    
    func createSessionObject(command: CDVInvokedUrlCommand) {
        if let sessionKey = command.argumentAtIndex(0) as? String {
            // create a session and initialize it.
            if let args = command.argumentAtIndex(1) {
                let config = SessionConfig(data: args)
                let session = Session(plugin: self, peerConnectionFactory: peerConnectionFactory,
                    config: config, callbackId: command.callbackId,
                    sessionKey: sessionKey)
                sessions[sessionKey] = session
            }
        }
    }
    
    func call(command: CDVInvokedUrlCommand) {
        let args: AnyObject = command.argumentAtIndex(0)
        if let sessionKey = args.objectForKey("sessionKey") as? String {
            dispatch_async(dispatch_get_main_queue()) {
                if let session = self.sessions[sessionKey] {
                    session.call()
                    // allow for a success callback
                    let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK)
                    pluginResult.setKeepCallbackAsBool(true);
                    self.commandDelegate.sendPluginResult(pluginResult, callbackId:command.callbackId)
                }
            }
        }
    }
    
    func receiveMessage(command: CDVInvokedUrlCommand) {
        let args: AnyObject = command.argumentAtIndex(0)
        if let sessionKey = args.objectForKey("sessionKey") as? String {
            if let message = args.objectForKey("message") as? String {
                if let session = self.sessions[sessionKey] {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) {
                        session.receiveMessage(message)
                    }
                }
            }
        }
    }
    
    func renegotiate(command: CDVInvokedUrlCommand) {
        let args: AnyObject = command.argumentAtIndex(0)
        if let sessionKey = args.objectForKey("sessionKey") as? String {
            if let config: AnyObject = args.objectForKey("config") {
                dispatch_async(dispatch_get_main_queue()) {
                    if let session = self.sessions[sessionKey] {
                        session.config = SessionConfig(data: config)
                        session.createOrUpdateStream()
                    }
                }
            }
        }
    }
    
    func disconnect(command: CDVInvokedUrlCommand) {
        let args: AnyObject = command.argumentAtIndex(0)
        if let sessionKey = args.objectForKey("sessionKey") as? String {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) {
                if (self.sessions[sessionKey] != nil) {
                    self.sessions[sessionKey]!.disconnect(true)
                }
            }
        }
    }

    func sendMessage(callbackId: String, message: NSData) {
        let json = NSJSONSerialization.JSONObjectWithData(message,
            options: NSJSONReadingOptions.MutableLeaves,
            error: nil) as! NSDictionary
        
        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAsDictionary: json as [NSObject : AnyObject])
        pluginResult.setKeepCallbackAsBool(true);
        
        self.commandDelegate.sendPluginResult(pluginResult, callbackId:callbackId)
    }
    
    func setVideoView(command: CDVInvokedUrlCommand) {
        let config: AnyObject = command.argumentAtIndex(0)
        
        dispatch_async(dispatch_get_main_queue()) {
            // create session config from the JS params
            let videoConfig = VideoConfig(data: config)
            
            println("\(videoConfig) yeah?")
            
            // make sure that it's not junk
            if videoConfig.container.width == 0 || videoConfig.container.height == 0 {
                return
            }
            
            self.videoConfig = videoConfig
            
            // add local video view
            if self.videoConfig!.local != nil {
                if self.localVideoTrack == nil {
                    self.initLocalVideoTrack()
                }
                
                if self.videoConfig!.local == nil {
                    // remove the local video view if it exists and
                    // the new config doesn't have the `local` property
                    if self.localVideoView != nil {
                        self.localVideoView!.hidden = true
                        self.localVideoView!.removeFromSuperview()
                        self.localVideoView = nil
                    }
                } else {
                    let params = self.videoConfig!.local!
                    
                    // if the local video view already exists, just
                    // change its position according to the new config.
                    if self.localVideoView != nil {
                        self.localVideoView!.frame = CGRectMake(
                            CGFloat(params.x + self.videoConfig!.container.x),
                            CGFloat(params.y + self.videoConfig!.container.y),
                            CGFloat(params.width),
                            CGFloat(params.height)
                        )
                    } else {
                        // otherwise, create the local video view
                        self.localVideoView = self.createVideoView(params: params)
                        self.localVideoTrack!.addRenderer(self.localVideoView!)
                    }
                }
                
                self.refreshVideoContainer()
            }
            // allow for a success callback
            let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK)
            pluginResult.setKeepCallbackAsBool(true);
            self.commandDelegate.sendPluginResult(pluginResult, callbackId:command.callbackId)

        }
    }
    
    func refreshVideoView(command: CDVInvokedUrlCommand) {
        let params: AnyObject = command.argumentAtIndex(0)
        println(params);
        dispatch_async(dispatch_get_main_queue()) {
            //replace the container layout then refresh the view
            self.videoConfig?.container = VideoLayoutParams(data: params);
            self.refreshVideoContainer();
        }
    }
    
    func hideVideoView(command: CDVInvokedUrlCommand) {
        dispatch_async(dispatch_get_main_queue()) {
            self.localVideoView!.hidden = true;
            
            for remoteVideoView in self.remoteVideoViews {
                remoteVideoView.videoView.hidden = true;
            }
        }
    }
    
    func showVideoView(command: CDVInvokedUrlCommand) {
        dispatch_async(dispatch_get_main_queue()) {
            if self.localVideoView != nil {
                self.localVideoView!.hidden = false;
            }
            
            
            for remoteVideoView in self.remoteVideoViews {
                remoteVideoView.videoView.hidden = false;
            } 
        }
    }
    
    func createVideoView(params: VideoLayoutParams? = nil) -> RTCEAGLVideoView {
        var view: RTCEAGLVideoView
        
        if params != nil {
            let frame = CGRectMake(
                CGFloat(params!.x + self.videoConfig!.container.x),
                CGFloat(params!.y + self.videoConfig!.container.y),
                CGFloat(params!.width),
                CGFloat(params!.height)
            )
            
            view = RTCEAGLVideoView(frame: frame)
        } else {
            view = RTCEAGLVideoView()
        }
        
        view.userInteractionEnabled = false
        
        self.webView.addSubview(view)
        self.webView.bringSubviewToFront(view)
        
        return view
    }
    
    func initLocalAudioTrack() {
        localAudioTrack = peerConnectionFactory.audioTrackWithID("ARDAMSa0")
    }
    
    func initLocalVideoTrack() {
        var cameraID: String?
        for captureDevice in AVCaptureDevice.devicesWithMediaType(AVMediaTypeVideo) {
            // TODO: Make this camera option configurable
            if captureDevice.position == AVCaptureDevicePosition.Front {
                cameraID = captureDevice.localizedName
            }
        }
        
        self.videoCapturer = RTCVideoCapturer(deviceName: cameraID)
        self.videoSource = self.peerConnectionFactory.videoSourceWithCapturer(
            self.videoCapturer,
            constraints: RTCMediaConstraints()
        )
    
        self.localVideoTrack = self.peerConnectionFactory
            .videoTrackWithID("ARDAMSv0", source: self.videoSource)
    }
    
    func addRemoteVideoTrack(videoTrack: RTCVideoTrack) {
        if self.videoConfig == nil {
            return
        }
        
        // add a video view without position/size as it will get
        // resized and re-positioned in refreshVideoContainer
        let videoView = createVideoView()
        
        videoTrack.addRenderer(videoView)
        self.remoteVideoViews.append(VideoTrackViewPair(videoView: videoView, videoTrack: videoTrack))
        
        refreshVideoContainer()
        
        if self.localVideoView != nil {
            self.webView.bringSubviewToFront(self.localVideoView!)
        }
    }
    
    func removeRemoteVideoTrack(videoTrack: RTCVideoTrack) {
        dispatch_async(dispatch_get_main_queue()) {
            for var i = 0; i < self.remoteVideoViews.count; i++ {
                let pair = self.remoteVideoViews[i]
                if pair.videoTrack == videoTrack {
                    pair.videoView.hidden = true
                    pair.videoView.removeFromSuperview()
                    self.remoteVideoViews.removeAtIndex(i)
                    self.refreshVideoContainer()
                    return
                }
            }
        }
    }
    
    func refreshVideoContainer() {
        var n = self.remoteVideoViews.count
        
        if n == 0 {
            return
        }
        
        let container = self.videoConfig!.container
        var bounds = CGRect(x: container.x, y: container.y, width: container.width, height: container.height)
        
        if n == 1 {
            //just fill the container with the video
            // set the video size to fit within the bounds of the entire container
            self.remoteVideoViews[0].setVideoSize(bounds);
            return;
        }
        
        if n == 2 {
            //split the display horizontally or vertically to maximize the usage given the two input video aspect ratios

            //calculate screen usage if split horizonally
            bounds.size.width /= 2
            let horizontalUsage = self.remoteVideoViews[0].getVideoArea(bounds)
                                + self.remoteVideoViews[1].getVideoArea(bounds);
            bounds.size.width *= 2

            //calculate screen usage if split vertically
            bounds.size.height /= 2
            let verticalUsage = self.remoteVideoViews[0].getVideoArea(bounds)
                + self.remoteVideoViews[1].getVideoArea(bounds);
            bounds.size.height *= 2
            
            // use the split that makes the best space for the input videos
            if horizontalUsage >= verticalUsage{
                bounds.size.width /= 2
                self.remoteVideoViews[0].setVideoSize(bounds);
                bounds.origin.x += bounds.size.width
                self.remoteVideoViews[1].setVideoSize(bounds);
            }
            else{
                bounds.size.height /= 2
                self.remoteVideoViews[0].setVideoSize(bounds);
                bounds.origin.y += bounds.size.height
                self.remoteVideoViews[1].setVideoSize(bounds);
            }
            return;
        }
    }
    
    func getCenter(videoCount: Int, videoSize: Int, containerSize: Int) -> Int {
        return lroundf(Float(containerSize - videoSize * videoCount) / 2.0)
    }
    
    func onSessionDisconnect(sessionKey: String) {
        self.sessions.removeValueForKey(sessionKey)
        
        if self.sessions.count == 0 {
            dispatch_sync(dispatch_get_main_queue()) {
                if self.localVideoView != nil {
                    self.localVideoView!.hidden = true
                    self.localVideoView!.removeFromSuperview()
                
                    self.localVideoView = nil
                }
            }
            
            self.localVideoTrack = nil
            self.localAudioTrack = nil
            
            self.videoSource = nil
            self.videoCapturer = nil
        }
    }
}

class VideoTrackViewPair : RTCEAGLVideoViewDelegate {
    var videoView: RTCEAGLVideoView
    var videoTrack: RTCVideoTrack
    var aspectRatio: CGFloat
    
    init(videoView:RTCEAGLVideoView, videoTrack: RTCVideoTrack){
        self.videoView = videoView
        self.videoTrack = videoTrack
        self.aspectRatio = 640/480
        videoView.delegate = self
    }
    
    @objc func videoView(videoView: RTCEAGLVideoView!,
        didChangeVideoSize size: CGSize){
            print(size);
            self.aspectRatio = size.width/size.height
            return
    }
    
    func getVideoArea(bounds: CGRect) -> CGFloat {
        // return the area we can use within the given bounds respecting the video source aspect ratio
        
        // if the height < width*aspect-ratio then don't use all the width
        var width = bounds.width
        var height = bounds.height
        
        if height < width / self.aspectRatio{
            width = height * self.aspectRatio
        }
        else{
            height = width / self.aspectRatio
        }
        return width*height;
    }

    func setVideoSize(bounds: CGRect){
        // use the aspect ratio to make the most use of the given maximum space
        // centering the resulting frame in the bounds
        var offset = CGPoint(x: bounds.origin.x, y: bounds.origin.y)

        // if the height < width*aspect-ratio then don't use all the width
        var width = bounds.width
        var height = bounds.height

        if height < width / self.aspectRatio{
            width = height * self.aspectRatio
            offset.x += (bounds.width - width) / 2
        }
        else{
            height = width / self.aspectRatio
            offset.y += (bounds.height - height) / 2
        }
        
        self.videoView.frame = CGRectMake(
            offset.x,
            offset.y,
            width,
            height
        )
    }
}