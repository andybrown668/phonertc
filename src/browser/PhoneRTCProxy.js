var PeerConnection = window.mozRTCPeerConnection || window.webkitRTCPeerConnection;
var IceCandidate = window.mozRTCIceCandidate || window.RTCIceCandidate;
var SessionDescription = window.mozRTCSessionDescription || window.RTCSessionDescription;
var MediaStream = window.webkitMediaStream || window.mozMediaStream || window.MediaStream;

navigator.getUserMedia = navigator.getUserMedia || navigator.mozGetUserMedia || navigator.webkitGetUserMedia;

var localStreams = [];
var localVideoTrack, localAudioTrack;

function Session(sessionKey, config, sendMessageCallback) {
  var self = this;
  self.sessionKey = sessionKey;
  self.config = config;
  self.sendMessage = sendMessageCallback;

  self.onIceCandidate = function (event) {
    if (event.candidate) {
      self.sendMessage({
        type: 'candidate',
        label: event.candidate.sdpMLineIndex,
        id: event.candidate.sdpMid,
        candidate: event.candidate.candidate
      });
    }
  };

  self.onRemoteStreamAdded = function (event) {
    self.videoView = addRemoteStream(event.stream);
    self.sendMessage({ type: '__answered' });
  };

  self.setRemote = function (message) {
    message.sdp = self.addCodecParam(message.sdp, 'opus/48000', 'stereo=1');

    this.peerConnection.setRemoteDescription(new SessionDescription(message), function () {
      console.log('setRemote success');
    }, function (error) { 
      console.log(error); 
    });
  };

  // Adds fmtp param to specified codec in SDP.
  self.addCodecParam = function (sdp, codec, param) {
    var sdpLines = sdp.split('\r\n');

    // Find opus payload.
    var index = self.findLine(sdpLines, 'a=rtpmap', codec);
    var payload;
    if (index) {
      payload = self.getCodecPayloadType(sdpLines[index]);
    }

    // Find the payload in fmtp line.
    var fmtpLineIndex = self.findLine(sdpLines, 'a=fmtp:' + payload.toString());
    if (fmtpLineIndex === null) {
      return sdp;
    }

    sdpLines[fmtpLineIndex] = sdpLines[fmtpLineIndex].concat('; ', param);

    sdp = sdpLines.join('\r\n');
    return sdp;
  };

  // Find the line in sdpLines that starts with |prefix|, and, if specified,
  // contains |substr| (case-insensitive search).
  self.findLine = function (sdpLines, prefix, substr) {
    return self.findLineInRange(sdpLines, 0, -1, prefix, substr);
  };

  // Find the line in sdpLines[startLine...endLine - 1] that starts with |prefix|
  // and, if specified, contains |substr| (case-insensitive search).
  self.findLineInRange = function (sdpLines, startLine, endLine, prefix, substr) {
    var realEndLine = endLine !== -1 ? endLine : sdpLines.length;
    for (var i = startLine; i < realEndLine; ++i) {
      if (sdpLines[i].indexOf(prefix) === 0) {
        if (!substr ||
            sdpLines[i].toLowerCase().indexOf(substr.toLowerCase()) !== -1) {
          return i;
        }
      }
    }
    return null;
  };

  // Gets the codec payload type from an a=rtpmap:X line.
  self.getCodecPayloadType = function (sdpLine) {
    var pattern = new RegExp('a=rtpmap:(\\d+) \\w+\\/\\d+');
    var result = sdpLine.match(pattern);
    return (result && result.length === 2) ? result[1] : null;
  };

  // Returns a new m= line with the specified codec as the first one.
  self.setDefaultCodec = function (mLine, payload) {
    var elements = mLine.split(' ');
    var newLine = [];
    var index = 0;
    for (var i = 0; i < elements.length; i++) {
      if (index === 3) { // Format of media starts from the fourth.
        newLine[index++] = payload; // Put target payload to the first.
      }
      if (elements[i] !== payload) {
        newLine[index++] = elements[i];
      }
    }
    return newLine.join(' ');
  };
}

Session.prototype.createOrUpdateStream = function () {
  if (this.localStream) {
    this.peerConnection.removeStream(this.localStream);
  }

  this.localStream = new MediaStream();
  
  if (this.config.streams.audio) {
    this.localStream.addTrack(localAudioTrack);
  }

  if (this.config.streams.video) {
    this.localStream.addTrack(localVideoTrack);
  }

  this.peerConnection.addStream(this.localStream);
};

