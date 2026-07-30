import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

/// iOS 系统级画中画桥接。
///
/// media-kit 的 iOS 输出本身就是 [CVPixelBuffer]；原生补丁会把同一帧送入
/// [AVSampleBufferDisplayLayer]，因此不需要更换播放器或重新解码视频。
final class IOSPictureInPictureService {
  IOSPictureInPictureService._() {
    if (Platform.isIOS) {
      _channel.setMethodCallHandler(_handleMethodCall);
    }
  }

  static final IOSPictureInPictureService instance =
      IOSPictureInPictureService._();

  static const MethodChannel _channel = MethodChannel(
    'com.piliplus/ios_picture_in_picture',
  );

  Player? _player;
  int? _handle;

  Future<bool> attach(Player player, {required bool isLive}) async {
    if (!Platform.isIOS) return false;
    if (_handle == player.handle) {
      _player = player;
      await updatePlaybackState(
        isLive: isLive,
        duration: player.state.duration,
        position: player.state.position,
      );
      return true;
    }

    try {
      final prepared =
          await _channel.invokeMethod<bool>('PictureInPicture.Prepare', {
            'handle': player.handle.toString(),
            'isLive': isLive,
          }) ??
          false;
      if (!prepared) return false;
      _player = player;
      _handle = player.handle;
      await updatePlaybackState(
        isLive: isLive,
        duration: player.state.duration,
        position: player.state.position,
      );
      return true;
    } catch (error) {
      // PiP is an optional enhancement: a channel/OS failure must never stop
      // the normal iOS player from being created.
      debugPrint('iOS PiP prepare failed: $error');
      return false;
    }
  }

  Future<void> updatePlaybackState({
    required bool isLive,
    required Duration duration,
    required Duration position,
  }) async {
    final handle = _handle;
    if (!Platform.isIOS || handle == null) return;
    try {
      await _channel.invokeMethod<void>('PictureInPicture.UpdatePlaybackState', {
        'handle': handle.toString(),
        'isLive': isLive,
        'duration': duration.inMilliseconds,
        'position': position.inMilliseconds,
      });
    } catch (error) {
      debugPrint('iOS PiP playback state update failed: $error');
    }
  }

  Future<void> setPlaying(bool playing) async {
    final handle = _handle;
    if (!Platform.isIOS || handle == null) return;
    try {
      await _channel.invokeMethod<void>('PictureInPicture.SetPlaying', {
        'handle': handle.toString(),
        'playing': playing,
      });
    } catch (error) {
      debugPrint('iOS PiP state update failed: $error');
    }
  }

  Future<void> detach(Player player) async {
    if (!Platform.isIOS || _handle != player.handle) return;
    final handle = _handle!;
    _player = null;
    _handle = null;
    try {
      await _channel.invokeMethod<void>('PictureInPicture.Dispose', {
        'handle': handle.toString(),
      });
    } catch (error) {
      debugPrint('iOS PiP dispose failed: $error');
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    final player = _player;
    if (player == null) return;

    switch (call.method) {
      case 'PictureInPicture.SetPlaying':
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        if (args['playing'] == true) {
          await player.play();
        } else {
          await player.pause();
        }
      case 'PictureInPicture.SkipByInterval':
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        final seconds = (args['seconds'] as num?)?.toDouble();
        if (seconds == null || !seconds.isFinite) return;
        final current = player.state.position;
        final duration = player.state.duration;
        var target =
            current + Duration(milliseconds: (seconds * 1000).round());
        if (target < Duration.zero) target = Duration.zero;
        if (duration > Duration.zero && target > duration) target = duration;
        await player.seek(target);
      case 'PictureInPicture.Error':
        debugPrint('iOS PiP: ${call.arguments}');
    }
  }
}
