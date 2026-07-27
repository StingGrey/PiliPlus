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

  Future<bool> attach(Player player) async {
    if (!Platform.isIOS) return false;
    if (_handle == player.handle) return true;

    try {
      final prepared =
          await _channel.invokeMethod<bool>('PictureInPicture.Prepare', {
            'handle': player.handle.toString(),
          }) ??
          false;
      if (!prepared) return false;
      _player = player;
      _handle = player.handle;
      return true;
    } catch (error) {
      // PiP is an optional enhancement: a channel/OS failure must never stop
      // the normal iOS player from being created.
      debugPrint('iOS PiP prepare failed: $error');
      return false;
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
      case 'PictureInPicture.Error':
        debugPrint('iOS PiP: ${call.arguments}');
    }
  }
}