Session.prototype.sendOffer = function () {
  var self = this;
  self.peerConnection.createOffer(function (sdp) {
    self.peerConnection.setLocalDescription(sdp, function () {
      console.log('Set session description success.');
    }, function (error) {
      console.log(error);
    });

    self.sendMessage(sdp);
  }, function (error) {
    console.log(error);
  }, { mandatory: { OfferToReceiveAudio: true, OfferToReceiveVideo: !!videoConfig }});
}

Session.prototype.sendAnswer = function () {
  var self = this;
  self.peerConnection.createAnswer(function (sdp) {
    self.peerConnection.setLocalDescription(sdp, function () {
      console.log('Set session description success.');
    }, function (error) {
      console.log(error);
    });

    self.sendMessage(sdp);
  }, function (error) {
    console.log(error);
  }, { mandatory: { OfferToReceiveAudio: true, OfferToReceiveVideo: !!videoConfig }});
}

Session.prototype.call = function (success, error) {
  var self = this;

  function call() {
    // create the peer connection
    self.peerConnection = new PeerConnection({
//    	iceTransports : 'relay',
    	iceServers: [
        { 
          url: 'stun:stun.l.google.com:19302' 
        },
        { 
          url: self.config.turn.host, 
          username: self.config.turn.username, 
        credential: self.config.turn.password 
        }
      ]
    }, { optional: [ { DtlsSrtpKeyAgreement: true } ]});

    self.peerConnection.onicecandidate = self.onIceCandidate;
    self.peerConnection.onaddstream = self.onRemoteStreamAdded;

    // attach the stream to the peer connection
    self.createOrUpdateStream.call(self);

    // if initiator - create offer
    if (self.config.isInitiator) {
      self.sendOffer.call(self);
    }
  }

  var missingStreams = { 
    video: self.config.streams.video && !localVideoTrack, 
    audio: self.config.streams.audio && !localAudioTrack 
  };

  if (missingStreams.audio || missingStreams.video) {
    navigator.getUserMedia(missingStreams, function (stream) {
      localStreams.push(stream);

      if (missingStreams.audio) {
        console.log('missing audio stream; retrieving');
        localAudioTrack = stream.getAudioTracks()[0];
      }

      if (missingStreams.video) {
        console.log('missing video stream; retrieving');
        localVideoTrack = stream.getVideoTracks()[0];
      }

      call();
      if (success)
    	  success();
    }, function (e) {
    	if (error)
    		error(e);
    	else
    		throw new Error(e);
    });
  } else {
    call();
    if (success)
  	  success();
  } 
};

Session.prototype.receiveMessage = function (message) {
  var self = this;
  if (message.type === 'offer') {
    self.setRemote(message);
    self.sendAnswer.call(self);
  } else if (message.type === 'answer') {
    self.setRemote(message);
  } else if (message.type === 'candidate') {
    var candidate = new RTCIceCandidate({
      sdpMLineIndex: message.label,
      candidate: message.candidate
    });
    
    self.peerConnection.addIceCandidate(candidate, function () {
      console.log('Remote candidate added successfully.');
    }, function (error) {
      console.log(error);
    });
     
  } else if (message.type === 'bye') {
    this.disconnect(false);
  }
};

Session.prototype.renegotiate = function () {
  if (this.config.isInitiator) {
    this.sendOffer();
  } else {
    this.sendAnswer();
  }
};

Session.prototype.disconnect = function (sendByeMessage) {
  if (this.videoView) {
    removeRemoteStream(this.videoView);
  }

  if (sendByeMessage) {
    this.sendMessage({ type: 'bye' });
  }

  if (this.peerConnection){
	  this.peerConnection.close();
	  this.peerConnection = null;
  }
  
  this.sendMessage({ type: '__disconnected' });

  onSessionDisconnect(this.sessionKey);
};


var sessions = {};
var videoConfig;
var localVideoView;
var remoteVideoViews = [];

