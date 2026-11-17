import 'package:material_ui/material_ui.dart';

// "Glow on Black": dark only, near-black ground, one coloured glow per screen.
// Colours and text styles live in classes so widget fields named label/title/body cannot shadow them.
abstract final class Palette {
  static const bg = Color(0xFF050507);
  static const surface = Color(0xFF161618);
  static const surfaceTop = Color(0xFF232326);
  static const surfaceHigh = Color(0xFF26262A);
  static const stroke = Color(0x12FFFFFF); // 7% white hairline
  static const textHi = Color(0xFFF4F4F6);
  static const textMid = Color(0xFFA2A2AB);
  static const textLo = Color(0xFF62626B); // ~3.9:1 on bg: captions only, never actionable text
  static const signal = Color(0xFFD6F45B); // "live / now / active" only
  static const danger = Color(0xFFFF6A3D);
}

abstract final class TextStyles {
  static const display =
      TextStyle(fontSize: 34, height: 1.12, fontWeight: FontWeight.w500, letterSpacing: -0.8, color: Palette.textHi);
  static const title = TextStyle(fontSize: 20, fontWeight: FontWeight.w500, letterSpacing: -0.3, color: Palette.textHi);
  static const body = TextStyle(fontSize: 15, height: 1.4, color: Palette.textMid);
  static const label = TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Palette.textHi);
  static const caption = TextStyle(fontSize: 11, letterSpacing: 0.2, color: Palette.textLo);
}

/// A card's look: gradient [fill], optional top [sheen], a [rim] gradient border of [rimWidth], and its glow [shadows].
typedef Glow = ({Gradient fill, Gradient? sheen, List<Color> rim, double rimWidth, List<BoxShadow> shadows});

const Glow glowMagenta = (
  fill: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFC46FD0), Color(0xFFA43FA8), Color(0xFF7A1F7E)],
      stops: [0, 0.45, 1]),
  sheen: RadialGradient(center: Alignment(0, -0.6), radius: 0.9, colors: [Color(0x38FFFFFF), Color(0x00FFFFFF)]),
  rim: [Color(0x66FFFFFF), Color(0x00FFFFFF)],
  rimWidth: 1.5,
  shadows: [BoxShadow(color: Color(0x73B044B8), blurRadius: 48, spreadRadius: -8, offset: Offset(0, 12))],
);

const Glow glowEmber = (
  fill: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFF2A1210), Color(0xFF7E2417), Color(0xFFE0532C), Color(0xFFFF7A45)],
      stops: [0, 0.45, 0.85, 1]),
  sheen: null,
  rim: [Color(0x4DFFB59A), Color(0x00FFB59A)],
  rimWidth: 1,
  shadows: [BoxShadow(color: Color(0x59E0532C), blurRadius: 28, spreadRadius: -8, offset: Offset(0, 8))],
);

/// Plain tile: surface gradient, hairline rim, no glow (glows are never put on ordinary tiles).
const Glow tilePlain = (
  fill: LinearGradient(
      begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Palette.surfaceTop, Palette.surface]),
  sheen: null,
  rim: [Palette.stroke, Color(0x00FFFFFF)],
  rimWidth: 1,
  shadows: [],
);

/// Full-bleed wash behind the top of Home.
const headerViolet = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0xFF8E63D9), Color(0xFF5B3A9E), Color(0xFF24183F), Palette.bg],
  stops: [0, 0.28, 0.55, 0.85],
);

final appTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: Palette.bg,
  fontFamily: 'Inter',
  splashFactory: NoSplash.splashFactory,
  highlightColor: Colors.transparent,
  colorScheme: const ColorScheme.dark(
    surface: Palette.bg,
    primary: Palette.textHi,
    onPrimary: Palette.bg,
    secondary: Palette.signal,
    error: Palette.danger,
  ),
  textSelectionTheme: const TextSelectionThemeData(cursorColor: Palette.signal),
  pageTransitionsTheme: const PageTransitionsTheme(
      builders: {TargetPlatform.android: FadeForwardsPageTransitionsBuilder()}),
);
