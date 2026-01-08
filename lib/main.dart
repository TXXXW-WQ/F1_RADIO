import 'package:flutter/material.dart';
import 'services/radio_service.dart';
import 'dart:async';
import 'dart:math';
import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';


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
  // RadioService は Agora エンジンのラッパー（lib/services/radio_service.dart）
  RadioService? _radioService;

  // 現在チャンネルに参加しているか
  bool _inChannel = false;

  // audio_waveforms の RecorderController。マイク入力を可視化します。
  late RecorderController _recorderController;

  // Push-to-talk が押されているか（UI 状態）
  bool _pttActive = false;

  // Recorder が実際に録音中かどうかのフラグ
  bool _isRecording = false;

  // エミュレータなどでマイク入力が無い場合の視覚フィードバック用の小さなアニメーションタイマー
  Timer? _pttAnimTimer;
  double _animPhase = 0.0;

  @override
  void initState() {
    super.initState();
    // コントローラを初期化。実際の録音は PTT 押下時に行う。
    _recorderController = RecorderController();
  }

  @override
  void dispose() {
    // 終了時に録音が残っていれば止めて、コントローラを破棄
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

  // PTT 用の補助アニメーションを開始
  // マイク入力が無い場合でも波形が動くように、小さな振幅の変化を与えます。
  void _startPttAnim() {
    _cancelPttAnim();
    _animPhase = 0.0;
    _pttAnimTimer = Timer.periodic(const Duration(milliseconds: 80), (t) {
      // フェーズを進めて sinus を計算し、setState で描画を更新
      _animPhase += 0.5;
      if (_animPhase > 2 * pi) _animPhase -= 2 * pi;
      if (mounted) setState(() {});
    });
  }

  // アニメーション停止
  void _cancelPttAnim() {
    try {
      _pttAnimTimer?.cancel();
    } catch (_) {}
    _pttAnimTimer = null;
  }

  // 波形のスケール係数を動的に返す。実録音中は高め、非録音時は控えめ。
  // PTT 押下中は補助アニメーションでさらに変化させる。
  double get _computedScaleFactor {
    // 設計:
    // - 通話参加中で Recorder が稼働していても、PTT 非アクティブ時は波形の変化を目立たなくする
    //   （scaleFactor を小さくして入力があっても視覚的にほぼ平坦に見せる）
    // - PTT アクティブ時は大きくして波形がはっきり動くようにする
    // 共通で使うアニメーション値（0..1）
    final anim = (sin(_animPhase) * 0.5 + 0.5);
    if (!_pttActive) {
      // PTT 非アクティブ時: 以前は控えめすぎて実質非表示になっていたため
      // 可視性を高める（ユーザ要望）。ただし PTT アクティブ時よりは弱めに表示。
      final baseSmall = 90.0; // 非アクティブでも目視できるレベルに変更
      return baseSmall * (1.0 + anim * 0.4); // 少し大きめに揺らす
    }
    // PTT アクティブ時は録音有無に依らず大きく表示
    final base = _isRecording ? 220.0 : 120.0;
    return base * (1.0 + anim * 0.9); // 動的に変化させる
  }

  /// _toggleChannel
  /// - チャンネルに参加していなければ参加（`RadioService.create()` → `joinChannel()`）
  /// - 参加済みなら退出してリソースを解放
  Future<void> _toggleChannel() async {
    if (!_inChannel) {
      // join
      try {
        _radioService = await RadioService.create(agoraAppId);
        await _radioService!.joinChannel(channelId: 'test');
        // デバイスのマイクは常に有効化したい（ハードウェア／OSレベルでオンの状態にする）。
        // ただし、PTT によって送信（Agora への送信）を制御するため、ここでは録音コントローラを開始し、
        // Agora 側はミュート状態にしておく（送信は PTT で unmute する）。
        try {
          await _radioService!.setMicEnabled(false); // Agora への送信は当面オフ
        } catch (e) {
          // setMic 操作に失敗しても続行
        }
        // Recorder を開始してデバイスのマイクを常時オンにしておく
        try {
          await _recorderController.record();
          _isRecording = true; // recorder が稼働している状態（波形の表示は PTT で制御）
        } catch (e, st) {
          print('Failed to start recorder on join: $e');
          print(st);
        }
        // 通話参加時にアニメーション（波形更新のタイマー）を開始しておく
        _startPttAnim();
        if (!mounted) return;
        setState(() {
          _inChannel = true;
        });
      } catch (e, st) {
        // 参加に失敗した場合はダイアログで通知し、ログを出す
        print('Failed to join channel: $e');
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
        // 退出前にマイクを確実にオフ
        try {
          await _radioService?.setMicEnabled(false);
        } catch (_) {}
        // 録音が走っているなら停止
        try {
          if (_isRecording) {
            await _recorderController.stop(false);
            _isRecording = false;
          }
        } catch (_) {}
        await _radioService?.leaveChannel();
        await _radioService?.dispose();
        _radioService = null;
        // stop recorder and cleanup (device mic no longer needed after leaving)
        try {
          if (_isRecording) await _recorderController.stop(false);
        } catch (_) {}
        try {
          _recorderController.dispose();
        } catch (_) {}
        _recorderController = RecorderController();

        // PTT 補助アニメーションを停止
        _cancelPttAnim();

        if (!mounted) return;
        setState(() {
          _inChannel = false;
          _pttActive = false;
        });
      } catch (e, st) {
        print('Failed to leave channel: $e');
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

  /// _onPttDown
  /// - PTT 押下時に呼ばれる
  /// - Agora 側でマイクを有効化（送信 unmute）し、Recorder を起動して波形を描画
  /// - エミュレータでマイクが無い場合でも補助アニメーションで視覚フィードバックを行う
  Future<void> _onPttDown() async {
    if (!_inChannel) return; // 通話未参加なら無視
    print('PTT down event');
    setState(() {
      _pttActive = true;
    });

    try {
      // Agora 側の送信だけを有効化（デバイスのマイクは既に Recorder によってオンになっている）
      await _radioService?.setMicEnabled(true);
    } catch (e) {
      print('setMicEnabled(true) failed: $e');
    }
    // 送信をオンにしたら UI 更新（波形は PTT アクティブで見える）
    if (mounted) setState(() {});
  }

  /// _onPttUp
  /// - PTT を離したときに呼ばれる
  /// - Recorder を停止し、Agora のマイク送信をオフにする
  /// - 波形表示は RecorderController を再生成して初期状態に戻す
  Future<void> _onPttUp() async {
    if (!_inChannel) return;
    // debug
    // ignore: avoid_print
    print('PTT up event');
    setState(() {
      _pttActive = false;
    });
    try {
      // Agora 側の送信だけをオフにする（デバイスのマイク自体はオンのまま）
      await _radioService?.setMicEnabled(false);
    } catch (e) {
      // ignore
      print('setMicEnabled(false) failed: $e');
    }
    try {
      // Recorder は通話中は常時稼働させる設計なので stop はしない。
      // ここでは波形の補助アニメーションのみ停止して、UI を更新する。
      // PTT を離しても波形は維持するため、アニメーションは停止しない
      if (mounted) setState(() {});
    } catch (e) {
      // ignore: avoid_print
      print('Recorder stop failed on PTT up: $e');
    }
  }

  // ビルド：Wave と PTT（通話中のみ表示）、および画面下中央の通話ボタンを配置
  @override
  Widget build(BuildContext context) {
    // Keep the UI minimal: only waveform and call button; PTT appears when in channel
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _inChannel
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Wave を少し上寄せして、PTT をその下に配置
                    const SizedBox(height: 20),

                    // Waveform：RecorderController を渡してマイク入力を可視化
                    SizedBox(
                      height: 190,
                      width: MediaQuery.of(context).size.width,
                      child: AudioWaveforms(
                        enableGesture: false,
                        size: Size(MediaQuery.of(context).size.width, 190.0),
                        recorderController: _recorderController,
                        // Wave の見た目設定
                        waveStyle: WaveStyle(
                          showMiddleLine: false,
                          // PTT 非アクティブ時でも視認性を確保する色に変更
                          waveColor: _pttActive ? Colors.cyanAccent : const Color.fromRGBO(0, 180, 200, 0.45),
                          showDurationLabel: false,
                          extendWaveform: true,
                          spacing: 26.0, // spacing は waveThickness より大きくする必要がある
                          waveThickness: 8.0,
                          waveCap: StrokeCap.round,
                          // scaleFactor は PTT の状態に応じて変化（非アクティブ時は小さくし、反応を抑制）
                          scaleFactor: _computedScaleFactor,
                          backgroundColor: Colors.black,
                        ),
                      ),
                    ),

                    const SizedBox(height: 18),

                    // PTT（長押しで送信、離すと停止）
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

                    const SizedBox(height: 36), // ボトム FAB と被らない余白
                  ],
                ),
              )
            : const SizedBox.shrink(),
      ),
      // 画面下中央の通話ボタン（参加／退出）
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
