import 'dart:async';
import 'dart:math' as math;
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
  runApp(const SmartDriverGuardApp());
}

class SmartDriverGuardApp extends StatelessWidget {
  const SmartDriverGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Driver Guard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0E17),
      ),
      home: const DriverGuardDashboard(),
    );
  }
}

class DriverGuardDashboard extends StatefulWidget {
  const DriverGuardDashboard({super.key});

  @override
  State<DriverGuardDashboard> createState() => _DriverGuardDashboardState();
}

class _DriverGuardDashboardState extends State<DriverGuardDashboard>
    with SingleTickerProviderStateMixin {
  CameraController? _cameraController;
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true,
      performanceMode: FaceDetectorMode.fast,
    ),
  );

  final FlutterTts _tts = FlutterTts();
  final TextEditingController _bacInputController = TextEditingController();

  late AnimationController _roadAnimController;

  bool _isProcessingFrame = false;
  bool _isCameraReady = false;

  // Driver metrics
  double _eyeOpenProbability = 1.0;
  DateTime? _eyesClosedStartTime;
  bool _isDrowsyAlert = false;

  // Alcohol metrics
  double _currentBac = 0.0;
  bool _isAlcoholLocked = false;

  @override
  void initState() {
    super.initState();
    _initTts();
    _initBackgroundCamera();

    _roadAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage("en-US");
    await _tts.setPitch(1.0);
    await _tts.setSpeechRate(0.5);
  }

  Future<void> _speak(String text) async {
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> _initBackgroundCamera() async {
    if (cameras.isEmpty) return;

    CameraDescription frontCamera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      frontCamera,
      ResolutionPreset.low, // lightweight processing
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );

    try {
      await _cameraController!.initialize();
      if (!mounted) return;
      setState(() {
        _isCameraReady = true;
      });
      _cameraController!.startImageStream((image) => _processLiveFeed(image));
    } catch (e) {
      debugPrint("Camera initialize error: $e");
    }
  }

  void _processLiveFeed(CameraImage image) async {
    if (_isProcessingFrame || _isAlcoholLocked) return;
    _isProcessingFrame = true;

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

      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isNotEmpty) {
        final face = faces.first;
        final left = face.leftEyeOpenProbability ?? 1.0;
        final right = face.rightEyeOpenProbability ?? 1.0;
        final avgScore = (left + right) / 2.0;

        _eyeOpenProbability = avgScore;

        // 5-Second continuous closed eyes trigger rule
        if (avgScore < 0.35) {
          _eyesClosedStartTime ??= DateTime.now();
          final durationClosed =
              DateTime.now().difference(_eyesClosedStartTime!).inSeconds;

          if (durationClosed >= 5) {
            if (!_isDrowsyAlert) {
              _isDrowsyAlert = true;
              _roadAnimController.stop();
              _speak("Extreme drowsiness alert! Driver is sleeping! Wake up!");
            }
          }
        } else {
          _eyesClosedStartTime = null;
          if (_isDrowsyAlert) {
            _isDrowsyAlert = false;
            if (!_isAlcoholLocked && !_roadAnimController.isAnimating) {
              _roadAnimController.repeat();
            }
          }
        }
      }
    } catch (e) {
      debugPrint("Face detect error: $e");
    } finally {
      if (mounted) setState(() {});
      _isProcessingFrame = false;
    }
  }

  void _submitBacReading() {
    FocusScope.of(context).unfocus();
    double? val = double.tryParse(_bacInputController.text.trim());
    if (val == null) return;

    setState(() {
      _currentBac = val;
      // Traffic police benchmark: >= 30 mg/100ml or >= 0.03 BAC%
      if (val >= 30.0 || (val > 0.0 && val < 1.0 && val >= 0.03)) {
        _isAlcoholLocked = true;
        _roadAnimController.stop();
        _speak("You drank so vehicle will not start!");
      } else {
        _isAlcoholLocked = false;
        if (!_isDrowsyAlert && !_roadAnimController.isAnimating) {
          _roadAnimController.repeat();
        }
        _speak("Sober confirmed. Vehicle safe to drive.");
      }
    });
  }

  @override
  void dispose() {
    _roadAnimController.dispose();
    _cameraController?.dispose();
    _faceDetector.close();
    _bacInputController.dispose();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isEngineStopped = _isAlcoholLocked || _isDrowsyAlert;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0A0E17),
          border: Border.all(
            color: isEngineStopped ? Colors.redAccent : Colors.transparent,
            width: isEngineStopped ? 4 : 0,
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 1. Silent Background Camera Status Pill
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF131B2A),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: _isCameraReady
                              ? const Color(0xFF00E5FF).withOpacity(0.5)
                              : Colors.grey,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _isCameraReady
                                  ? const Color(0xFF00FF88)
                                  : Colors.orange,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _isCameraReady
                                ? "Face Detecting... (Active)"
                                : "Starting Camera Feed...",
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // 2. Big Central Gauge Meter (Circular Speedometer)
                SizedBox(
                  width: 250,
                  height: 220,
                  child: CustomPaint(
                    painter: BacSpeedometerPainter(
                      bacValue: _currentBac,
                      isLocked: isEngineStopped,
                    ),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(height: 24),
                          Text(
                            _isDrowsyAlert
                                ? "DRIVER\nDROWSY"
                                : _currentBac.toStringAsFixed(1),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: _isDrowsyAlert ? 22 : 36,
                              fontWeight: FontWeight.bold,
                              color: isEngineStopped
                                  ? Colors.redAccent
                                  : Colors.white,
                              letterSpacing: 1.2,
                            ),
                          ),
                          Text(
                            _isDrowsyAlert ? "" : "mg/100ml",
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.white54,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // 3. Manual BAC Input Field & Submit Button
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF131B2A),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Enter Police Alcohol Reading (BAC)",
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _bacInputController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                              decoration: InputDecoration(
                                hintText: "0",
                                hintStyle:
                                    const TextStyle(color: Colors.white30),
                                filled: true,
                                fillColor: const Color(0xFF0A0E17),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00E5FF),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 14,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            onPressed: _submitBacReading,
                            child: const Text(
                              "Submit & Test",
                              style: TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // 4. Alert Warning Banner (If stopped or drowsiness)
                if (isEngineStopped)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.redAccent, width: 1.5),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            color: Colors.redAccent, size: 30),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _isDrowsyAlert
                                ? "⚠ EXTREME DROWSINESS ALERT! DRIVER SLEEPING!"
                                : "⚠ YOU DRANK SO VEHICLE WILL NOT START!",
                            style: const TextStyle(
                              color: Colors.redAccent,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                // 5. Animated Car / Vehicle Area
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF131B2A),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: isEngineStopped
                          ? Colors.redAccent.withOpacity(0.6)
                          : const Color(0xFF00E5FF).withOpacity(0.3),
                    ),
                  ),
                  child: Column(
                    children: [
                      // Status Label
                      Text(
                        isEngineStopped
                            ? "ENGINE STATUS: LOCKED / STOPPED"
                            : "VEHICLE STATUS: ENGINE RUNNING (Driving Safe)",
                        style: TextStyle(
                          color: isEngineStopped
                              ? Colors.redAccent
                              : const Color(0xFF00FF88),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Animated Track and Car Canvas
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox(
                            height: 110,
                            width: double.infinity,
                            child: AnimatedBuilder(
                              animation: _roadAnimController,
                              builder: (context, child) {
                                return CustomPaint(
                                  painter: AnimatedRoadAndCarPainter(
                                    progress: isEngineStopped
                                        ? 0.0
                                        : _roadAnimController.value,
                                    isStopped: isEngineStopped,
                                  ),
                                );
                              },
                            ),
                          ),

                          // Lock icon overlay when car is immobilized
                          if (isEngineStopped)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.75),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.redAccent),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.lock_rounded,
                                      color: Colors.redAccent, size: 24),
                                  SizedBox(width: 8),
                                  Text(
                                    "STOP / LOCKED",
                                    style: TextStyle(
                                      color: Colors.redAccent,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 6. Driver Alertness Indicator Bottom Bar
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.remove_red_eye_outlined,
                      size: 16,
                      color: _eyeOpenProbability < 0.35
                          ? Colors.redAccent
                          : const Color(0xFF00E5FF),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      "Driver Alertness: ${(_eyeOpenProbability * 100).toInt()}%",
                      style: TextStyle(
                        color: _eyeOpenProbability < 0.35
                            ? Colors.redAccent
                            : Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// -------------------------------------------------------------
// Custom Vector Painter: Speedometer BAC Dial Meter (Zero Images)
// -------------------------------------------------------------
class BacSpeedometerPainter extends CustomPainter {
  final double bacValue;
  final bool isLocked;

  BacSpeedometerPainter({required this.bacValue, required this.isLocked});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.72);
    final radius = size.width * 0.42;

    const startAngle = 3 * math.pi / 4; // 135 deg
    const sweepAngle = 3 * math.pi / 2; // 270 deg

    final bgPaint = Paint()
      ..color = Colors.white12
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      bgPaint,
    );

    // Green Safe Zone Arc (0 to 29)
    final safePaint = Paint()
      ..color = const Color(0xFF00FF88)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle * 0.55,
      false,
      safePaint,
    );

    // Red Danger Zone Arc (30+)
    final dangerPaint = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle + (sweepAngle * 0.65),
      sweepAngle * 0.35,
      false,
      dangerPaint,
    );

    // Needle Angle
    double normalized = (bacValue / 60.0).clamp(0.0, 1.0);
    double needleAngle = startAngle + (sweepAngle * normalized);

    final needlePaint = Paint()
      ..color = isLocked ? Colors.redAccent : const Color(0xFF00E5FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    final needleEnd = Offset(
      center.dx + (radius - 18) * math.cos(needleAngle),
      center.dy + (radius - 18) * math.sin(needleAngle),
    );

    canvas.drawLine(center, needleEnd, needlePaint);

    final centerDotPaint = Paint()
      ..color = isLocked ? Colors.redAccent : const Color(0xFF00E5FF)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 7, centerDotPaint);
  }

  @override
  bool shouldRepaint(covariant BacSpeedometerPainter oldDelegate) =>
      oldDelegate.bacValue != bacValue || oldDelegate.isLocked != isLocked;
}

