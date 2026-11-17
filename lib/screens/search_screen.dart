import 'package:material_ui/material_ui.dart';

import '../db.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'chunk_screen.dart';
import 'timeline_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.db});

  final AppDb db;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  List<SearchHit>? _hits;

  void _open(SearchHit h) {
    final chunk = widget.db.chunk(h.chunkId);
    if (chunk == null) return;
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => ChunkScreen(db: widget.db, chunk: chunk, seekMs: h.startMs)));
  }

  @override
  Widget build(BuildContext context) {
    final hits = _hits;
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
          onSubmitted: (q) => setState(() => _hits = widget.db.search(q)),
        ),
        const SizedBox(height: 16),
        if (hits == null)
          const Text('Search everything that was transcribed.', style: TextStyles.body)
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
