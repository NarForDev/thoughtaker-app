import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// Gradient card with a gradient rim and a coloured glow. No BackdropFilter: over black there is nothing to blur.
class GlowCard extends StatelessWidget {
  const GlowCard(
      {super.key,
      required this.glow,
      required this.child,
      this.radius = 36,
      this.padding = const EdgeInsets.all(20),
      this.onTap});

  final Glow glow;
  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final inner = BorderRadius.circular(radius - glow.rimWidth);
    final card = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: glow.rim),
        boxShadow: glow.shadows,
      ),
      child: Padding(
        padding: EdgeInsets.all(glow.rimWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(borderRadius: inner, gradient: glow.fill),
          child: DecoratedBox(
            decoration: BoxDecoration(borderRadius: inner, gradient: glow.sheen),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
    final tap = onTap;
    return tap == null ? card : _Pressable(onTap: tap, child: card);
  }
}

/// Small card: [label] on top, [child] at the bottom.
class Tile extends StatelessWidget {
  const Tile({super.key, required this.label, required this.child, this.glow = tilePlain, this.onTap});

  final String label;
  final Widget child;
  final Glow glow;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => GlowCard(
        glow: glow,
        radius: 24,
        padding: const EdgeInsets.all(16),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [Text(label, style: TextStyles.label), const SizedBox(height: 12), child],
          ),
        ),
      );
}

/// Labelled on/off pill. A null [onChanged] disables it.
class PillToggle extends StatelessWidget {
  const PillToggle({super.key, required this.label, required this.value, this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    const motion = Duration(milliseconds: 180);
    final change = onChanged;
    return MergeSemantics(
      child: Semantics(
        toggled: value,
        enabled: change != null,
        child: GestureDetector(
          onTap: change == null ? null : () => change(!value),
          child: Opacity(
            opacity: change == null ? 0.4 : 1,
            child: Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(color: Palette.surfaceHigh, borderRadius: BorderRadius.circular(999)),
              child: Row(children: [
                Expanded(child: Text(label, style: TextStyles.label)),
                AnimatedContainer(
                  duration: motion,
                  curve: Curves.easeOutCubic,
                  width: 44,
                  height: 26,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: value ? const Color(0xE6F4F4F6) : const Color(0xFF3A3A3E), // on: textHi at 90%
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: AnimatedAlign(
                    duration: motion,
                    curve: Curves.easeOutCubic,
                    alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration:
                          BoxDecoration(color: value ? Palette.bg : Palette.textHi, shape: BoxShape.circle),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Press feedback without ink: scales to 0.98.
class _Pressable extends StatefulWidget {
  const _Pressable({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;

  void _press(bool down) => setState(() => _down = down);

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: GestureDetector(
          onTapDown: (_) => _press(true),
          onTapUp: (_) => _press(false),
          onTapCancel: () => _press(false),
          onTap: widget.onTap,
          child: AnimatedScale(
              scale: _down ? 0.98 : 1, duration: const Duration(milliseconds: 120), child: widget.child),
        ),
      );
}
