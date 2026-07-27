import 'dart:io' show Platform;

import 'package:PiliPlus/pages/search/view.dart';
import 'package:flutter/cupertino.dart';
import 'package:get/get.dart';

/// Opens the search page with an iOS-native, interactive transition.
///
/// The project's GetX fork intentionally uses one global transition and does
/// not expose a transition on [GetPage]. A dedicated [GetPageRoute] keeps GetX
/// lifecycle reporting and route parameters while allowing search to animate
/// even when the user's global transition preference is disabled.
abstract final class SearchNavigation {
  static Future<T?>? open<T>({
    Map<String, String>? parameters,
    bool replace = false,
  }) {
    if (!Platform.isIOS) {
      return replace
          ? Get.offNamed<T>('/search', parameters: parameters)
          : Get.toNamed<T>('/search', parameters: parameters);
    }

    if (!replace && Get.currentRoute.split('?').first == '/search') {
      return null;
    }

    final routeName = Uri(
      path: '/search',
      queryParameters: parameters?.isEmpty == true ? null : parameters,
    ).toString();
    final navigator = Get.key.currentState;
    if (navigator == null) return null;

    // Direct Navigator pushes bypass PageRedirect, which normally synchronizes
    // named-route query parameters into Get.parameters before page creation.
    Get.parameters = <String, String?>{...?parameters};
    final route = _IOSSearchPageRoute<T>(
      routeName: routeName,
      parameters: parameters,
    );
    return replace
        ? navigator.pushReplacement<T, Object?>(route)
        : navigator.push<T>(route);
  }
}

final class _IOSSearchPageRoute<T> extends GetPageRoute<T> {
  _IOSSearchPageRoute({
    required String routeName,
    Map<String, String>? parameters,
  }) : super(
         page: () => const SearchPage(),
         routeName: routeName,
         settings: RouteSettings(name: routeName),
         parameter: parameters,
       );

  // Keep the search transition visible even when the global GetX transition
  // preference is set to "none". The sidebar entry is small on iPad, so a
  // short, explicit route duration makes the page change perceptible without
  // delaying the first frame of the search UI.
  @override
  Duration get transitionDuration => const Duration(milliseconds: 420);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: Tween<double>(begin: 0, end: 1).animate(curved),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(-0.035, 0),
          end: Offset.zero,
        ).animate(curved),
        child: ScaleTransition(
          alignment: const Alignment(-0.92, -0.56),
          scale: Tween<double>(begin: 0.92, end: 1).animate(curved),
          child: child,
        ),
      ),
    );
  }
}
