/// The app's forced-dark Claude palette, written as Material 3 meant
/// it to be written: one brand seed, HCT tonal palettes, and the
/// spec's tone table — not a hand-picked hex per role.
///
/// +292 (the M3 study): the old file pinned ~15 of the scheme's 45
/// roles by eye and left the rest at fromSeed defaults — which is how
/// the surface container ladder ended up with two identical rungs
/// (High == Highest), no Low at all, no error, no fixed, no inverse,
/// and orphan literals (the latency strip's green, the cone's white)
/// doing roles' jobs off the books. M3's answer is arithmetic, not
/// taste: every role is a TONE (lightness) from a tonal palette
/// (brand hue, tuned chroma), and the tone table encodes the role's
/// JOB — containers step 2→18 for elevation, on-colors sit at tone
/// 90 over containers at 30 so contrast is a property, not a hope.
/// The numbers below are that table; `Hct.from(hue, chroma, tone)`
/// (material_color_utilities — Google's reference implementation,
/// the same math Material Theme Builder exports from) resolves them
/// in the perceptual color space the spec is defined in.
///
/// Deliberate overrides, still Claude's law: the canvas is pure
/// black (Claude Code's, not M3's tone-6 grey — mimicry is the
/// point), the primary is the EXACT #D97757 brand (a scheme may tune
/// its seed's tone and chroma; the fidelity variants' whole reason
/// to exist is refusing to), and the on-colors of saturated fills
/// stay black (the spec's tone-20 reads muddy under this orange).
/// System light mode is still refused (the library comment that
/// predates tabs, unchanged): the palette is this app's face.
///
/// The one extended color the UI actually uses — the latency
/// strip's completion green — rides a ThemeExtension, per M3's
/// guidance, instead of a literal off-palette.
library;

import 'package:flutter/material.dart';
import 'package:material_color_utilities/hct/hct.dart';

/// The brand seed: Claude orange. Its HCT hue inked (chroma and tone
/// are recomputed per role from the table below; the exact seed
/// stands as `primary`).
const Color _seedColor = Color(0xFFD97757);

/// M3's extended green — 'a hop completed' on the latency strip.
/// Hue 145 (the family Colors.green lived in), chroma and tone from
/// the dark-theme success spot (T50-ish, readable on black without
/// the literal's acid glare).
const Color _successColor = Color.fromARGB(255, 95, 173, 86);

/// M3's error family: red lives at HCT hue ~27, not the sRGB 0° the
/// old literal guessed at.
const double _errorHue = 27;

ThemeData buildClaudeDarkTheme() {
  final seed = Hct.fromInt(_seedColor.toARGB32());
  final h = seed.hue;
  // The app is black-and-orange: neutrals carry the seed's hue at
  // whisper chroma (the warm greys the field already knows — the
  // old 0xFF7A6F63 outline was HCT(24, 6, 50) within a hair).
  Color tinted(double chroma, double tone, [double dHue = 0]) =>
      Color(Hct.from(h + dHue, chroma, tone).toInt());
  Color red(double chroma, double tone) =>
      Color(Hct.from(_errorHue, chroma, tone).toInt());
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    extensions: const [AppExtendedColors(success: _successColor)],
    colorScheme: ColorScheme(
      brightness: Brightness.dark,
      // ── Primary: the brand, pinned, with its spec family ──────
      primary: _seedColor,
      onPrimary: Colors.black, // pinned (spec: tone 20)
      primaryContainer: tinted(40, 30),
      onPrimaryContainer: tinted(22, 90),
      primaryFixed: tinted(22, 90),
      primaryFixedDim: tinted(30, 80),
      onPrimaryFixed: tinted(40, 10),
      onPrimaryFixedVariant: tinted(40, 30),
      // ── Secondary: quiet parts of the UI (chips, the file slip's
      // accents) — same hue, drained of shouting ─────────────────
      secondary: tinted(9, 82),
      onSecondary: Colors.black, // pinned (spec: tone 20)
      secondaryContainer: tinted(9, 30),
      onSecondaryContainer: tinted(5, 90),
      secondaryFixed: tinted(5, 90),
      secondaryFixedDim: tinted(6, 80),
      onSecondaryFixed: tinted(9, 10),
      onSecondaryFixedVariant: tinted(9, 30),
      // ── Tertiary: the listening glyph's cousin — the old law
      // ('must not drift off-hue') honored: a depth-shifted twin,
      // now with the containers the role was supposed to have ────
      tertiary: tinted(24, 68), // ≈ the old hand-picked 0xFFC97A55
      onTertiary: Colors.black, // pinned
      tertiaryContainer: tinted(24, 30),
      onTertiaryContainer: tinted(14, 90),
      tertiaryFixed: tinted(14, 90),
      tertiaryFixedDim: tinted(18, 80),
      onTertiaryFixed: tinted(24, 10),
      onTertiaryFixedVariant: tinted(24, 30),
      // ── Error: the roles the file only had as a `red` parameter ─
      error: red(46, 80),
      onError: red(46, 20),
      errorContainer: red(40, 30),
      onErrorContainer: red(30, 90),
      // ── Surfaces: the canvas law (pure black) plus the full
      // container ladder the old scheme half-skipped ──────────────
      surface: Colors.black, // pinned override (spec: tone 6)
      onSurface: tinted(2, 93), // the warm near-white, kept
      surfaceDim: Colors.black,
      surfaceBright: tinted(3, 30),
      surfaceContainerLowest: tinted(3, 2),
      surfaceContainerLow: tinted(3, 5),
      surfaceContainer: tinted(3, 8), // ≈ the old 0xFF14110E
      surfaceContainerHigh: tinted(3, 12), // ≈ the old 0xFF1F1B16,
      surfaceContainerHighest: tinted(3, 16), //   and NO LONGER equal
      // (surfaceVariant retired with the container ladder — Flutter
      // maps the deprecated role onto surfaceContainerHighest; the
      // variant-toned field the old scheme wanted lives there now.)
      onSurfaceVariant: tinted(6, 76), // ≈ the old 0xFFB3AA9C
      // ── Lines, inverse (snackbars), and the shadows the overlays
      // were hand-rolling alphas for ──────────────────────────────
      outline: tinted(6, 50), // ≈ the old 0xFF7A6F63
      outlineVariant: tinted(6, 24), // ≈ the old 0xFF3A342C
      inverseSurface: tinted(2, 90),
      onInverseSurface: tinted(2, 20),
      inversePrimary: tinted(40, 40),
      shadow: Colors.black,
      scrim: Colors.black,
    ),
  );
}

/// +292: M3's extended colors ride a ThemeExtension — a role the base
/// scheme does not define (success) gets an owner instead of a
/// literal. Ask with [AppExtended.success]; the fallback keeps a
/// rogue bare ThemeData honest.
@immutable
class AppExtendedColors extends ThemeExtension<AppExtendedColors> {
  const AppExtendedColors({required this.success});

  final Color success;

  @override
  AppExtendedColors copyWith({Color? success}) =>
      AppExtendedColors(success: success ?? this.success);

  @override
  AppExtendedColors lerp(AppExtendedColors? other, double t) =>
      AppExtendedColors(
        success: Color.lerp(success, other?.success ?? success, t)!,
      );
}

/// The extension's one-hand pickup: every widget asks this way and
/// nobody reaches for Colors.green again.
extension AppExtended on BuildContext {
  Color get success =>
      Theme.of(this).extension<AppExtendedColors>()?.success ??
      const Color(0xFF4CAF50);
}
