import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// 5x7 dot glyphs, one 5-bit row each, most significant bit on the left. Unknown characters draw as a space.
const dotMatrixGlyphs = <String, List<int>>{
  '0': [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E],
  '1': [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
  '2': [0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F],
  '3': [0x1E, 0x01, 0x01, 0x0E, 0x01, 0x01, 0x1E],
  '4': [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
  '5': [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
  '6': [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E],
  '7': [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
  '8': [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
  '9': [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
  '.': [0, 0, 0, 0, 0, 0x0C, 0x0C],
  ':': [0, 0x0C, 0x0C, 0, 0x0C, 0x0C, 0],
  '-': [0, 0, 0, 0x1F, 0, 0, 0],
  '%': [0x18, 0x19, 0x02, 0x04, 0x08, 0x13, 0x03],
  ' ': [0, 0, 0, 0, 0, 0, 0],
};

/// Hero numerals drawn as dots, no font. Screen readers get [text].
class DotMatrixText extends StatelessWidget {
  const DotMatrixText(this.text, {super.key, this.height = 44});

  final String text;
  final double height;

  @override
  Widget build(BuildContext context) => Semantics(
        label: text,
        child: CustomPaint(
            size: Size((text.length * 6 - 1).clamp(0, 1 << 20) * height / 7, height), painter: _DotMatrixPainter(text)),
      );
}

class _DotMatrixPainter extends CustomPainter {
  _DotMatrixPainter(this.text);

  final String text;

  @override
  void paint(Canvas canvas, Size size) {
    final pitch = size.height / 7;
    final paint = Paint()..color = Palette.textHi;
    for (var i = 0; i < text.length; i++) {
      final rows = dotMatrixGlyphs[text[i]] ?? dotMatrixGlyphs[' ']!;
      for (var r = 0; r < 7; r++) {
        for (var c = 0; c < 5; c++) {
          if ((rows[r] >> (4 - c)) & 1 == 1) {
            canvas.drawCircle(Offset((i * 6 + c + 0.5) * pitch, (r + 0.5) * pitch), pitch * 0.32, paint);
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(_DotMatrixPainter old) => old.text != text;
}

/// Progress as a row of dots with a signal tick at [value] (0..1). Null = unknown: dim dots, no tick.
class DottedTrack extends StatelessWidget {
  const DottedTrack({super.key, this.value});

  final double? value;

  @override
  Widget build(BuildContext context) {
    final v = value;
    // Explicit height so the track reports its intrinsic height inside IntrinsicHeight rows.
    return Semantics(
      value: v == null ? null : '${(v * 100).round()}%',
      child: SizedBox(height: 14, width: double.infinity, child: CustomPaint(painter: _DottedTrackPainter(v))),
    );
  }
}

class _DottedTrackPainter extends CustomPainter {
  _DottedTrackPainter(this.value);

  final double? value;

  @override
  void paint(Canvas canvas, Size size) {
    const pitch = 6.0;
    final v = value?.clamp(0.0, 1.0);
    final n = (size.width / pitch).floor();
    final lit = Paint()..color = const Color(0xB3F4F4F6); // textHi at 70%
    final dim = Paint()..color = Palette.textLo;
    for (var i = 0; i < n; i++) {
      final done = v != null && (i + 0.5) * pitch <= v * size.width;
      canvas.drawCircle(Offset((i + 0.5) * pitch, size.height / 2), 1.5, done ? lit : dim);
    }
    if (v != null) {
      canvas.drawRect(Rect.fromCenter(center: Offset(v * size.width, size.height / 2), width: 2, height: size.height),
          Paint()..color = Palette.signal);
    }
  }

  @override
  bool shouldRepaint(_DottedTrackPainter old) => old.value != value;
}
