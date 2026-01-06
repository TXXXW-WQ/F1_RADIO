import 'package:flutter/material.dart';
import 'services/radio_service.dart';
import 'dart:async';
import 'package:audio_waveforms/audio_waveforms.dart';

// Simple waveform UI using microphone input (audio_waveforms)
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

class _MyHomePageState extends State<MyHomePage> {
  RadioService? _radioService;
  bool _inChannel = false;

  // RecorderController (audio_waveforms) for capturing mic PCM and rendering detailed waveform
  late RecorderController _recorderController;

  // Push-to-talk state
  bool _pttActive = false;

  // whether recorder is currently recording
  bool _isRecording = false;

  @override
  void initState() {
    super.initState();
    _recorderController = RecorderController();
  }

  @override
  void dispose() {
    try {
      if (_isRecording) _recorderController.stop(false);
    } catch (_) {}
    _recorderController.dispose();
    _radioService?.dispose();
    super.dispose();
  }

  Future<void> _toggleChannel() async {
    if (!_inChannel) {
      // join
      try {
        _radioService = await RadioService.create(agoraAppId);
        await _radioService!.joinChannel(channelId: 'test');
        // Do NOT start recorder here. Recorder will run only when PTT pressed.
        // default mic state: muted until user presses PTT
        try {
          await _radioService!.setMicEnabled(false);
        } catch (e) {
          // ignore
        }
        if (!mounted) return;
        setState(() {
          _inChannel = true;
        });
      } catch (e, st) {
        // ignore: avoid_print
        print('Failed to join channel: $e');
        // ignore: avoid_print
        print(st);
        if (!mounted) return;
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
        // ensure mic off
        try {
          await _radioService?.setMicEnabled(false);
        } catch (_) {}
        // stop recorder if running
        try {
          if (_isRecording) {
            await _recorderController.stop(false);
            _isRecording = false;
          }
        } catch (_) {}
        await _radioService?.leaveChannel();
        await _radioService?.dispose();
        _radioService = null;
        // stop recorder waveform (redundant but safe)
        try {
          if (_isRecording) await _recorderController.stop(false);
        } catch (_) {}
        if (!mounted) return;
        setState(() {
          _inChannel = false;
          _pttActive = false;
        });
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

  // When PTT pressed: enable mic and start recorder. When released: disable mic and stop recorder.
  Future<void> _onPttDown() async {
    if (!_inChannel) return;
    setState(() => _pttActive = true);
    try {
      await _radioService?.setMicEnabled(true);
    } catch (e) {
      // ignore
    }
    try {
      if (!_isRecording) {
        // debug
        // ignore: avoid_print
        print('PTT down: starting recorder');
        await _recorderController.record();
        _isRecording = true;
        // ignore: avoid_print
        print('PTT down: recorder started');
      } else {
        // ignore: avoid_print
        print('PTT down: recorder already running');
      }
    } catch (e) {
      // ignore: avoid_print
      print('Recorder start failed on PTT down: $e');
    }
  }

  Future<void> _onPttUp() async {
    if (!_inChannel) return;
    setState(() => _pttActive = false);
    try {
      await _radioService?.setMicEnabled(false);
    } catch (e) {
      // ignore
    }
    try {
      if (_isRecording) {
        // debug
        // ignore: avoid_print
        print('PTT up: stopping recorder');
        await _recorderController.stop(false);
        _isRecording = false;
        // ignore: avoid_print
        print('PTT up: recorder stopped');
      } else {
        // ignore: avoid_print
        print('PTT up: recorder was not running');
      }
    } catch (e) {
      // ignore: avoid_print
      print('Recorder stop failed on PTT up: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keep the UI minimal: only waveform and call button; PTT appears when in channel
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _inChannel
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Waveform placed near the vertical center
                  SizedBox(
                    height: 220,
                    width: MediaQuery.of(context).size.width,
                    child: AudioWaveforms(
                      enableGesture: false,
                      size: Size(MediaQuery.of(context).size.width, 220.0),
                      recorderController: _recorderController,
                      // Note: recorder is started only while PTT is pressed; when stopped the widget remains visible but won't change
                      waveStyle: WaveStyle(
                        showMiddleLine: false,
                        waveColor: Colors.cyanAccent,
                        showDurationLabel: false,
                        extendWaveform: true,
                        spacing: 28.0, // spacing must be larger than waveThickness
                        waveThickness: 12.0,
                        waveCap: StrokeCap.round,
                        scaleFactor: 1000.0, // further increase sensitivity / amplification
                        backgroundColor: Colors.black,
                      ),
                    ),
                  ),

                  const SizedBox(height: 20), // smaller spacing so both sit near center

                  // Push-to-talk button below the waveform
                  Center(
                    child: GestureDetector(
                      onTapDown: (_) => _onPttDown(),
                      onTapUp: (_) => _onPttUp(),
                      onTapCancel: _onPttUp,
                      child: Container(
                        width: 140,
                        height: 140,
                        decoration: BoxDecoration(
                          color: _pttActive ? Colors.redAccent : Colors.red,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Color.fromRGBO(255, 0, 0, 0.4),
                              blurRadius: 20,
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.mic,
                                size: 48,
                                color: Colors.white,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Push to Talk',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // keep a little bottom padding so FAB doesn't overlap
                  const SizedBox(height: 48),
                ],
              )
            : const SizedBox.shrink(),
      ),
      // Join / Leave button at bottom center
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FloatingActionButton.large(
        onPressed: _toggleChannel,
        backgroundColor: _inChannel ? Colors.red : const Color(0xFF002B5B),
        child: Icon(
          _inChannel ? Icons.call_end : Icons.call,
          size: 40,
        ),
      ),
    );
  }
}
