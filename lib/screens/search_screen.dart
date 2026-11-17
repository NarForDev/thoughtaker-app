import 'package:material_ui/material_ui.dart';

import '../db.dart';
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

  @override
  Widget build(BuildContext context) {
    final hits = _hits;
    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Words, people, topics',
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.search,
            onSubmitted: (q) => setState(() => _hits = widget.db.search(q)),
          ),
        ),
        Expanded(
          child: hits == null
              ? const Center(child: Text('Search everything that was transcribed.'))
              : hits.isEmpty
                  ? const Center(child: Text('No matches. Transcripts appear here once transcription runs.'))
                  : ListView(children: [
                      for (final h in hits)
                        ListTile(
                          title: Text(h.snippet),
                          subtitle: Text('${h.speaker ?? 'Unknown'} · ${formatDuration(h.startMs)}'),
                          onTap: () {
                            final chunk = widget.db.chunk(h.chunkId);
                            if (chunk == null) return;
                            Navigator.of(context).push(MaterialPageRoute<void>(
                                builder: (_) => ChunkScreen(db: widget.db, chunk: chunk, seekMs: h.startMs)));
                          },
                        ),
                    ]),
        ),
      ]),
    );
  }
}
