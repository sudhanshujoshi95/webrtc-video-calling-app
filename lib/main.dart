import 'dart:convert';
import 'dart:developer';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:web_socket_channel/web_socket_channel.dart';
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
        primaryColor: const Color(0xFF2196F3),
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF2196F3),
          secondary: Color(0xFF4CAF50),
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
        cardTheme: CardThemeData(
          elevation: 3,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          shadowColor: Colors.black12,
        ),
      ),
      home: const TelemedicineCallPage(),
    );
  }
}

class TelemedicineCallPage extends StatefulWidget {
  const TelemedicineCallPage({super.key});

  @override
  State<TelemedicineCallPage> createState() => _TelemedicineCallPageState();
}

class _TelemedicineCallPageState extends State<TelemedicineCallPage> {
  // Connection details
  final TextEditingController _hospitalIdController = TextEditingController(
    text: 'hospital123',
  );
  final TextEditingController _userIdController = TextEditingController(
    text: 'doctor_john',
  );
  final TextEditingController _roleController = TextEditingController(
    text: 'doctor',
  );
  final TextEditingController _usernameController = TextEditingController(
    text: 'doctor_john',
  );
  final TextEditingController _targetController = TextEditingController();

  // WebSocket and connection state
  WebSocketChannel? _channel;
  bool connected = false;
  bool registered = false;
  String? socketId;

  // Call state
  bool incomingCall = false;
  String incomingFrom = "";
  Map<String, dynamic>? incomingOffer;
  bool inCall = false;
  bool offerSent = false;

