import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:flutter_tts/flutter_tts.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera access error: $e');
  }
  runApp(const DrowsyGuardApp());
}

class DrowsyGuardApp extends StatelessWidget {
  const DrowsyGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Driver Guard v2.0',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          secondary: Color(0xFFFF3366),
          surface: Color(0xFF161B22),
        ),
      ),
      home: const DriverDashboardScreen(),
    );
  }
}

class DriverDashboardScreen extends StatefulWidget {
  const DriverDashboardScreen({super.key});

  @override
  State<DriverDashboardScreen> createState() => _DriverDashboardScreenState();
}

class _DriverDashboardScreenState extends State<DriverDashboardScreen> {
  CameraController? _cameraController;
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true,
      performanceMode: FaceDetectorMode.fast,
    ),
  );

  final FlutterTts _tts = FlutterTts();
  final TextEditingController _bacController = TextEditingController();

  bool _isProcessing = false;
  bool _isDrowsy = false;
  bool _isEngineLocked = false;
  String _alertMessage = "SYSTEM MONITORING ACTIVE";
  double _eyeOpenProbability = 1.0;
  DateTime? _eyesClosedStartTime;

  @override
  void initState() {
    super.initState();
    _setupVoiceAlerts();
    _initFrontCamera();
  }

  Future<void> _setupVoiceAlerts() async {
    await _tts.setLanguage("en-US");
    await _tts.setPitch(1.0);
    await _tts.setSpeechRate(0.5);
  }

  Future<void> _speakAlert(String text) async {
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> _initFrontCamera() async {
    if (cameras.isEmpty) return;

    CameraDescription frontCamera = cameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      frontCamera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );

    try {
      await _cameraController!.initialize();
      if (!mounted) return;
      _cameraController!.startImageStream((image) => _analyzeFaceFrame(image));
      setState(() {});
    } catch (e) {
      debugPrint("Camera initialize failed: $e");
    }
  }

  void _analyzeFaceFrame(CameraImage image) async {
    if (_isProcessing || _isEngineLocked) return;
    _isProcessing = true;

    try {
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      final inputImage = InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: InputImageRotation.rotation270deg,
          format: InputImageFormat.nv21,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );

      final List<Face> detectedFaces = await _faceDetector.processImage(inputImage);

      if (detectedFaces.isNotEmpty) {
        final face = detectedFaces.first;
        final double leftEye = face.leftEyeOpenProbability ?? 1.0;
        final double rightEye = face.rightEyeOpenProbability ?? 1.0;
        final double avgEyeScore = (leftEye + rightEye) / 2.0;

        _eyeOpenProbability = avgEyeScore;

        if (avgEyeScore < 0.35) {
          _eyesClosedStartTime ??= DateTime.now();
          final durationClosed = DateTime.now().difference(_eyesClosedStartTime!).inSeconds;

          if (durationClosed >= 2) {
            if (!_isDrowsy) {
              _isDrowsy = true;
              _alertMessage = "DROWSINESS DETECTED! WAKE UP!";
              _speakAlert("Warning! Drowsiness detected. Please wake up!");
            }
          }
        } else {
          _eyesClosedStartTime = null;
          if (_isDrowsy) {
            _isDrowsy = false;
            _alertMessage = "SYSTEM MONITORING ACTIVE";
          }
        }
      }
    } catch (e) {
      debugPrint("Analysis error: $e");
    } finally {
      if (mounted) setState(() {});
      _isProcessing = false;
    }
  }

  void _processAlcoholTest() {
    double? bacValue = double.tryParse(_bacController.text.trim());
    if (bacValue == null) return;

    // Traffic police benchmark: >= 30 mg/100ml or >= 0.03 BAC%
    if (bacValue >= 30.0 || (bacValue > 0.0 && bacValue < 1.0 && bacValue >= 0.03)) {
      setState(() {
        _isEngineLocked = true;
        _alertMessage = "You drank so vehicle will not start!";
      });
      _speakAlert("You drank so vehicle will not start!");
    } else {
      setState(() {
        _isEngineLocked = false;
        _alertMessage = "ENGINE UNLOCKED: DRIVE SAFE";
      });
      _speakAlert("Sober confirmed. Vehicle ready to drive.");
    }
    _bacController.clear();
    Navigator.of(context).pop();
  }

  void _openAlcoholInputModal() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.local_bar_rounded, color: Color(0xFFFF3366)),
            SizedBox(width: 8),
            Text("Breathalyzer Test", style: TextStyle(color: Colors.white, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Enter reading from traffic police meter:\n(e.g., 35 mg/100ml or 0.08 BAC%)",
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _bacController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                hintText: "Enter reading value",
                hintStyle: const TextStyle(color: Colors.white30, fontSize: 14),
                filled: true,
                fillColor: const Color(0xFF0D1117),
                prefixIcon: const Icon(Icons.speed, color: Color(0xFF00E5FF)),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.white24),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E5FF),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: _processAlcoholTest,
            child: const Text("Submit & Verify", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _faceDetector.close();
    _bacController.dispose();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          "SMART DRIVER GUARD 2.0",
          style: TextStyle(
            letterSpacing: 1.5,
            fontWeight: FontWeight.bold,
            fontSize: 16,
            color: Color(0xFF00E5FF),
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            // Status & Engine Lock Indicator Card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: _isEngineLocked
                    ? Colors.red.withAlpha(45)
                    : (_isDrowsy ? Colors.orange.withAlpha(45) : const Color(0xFF161B22)),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _isEngineLocked
                      ? Colors.redAccent
                      : (_isDrowsy ? Colors.orangeAccent : const Color(0xFF00E5FF)),
                  width: 1.5,
                ),
              ),
              child: Column(
                children: [
                  Icon(
                    _isEngineLocked
                        ? Icons.lock_rounded
                        : (_isDrowsy ? Icons.warning_rounded : Icons.shield_rounded),
                    color: _isEngineLocked
                        ? Colors.redAccent
                        : (_isDrowsy ? Colors.orangeAccent : const Color(0xFF00E5FF)),
                    size: 42,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _alertMessage,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _isEngineLocked ? Colors.redAccent : Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: _isEngineLocked ? Colors.red : Colors.green.withAlpha(60),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _isEngineLocked ? "VEHICLE ENGINE: LOCKED" : "VEHICLE ENGINE: ALLOWED",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Live Camera Preview
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                height: 290,
                width: double.infinity,
                color: const Color(0xFF161B22),
                child: _cameraController != null && _cameraController!.value.isInitialized
                    ? Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          Positioned.fill(
                            child: CameraPreview(_cameraController!),
                          ),
                          Container(
                            height: 50,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [Colors.black.withAlpha(200), Colors.transparent],
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                              ),
                            ),
                          ),
                        ],
                      )
                    : const Center(child: CircularProgressIndicator(color: Color(0xFF00E5FF))),
              ),
            ),
            const SizedBox(height: 16),

            // Driver Alertness / Eye Open Score
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "Driver Alertness (Eye Openness)",
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                      Text(
                        "${(_eyeOpenProbability * 100).toInt()}%",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: _eyeOpenProbability < 0.35 ? Colors.redAccent : const Color(0xFF00E5FF),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: _eyeOpenProbability.clamp(0.0, 1.0),
                    backgroundColor: Colors.white12,
                    color: _eyeOpenProbability < 0.35 ? Colors.redAccent : const Color(0xFF00E5FF),
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Alcohol Detection Button
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00E5FF),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 4,
                ),
                onPressed: _openAlcoholInputModal,
                icon: const Icon(Icons.local_bar_rounded, color: Colors.black),
                label: const Text(
                  "ENTER POLICE ALCOHOL TEST",
                  style: TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