module.exports = {
  createSessionObject: function (success, error, options) {
    var sessionKey = options[0];
    var session = new Session(sessionKey, options[1], success);

    session.sendMessage({
      type: '__set_session_key',
      sessionKey: sessionKey
    });

    sessions[sessionKey] = session;
  },
  call: function (success, error, options) {
    sessions[options[0].sessionKey].call(success, error);
  },
  receiveMessage: function (success, error, options) {
    sessions[options[0].sessionKey]
      .receiveMessage(JSON.parse(options[0].message));
  },
  renegotiate: function (success, error, options) {
    console.log('Renegotiation is currently only supported in iOS and Android.')
    // var session = sessions[options[0].sessionKey];
    // session.config = options[0].config;
    // session.createOrUpdateStream();
    // session.renegotiate();
  },
  disconnect: function (success, error, options) {
    var session = sessions[options[0].sessionKey];
    if (session) {
      session.disconnect(true);
    }
  },
  setVideoView: function (success, error, options) {
    videoConfig = options[0];

    if (videoConfig.containerParams.size[0] === 0 
        || videoConfig.containerParams.size[1] === 0) {
      throw 'local video container has no size';
    }

    if (videoConfig.local) {
      if (!localVideoView) {
        localVideoView = document.createElement('video');
        localVideoView.autoplay = true;
        localVideoView.muted = true;
        localVideoView.style.position = 'absolute';
        localVideoView.style.zIndex = 999;
        localVideoView.addEventListener("loadeddata", refreshVideoView);

        refreshLocalVideoView();

        if (!localVideoTrack) {
          navigator.getUserMedia({ audio: true, video: true }, function (stream) {
            localStreams.push(stream);

            localAudioTrack = stream.getAudioTracks()[0];
            localVideoTrack = stream.getVideoTracks()[0];

            localVideoView.src = URL.createObjectURL(stream);
            localVideoView.load();
            if (success)
          	  success();
          }, function (e) {
        	  throw e;
          }); 
        } else {
          var stream = new MediaStream();
          stream.addTrack(localVideoTrack);

          localVideoView.src = URL.createObjectURL(stream);
          localVideoView.load();         
        }

        document.body.appendChild(localVideoView);
      } else {
        refreshLocalVideoView();
        refreshVideoView();
      }
    }
    else if (localVideoView) {
    	dropLocalStreams();    
    }
  },
  
  refreshVideoView: function(success, error, layoutParams){
	  //recalculate the dimensions of the video container, then refresh the remote videos
	  videoConfig.containerParams = layoutParams;
	  refreshVideoView();
  },
  
  hideVideoView: function (success, error, options) {
    localVideoView.style.display = 'none';
    remoteVideoViews.forEach(function (remoteVideoView) {
      remoteVideoView.style.display = 'none';
    });
  },
  showVideoView: function (success, error, options) {
    localVideoView.style.display = '';
    remoteVideoViews.forEach(function (remoteVideoView) {
      remoteVideoView.style.display = '';
    });
  }
};

function addRemoteStream(stream) {
  var videoView = document.createElement('video');
  videoView.autoplay = true;
  videoView.addEventListener("loadeddata", refreshVideoView);
  videoView.style.position = 'absolute';
  videoView.style.zIndex = 998;

  videoView.src = URL.createObjectURL(stream);
  videoView.load();

  remoteVideoViews.push(videoView);
  document.body.appendChild(videoView);

  refreshVideoView();
  return videoView;
}

function removeRemoteStream(videoView) {
  console.log(remoteVideoViews);
  document.body.removeChild(videoView);
  remoteVideoViews.splice(videoView, 1);
  console.log(remoteVideoViews);

  refreshVideoView();
}

function getCenter(videoCount, videoSize, containerSize) {
  return Math.round((containerSize - videoSize * videoCount) / 2); 
}

function refreshLocalVideoView() {
  localVideoView.style.width = videoConfig.local.size[0] + 'px';
  localVideoView.style.height = videoConfig.local.size[1] + 'px';

  localVideoView.style.left = 
    (videoConfig.containerParams.position[0] + videoConfig.local.position[0]) + 'px';

  localVideoView.style.top = 
    (videoConfig.containerParams.position[1] + videoConfig.local.position[1]) + 'px';       
}

