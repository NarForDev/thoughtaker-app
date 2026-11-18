import 'package:material_ui/material_ui.dart';

import '../db.dart';
import '../services.dart';
import '../ui/format.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'conversation_screen.dart';
import 'timeline_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.s, this.showBack = true});

  final Services s;
  final bool showBack;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  List<SearchHit>? _hits;
  String _query = '';
  String? _person; // null = everyone

  List<String> _days = []; // days whose summary or topics match

  void _search() => setState(() {
        _hits = _query.trim().isEmpty && _person == null ? null : widget.s.db.search(_query, speaker: _person);
        final words = _query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
        _days = _person != null || words.isEmpty
            ? []
            : [
                for (final MapEntry(key: day, value: v) in widget.s.db.summaries().entries)
                  if (words.every((w) => v.topics.any((t) => t.contains(w)) || v.text.toLowerCase().contains(w))) day,
              ]..sort((a, b) => b.compareTo(a));
      });

  /// When the line was said, rather than where it sits in its one-minute recording.
  String _saidAt(SearchHit h) {
    final start = widget.s.db.chunk(h.chunkId)?.startMs;
    if (start == null) return 'time unknown';
    final ms = start + h.startMs;
    return '${MaterialLocalizations.of(context).formatShortMonthDay(DateTime.fromMillisecondsSinceEpoch(ms))}, '
        '${clockTime(context, ms)}';
  }

  /// Matches come wrapped in char(2)…char(3): bright and bold, the rest dimmer. No marks means a person's whole
  /// line, shown bright.
  static TextSpan _highlight(String snippet) {
    final parts = snippet.split(RegExp(r'[\x02\x03]'));
    final hi = TextStyles.body.copyWith(color: Palette.textHi);
    return TextSpan(children: [
      for (final (i, p) in parts.indexed)
        TextSpan(
            text: p,
            style: parts.length == 1 ? hi : (i.isOdd ? hi.copyWith(fontWeight: FontWeight.w600) : TextStyles.body)),
    ]);
  }

  void _open(SearchHit h) => openConversationAt(context, widget.s, h.chunkId, h.startMs);

  @override
  Widget build(BuildContext context) {
    final hits = _hits;
    final people = widget.s.db.people();
    return ScreenFrame(
      title: 'Search',
      wash: headerBlue,
      showBack: widget.showBack,
      children: [
        const SizedBox(height: 16),
        const Text('Find anything', style: TextStyles.display),
        const SizedBox(height: 16),
        PillInput(
          hint: 'Words, people, topics',
          icon: Icons.search_rounded,
          autofocus: true,
          onChanged: (q) {
            _query = q;
            _search();
          },
        ),
        const SizedBox(height: 16),
        if (people.isNotEmpty) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final p in people)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: PillButton(
                    label: p,
                    light: _person == p,
                    onPressed: () {
                      _person = _person == p ? null : p;
                      _search();
                    },
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 16),
        ],
        for (final day in _days)
          ListRow(
            marked: true,
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => TimelineScreen(s: widget.s, day: day))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(MaterialLocalizations.of(context).formatFullDate(DateTime.parse(day)), style: TextStyles.label),
              const SizedBox(height: 4),
              Text(widget.s.db.summaries()[day]!.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyles.body),
            ]),
          ),
        if (hits == null)
          const Text('Search everything that was transcribed, or pick a person to see what they said.',
              style: TextStyles.body)
        else if (hits.isEmpty)
          const Text('No matches. Transcripts appear here once transcription runs.', style: TextStyles.body)
        else
          for (final h in hits)
            ListRow(
              onTap: () => _open(h),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text.rich(_highlight(h.snippet)),
                const SizedBox(height: 4),
                Text('${h.speaker ?? 'Someone'}, ${_saidAt(h)}', style: TextStyles.caption),
              ]),
            ),
      ],
    );
  }
}
