import 'package:flutter/material.dart';

import 'tokens.dart';

/// Clinical teal with amber and signal colours. Built by hand rather than from
/// a seed colour so no purple tints creep in.
const _light = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFF0D6E76),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFD3ECEC),
  onPrimaryContainer: Color(0xFF053A3F),
  secondary: Color(0xFF9A5E0B),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFFBEFD9),
  onSecondaryContainer: Color(0xFF4A2C00),
  tertiary: Color(0xFF2F7336),
  onTertiary: Color(0xFFFFFFFF),
  tertiaryContainer: Color(0xFFE3F0E1),
  onTertiaryContainer: Color(0xFF0E3A14),
  error: Color(0xFFB33A27),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFFCE6E1),
  onErrorContainer: Color(0xFF5C150A),
  surface: Color(0xFFFFFFFF),
  onSurface: Color(0xFF17232B),
  surfaceDim: Color(0xFFE2E8E9),
  surfaceBright: Color(0xFFFFFFFF),
  surfaceContainerLowest: Color(0xFFFFFFFF),
  surfaceContainerLow: Color(0xFFF7F9F9),
  surfaceContainer: Color(0xFFF0F4F4),
  surfaceContainerHigh: Color(0xFFE9EEEF),
  surfaceContainerHighest: Color(0xFFE1E7E8),
  onSurfaceVariant: Color(0xFF56646C),
  outline: Color(0xFF7E8D95),
  outlineVariant: Color(0xFFCBD4D6),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
  inverseSurface: Color(0xFF26333A),
  onInverseSurface: Color(0xFFEDF2F3),
  inversePrimary: Color(0xFF4FC1C8),
  surfaceTint: Color(0x00000000),
);

const _dark = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFF4FC1C8),
  onPrimary: Color(0xFF00363A),
  primaryContainer: Color(0xFF12454A),
  onPrimaryContainer: Color(0xFFBDEDEF),
  secondary: Color(0xFFE4A94F),
  onSecondary: Color(0xFF3D2500),
  secondaryContainer: Color(0xFF36280F),
  onSecondaryContainer: Color(0xFFF7DDB4),
  tertiary: Color(0xFF7FC884),
  onTertiary: Color(0xFF0B3911),
  tertiaryContainer: Color(0xFF18301B),
  onTertiaryContainer: Color(0xFFCBEFCD),
  error: Color(0xFFF0816D),
  onError: Color(0xFF4A0F05),
  errorContainer: Color(0xFF3A1D18),
  onErrorContainer: Color(0xFFFFD9D2),
  surface: Color(0xFF161E23),
  onSurface: Color(0xFFE3E9EC),
  surfaceDim: Color(0xFF0F1519),
  surfaceBright: Color(0xFF2B363C),
  surfaceContainerLowest: Color(0xFF0F1519),
  surfaceContainerLow: Color(0xFF131A1E),
  surfaceContainer: Color(0xFF1C262C),
  surfaceContainerHigh: Color(0xFF222D33),
  surfaceContainerHighest: Color(0xFF29353C),
  onSurfaceVariant: Color(0xFF97A5AD),
  outline: Color(0xFF6B7B84),
  outlineVariant: Color(0xFF2E3A41),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
  inverseSurface: Color(0xFFE3E9EC),
  onInverseSurface: Color(0xFF1C262C),
  inversePrimary: Color(0xFF0D6E76),
  surfaceTint: Color(0x00000000),
);

ThemeData buildTheme(Brightness brightness) {
  final cs = brightness == Brightness.light ? _light : _dark;
  final base = ThemeData(useMaterial3: true, colorScheme: cs, visualDensity: VisualDensity.adaptivePlatformDensity);
  final text = base.textTheme;
  final scaffold = brightness == Brightness.light ? const Color(0xFFF3F6F5) : const Color(0xFF0F1519);
  final radius = BorderRadius.circular(Radii.md);

  return base.copyWith(
    scaffoldBackgroundColor: scaffold,
    textTheme: text.copyWith(
      headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.4),
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scaffold,
      surfaceTintColor: Colors.transparent,
      foregroundColor: cs.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface),
    ),
    cardTheme: CardThemeData(
      color: cs.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
        side: BorderSide(color: cs.outlineVariant),
      ),
    ),
    dividerTheme: DividerThemeData(color: cs.outlineVariant, thickness: 1, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: brightness == Brightness.light ? cs.surface : cs.surfaceContainer,
      border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: cs.outlineVariant)),
      enabledBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: cs.outlineVariant)),
      focusedBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: cs.primary, width: 1.6)),
      errorBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: cs.error)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: TextStyle(color: cs.onSurfaceVariant),
      helperMaxLines: 2,
      errorMaxLines: 2,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: radius),
        side: BorderSide(color: cs.outlineVariant),
        foregroundColor: cs.onSurface,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 44),
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(minimumSize: const Size(44, 44))),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        minimumSize: const Size(0, 40),
        side: BorderSide(color: cs.outlineVariant),
        selectedBackgroundColor: cs.primaryContainer,
        selectedForegroundColor: cs.onPrimaryContainer,
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      side: BorderSide(color: cs.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.sm)),
      selectedColor: cs.primaryContainer,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.xl)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl))),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: cs.primaryContainer,
      height: 68,
      labelTextStyle: WidgetStatePropertyAll(text.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: cs.surface,
      indicatorColor: cs.primaryContainer,
      selectedIconTheme: IconThemeData(color: cs.onPrimaryContainer),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: radius),
      iconColor: cs.onSurfaceVariant,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(color: cs.inverseSurface, borderRadius: BorderRadius.circular(Radii.sm)),
      textStyle: TextStyle(color: cs.onInverseSurface, fontSize: 12),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: cs.inverseSurface,
      contentTextStyle: TextStyle(color: cs.onInverseSurface),
      shape: RoundedRectangleBorder(borderRadius: radius),
    ),
    scrollbarTheme: ScrollbarThemeData(
      radius: const Radius.circular(8),
      thickness: const WidgetStatePropertyAll(8),
      thumbColor: WidgetStatePropertyAll(cs.outline.withValues(alpha: 0.5)),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: cs.primary,
      unselectedLabelColor: cs.onSurfaceVariant,
      indicatorColor: cs.primary,
      dividerColor: cs.outlineVariant,
      labelStyle: text.titleSmall,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: cs.primary),
  );
}