function refreshVideoView(event) {
	/*
	 * resize the container to contain the remote video(s) without letter-boxing.
	 * we won't ever make the container bigger - only reduce it's width or height.
	 * 
	 * note, this is called when a video has loaded and when the window is just resized
	 * 
	 * in the first case, we'll know the target and we adjust the target to contain the video without letter-boxing.
	 * we'll then re-enter this routine to do the second case below.
	 * 
	 * in the second case, we need to divide the container so the contained videos are largest while keeping the
	 * correct aspect ratio
	 * 
	 */
	
	target = event && event.target ? event.target : null;
	if (target){
		//first case - just set the video dimensions to completely enclose the video without letter-boxing
		var newHeight = (parseInt(target.style.width) * target.videoHeight) / target.videoWidth;
		target.style.height = newHeight;
		//now fall through to the second case
	}

	//second case scale all remote videos to the container
	
	// Bounds class definition
	var Bounds = function(rect){
		this.top = rect.top || 0;
		this.left = rect.left || 0;
		this.width = rect.width || 0;
		this.height = rect.height || 0;
		
		this.aspectRatio = function() { return this.width / this.height };
		
		this.copy = function() { return new Bounds({top:1*this.top, left:1*this.left, width:1*this.width, height:1*this.height}); };
		
		this.splitHorz = function() { 
			var halfWidth = this.width / 2;
			b1 = this.copy();
			b2 = this.copy();
			b1.width = b2.width = halfWidth;
			b2.left += halfWidth;
			return [b1, b2];
		}
		this.splitVert = function() { 
			var halfHeight = this.height / 2;
			b1 = this.copy();
			b2 = this.copy();
			b1.height = b2.height = halfHeight;
			b2.top += halfHeight;
			return [b1, b2];
		}
		
		this.aspectDiff = function(other){
			return Math.abs(this.aspectRatio() - other.aspectRatio());
		};

		this.setBoundingClientRect = function(el){
			el.style.top = this.top;
			el.style.left = this.left;
			el.style.width = this.width;
			el.style.height = this.height;
		};
	};
	var getBoundsFromEl = function (el) { return new Bounds(el.getBoundingClientRect()); }
	
	var containerBounds = getBoundsFromEl(videoConfig.container);
	var containers;

	var nVideos = remoteVideoViews.length;

	if (nVideos == 0){
		return;
	}
	
	else if (nVideos == 1){
		//no container split required for single remote video
		containers = [containerBounds];
	}
	
	else{
		/* split the container so the aspect ratios of the resulting parts is closest to the video aspect ration
		 * assume all videos are the same ratio
		 */
		var videoBounds = getBoundsFromEl(remoteVideoViews[0]);
		
		//keep the split having the containers that best match the video aspect ratio
		var splitVert = containerBounds.splitVert();
		var splitHorz = containerBounds.splitHorz();
		if (splitVert[0].aspectDiff(videoBounds) < splitHorz[0].aspectDiff(videoBounds)){
			containers = splitVert;
		}
		else{
			containers = splitHorz;
		}
	}	

	// change the video bounds to fit each container
	for (var n = 0; n < nVideos; n++){
		var containerBounds = containers[n];
		videoBounds = getBoundsFromEl(remoteVideoViews[n]);
		
		//video fills the container without changing its aspect ratio 
		var newVideoBounds = containerBounds.copy();
		if (containerBounds.height > (newVideoBounds.height = containerBounds.width/videoBounds.aspectRatio()))
			newVideoBounds.width = containerBounds.width;
		else{
			newVideoBounds.height = containerBounds.height;
			newVideoBounds.width = newVideoBounds.height * videoBounds.aspectRatio();
		}
		
		//center the video in its container
		newVideoBounds.left += (containerBounds.width - newVideoBounds.width) / 2;
		newVideoBounds.top += (containerBounds.height - newVideoBounds.height) / 2;
		newVideoBounds.setBoundingClientRect(remoteVideoViews[n])

	}
}

function dropLocalStreams(){
    if (localVideoView) {
        document.body.removeChild(localVideoView);
        localVideoView = null;
      }

      localStreams.forEach(function (stream) {
        stream.stop();
      });

      localStreams = [];
      localVideoTrack = null;
      localAudioTrack = null;
	};

function onSessionDisconnect(sessionKey) {
  delete sessions[sessionKey];

  if (Object.keys(sessions).length === 0) {
	  dropLocalStreams();
  }
}

require("cordova/exec/proxy").add("PhoneRTCPlugin", module.exports);