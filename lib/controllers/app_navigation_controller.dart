import 'package:get/get.dart';

class AppNavigationController extends GetxController {
  final selectedIndex = 3.obs;

  void selectPage(int index) {
    if (index < 0) {
      return;
    }
    selectedIndex.value = index;
  }
}
