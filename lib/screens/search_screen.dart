import 'package:material_ui/material_ui.dart';

import '../db.dart';
import '../ui/format.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'conversation_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.db, required this.transcriber});

  final AppDb db;
  final Listenable transcriber;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  List<SearchHit>? _hits;
  String _query = '';
  String? _person; // null = everyone

  void _search() => setState(() => _hits = widget.db.search(_query, speaker: _person));

  void _open(SearchHit h) => openConversationAt(context, widget.db, widget.transcriber, h.chunkId, h.startMs);

  @override
  Widget build(BuildContext context) {
    final hits = _hits;
    final people = widget.db.people();
    return ScreenFrame(
      title: 'Search',
      wash: headerBlue,
      children: [
        const SizedBox(height: 16),
        const Text('Find anything', style: TextStyles.display),
        const SizedBox(height: 16),
        PillInput(
          hint: 'Words, people, topics',
          icon: Icons.search_rounded,
          autofocus: true,
          onSubmitted: (q) {
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
                Text(h.snippet, style: TextStyles.body.copyWith(color: Palette.textHi)),
                const SizedBox(height: 4),
                Text('${h.speaker ?? 'Unknown'} · ${formatDuration(h.startMs)}', style: TextStyles.caption),
              ]),
            ),
      ],
    );
  }
}
