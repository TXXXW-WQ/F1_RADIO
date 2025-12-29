import 'package:flutter/material.dart';
import 'services/radio_service.dart';
import 'dart:async';
import 'package:noise_meter/noise_meter.dart';

// Simple waveform UI using microphone input (noise_meter)
const String agoraAppId = '51ef80a60cca4d878865d3124810d35d';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const darkBlue = Color(0xFF002B5B);

    return MaterialApp(
      title: 'F1 Effect Radio',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: darkBlue,
          secondary: Colors.blueAccent,
          surface: Color(0xFF121212),
        ),
        scaffoldBackgroundColor: Colors.black,
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: darkBlue,
          foregroundColor: Colors.white,
        ),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'F1 Effect Radio'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage>
    with SingleTickerProviderStateMixin {
  final int _counter = 0;
  late AnimationController _pulseController;

  RadioService? _radioService;
  bool _inChannel = false;

  // NoiseMeter for capturing mic input level
  late NoiseMeter _noiseMeter;
  StreamSubscription<NoiseReading>? _noiseSubscription;
  final List<double> _amplitudes = List<double>.filled(60, 0.0, growable: false);

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
      lowerBound: 0,
      upperBound: 1,
    );
    _noiseMeter = NoiseMeter();
  }

  @override
  void dispose() {
    _stopNoiseMonitoring();
    _noiseSubscription?.cancel();
    _noiseSubscription = null;
    _radioService?.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _toggleChannel() async {
    if (!_inChannel) {
      // join
      try {
        _radioService = await RadioService.create(agoraAppId);
        await _radioService!.joinChannel(channelId: 'test');
        // ignore: avoid_print
        print('UI: joinChannel completed without throwing');
        // start waveform monitoring
        _startNoiseMonitoring();
        if (!mounted) return;
        setState(() {
          _inChannel = true;
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Joined channel')));
      } catch (e, st) {
        // Log full error + stacktrace to console for debugging
        // ignore: avoid_print
        print('Failed to join channel: $e');
        // ignore: avoid_print
        print(st);
        if (!mounted) return;
        // Show dialog with error details (short form)
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Failed to join channel'),
            content: SingleChildScrollView(
              child: Text('$e\n\nSee console for stack trace.'),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK')),
            ],
          ),
        );
      }
    } else {
      // leave
      try {
        await _radioService?.leaveChannel();
        await _radioService?.dispose();
        _radioService = null;
        // stop waveform monitoring
        _stopNoiseMonitoring();
        if (!mounted) return;
        setState(() {
          _inChannel = false;
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Left channel')));
      } catch (e, st) {
        // ignore: avoid_print
        print('Failed to leave channel: $e');
        // ignore: avoid_print
        print(st);
        if (!mounted) return;
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Failed to leave channel'),
            content: SingleChildScrollView(child: Text('$e\n\nSee console for stack trace.')),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK')),
            ],
          ),
        );
      }
    }
  }

  void _startNoiseMonitoring() {
    try {
      _noiseSubscription?.cancel();
      _noiseSubscription = _noiseMeter.noise.listen((NoiseReading event) {
        final db = event.meanDecibel;
        final normalized = ((db + 60) / 60).clamp(0.0, 1.0);
        setState(() {
          _amplitudes.removeAt(0);
          _amplitudes.add(normalized);
        });
      }, onError: (err) {
        // ignore: avoid_print
        print('NoiseMeter error: $err');
      });
    } catch (e) {
      // ignore: avoid_print
      print('Failed to start noise monitoring: $e');
    }
  }

  void _stopNoiseMonitoring() {
    try {
      _noiseSubscription?.cancel();
      _noiseSubscription = null;
      setState(() {
        for (int i = 0; i < _amplitudes.length; i++) {
          _amplitudes[i] = 0.0;
        }
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final darkBlue = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Colors.black,
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),
            Center(
              child: Column(
                children: [
                  const Text(
                    'You have pushed the button this many times:',
                    style: TextStyle(color: Colors.white70),
                  ),
                  Text(
                    '$_counter',
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(color: Colors.white),
                  ),
                  const SizedBox(height: 24),
                  if (_inChannel)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          vertical: 8.0, horizontal: 16.0),
                      decoration: BoxDecoration(
                        color: darkBlue,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'In Channel',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Waveform display
            SizedBox(
              height: 120,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: CustomPaint(
                  painter: WaveformPainter(List<double>.from(_amplitudes), color: darkBlue),
                  child: Container(),
                ),
              ),
            ),
            const Expanded(child: SizedBox()),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: SizedBox(
        width: 88,
        height: 88,
        child: FloatingActionButton(
          onPressed: _toggleChannel,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, child) {
                  final double scale = 1.0 + (_inChannel ? _pulseController.value * 0.35 : 0.0);
                  return Transform.scale(
                    scale: scale,
                    child: Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _inChannel ? darkBlue.withAlpha((0.6 * 255).round()) : Colors.transparent,
                        boxShadow: [
                          if (_inChannel)
                            BoxShadow(
                              color: darkBlue.withAlpha((0.35 * 255).round()),
                              blurRadius: 20 * _pulseController.value,
                              spreadRadius: 1,
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [Colors.black, darkBlue],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  border: Border.all(color: Colors.white10, width: 1),
                ),
                child: Icon(
                  _inChannel ? Icons.call_end : Icons.call,
                  color: _inChannel ? Colors.redAccent : Colors.white70,
                  size: 32,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Simple painter that draws a waveform from amplitude samples (0.0 - 1.0)
class WaveformPainter extends CustomPainter {
  final List<double> samples;
  final Color color;
  WaveformPainter(this.samples, {this.color = Colors.blue});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withAlpha((0.9 * 255).round())
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..isAntiAlias = true;

    final path = Path();
    if (samples.isEmpty) return;
    final dx = size.width / (samples.length - 1);
    for (int i = 0; i < samples.length; i++) {
      final x = i * dx;
      final v = (samples[i].clamp(0.0, 1.0));
      final y = size.height - (v * size.height);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) => true;
}