  // WebRTC components
  webrtc.RTCPeerConnection? _peerConnection;
  webrtc.MediaStream? _localStream;
  final webrtc.RTCVideoRenderer _localRenderer = webrtc.RTCVideoRenderer();
  final webrtc.RTCVideoRenderer _remoteRenderer = webrtc.RTCVideoRenderer();

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
      setState(() {});
    } catch (e) {
      log("❌ Error initializing renderers: $e");
      _showSnackBar("Error initializing video renderers: $e");
    }
  }

  Future<bool> requestPermissions() async {
    if (kIsWeb) {
      return true;
    }

    // For Android, we need to request camera and microphone permissions
    Map<Permission, PermissionStatus> statuses = await [
      Permission.camera,
      Permission.microphone,
      // Add storage permission if needed for recording
      // Permission.storage,
    ].request();

    bool cameraGranted = statuses[Permission.camera] == PermissionStatus.granted;
    bool micGranted = statuses[Permission.microphone] == PermissionStatus.granted;

    if (!cameraGranted || !micGranted) {
      log("❌ Camera or microphone permissions denied");
      _showSnackBar("Camera and microphone permissions are required");
      return false;
    }

    log("✅ Camera and microphone permissions granted");
    return true;
  }

  Future<void> openUserMedia() async {
    try {
      // Different constraints for Web vs Android
      final mediaConstraints = kIsWeb
          ? {
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
            }
          : {
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
          "✅ Local stream opened with tracks: ${_localStream?.getTracks().map((t) => '${t.kind} (enabled: ${t.enabled})').join(', ')}",
        );
        setState(() {});
      }
    } catch (e) {
      log("❌ Failed to open user media: $e");
      _showSnackBar("Failed to access camera/microphone: $e");
    }
  }

  Future<void> createPeerConnection() async {
    if (_peerConnection != null) {
      await _peerConnection!.close();
      _peerConnection = null;
    }

    // Android-specific configuration
    final configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        {
          'urls': 'turn:openrelay.metered.ca:80',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
        {
          'urls': 'turn:openrelay.metered.ca:443',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
          'turnTransport': 'tcp',
        },
        {
          'urls': 'turn:openrelay.metered.ca:443?transport=tcp',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
      ],
      'sdpSemantics': 'unified-plan',
      // Android-specific configuration
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
      'iceTransportPolicy': 'all',
    };

    try {
      _peerConnection = await webrtc.createPeerConnection(configuration);
      log("✅ Peer connection created");

      if (_localStream != null) {
        _localStream!.getTracks().forEach((track) {
          track.enabled = true;
          _peerConnection!.addTrack(track, _localStream!);
          log("➡️ Added track to peer connection: ${track.kind}");
        });
      }

      _peerConnection!.onTrack = (event) {
        log("📡 onTrack event received");
        if (event.streams.isNotEmpty) {
          final remoteStream = event.streams[0];
          log(
            "📡 Remote stream received with ${remoteStream.getTracks().length} tracks",
          );

          remoteStream.getTracks().forEach((track) {
            track.enabled = true;
            log("📡 Remote track: ${track.kind} (enabled: ${track.enabled})");
          });

          setState(() {
            _remoteRenderer.srcObject = remoteStream;
            log("✅ Remote stream set to renderer");
          });

          if (kIsWeb) {
            Future.delayed(const Duration(milliseconds: 500), () {
              setState(() {});
            });
          }
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
          _showSnackBar("Connection failed. Try again.");
          hangUp();
        }
        if (state ==
            webrtc.RTCIceConnectionState.RTCIceConnectionStateConnected) {
          setState(() => inCall = true);
          log("🎉 Call connected successfully!");
        }
      };

      _peerConnection!.onIceCandidate = (candidate) {
        if (candidate != null &&
            _channel != null &&
            _targetController.text.isNotEmpty) {
          _sendMessage({
            'type': 'telemedicine_candidate',
            'target': _targetController.text,
            'from': _usernameController.text,
            'candidate': {
              'candidate': candidate.candidate,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
            },
          });
          log("➡️ ICE candidate sent to ${_targetController.text}");
        }
      };

      // Handle signaling state changes
      _peerConnection!.onSignalingState = (state) {
        log("📶 Signaling State: $state");
      };

      // Handle ice gathering state changes
      _peerConnection!.onIceGatheringState = (state) {
        log("🧊 ICE Gathering State: $state");
      };
    } catch (e) {
      log("❌ Failed to create peer connection: $e");
      _showSnackBar("Failed to create peer connection: $e");
    }
  }

  void connectToServer() async {
    if (!await requestPermissions()) return;

    final hospitalId = _hospitalIdController.text;
    final userId = _userIdController.text;
    final role = _roleController.text;

    if (hospitalId.isEmpty || userId.isEmpty || role.isEmpty) {
      _showSnackBar("Please fill in all connection fields");
      return;
    }

    try {
      // Updated URLs based on your backend documentation
      final wsUrl =
          'wss://devbackend.medoc.app/hospital/ws?hospitalId=$hospitalId&userId=$userId&role=$role';

      log("🔗 Connecting to: $wsUrl");

      // Add connection timeout and better error handling
      _channel = WebSocketChannel.connect(
        Uri.parse(wsUrl),
      );

      // Wait for connection to establish before setting connected=true
      await _channel!.ready.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw Exception('Connection timeout - server may be unreachable');
        },
      );

      setState(() => connected = true);
      log("✅ Successfully connected to telemedicine server");

      _channel!.stream.listen(
        (message) {
          log("📨 Raw message received: $message");
          try {
            final data = jsonDecode(message);
            _handleMessage(data);
          } catch (e) {
            log("❌ Error parsing message: $e");
            log("Raw message was: $message");
          }
        },
        onError: (error) {
          log("❌ WebSocket error: $error");
          _showSnackBar("Connection error: $error");
          setState(() {
            connected = false;
            registered = false;
          });
        },
        onDone: () {
          log("🔴 WebSocket connection closed");
          setState(() {
            connected = false;
            registered = false;
          });
          _resetCallState();
        },
      );

      // Auto-register after connection is confirmed
      _registerForTelemedicine();

      await openUserMedia();
      if (_localStream != null) {
        await createPeerConnection();
      }
    } catch (e) {
      log("❌ Failed to connect: $e");
      _showSnackBar("Failed to connect: $e");
      setState(() {
        connected = false;
        registered = false;
      });
    }
  }

  void _registerForTelemedicine() {
    if (_channel == null) return;

    final username = _usernameController.text;
    if (username.isEmpty) {
      _showSnackBar("Please enter a username");
      return;
    }

    _sendMessage({'type': 'telemedicine_register', 'username': username});

    log("📡 Registering for telemedicine as: $username");
  }

  void _sendMessage(Map<String, dynamic> message) {
    if (_channel != null) {
      _channel!.sink.add(jsonEncode(message));
    }
  }

  void _handleMessage(Map<String, dynamic> message) {
    log("📩 Received message: ${message['type']}");

    switch (message['type']) {
      case 'telemedicine_registered':
        setState(() {
          registered = true;
          socketId = message['socketId'];
        });
        log("✅ Registered for telemedicine: ${message['username']}");
        _showSnackBar("Successfully registered as ${message['username']}");
        break;

      case 'telemedicine_offer':
        _handleIncomingOffer(message);
        break;

      case 'telemedicine_answer':
        _handleIncomingAnswer(message);
        break;

      case 'telemedicine_candidate':
        _handleIncomingCandidate(message);
        break;

      case 'telemedicine_reject':
        log("❌ Call rejected by ${message['from']}");
        _showSnackBar("Call rejected by ${message['from']}");
        _resetCallState();
        break;

      case 'telemedicine_error':
        log("❌ Server error: ${message['message']}");
        _showSnackBar("Error: ${message['message']}");
        break;

      default:
        log("⚠️ Unknown message type: ${message['type']}");
    }
  }

  Future<void> _handleIncomingOffer(Map<String, dynamic> data) async {
    final fromUser = data['from'];
    final sdp = data['sdp'];

    log("📩 Received offer from $fromUser");

    if (inCall || offerSent) {
      log("⚠️ Ignoring offer: already in call or offer sent");
      _sendMessage({
        'type': 'telemedicine_reject',
        'target': fromUser,
        'from': _usernameController.text,
      });
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
          _sendMessage({
            'type': 'telemedicine_reject',
            'target': fromUser,
            'from': _usernameController.text,
          });
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
        incomingOffer = data;
        _targetController.text = fromUser;
      });

      await _processQueuedCandidates();
    } catch (e) {
      log("❌ Error processing offer: $e");
      _sendMessage({
        'type': 'telemedicine_reject',
        'target': fromUser,
        'from': _usernameController.text,
      });
    }
  }

  Future<void> _handleIncomingAnswer(Map<String, dynamic> data) async {
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
      _showSnackBar("Error processing answer: $e");
    }
  }

  Future<void> _handleIncomingCandidate(Map<String, dynamic> data) async {
    final candidateData = data['candidate'];
    if (candidateData != null) {
      final candidate = webrtc.RTCIceCandidate(
        candidateData['candidate'],
        candidateData['sdpMid'],
        candidateData['sdpMLineIndex'],
      );
      log("📩 Received ICE candidate from ${data['from']}");

      if (_peerConnection != null &&
         (await _peerConnection!.getRemoteDescription() != null)) {
        try {
          await _peerConnection!.addCandidate(candidate);
          log("✅ ICE candidate added immediately");
        } catch (e) {
          log("❌ Error adding ICE candidate: $e");
        }
      } else {
        _remoteCandidatesQueue.add(candidate);
        log("🟡 ICE candidate queued (${_remoteCandidatesQueue.length} total)");
      }
    }
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
      incomingOffer = null;
      incomingCall = false;
      inCall = false;
      offerSent = false;
      incomingFrom = "";
    });
  }

  Future<void> sendOffer() async {
    if (_targetController.text.isEmpty || inCall || offerSent) {
      log("⚠️ Cannot call: no target, already in call, or offer already sent");
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

      _sendMessage({
        'type': 'telemedicine_offer',
        'target': _targetController.text,
        'from': _usernameController.text,
        'sdp': offer.sdp,
      });

      log("➡️ Sent offer to ${_targetController.text}");
      setState(() => offerSent = true);
    } catch (e) {
      log("❌ Error sending offer: $e");
      _showSnackBar("Failed to send offer: $e");
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

      _sendMessage({
        'type': 'telemedicine_answer',
        'target': fromUser,
        'from': _usernameController.text,
        'sdp': answer.sdp,
      });

      log("✅ Sent answer to $fromUser");

      setState(() {
        incomingCall = false;
        inCall = true; // Changed from false to true
        _targetController.text = fromUser;
      });

      await _processQueuedCandidates();
      incomingOffer = null;
    } catch (e) {
      log("❌ Error answering call: $e");
      _showSnackBar("Failed to answer call: $e");
    }
  }

  void rejectCall() {
    if (incomingFrom.isEmpty) return;

    _sendMessage({
      'type': 'telemedicine_reject',
      'target': incomingFrom,
      'from': _usernameController.text,
    });

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

    if (_channel != null && _targetController.text.isNotEmpty) {
      _sendMessage({
        'type': 'telemedicine_reject',
        'target': _targetController.text,
        'from': _usernameController.text,
      });
    }

    _remoteCandidatesQueue.clear();
    _resetCallState();

    log("✅ Call ended and cleaned up");

    // Show dialog
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text("Call Ended"),
          content: const Text(
            "The call has ended. Hope you enjoyed the experience!",
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
    }

    // Reinitialize for next call
    if (connected && mounted) {
      await openUserMedia();
      if (_localStream != null) {
        await createPeerConnection();
      }
    }
  }

  void _showSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void disconnect() {
    _channel?.sink.close();
    hangUp();
    setState(() {
      connected = false;
      registered = false;
      socketId = null;
    });
  }

  @override
  void dispose() {
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _peerConnection?.close();
    _channel?.sink.close();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _hospitalIdController.dispose();
    _userIdController.dispose();
    _roleController.dispose();
    _usernameController.dispose();
    _targetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          registered
              ? "Telemedicine - ${_usernameController.text}"
              : "Telemedicine Call",
        ),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF2196F3), Color(0xFF64B5F6)],
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
                  connected ? "Connected" : "Disconnected",
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
              // Connection Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Connection Setup",
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _hospitalIdController,
                        decoration: const InputDecoration(
                          labelText: "Hospital ID",
                          prefixIcon: Icon(Icons.local_hospital),
                        ),
                        enabled: !connected,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _userIdController,
                        decoration: const InputDecoration(
                          labelText: "User ID",
                          prefixIcon: Icon(Icons.badge),
                        ),
                        enabled: !connected,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _roleController,
                        decoration: const InputDecoration(
                          labelText: "Role (doctor/patient)",
                          prefixIcon: Icon(Icons.person),
                        ),
                        enabled: !connected,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _usernameController,
                        decoration: const InputDecoration(
                          labelText: "Username for telemedicine",
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        enabled: !connected,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: connected ? null : connectToServer,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: connected
                                    ? Colors.grey[300]
                                    : Theme.of(context).colorScheme.primary,
                                foregroundColor: connected
                                    ? Colors.black54
                                    : Colors.white,
                              ),
                              child: Text(connected ? "Connected" : "Connect"),
                            ),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton(
                            onPressed: connected ? disconnect : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.redAccent,
                              foregroundColor: Colors.white,
                            ),
                            child: const Text("Disconnect"),
                          ),
                        ],
                      ),
                      if (registered) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.green[50],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.green[200]!),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.check_circle,
                                color: Colors.green[600],
                              ),
                              const SizedBox(width: 8),
                              Text(
                                "Registered for telemedicine",
                                style: TextStyle(
                                  color: Colors.green[700],
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Call Controls Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Make a Call",
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _targetController,
                        decoration: const InputDecoration(
                          labelText: "Target Username",
                          prefixIcon: Icon(Icons.call_outlined),
                        ),
                        enabled: registered && !inCall && !offerSent,
                      ),
                      const SizedBox(height: 16),
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
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: (registered && !inCall && !offerSent)
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
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: (inCall || offerSent) ? hangUp : null,
                              icon: const Icon(Icons.call_end),
                              label: const Text("Hang Up"),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.redAccent,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Video Streams
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Local Video
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
                              "${_usernameController.text.isNotEmpty ? _usernameController.text : 'Me'} (You)",
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Remote Video
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

              const SizedBox(height: 16),

              // Debug Info Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Debug Information",
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        onPressed: () {
                          log("🔍 === DEBUG INFO ===");
                          log("Platform: ${kIsWeb ? 'Web' : 'Native'}");
                          log("Connected: $connected");
                          log("Registered: $registered");
                          log("Socket ID: $socketId");
                          log("In Call: $inCall");
                          log("Offer Sent: $offerSent");
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
                          log("PC ICE: ${_peerConnection?.iceConnectionState}");
                          log(
                            "PC Connection: ${_peerConnection?.connectionState}",
                          );
                          log(
                            "Queued candidates: ${_remoteCandidatesQueue.length}",
                          );
                          log("==================");

                          _showSnackBar("Debug info logged to console");
                        },
                        icon: const Icon(Icons.bug_report),
                        label: const Text("Log Debug Info"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          foregroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "Status: ${connected ? 'Connected' : 'Disconnected'}${registered ? ' & Registered' : ''}",
                        style: TextStyle(
                          color: connected
                              ? (registered ? Colors.green : Colors.orange)
                              : Colors.red,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (socketId != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          "Socket ID: $socketId",
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: (registered && !inCall && !offerSent)
          ? FloatingActionButton(
              onPressed: sendOffer,
              backgroundColor: Theme.of(context).colorScheme.secondary,
              child: const Icon(Icons.videocam, color: Colors.white),
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
                          padding: const EdgeInsets.symmetric(
                            horizontal: 32,
                            vertical: 16,
                          ),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: rejectCall,
                        icon: const Icon(Icons.call_end, color: Colors.white),
                        label: const Text("Reject"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 32,
                            vertical: 16,
                          ),
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