// -------------------------------------------------------------
// Custom Vector Painter: Animated Road & Car (Zero Images)
// -------------------------------------------------------------
class AnimatedRoadAndCarPainter extends CustomPainter {
  final double progress;
  final bool isStopped;

  AnimatedRoadAndCarPainter({required this.progress, required this.isStopped});

  @override
  void paint(Canvas canvas, Size size) {
    final roadY = size.height * 0.78;

    // 1. Road Base Line
    final roadBasePaint = Paint()
      ..color = const Color(0xFF232D42)
      ..strokeWidth = 5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(0, roadY), Offset(size.width, roadY), roadBasePaint);

    // 2. Animated Moving Road Dashes
    final dashPaint = Paint()
      ..color = isStopped
          ? Colors.grey.withOpacity(0.3)
          : const Color(0xFF00E5FF).withOpacity(0.6)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    const dashWidth = 24.0;
    const dashGap = 16.0;
    const totalCycle = dashWidth + dashGap;
    double offset = progress * totalCycle;

    for (double x = -totalCycle + offset; x < size.width; x += totalCycle) {
      if (x + dashWidth > 0 && x < size.width) {
        canvas.drawLine(
          Offset(x, roadY + 8),
          Offset(x + dashWidth, roadY + 8),
          dashPaint,
        );
      }
    }

