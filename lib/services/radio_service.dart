import 'dart:async';
import 'dart:io';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// RadioService
/// - Agora SDK を使って音声チャネルに参加/退出する機能を提供します。
/// - マイクの ON/OFF 切替、スピーカー音量の調整、スピーカー出力切替をサポートします。
/// - 加えて、ローカルの音声ファイルを通話チャネルに流す（startAudioMixing）機能を提供します。
///
/// 使い方 (例):
/// final service = await RadioService.create(appId);
/// await service.joinChannel(token: token, channelId: 'test');
/// await service.playStartSound(); // assets/sounds/f1_start.m4a を再生して相手に聞かせる
/// await service.leaveChannel();
class RadioService {
  late final RtcEngine _engine;
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _joined = false;
  bool _micEnabled = true;
  int _playbackVolume = 100; // 0 - 400 (agora SDK の範囲)

  // asset -> device file path cache
  final Map<String, String> _assetCache = {};

  RadioService._();

  /// Factory: Agora エンジンを初期化して RadioService インスタンスを返す
  static Future<RadioService> create(String appId) async {
    final s = RadioService._();

    // AudioPlayer のグローバル設定を行い、オーディオフォーカスの競合を解決する
    await AudioPlayer.global.setAudioContext(AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: true,
        stayAwake: true,
        contentType: AndroidContentType.sonification,
        usageType: AndroidUsageType.assistanceSonification,
        // gainTransientMayDuck は、他のオーディオを止める代わりに音量を下げることを許可する
        // これにより、Agora の通話音声との共存が改善される可能性がある
        audioFocus: AndroidAudioFocus.gainTransientMayDuck,
      ),
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playAndRecord, // Corrected category
        options: const {
          AVAudioSessionOptions.mixWithOthers,
          AVAudioSessionOptions.defaultToSpeaker,
        },
      ),
    ));

    // AudioPlayer の状態をログに出力してデバッグしやすくする
    s._audioPlayer.onPlayerStateChanged.listen((state) {
      // ignore: avoid_print
      print('[AudioPlayer] State changed: $state');
    });
    s._audioPlayer.onLog.listen((msg) {
      // ignore: avoid_print
      print('[AudioPlayer] Log: $msg');
    });

    // エンジン作成・初期化
    s._engine = createAgoraRtcEngine();
    await s._engine.initialize(RtcEngineContext(appId: appId));
    // ignore: avoid_print
    print('Agora engine initialized with appId: $appId');

    // オーディオを有効化
    await s._engine.enableAudio();

    // 簡単なイベントハンドラ（ログ用途）
    s._engine.registerEventHandler(RtcEngineEventHandler(
      onJoinChannelSuccess: (connection, elapsed) {
        // ignore: avoid_print
        print('Joined channel: ${connection.channelId} uid:${connection.localUid}');
      },
      onUserJoined: (connection, remoteUid, elapsed) {
        // ignore: avoid_print
        print('Remote user joined: $remoteUid');
      },
      onUserOffline: (connection, remoteUid, reason) {
        // ignore: avoid_print
        print('Remote user offline: $remoteUid reason:$reason');
      },
    ));

    return s;
  }

  /// マイク権限を確認・要求します
  Future<bool> _ensureMicPermission() async {
    final status = await Permission.microphone.status;
    if (status.isGranted) return true;
    final req = await Permission.microphone.request();
    return req.isGranted;
  }

  /// チャンネルに参加します。マイク権限が必要です。
  /// token は null でも可（無効な場合は空文字列を渡す等は呼び出し側で調整してください）
  Future<void> joinChannel({String? token, required String channelId, int uid = 0}) async {
    // Debug logs to help diagnose join failures
    // ignore: avoid_print
    print('Attempting to join channel: $channelId uid:$uid');
    // ignore: avoid_print
    print('Token provided: ${token != null ? '(length=${token.length})' : 'null'}');

    final ok = await _ensureMicPermission();
    // ignore: avoid_print
    print('Microphone permission granted: $ok');
    if (!ok) {
      throw Exception('Microphone permission denied');
    }

    try {
      await _engine.joinChannel(
        token: token ?? '',
        channelId: channelId,
        uid: uid,
        options: const ChannelMediaOptions(),
      );
      _joined = true;
      // ignore: avoid_print
      print('RadioService: joinChannel API returned success for channel: $channelId');
    } catch (e, st) {
      // Log and rethrow with additional context for easier debugging
      // ignore: avoid_print
      print('RadioService.joinChannel failed: $e');
      // ignore: avoid_print
      print(st);
      throw Exception('Failed to join channel "$channelId": $e');
    }
  }

  /// チャンネルから退出します
  Future<void> leaveChannel() async {
    if (!_joined) return;
    await _engine.leaveChannel();
    _joined = false;
  }

  /// マイクの ON/OFF を切り替えます (ローカルオーディオのミュート)
  Future<void> toggleMic() async {
    _micEnabled = !_micEnabled;
    // muteLocalAudioStream(true) はマイクをミュートする（送信停止）
    await _engine.muteLocalAudioStream(!_micEnabled);
  }

  /// マイクを明示的に設定します
  Future<void> setMicEnabled(bool enabled) async {
    _micEnabled = enabled;
    await _engine.muteLocalAudioStream(!enabled);
  }

  /// スピーカー音量を調整します（0-400）。agora SDK の adjustPlaybackSignalVolume を使用。
  /// 値の範囲は SDK に依存しますが、一般的に 0-400 の範囲を想定します。
  Future<void> setSpeakerVolume(int volume) async {
    final v = volume.clamp(0, 400);
    _playbackVolume = v;
    await _engine.adjustPlaybackSignalVolume(v);
  }

  /// スピーカー出力（イヤホンやスピーカー）を切り替えます
  Future<void> setSpeakerphoneOn(bool on) async {
    await _engine.setEnableSpeakerphone(on);
  }

  bool get isJoined => _joined;
  bool get micEnabled => _micEnabled;
  int get playbackVolume => _playbackVolume;

  /// --- audio effect helpers ---

  /// F1無線エフェクトを有効/無効にします
  Future<void> setRadioEffectEnabled(bool enabled) async {
    if (enabled) {
      // 蓄音機プリセットで、古い無線のような音質をシミュレート
      await _engine.setAudioEffectPreset(AudioEffectPreset.roomAcousticsPhonograph);
    } else {
      // エフェクトをオフにする
      await _engine.setAudioEffectPreset(AudioEffectPreset.audioEffectOff);
    }
  }

  /// --- audio mixing helpers ---

  // Ensure an asset (e.g. 'sounds/f1_start.m4a') is copied to a device file and return its path.
  Future<String> _ensureAssetFile(String assetPath) async {
    if (_assetCache.containsKey(assetPath)) return _assetCache[assetPath]!;
    // Load asset bytes
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List();
    final dir = await getTemporaryDirectory();
    final fileName = assetPath.split('/').last;
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    _assetCache[assetPath] = file.path;
    return file.path;
  }

  /// Play a local asset into the channel using startAudioMixing.
  Future<void> _startAudioMixingFromAsset(String assetPath,
      {bool loop = false, bool loopback = true}) async {
    final path = await _ensureAssetFile(assetPath);
    // cycle: 0 -> loop forever, >0 -> number of times
    final cycle = loop ? 0 : 1;
    try {
      // The 'replace' parameter is not available in this version of the Agora SDK.
      // The default behavior is mixing, which is what we want.
      await _engine.startAudioMixing(
          filePath: path, loopback: loopback, cycle: cycle);
      // ignore: avoid_print
      print('Started audio mixing for $assetPath -> $path');
    } catch (e, st) {
      // ignore: avoid_print
      print('startAudioMixing failed for $assetPath: $e');
      // ignore: avoid_print
      print(st);
    }
  }

  /// Stop audio mixing (if playing)
  Future<void> stopAudioMixing() async {
    try {
      await _engine.stopAudioMixing();
      // ignore: avoid_print
      print('Stopped audio mixing');
    } catch (e) {
      // ignore: avoid_print
      print('stopAudioMixing failed: $e');
    }
  }

  /// Public helpers to play start/end sounds that are included as assets
  Future<void> playStartSound() async {
    if (!_joined) return;
    try {
      // Play locally for instant feedback using AssetSource for simplicity and reliability
      await _audioPlayer.play(AssetSource('sounds/f1_start.m4a'));

      // Mix into channel for remote users
      await _startAudioMixingFromAsset('assets/sounds/f1_start.m4a',
          loop: false, loopback: false); // loopback: false to avoid double playback
    } catch (e) {
      // ignore: avoid_print
      print('playStartSound failed: $e');
    }
  }

  Future<void> playEndSound() async {
    if (!_joined) return;
    try {
      // Play locally for instant feedback using AssetSource for simplicity and reliability
      await _audioPlayer.play(AssetSource('sounds/f1_end.m4a'));

      // Mix into channel for remote users
      await _startAudioMixingFromAsset('assets/sounds/f1_end.m4a',
          loop: false, loopback: false); // loopback: false to avoid double playback
    } catch (e) {
      // ignore: avoid_print
      print('playEndSound failed: $e');
    }
  }

  /// リソース解放
  Future<void> dispose() async {
    await _audioPlayer.dispose();
    try {
      await _engine.release();
    } catch (_) {
      // ignore
    }
  }
}
