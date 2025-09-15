import 'dart:developer';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primaryColor: const Color(0xFF2196F3), // Soft blue
        scaffoldBackgroundColor: const Color(0xFFF8FAFC), // Light gray
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF2196F3),
          secondary: Color(0xFFFF6F61), // Coral accent
          surface: Colors.white,
          onPrimary: Colors.white,
          onSurface: Colors.black87,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            elevation: 2,
            shadowColor: Colors.black12,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
          hintStyle: TextStyle(color: Colors.grey[400]),
          prefixIconColor: Colors.grey[600],
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 16, color: Colors.black87),
          bodyMedium: TextStyle(fontSize: 14, color: Colors.black54),
          headlineSmall: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
          titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
        cardTheme: CardThemeData(
          elevation: 3,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          shadowColor: Colors.black12,
        ),
      ),
      home: const VideoCallPage(),
    );
  }
}

class VideoCallPage extends StatefulWidget {
  const VideoCallPage({super.key});

  @override
  State<VideoCallPage> createState() => _VideoCallPageState();
}

class _VideoCallPageState extends State<VideoCallPage> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _targetController = TextEditingController();

  IO.Socket? socket;
  String? myUsername;
  bool connected = false;

  webrtc.RTCPeerConnection? _peerConnection;
  webrtc.MediaStream? _localStream;
  final webrtc.RTCVideoRenderer _localRenderer = webrtc.RTCVideoRenderer();
  final webrtc.RTCVideoRenderer _remoteRenderer = webrtc.RTCVideoRenderer();

  bool incomingCall = false;
  String incomingFrom = "";
  String? _incomingOfferSdp;
  bool inCall = false;
  bool _offerSent = false;

  List<webrtc.RTCIceCandidate> _remoteCandidatesQueue = [];

  @override
  void initState() {
    super.initState();
    initRenderers();
  }

  Future<void> initRenderers() async {
    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();
      log("✅ Renderers initialized");
      if (kIsWeb) {
        log("🌐 Running on web platform");
      }
      setState(() {});
    } catch (e) {
      log("❌ Error initializing renderers: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error initializing video renderers: $e")),
      );
    }
  }

  Future<bool> requestPermissions() async {
    if (kIsWeb) {
      return true;
    }

    final statuses = await [Permission.camera, Permission.microphone].request();
    final granted =
        statuses[Permission.camera]!.isGranted &&
        statuses[Permission.microphone]!.isGranted;
    if (!granted) {
      log("❌ Camera or microphone permissions denied");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Camera and microphone permissions are required"),
        ),
      );
    } else {
      log("✅ Camera and microphone permissions granted");
    }
    return granted;
  }

  Future<void> openUserMedia() async {
    try {
      final mediaConstraints = {
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': {
          'mandatory': {
            'minWidth': '320',
            'minHeight': '240',
            'minFrameRate': '15',
          },
          'facingMode': 'user',
          'optional': [],
        },
      };

      _localStream = await webrtc.navigator.mediaDevices.getUserMedia(
        mediaConstraints,
      );

      if (_localStream != null) {
        _localRenderer.srcObject = _localStream;

        _localStream!.getTracks().forEach((track) {
          track.enabled = true;
          log("📹 Track enabled: ${track.kind} - ${track.id}");
        });

        log(
          "✅ Local stream opened with tracks: ${_localStream?.getTracks().map((t) => '${t.kind} (enabled: ${t.enabled}, id: ${t.id})').join(', ')}",
        );
        setState(() {});
      }
    } catch (e) {
      log("❌ Failed to open user media: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to access camera/microphone: $e")),
      );
    }
  }

  Future<void> createPeerConnection() async {
    if (_peerConnection != null) {
      await _peerConnection!.close();
      _peerConnection = null;
    }

    final configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        {
          'urls': 'turn:openrelay.metered.ca:80',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
      ],
      'sdpSemantics': 'unified-plan',
      'offerExtmapAllowMixed': false,
    };

    try {
      _peerConnection = await webrtc.createPeerConnection(configuration);
      log("✅ Peer connection created");

      if (_localStream != null) {
        _localStream!.getTracks().forEach((track) {
          track.enabled = true;
          _peerConnection!.addTrack(track, _localStream!);
          log(
            "➡️ Added track to peer connection: ${track.kind} (enabled: ${track.enabled})",
          );
        });
      }

      _peerConnection!.onTrack = (event) {
        log("📡 onTrack event received");
        log("📡 Event streams count: ${event.streams.length}");

        if (event.streams.isNotEmpty) {
          final remoteStream = event.streams[0];
          log(
            "📡 Remote stream received with ${remoteStream.getTracks().length} tracks",
          );

          remoteStream.getTracks().forEach((track) {
            track.enabled = true;
            log(
              "📡 Remote track: ${track.kind} (enabled: ${track.enabled}, id: ${track.id})",
            );
          });

          setState(() {
            _remoteRenderer.srcObject = remoteStream;
            log("✅ Remote stream set to renderer");
          });

          if (kIsWeb) {
            Future.delayed(Duration(milliseconds: 500), () {
              setState(() {});
            });
          }
        } else {
          log("⚠️ onTrack called but no streams provided");
        }
      };

      _peerConnection!.onConnectionState = (state) {
        log("🔗 Connection State: $state");
      };

      _peerConnection!.onIceConnectionState = (state) {
        log("🌐 ICE Connection State: $state");
        if (state == webrtc.RTCIceConnectionState.RTCIceConnectionStateFailed ||
            state ==
                webrtc
                    .RTCIceConnectionState
                    .RTCIceConnectionStateDisconnected) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Connection failed. Try again.")),
          );
          hangUp();
        }
        if (state ==
            webrtc.RTCIceConnectionState.RTCIceConnectionStateConnected) {
          setState(() => inCall = true);
          log("🎉 Call connected successfully!");
        }
      };

      _peerConnection!.onSignalingState = (state) {
        log("📶 Signaling State: $state");
      };

      _peerConnection!.onIceCandidate = (candidate) {
        if (candidate != null &&
            socket != null &&
            _targetController.text.isNotEmpty) {
          socket!.emit("candidate", {
            "target": _targetController.text,
            "candidate": {
              "candidate": candidate.candidate,
              "sdpMid": candidate.sdpMid,
              "sdpMLineIndex": candidate.sdpMLineIndex,
            },
            "from": myUsername,
          });
          log("➡️ ICE candidate sent to ${_targetController.text}");
        }
      };
    } catch (e) {
      log("❌ Failed to create peer connection: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to create peer connection: $e")),
      );
    }
  }

  bool isValidUsername(String username) {
    return username.isNotEmpty &&
        username.length >= 3 &&
        RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(username);
  }

  void connectToServer(String username) async {
    if (!isValidUsername(username)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Username must be at least 3 characters and contain only letters, numbers, or underscores",
          ),
        ),
      );
      return;
    }

    if (!await requestPermissions()) return;

    myUsername = username;
    socket = IO.io("http://localhost:9000", {
      "transports": ["websocket"],
      "autoConnect": false,
    });

    socket!.connect();

    socket!.onConnect((_) async {
      setState(() => connected = true);
      log("✅ Connected to signaling server: ${socket!.id}");

      socket!.emit("register", username);
      log("📡 Registered as $username");

      await openUserMedia();
      if (_localStream != null) {
        await createPeerConnection();
      } else {
        log("❌ Cannot create peer connection: local stream is null");
      }
    });

    socket!.on("offer", (data) async {
      final fromUser = data['from'];
      final sdp = data['sdp'];
      log("📩 Received offer from $fromUser");

      if (inCall || _offerSent) {
        log("⚠️ Ignoring offer: already in call or offer sent");
        socket!.emit("reject", {"target": fromUser, "from": myUsername});
        return;
      }

      try {
        if (_peerConnection == null) {
          log("🔄 Creating new peer connection for incoming offer");
          await openUserMedia();
          if (_localStream != null) {
            await createPeerConnection();
          } else {
            log("❌ Cannot process offer: local stream is null");
            socket!.emit("reject", {"target": fromUser, "from": myUsername});
            return;
          }
        }

        await _peerConnection!.setRemoteDescription(
          webrtc.RTCSessionDescription(sdp, 'offer'),
        );
        log("✅ Remote description set for offer");

        setState(() {
          incomingCall = true;
          incomingFrom = fromUser;
          _incomingOfferSdp = sdp;
          _targetController.text = fromUser;
        });

        await _processQueuedCandidates();
      } catch (e) {
        log("❌ Error processing offer: $e");
        socket!.emit("reject", {"target": fromUser, "from": myUsername});
      }
    });

    socket!.on("answer", (data) async {
      final sdp = data['sdp'];
      log("📩 Received answer from ${data['from']}");

      try {
        if (_peerConnection != null) {
          await _peerConnection!.setRemoteDescription(
            webrtc.RTCSessionDescription(sdp, 'answer'),
          );
          log("✅ Remote description set for answer");

          await _processQueuedCandidates();
        }
      } catch (e) {
        log("❌ Error setting remote description for answer: $e");
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Error processing answer: $e")));
      }
    });

    socket!.on("candidate", (data) async {
      final candidateData = data['candidate'];
      if (candidateData != null) {
        final candidate = webrtc.RTCIceCandidate(
          candidateData['candidate'],
          candidateData['sdpMid'],
          candidateData['sdpMLineIndex'],
        );
        log("📩 Received ICE candidate from ${data['from']}");

        if (_peerConnection != null &&
            _peerConnection!.getRemoteDescription() != null) {
          try {
            await _peerConnection!.addCandidate(candidate);
            log("✅ ICE candidate added immediately");
          } catch (e) {
            log("❌ Error adding ICE candidate: $e");
          }
        } else {
          _remoteCandidatesQueue.add(candidate);
          log(
            "🟡 ICE candidate queued (${_remoteCandidatesQueue.length} total)",
          );
        }
      }
    });

    socket!.on("reject", (data) {
      final fromUser = data['from'];
      log("❌ Call rejected by $fromUser");
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Call rejected by $fromUser")));
      _resetCallState();
    });

    socket!.on("hangup", (data) {
      final fromUser = data['from'];
      log("📴 Call hung up by $fromUser");
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text("Call Ended"),
          content: Text(
            "The call with $fromUser has ended, $myUsername. Hope you enjoyed the experience!",
            style: const TextStyle(fontSize: 16),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _resetCallState();
              },
              child: const Text("OK"),
            ),
          ],
        ),
      );
      hangUp();
    });

    socket!.on("error", (data) {
      log("❌ Server error: ${data['message']}");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Server error: ${data['message']}")),
      );
    });

    socket!.onDisconnect((_) {
      setState(() => connected = false);
      log("🔴 Disconnected from server");
      hangUp();
    });
  }

  Future<void> _processQueuedCandidates() async {
    if (_remoteCandidatesQueue.isNotEmpty && _peerConnection != null) {
      log("🔄 Processing ${_remoteCandidatesQueue.length} queued candidates");
      for (var candidate in _remoteCandidatesQueue) {
        try {
          await _peerConnection!.addCandidate(candidate);
          log("✅ Added queued ICE candidate");
        } catch (e) {
          log("❌ Error adding queued ICE candidate: $e");
        }
      }
      _remoteCandidatesQueue.clear();
      log("✅ All queued candidates processed");
    }
  }

  void _resetCallState() {
    setState(() {
      _targetController.clear();
      _incomingOfferSdp = null;
      incomingCall = false;
      inCall = false;
      _offerSent = false;
      incomingFrom = "";
    });
  }

  Future<void> sendOffer() async {
    if (_targetController.text.isEmpty || inCall || _offerSent) {
      log("⚠️ Cannot call: no target, already in call, or offer already sent");
      return;
    }

    if (!isValidUsername(_targetController.text)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Invalid target username")));
      return;
    }

    try {
      if (_peerConnection == null) {
        log("❌ Peer connection not ready");
        return;
      }

      final offer = await _peerConnection!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });

      await _peerConnection!.setLocalDescription(offer);

      socket!.emit("offer", {
        "target": _targetController.text,
        "sdp": offer.sdp,
        "from": myUsername,
      });

      log("➡️ Sent offer to ${_targetController.text}");
      setState(() => _offerSent = true);
    } catch (e) {
      log("❌ Error sending offer: $e");
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Failed to send offer: $e")));
    }
  }

  Future<void> answerCall() async {
    if (_peerConnection == null) {
      log("❌ Cannot answer: peer connection is null");
      return;
    }

    final fromUser = incomingFrom;
    log("📞 Answering call from $fromUser");

    try {
      final answer = await _peerConnection!.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });

      await _peerConnection!.setLocalDescription(answer);

      socket!.emit("answer", {
        "target": fromUser,
        "sdp": answer.sdp,
        "from": myUsername,
      });

      log("✅ Sent answer to $fromUser");

      setState(() {
        incomingCall = false;
        inCall = false;
        _targetController.text = fromUser;
      });

      await _processQueuedCandidates();

      _incomingOfferSdp = null;
    } catch (e) {
      log("❌ Error answering call: $e");
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Failed to answer call: $e")));
    }
  }

  void rejectCall() {
    if (incomingFrom.isEmpty) return;

    socket!.emit("reject", {"target": incomingFrom, "from": myUsername});
    log("❌ Call rejected from $incomingFrom");
    _resetCallState();
  }

  Future<void> hangUp() async {
    log("📴 Hanging up call");

    if (_peerConnection != null) {
      await _peerConnection!.close();
      _peerConnection = null;
    }

    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream = null;

    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;

    if (socket != null && _targetController.text.isNotEmpty) {
      socket!.emit("hangup", {
        "target": _targetController.text,
        "from": myUsername,
      });
    }

    _remoteCandidatesQueue.clear();
    _resetCallState();

    log("✅ Call ended and cleaned up");

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("Call Ended"),
        content: Text(
          "The call has ended, $myUsername. Hope you enjoyed the experience!",
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: const Text("OK"),
          ),
        ],
      ),
    );

    if (_localStream == null && connected) {
      await openUserMedia();
      if (_localStream != null) {
        await createPeerConnection();
      }
    }
  }

  @override
  void dispose() {
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _peerConnection?.close();
    socket?.dispose();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _usernameController.dispose();
    _targetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          myUsername != null ? "Welcome, $myUsername!" : "Video Connect",
        ),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Color(0xFF2196F3),
                Color(0xFF64B5F6),
              ], // Light blue gradient
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              children: [
                Text(
                  connected ? "Online" : "Offline",
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(width: 8),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: connected ? Colors.greenAccent : Colors.redAccent,
                    boxShadow: [
                      BoxShadow(
                        color: connected
                            ? Colors.greenAccent.withOpacity(0.4)
                            : Colors.redAccent.withOpacity(0.4),
                        spreadRadius: 2,
                        blurRadius: 8,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Join the Call${myUsername != null ? ", $myUsername" : ""}",
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _usernameController,
                        decoration: const InputDecoration(
                          labelText: "Your Username",
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: connected
                              ? null
                              : () {
                                  if (_usernameController.text.isNotEmpty) {
                                    connectToServer(_usernameController.text);
                                  } else {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          "Please enter a username",
                                        ),
                                      ),
                                    );
                                  }
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: connected
                                ? Colors.grey[300]
                                : Theme.of(context).colorScheme.primary,
                            foregroundColor: connected
                                ? Colors.black54
                                : Colors.white,
                          ),
                          child: Text(
                            connected
                                ? "Connected as $myUsername"
                                : "Connect & Register",
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Make a Call",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _targetController,
                        decoration: const InputDecoration(
                          labelText: "Target Username",
                          prefixIcon: Icon(Icons.call_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_targetController.text.isNotEmpty && inCall)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            "📞 Connected to: ${_targetController.text}",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.secondary,
                            ),
                          ),
                        ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ElevatedButton.icon(
                            onPressed: (connected && !inCall && !_offerSent)
                                ? sendOffer
                                : null,
                            icon: const Icon(Icons.videocam),
                            label: const Text("Call"),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.secondary,
                              foregroundColor: Colors.white,
                            ),
                          ),
                          ElevatedButton.icon(
                            onPressed: (inCall || _offerSent) ? hangUp : null,
                            icon: const Icon(Icons.call_end),
                            label: const Text("Hang Up"),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.redAccent,
                              foregroundColor: Colors.white,
                            ),
                          ),
                          ElevatedButton.icon(
                            onPressed: () {
                              log("🔍 === DEBUG INFO ===");
                              log("Platform: ${kIsWeb ? 'Web' : 'Native'}");
                              log("Connected: $connected");
                              log("In Call: $inCall");
                              log("Offer Sent: $_offerSent");
                              log("Local stream: ${_localStream?.id}");
                              log(
                                "Remote renderer stream: ${_remoteRenderer.srcObject?.id}",
                              );
                              log(
                                "Local tracks: ${_localStream?.getTracks().map((t) => '${t.kind}(${t.enabled})').join(', ')}",
                              );
                              log(
                                "Remote tracks: ${_remoteRenderer.srcObject?.getTracks().map((t) => '${t.kind}(${t.enabled})').join(', ')}",
                              );
                              log(
                                "PC Signaling: ${_peerConnection?.signalingState}",
                              );
                              log(
                                "PC ICE: ${_peerConnection?.iceConnectionState}",
                              );
                              log(
                                "PC Connection: ${_peerConnection?.connectionState}",
                              );
                              log(
                                "Queued candidates: ${_remoteCandidatesQueue.length}",
                              );
                            },
                            icon: const Icon(Icons.bug_report),
                            label: const Text("Debug"),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          children: [
                            AspectRatio(
                              aspectRatio: 4 / 3,
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    width: 2,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.1),
                                      blurRadius: 8,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: webrtc.RTCVideoView(
                                    _localRenderer,
                                    mirror: true,
                                    objectFit: webrtc
                                        .RTCVideoViewObjectFit
                                        .RTCVideoViewObjectFitCover,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              "${myUsername ?? 'Me'} (You)",
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          children: [
                            AspectRatio(
                              aspectRatio: 4 / 3,
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: inCall
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.secondary
                                        : Colors.grey[400]!,
                                    width: 2,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.1),
                                      blurRadius: 8,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: _remoteRenderer.srcObject != null
                                      ? webrtc.RTCVideoView(
                                          _remoteRenderer,
                                          objectFit: webrtc
                                              .RTCVideoViewObjectFit
                                              .RTCVideoViewObjectFitCover,
                                        )
                                      : Container(
                                          color: Colors.grey[200],
                                          child: const Center(
                                            child: Text(
                                              "Remote Video",
                                              style: TextStyle(
                                                color: Colors.grey,
                                              ),
                                            ),
                                          ),
                                        ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _targetController.text.isNotEmpty
                                  ? _targetController.text
                                  : "Remote",
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: connected && !inCall && !_offerSent
          ? FloatingActionButton(
              onPressed: sendOffer,
              backgroundColor: Theme.of(context).colorScheme.secondary,
              child: const Icon(Icons.videocam),
            )
          : null,
      bottomNavigationBar: incomingCall
          ? Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 8,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.video_call,
                    size: 48,
                    color: Color(0xFF2196F3),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Incoming Call from $incomingFrom",
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton.icon(
                        onPressed: answerCall,
                        icon: const Icon(Icons.call, color: Colors.white),
                        label: const Text("Answer"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: rejectCall,
                        icon: const Icon(Icons.call_end, color: Colors.white),
                        label: const Text("Reject"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            )
          : null,
    );
  }
}
