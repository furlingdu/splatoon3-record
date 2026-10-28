import 'package:flutter/widgets.dart';

abstract final class AppLayout {
  static const double CompactWidth = 640;
  static const double WideWidth = 840;

  static double Width(BuildContext Context) => MediaQuery.sizeOf(Context).width;

  static bool Compact(BuildContext Context) => Width(Context) < CompactWidth;

  static bool Wide(BuildContext Context) => Width(Context) >= WideWidth;

  static bool Tablet(BuildContext Context) => MediaQuery.sizeOf(Context).shortestSide >= 600;

  static double Padding(BuildContext Context) => Compact(Context) ? 16 : 28;

  static double DrawerWidth(BuildContext Context) {
    final Full = Width(Context);
    final Limit = Full * 0.88;
    return Limit < 360 ? Limit : 360;
  }
}
