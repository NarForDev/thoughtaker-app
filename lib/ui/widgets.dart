import 'package:flutter/services.dart' show SystemUiOverlayStyle;
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

/// 44 px round icon button; [light] is the white variant.
class CircleIconButton extends StatelessWidget {
  const CircleIconButton(
      {super.key, required this.icon, required this.tooltip, this.onPressed, this.light = false, this.size = 44});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool light;
  final double size;

  @override
  Widget build(BuildContext context) => _Pressable(
        onTap: onPressed,
        label: tooltip,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: light ? Palette.textHi : Palette.surfaceHigh,
            border: light ? null : Border.all(color: Palette.stroke),
          ),
          child: Icon(icon, size: size * 0.45, color: light ? Palette.bg : Palette.textHi),
        ),
      );
}

/// Pill-shaped button; replaces Filled/Outlined/TextButton.
class PillButton extends StatelessWidget {
  const PillButton({super.key, required this.label, this.onPressed, this.icon, this.light = false, this.danger = false});

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool light;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final fg = light ? Palette.bg : (danger ? Palette.danger : Palette.textHi);
    return _Pressable(
      onTap: onPressed,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: light ? Palette.textHi : Palette.surfaceHigh,
          borderRadius: BorderRadius.circular(999),
          border: light ? null : Border.all(color: danger ? Palette.danger : Palette.stroke),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 18, color: fg), const SizedBox(width: 8)],
          Text(label, style: TextStyles.label.copyWith(color: fg)),
        ]),
      ),
    );
  }
}

/// Borderless text field in a rounded box, like the reference's prompt input.
class PillInput extends StatelessWidget {
  const PillInput(
      {super.key, required this.hint, this.controller, this.onSubmitted, this.autofocus = false, this.icon});

  final String hint;
  final TextEditingController? controller;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: Palette.surfaceHigh,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Palette.stroke),
        ),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: autofocus,
              onSubmitted: onSubmitted,
              textInputAction: TextInputAction.search,
              style: TextStyles.body.copyWith(color: Palette.textHi),
              decoration: InputDecoration.collapsed(hintText: hint, hintStyle: TextStyles.body),
            ),
          ),
          if (icon != null) Icon(icon, size: 18, color: Palette.textMid),
        ]),
      );
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
        child: Row(children: [
          Expanded(child: Text(text, style: TextStyles.heading)),
          ?trailing,
        ]),
      );
}

/// Quiet text action, e.g. "All items" beside a section header.
class TextLink extends StatelessWidget {
  const TextLink(this.label, {super.key, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4), // 44 px tall hit area
            child: Text(label, style: TextStyles.label.copyWith(color: Palette.textMid)),
          ),
        ),
      );
}

/// A list row in tile style. [marked] draws the signal bar used for bookmarks.
class ListRow extends StatelessWidget {
  const ListRow({super.key, required this.child, this.onTap, this.onLongPress, this.marked = false, this.dim = false});

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool marked;
  final bool dim;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _Pressable(
          onTap: onTap,
          onLongPress: onLongPress,
          dimWhenDisabled: false,
          child: Opacity(
            opacity: dim ? 0.5 : 1,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Palette.surfaceTop, Palette.surface]),
                borderRadius: BorderRadius.circular(20),
                border: Border(
                  left: BorderSide(color: marked ? Palette.signal : Palette.stroke, width: marked ? 3 : 1),
                  top: const BorderSide(color: Palette.stroke),
                ),
              ),
              child: child,
            ),
          ),
        ),
      );
}

/// Blue glowing panel docked at the bottom of a screen.
class ControlPanel extends StatelessWidget {
  const ControlPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: GlowCard(glow: glowBlue, radius: 32, padding: const EdgeInsets.all(16), child: child),
      );
}

/// Every screen: header wash, circle back button (not on tabs), centred title, scrolling [children], optional
/// bottom [panel]. [onRefresh] adds pull down to sync.
class ScreenFrame extends StatelessWidget {
  const ScreenFrame(
      {super.key,
      required this.title,
      required this.children,
      this.action,
      this.wash,
      this.panel,
      this.controller,
      this.showBack = true,
      this.onRefresh});

  final String title;
  final List<Widget> children;
  final Widget? action;
  final Gradient? wash;
  final Widget? panel;
  final ScrollController? controller;
  final bool showBack;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          body: Stack(children: [
            if (wash != null)
              Container(height: MediaQuery.sizeOf(context).height * 0.3, decoration: BoxDecoration(gradient: wash)),
            SafeArea(
              bottom: panel == null,
              child: Column(children: [
                SizedBox(
                  height: 56,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(children: [
                      if (showBack)
                        CircleIconButton(
                            icon: Icons.arrow_back_rounded,
                            tooltip: 'Back',
                            onPressed: () => Navigator.of(context).maybePop())
                      else
                        const SizedBox(width: 44),
                      Expanded(child: Text(title, textAlign: TextAlign.center, style: TextStyles.title)),
                      action ?? const SizedBox(width: 44),
                    ]),
                  ),
                ),
                Expanded(child: refreshable(onRefresh, ListView(
                    controller: controller,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: children))),
                ?panel,
              ]),
            ),
          ]),
        ),
      );
}

/// Pull down to run [onRefresh], in the app's colours; [list] as it is when null.
Widget refreshable(Future<void> Function()? onRefresh, Widget list) => onRefresh == null
    ? list
    : RefreshIndicator(onRefresh: onRefresh, color: Palette.textHi, backgroundColor: Palette.surfaceHigh, child: list);

/// Bottom sheet in the app's style; returns true when [confirm] is tapped.
Future<bool> confirmSheet(BuildContext context, {required String title, required String body, required String confirm}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Palette.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyles.title),
          const SizedBox(height: 8),
          Text(body, style: TextStyles.body),
          const SizedBox(height: 24),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            PillButton(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
            const SizedBox(width: 8),
            PillButton(label: confirm, danger: true, onPressed: () => Navigator.pop(context, true)),
          ]),
        ]),
      ),
    ),
  );
  return ok ?? false;
}

/// Press feedback without ink: scales to 0.98. A null [onTap] dims it.
class _Pressable extends StatefulWidget {
  const _Pressable({required this.onTap, required this.child, this.onLongPress, this.label, this.dimWhenDisabled = true});

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? label;
  final bool dimWhenDisabled;
  final Widget child;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;

  void _press(bool down) => setState(() => _down = down);

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: GestureDetector(
        onTapDown: enabled ? (_) => _press(true) : null,
        onTapUp: enabled ? (_) => _press(false) : null,
        onTapCancel: enabled ? () => _press(false) : null,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: Opacity(
          opacity: enabled || !widget.dimWhenDisabled ? 1 : 0.4,
          child: AnimatedScale(
              scale: _down ? 0.98 : 1, duration: const Duration(milliseconds: 120), child: widget.child),
        ),
      ),
    );
  }
}