    // 3. Draw Sleek Vector Sports Car Body
    final carCenterX = size.width / 2;
    final carCenterY = roadY - 18;

    final carBodyPaint = Paint()
      ..color = isStopped ? const Color(0xFF637381) : const Color(0xFF29B6F6)
      ..style = PaintingStyle.fill;

    // Car Body Path
    final carPath = Path();
    carPath.moveTo(carCenterX - 55, carCenterY + 12);
    carPath.lineTo(carCenterX + 55, carCenterY + 12);
    carPath.lineTo(carCenterX + 50, carCenterY + 2);
    carPath.lineTo(carCenterX + 35, carCenterY - 2);
    carPath.lineTo(carCenterX + 16, carCenterY - 18);
    carPath.lineTo(carCenterX - 22, carCenterY - 18);
    carPath.lineTo(carCenterX - 42, carCenterY - 2);
    carPath.lineTo(carCenterX - 55, carCenterY + 2);
    carPath.close();

    canvas.drawPath(carPath, carBodyPaint);

    // Car Roof / Glass Window
    final glassPaint = Paint()
      ..color = const Color(0xFF101B2B)
      ..style = PaintingStyle.fill;

    final glassPath = Path();
    glassPath.moveTo(carCenterX - 20, carCenterY - 15);
    glassPath.lineTo(carCenterX + 13, carCenterY - 15);
    glassPath.lineTo(carCenterX + 30, carCenterY - 2);
    glassPath.lineTo(carCenterX - 38, carCenterY - 2);
    glassPath.close();
    canvas.drawPath(glassPath, glassPaint);

    // Wheels
    final wheelPaint = Paint()
      ..color = const Color(0xFF0F141C)
      ..style = PaintingStyle.fill;
    final rimPaint = Paint()
      ..color = isStopped ? Colors.grey : const Color(0xFF00E5FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    Offset rearWheel = Offset(carCenterX - 34, carCenterY + 14);
    Offset frontWheel = Offset(carCenterX + 34, carCenterY + 14);

    canvas.drawCircle(rearWheel, 10, wheelPaint);
    canvas.drawCircle(rearWheel, 6, rimPaint);

    canvas.drawCircle(frontWheel, 10, wheelPaint);
    canvas.drawCircle(frontWheel, 6, rimPaint);

    // Headlight Beam (Greenish/Cyan when moving, Red when stopped)
    final lightPaint = Paint()
      ..color = isStopped
          ? Colors.redAccent.withOpacity(0.2)
          : const Color(0xFF00E5FF).withOpacity(0.3)
      ..style = PaintingStyle.fill;

    final lightBeam = Path();
    lightBeam.moveTo(carCenterX + 55, carCenterY + 4);
    lightBeam.lineTo(carCenterX + 90, carCenterY - 6);
    lightBeam.lineTo(carCenterX + 90, carCenterY + 14);
    lightBeam.close();
    canvas.drawPath(lightBeam, lightPaint);
  }

  @override
  bool shouldRepaint(covariant AnimatedRoadAndCarPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.isStopped != isStopped;
}
