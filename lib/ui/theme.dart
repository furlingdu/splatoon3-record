import 'package:flutter/material.dart';

class AppTheme {
  static const Color Seed = Color(0xff4285f4);
  static const Color Ink = Color(0xff141218);
  static Color ChromeColor(BuildContext Context, {bool Soft = false}) {
    return ChromeFor(Theme.of(Context).colorScheme, Soft: Soft);
  }

  static Color ChromeFor(ColorScheme Scheme, {bool Soft = false}) {
    final Tint = Scheme.primary.withValues(alpha: Soft ? 0.28 : 0.36);
    final Base = Color.alphaBlend(Tint, const Color(0xff17161d));
    return Base.withValues(alpha: Soft ? 0.64 : 0.80);
  }
  static const List<String> FontFallback = <String>[
    'SplatoonZhL1',
    'SplatoonZhL2',
    'SplatoonCjk',
    'SplatoonKana',
    'SplatoonSymbol',
    'Microsoft YaHei',
    'PingFang SC',
    'Segoe UI',
  ];

  static TextStyle Style({
    double Size = 14,
    FontWeight Weight = FontWeight.w400,
    Color? ColorValue,
    double Height = 1.4,
    double Spacing = 0,
  }) {
    return TextStyle(
      fontFamily: 'Splatoon1',
      fontFamilyFallback: FontFallback,
      fontSize: Size,
      fontWeight: Weight,
      color: ColorValue,
      height: Height,
      letterSpacing: Spacing,
    );
  }

  static ThemeData Build(String ThemeColor) {
    final SeedColor = ParseColor(ThemeColor);
    final Scheme = ColorScheme.fromSeed(seedColor: SeedColor, brightness: Brightness.dark, dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot);
    final Base = ThemeData(useMaterial3: true, colorScheme: Scheme, brightness: Brightness.dark);
    final Text = Base.textTheme.apply(fontFamily: 'Splatoon1', fontFamilyFallback: FontFallback);
    return Base.copyWith(
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: Colors.transparent,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      dividerColor: Scheme.outlineVariant,
      textTheme: Text.copyWith(
        headlineSmall: Style(Size: 24, Weight: FontWeight.w400, ColorValue: Scheme.onSurface),
        titleMedium: Style(Size: 16, Weight: FontWeight.w500, ColorValue: Scheme.onSurface),
        bodyLarge: Style(Size: 16, ColorValue: Scheme.onSurface),
        bodyMedium: Style(Size: 14, ColorValue: Scheme.onSurface),
        bodySmall: Style(Size: 12, ColorValue: Scheme.onSurfaceVariant),
        labelLarge: Style(Size: 14, Weight: FontWeight.w500, ColorValue: Scheme.onSurface, Spacing: 0.1),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(Size(48, 40)),
          padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.symmetric(horizontal: 24)),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(StadiumBorder()),
          textStyle: WidgetStatePropertyAll<TextStyle>(Style(Size: 14, Weight: FontWeight.w500, ColorValue: Scheme.onPrimary)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(Size(48, 40)),
          padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.symmetric(horizontal: 12)),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(StadiumBorder()),
          textStyle: WidgetStatePropertyAll<TextStyle>(Style(Size: 14, Weight: FontWeight.w500, ColorValue: Scheme.primary)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: Scheme.primary)),
        labelStyle: Style(Size: 14, ColorValue: Scheme.onSurfaceVariant),
        hintStyle: Style(Size: 14, ColorValue: Scheme.onSurfaceVariant.withValues(alpha: 0.7)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        titleTextStyle: Style(Size: 24, ColorValue: Scheme.onSurface),
        contentTextStyle: Style(Size: 14, ColorValue: Scheme.onSurfaceVariant),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: Scheme.inverseSurface,
        contentTextStyle: Style(Size: 14, ColorValue: Scheme.onInverseSurface),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        elevation: 3,
        width: 420,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: Scheme.primary,
        inactiveTrackColor: Scheme.surfaceContainerHighest,
        thumbColor: Scheme.primary,
        overlayColor: Scheme.primary.withValues(alpha: 0.12),
        trackHeight: 4,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((States) => States.contains(WidgetState.selected) ? Scheme.onPrimary : Scheme.outline),
        trackColor: WidgetStateProperty.resolveWith((States) => States.contains(WidgetState.selected) ? Scheme.primary : Scheme.surfaceContainerHighest),
        trackOutlineColor: WidgetStatePropertyAll<Color>(Colors.transparent),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: Scheme.primary, linearTrackColor: Scheme.surfaceContainerHighest),
      iconTheme: IconThemeData(color: Scheme.onSurfaceVariant, size: 24),
    );
  }

  static Color ParseColor(String Value) {
    final Text = Value.trim();
    if (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(Text)) {
      return Color(int.parse('ff${Text.substring(1)}', radix: 16));
    }
    return Seed;
  }
}









