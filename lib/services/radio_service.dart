import 'dart:async';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';

/// RadioService
/// - Agora SDK を使って音声チャネルに参加/退出する機能を提供します。
/// - マイクの ON/OFF 切替、スピーカー音量の調整、スピーカー出力切替をサポートします。
///
/// 使い方 (例):
/// final service = await RadioService.create(appId);
/// await service.joinChannel(token: token, channelId: 'test');
/// await service.toggleMic();
/// await service.setSpeakerVolume(80);
/// await service.leaveChannel();
class RadioService {
  late final RtcEngine _engine;
  bool _joined = false;
  bool _micEnabled = true;
  int _playbackVolume = 100; // 0 - 400 (agora SDK の範囲)

  RadioService._();

  /// Factory: Agora エンジンを初期化して RadioService インスタンスを返す
  static Future<RadioService> create(String appId) async {
    final s = RadioService._();

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

  /// リソース解放
  Future<void> dispose() async {
    try {
      await _engine.release();
    } catch (_) {
      // ignore
    }
  }
}
