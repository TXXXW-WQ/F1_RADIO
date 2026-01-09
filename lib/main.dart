import 'dart:async';
import 'dart:math';

import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'services/radio_service.dart';

late String agoraAppId;

Future<void> main() async {
  // .env を読み込み、AGORA_APP_ID を実行時に設定します。
  // .env が無い、またはキーが未定義の場合に備えてフォールバック値を指定します。
  await dotenv.load(fileName: '.env');
  agoraAppId = dotenv.get('AGORA_APP_ID', fallback: '51ef80a60cca4d878865d3124810d35d');
  runApp(const MyApp());
}

/// MyApp
/// - アプリ全体のテーマとルート画面を提供します。
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

/// MyHomePage
/// - 通話（Join/Leave）ボタン
/// - 通話中に表示される Waveform（audio_waveforms）
/// - 通話中に表示される Push-to-Talk（PTT）ボタン（押している間だけマイク ON）
class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  RadioService? _radioService;
  bool _inChannel = false;
  bool _isJoining = false; // チャンネル参加処理中の状態
  bool _isRadioEffectEnabled = false; // F1無線エフェクトの状態

  late RecorderController _recorderController;
  bool _pttActive = false;
  bool _isRecording = false;

  Timer? _pttAnimTimer;
  double _animPhase = 0.0;

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
    try {
      _recorderController.dispose();
    } catch (_) {}
    _cancelPttAnim();
    _radioService?.dispose();
    super.dispose();
  }

  void _startPttAnim() {
    _cancelPttAnim();
    _animPhase = 0.0;
    _pttAnimTimer = Timer.periodic(const Duration(milliseconds: 80), (t) {
      _animPhase += 0.5;
      if (_animPhase > 2 * pi) _animPhase -= 2 * pi;
      if (mounted) setState(() {});
    });
  }

  void _cancelPttAnim() {
    _pttAnimTimer?.cancel();
    _pttAnimTimer = null;
  }

  double get _computedScaleFactor {
    final anim = (sin(_animPhase) * 0.5 + 0.5);
    if (!_pttActive) {
      final baseSmall = 90.0;
      return baseSmall * (1.0 + anim * 0.4);
    }
    final base = _isRecording ? 220.0 : 120.0;
    return base * (1.0 + anim * 0.9);
  }

  Future<void> _toggleChannel() async {
    if (_isJoining) return; // 処理中の多重実行を防止

    if (!_inChannel) {
      // チャンネルに参加する処理
      setState(() {
        _isJoining = true;
      });

      try {
        _radioService = await RadioService.create(agoraAppId);
        await _radioService!.joinChannel(channelId: 'test');

        await _radioService!.setMicEnabled(false);
        await _recorderController.record();
        _isRecording = true;
        _startPttAnim();

        if (!mounted) return;
        setState(() {
          _inChannel = true;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('チャンネルに参加しました'), duration: Duration(seconds: 2)),
        );
      } catch (e) {
        // ignore: avoid_print
        print('Failed to join channel: $e');
        await _radioService?.dispose();
        _radioService = null;

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('チャンネルに参加できませんでした: ${e.toString()}'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.red,
          ),
        );
      } finally {
        if (mounted) {
          setState(() {
            _isJoining = false;
          });
        }
      }
    } else {
      // チャンネルから退出する処理
      try {
        await _radioService?.setRadioEffectEnabled(false);
        await _radioService?.setMicEnabled(false);
        if (_isRecording) {
          await _recorderController.stop(false);
          _isRecording = false;
        }
        await _radioService?.leaveChannel();
        await _radioService?.dispose();
        _radioService = null;

        _recorderController.dispose();
        _recorderController = RecorderController();
        _cancelPttAnim();

        if (!mounted) return;
        setState(() {
          _inChannel = false;
          _pttActive = false;
          _isRadioEffectEnabled = false;
        });
      } catch (e) {
        // ignore: avoid_print
        print('Failed to leave channel: $e');
      }
    }
  }

  Future<void> _onPttDown() async {
    if (!_inChannel) return;
    setState(() {
      _pttActive = true;
    });

    try {
      await _radioService?.setMicEnabled(true);
      await _radioService?.stopAudioMixing();
      await _radioService?.playStartSound();
    } catch (e) {
      // ignore: avoid_print
      print('PTT down actions failed: $e');
    }
  }

  Future<void> _onPttUp() async {
    if (!_inChannel) return;
    setState(() {
      _pttActive = false;
    });

    try {
      await _radioService?.setMicEnabled(false);
      await _radioService?.stopAudioMixing();
      await _radioService?.playEndSound();
    } catch (e) {
      // ignore: avoid_print
      print('PTT up actions failed: $e');
    }
  }

  Future<void> _toggleRadioEffect(bool enabled) async {
    setState(() {
      _isRadioEffectEnabled = enabled;
    });
    await _radioService?.setRadioEffectEnabled(enabled);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: _isJoining
              ? const CircularProgressIndicator() // 参加中はローディング表示
              : _inChannel
                  ? // 参加後は PTT と Wave を表示
                  Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        SizedBox(
                          height: 190,
                          width: MediaQuery.of(context).size.width,
                          child: AudioWaveforms(
                            enableGesture: false,
                            size: Size(MediaQuery.of(context).size.width, 190.0),
                            recorderController: _recorderController,
                            waveStyle: WaveStyle(
                              showMiddleLine: false,
                              waveColor: _pttActive ? Colors.cyanAccent : const Color.fromRGBO(0, 180, 200, 0.45),
                              showDurationLabel: false,
                              extendWaveform: true,
                              spacing: 26.0,
                              waveThickness: 8.0,
                              waveCap: StrokeCap.round,
                              scaleFactor: _computedScaleFactor,
                              backgroundColor: Colors.black,
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Listener(
                          onPointerDown: (_) => _onPttDown(),
                          onPointerUp: (_) => _onPttUp(),
                          onPointerCancel: (_) => _onPttUp(),
                          child: Semantics(
                            button: true,
                            label: 'Push to Talk',
                            child: Container(
                              width: 140,
                              height: 140,
                              decoration: BoxDecoration(
                                color: _pttActive ? Colors.redAccent : Colors.red,
                                shape: BoxShape.circle,
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color.fromRGBO(255, 0, 0, 0.4),
                                    blurRadius: 20,
                                    spreadRadius: 4,
                                  ),
                                ],
                              ),
                              child: const Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.mic, size: 48, color: Colors.white),
                                  SizedBox(height: 8),
                                  Text('Push to Talk', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        // F1 Radio Effect Switch
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text('F1 Radio Effect', style: TextStyle(fontSize: 16)),
                              const SizedBox(width: 10),
                              Switch(
                                value: _isRadioEffectEnabled,
                                onChanged: _toggleRadioEffect,
                                // ✅ activeColorなどの代わりに thumbColor / trackColor を使用
                                thumbColor: WidgetStateProperty.resolveWith<Color?>((states) {
                                  if (states.contains(WidgetState.selected)) {
                                    return Colors.blueAccent; // オン時のつまみの色
                                  }
                                  return null; // オフ時はデフォルト
                                }),
                                trackOutlineColor: WidgetStateProperty.all(Colors.transparent), // 枠線を消してスッキリさせる場合
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : const SizedBox.shrink(), // 参加前は何も表示しない
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _isJoining
          ? null // 参加処理中はボタンを非表示
          : FloatingActionButton.large(
              onPressed: _toggleChannel,
              backgroundColor: _inChannel ? Colors.red : const Color(0xFF002B5B),
              child: Icon(_inChannel ? Icons.call_end : Icons.call, size: 40),
            ),
    );
  }
}
