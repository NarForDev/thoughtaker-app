import 'package:material_ui/material_ui.dart';

import '../services.dart';
import '../ui/theme.dart';
import 'home_screen.dart';
import 'items_screen.dart';
import 'search_screen.dart';
import 'timeline_screen.dart';

const _tabs = [
  (Icons.wb_twilight_rounded, 'Today'),
  (Icons.view_timeline_rounded, 'Timeline'),
  (Icons.checklist_rounded, 'To-dos'),
  (Icons.search_rounded, 'Search'),
];

/// The four places you go most, behind a bottom bar like most phone apps. Back on another tab returns to Today.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.s});

  final Services s;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;
  bool _searchOpened = false; // Search keeps its query and results once opened

  void _go(int tab) {
    FocusManager.instance.primaryFocus?.unfocus(); // the keyboard does not follow you to another tab
    setState(() {
      _tab = tab;
      _searchOpened |= tab == 3;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final typing = MediaQuery.viewInsetsOf(context).bottom > 0;
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _go(0);
      },
      child: Scaffold(
        body: Column(children: [
          Expanded(
            // The shell already makes room for the bar and the keyboard; the tabs must not do it again.
            // One MediaQuery: nested remove* helpers each rebuild from the outer data and undo each other.
            child: MediaQuery(
              data: MediaQuery.of(context).removePadding(removeBottom: true).removeViewInsets(removeBottom: true),
              child: IndexedStack(index: _tab, children: [
                HomeScreen(s: s, openTab: _go),
                TimelineScreen(s: s, showBack: false),
                ItemsScreen(s: s, showBack: false),
                // Built once first opened, so its field does not grab the keyboard at launch.
                if (_searchOpened) SearchScreen(s: s, showBack: false) else const SizedBox.shrink(),
              ]),
            ),
          ),
          if (!typing) _NavBar(tab: _tab, onTap: _go), // hidden while typing, as in most apps
        ]),
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  const _NavBar({required this.tab, required this.onTap});

  final int tab;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Container(
          height: 64,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Palette.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Palette.stroke),
          ),
          child: Row(children: [
            for (final (i, (icon, label)) in _tabs.indexed)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: i == tab,
                  label: label,
                  excludeSemantics: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onTap(i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      decoration: BoxDecoration(
                          color: i == tab ? Palette.textHi : Colors.transparent, borderRadius: BorderRadius.circular(999)),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(icon, size: 20, color: i == tab ? Palette.bg : Palette.textMid),
                        const SizedBox(height: 2),
                        Text(label,
                            style: TextStyles.caption.copyWith(color: i == tab ? Palette.bg : Palette.textMid)),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      );
}
