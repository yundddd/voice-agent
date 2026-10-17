/// The app's forced-dark Claude palette: pure-black canvas with the
/// #D97757 Claude orange as the accent (same family as the chat
/// window's harness spinner). The mimicry is the point, so system light
/// mode must not wash it back to Material default.
///
/// `fromSeed` tonally shifts the seed, so its `primary` would be a
/// pastel wash of orange rather than the real #D97757. The roles the UI
/// actually draws (primary/onPrimary for buttons and the mic, tertiary
/// for the listening glyph, the warm greys for chips, borders and
/// secondary text) are pinned to hand-picked Claude Code values
/// instead: black canvas, true Claude orange, warm-neutral ink.
library;

import 'package:flutter/material.dart';

ThemeData buildClaudeDarkTheme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFFD97757),
    brightness: Brightness.dark,
  ).copyWith(
    surface: Colors.black, // scaffold, appbar, dialogs
    onSurface: const Color(0xFFF0EDE6), // warm near-white
    primary: const Color(0xFFD97757), // official Claude orange
    onPrimary: Colors.black,
    primaryContainer: const Color(0xFF41231A),
    onPrimaryContainer: const Color(0xFFF2B89B),
    secondary: const Color(0xFFE0A183),
    onSecondary: Colors.black,
    secondaryContainer: const Color(0xFF5A3427),
    onSecondaryContainer: const Color(0xFFF2B89B),
    // Same orange family (dusty copper): the app is black-and-
    // orange, so the listening indicator must not drift off-hue.
    tertiary: const Color(0xFFC97A55),
    onTertiary: Colors.black,
    surfaceContainer: const Color(0xFF14110E),
    surfaceContainerHigh: const Color(0xFF1F1B16),
    surfaceContainerHighest: const Color(0xFF1F1B16),
    outline: const Color(0xFF7A6F63), // warm grey text/borders
    outlineVariant: const Color(0xFF3A342C),
    onSurfaceVariant: const Color(0xFFB3AA9C),
  ),
);
