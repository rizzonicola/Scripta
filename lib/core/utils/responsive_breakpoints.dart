import 'package:flutter/material.dart';
import '../constants/app_constants.dart';

enum DeviceScreenType {
  mobile,
  tablet,
  desktop,
}

class ResponsiveBreakpoints {
  static DeviceScreenType getScreenType(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width >= AppConstants.tabletBreakpoint) {
      return DeviceScreenType.desktop;
    } else if (width >= AppConstants.mobileBreakpoint) {
      return DeviceScreenType.tablet;
    } else {
      return DeviceScreenType.mobile;
    }
  }

  static bool isDesktop(BuildContext context) =>
      getScreenType(context) == DeviceScreenType.desktop;
}
