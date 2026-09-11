import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:audioplayers/audioplayers.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera error: $e');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: DrowsinessDetector(),
    );
  }
}

class DrowsinessDetector extends StatefulWidget {
  const DrowsinessDetector({super.key});

  @override
  State<DrowsinessDetector> createState() => _DrowsinessDetectorState();
}

class _DrowsinessDetectorState extends State<DrowsinessDetector> {
  CameraController? _cameraController;
  late FaceDetector _faceDetector;
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isProcessing = false;
  int _closedEyeFrames = 0;
  bool _isAlarmPlaying = false;
  String _statusMessage = 'System Ready';

  @override
  void initState() {
    super.initState();
    _initDetector();
    _initCamera();
  }

  void _initDetector() {
    final options = FaceDetectorOptions(
      enableClassification: true,
      performanceMode: FaceDetectorMode.fast,
    );
    _faceDetector = FaceDetector(options: options);
  }

  Future<void> _initCamera() async {
    if (cameras.isEmpty) return;

    final frontCamera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      frontCamera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _cameraController!.initialize();
    if (!mounted) return;

    _cameraController!.startImageStream((image) => _processCameraImage(image));
    setState(() {});
  }

  void _processCameraImage(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final inputImage = _createInputImage(image);
      if (inputImage == null) {
        _isProcessing = false;
        return;
      }

      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isEmpty) {
        setState(() => _statusMessage = 'No Face Detected');
        _isProcessing = false;
        return;
      }

      final face = faces.first;
      final leftOpen = face.leftEyeOpenProbability ?? 1.0;
      final rightOpen = face.rightEyeOpenProbability ?? 1.0;

      // Threshold: Dono aankhen 30% se zyada band hain
      if (leftOpen < 0.3 && rightOpen < 0.3) {
        _closedEyeFrames++;
        if (_closedEyeFrames >= 6) {
          // Approx 1.5 - 2 seconds continuous closed eyes
          _triggerAlarm(true);
          setState(() => _statusMessage = 'DROWSINESS ALERT!');
        }
      } else {
        _closedEyeFrames = 0;
        _triggerAlarm(false);
        setState(() => _statusMessage = 'Driver Awake');
      }
    } catch (e) {
      debugPrint('ML error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  void _triggerAlarm(bool play) async {
    if (play && !_isAlarmPlaying) {
      _isAlarmPlaying = true;
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      // Online sample alert beep
      await _audioPlayer.play(
        UrlSource('https://actions.google.com/sounds/v1/alarms/alarm_clock.ogg'),
      );
    } else if (!play && _isAlarmPlaying) {
      _isAlarmPlaying = false;
      await _audioPlayer.stop();
    }
  }

  InputImage? _createInputImage(CameraImage image) {
    if (_cameraController == null) return null;

    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final planeMetadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: InputImageRotation.rotation270deg,
      format: InputImageFormat.nv21,
      bytesPerRow: image.planes[0].bytesPerRow,
    );

    return InputImage.fromBytes(bytes: bytes, metadata: planeMetadata);
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _faceDetector.close();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final alertColor = _isAlarmPlaying ? Colors.red : Colors.green;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Drowsy Driver Detection'),
        backgroundColor: alertColor,
      ),
      body: Column(
        children: [
          Expanded(
            child: _cameraController != null && _cameraController!.value.isInitialized
                ? CameraPreview(_cameraController!)
                : const Center(child: CircularProgressIndicator()),
          ),
          Container(
            padding: const EdgeInsets.all(20),
            color: alertColor,
            width: double.infinity,
            child: Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}