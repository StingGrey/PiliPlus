import 'dart:io' show Platform;

import 'package:flutter/widgets.dart' show BuildContext, View;

abstract final class PlatformUtils {
  @pragma("vm:platform-const")
  static final bool isMobile = Platform.isAndroid || Platform.isIOS;

  @pragma("vm:platform-const")
  static final bool isDesktop =
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @pragma("vm:platform-const")
  static final bool isDarwin = Platform.isIOS || Platform.isMacOS;

  /// Uses the physical view rather than the app's scaled MediaQuery, so a
  /// custom UI scale cannot make an iPad look like an iPhone (or vice versa).
  static bool isIPad(BuildContext context) {
    if (!Platform.isIOS) return false;
    final view = View.of(context);
    return view.physicalSize.shortestSide / view.devicePixelRatio >= 600;
  }
}
