import 'package:get/get.dart';

abstract final class SearchNavigation {
  static Future<T?>? open<T>({
    Map<String, String>? parameters,
    bool replace = false,
  }) {
    return replace
        ? Get.offNamed<T>('/search', parameters: parameters)
        : Get.toNamed<T>('/search', parameters: parameters);
  }
}
