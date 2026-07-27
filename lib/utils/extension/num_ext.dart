import 'dart:math' show pow;

import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter/widgets.dart' show BuildContext, MediaQuery;

extension ImageExtension on num {
  int? cacheSize(BuildContext context) {
    if (this == 0) {
      return null;
    }
    final mediaQuery = MediaQuery.of(context);
    var decodeScale = mediaQuery.devicePixelRatio;
    if (PlatformUtils.isIPad(context)) {
      // iPad 的列表缩略图无需按完整 2x 像素密度解码。1.5x 可减少约
      // 44% 的解码像素与纹理上传量，同时保持滚动场景下的清晰度。
      decodeScale = decodeScale.clamp(1.0, 1.5).toDouble();
    }
    return (this * decodeScale).round();
  }
}

extension IntExt on int? {
  int? operator +(int other) => this == null ? null : this! + other;
  int? operator -(int other) => this == null ? null : this! - other;
}

extension DoubleExt on double {
  double toPrecision(int fractionDigits) {
    final mod = pow(10, fractionDigits).toDouble();
    return (this * mod).roundToDouble() / mod;
  }

  bool equals(double other, [double epsilon = 1e-10]) =>
      (this - other).abs() < epsilon;

  double lerp(double a, double b) {
    assert(
      a.isFinite,
      'Cannot interpolate between finite and non-finite values',
    );
    assert(
      b.isFinite,
      'Cannot interpolate between finite and non-finite values',
    );
    assert(isFinite, 't must be finite when interpolating between values');
    return a * (1.0 - this) + b * this;
  }
}
