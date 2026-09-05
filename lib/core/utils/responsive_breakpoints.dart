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

  static bool isMobile(BuildContext context) =>
      getScreenType(context) == DeviceScreenType.mobile;

  static bool isTablet(BuildContext context) =>
      getScreenType(context) == DeviceScreenType.tablet;

  static bool isDesktop(BuildContext context) =>
      getScreenType(context) == DeviceScreenType.desktop;

  static bool isLandscape(BuildContext context) =>
      MediaQuery.of(context).orientation == Orientation.landscape;

  static bool isPortrait(BuildContext context) =>
      MediaQuery.of(context).orientation == Orientation.portrait;
}
