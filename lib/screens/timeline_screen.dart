import 'package:material_ui/material_ui.dart';

import '../db.dart';
import '../pendant.dart';
import '../ui/painters.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'chunk_screen.dart';

String formatDuration(int ms) {
  final s = ms ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Local clock time of an epoch [ms], in the device's 12/24 h format.
String clockTime(BuildContext context, int ms) =>
    MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(ms)));

/// Orders chunks newest first. A chunk with unknown time borrows the time of the nearest
/// known chunk of the same store (protocol 1.4), so it sits in the right place by seq.
List<(Chunk, int?)> placeChunks(List<Chunk> byStoreSeq) {
  final approx = [for (final c in byStoreSeq) c.startMs];
  for (var i = 1; i < approx.length; i++) {
    if (approx[i] == null && byStoreSeq[i].storeId == byStoreSeq[i - 1].storeId) approx[i] = approx[i - 1];
  }
  for (var i = approx.length - 2; i >= 0; i--) {
    if (approx[i] == null && byStoreSeq[i].storeId == byStoreSeq[i + 1].storeId) approx[i] = approx[i + 1];
  }
  final placed = [for (var i = 0; i < byStoreSeq.length; i++) (byStoreSeq[i], approx[i])];
  // List.sort is not stable, so break ties on the original order.
  final order = {for (var i = 0; i < placed.length; i++) placed[i].$1: i};
  placed.sort((a, b) {
    final c = (b.$2 ?? -1).compareTo(a.$2 ?? -1);
    return c != 0 ? c : order[b.$1]!.compareTo(order[a.$1]!);
  });
  return placed;
}

class TimelineScreen extends StatefulWidget {
  const TimelineScreen({super.key, required this.db, required this.pendant});

  final AppDb db;
  final PendantController pendant;

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  late List<(Chunk, int?)> _placed;
  int _seen = -1;

  @override
  Widget build(BuildContext context) {
    final loc = MaterialLocalizations.of(context);
    return ListenableBuilder(
      listenable: widget.pendant,
      builder: (context, _) {
        // Re-query only when a chunk was committed, not on every progress tick.
        if (_seen != widget.pendant.chunksStored) {
          _seen = widget.pendant.chunksStored;
          _placed = placeChunks(widget.db.chunks());
        }
        final rows = <Widget>[];
        String? day;
        for (final (c, approx) in _placed) {
          final d = approx == null ? null : DateTime.fromMillisecondsSinceEpoch(approx);
          final label = d == null ? 'Time unknown' : loc.formatFullDate(d);
          if (label != day) {
            day = label;
            rows.add(SectionHeader(label));
          }
          final start = c.startMs;
          rows.add(ListRow(
            marked: c.bookmarked,
            dim: !c.hasSpeech,
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => ChunkScreen(db: widget.db, chunk: c))),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(start == null ? 'Time unknown (#${c.seq})' : clockTime(context, start), style: TextStyles.label),
                  const SizedBox(height: 2),
                  Text([
                    formatDuration(c.durationMs),
                    c.hasSpeech ? 'speech' : 'quiet',
                    if (c.bookmarksMs.isNotEmpty) '${c.bookmarksMs.length} bookmark(s)',
                  ].join(' · '), style: TextStyles.caption),
                ]),
              ),
              if (c.bookmarked) const Icon(Icons.star_rounded, size: 18, color: Palette.signal),
            ]),
          ));
        }
        return ScreenFrame(
          title: 'Timeline',
          children: rows.isNotEmpty
              ? rows
              : const [
                  SizedBox(height: 48),
                  Center(child: HalftoneSphere(size: 160)),
                  SizedBox(height: 24),
                  Text('No conversations yet.\nPair the pendant from Home.',
                      textAlign: TextAlign.center, style: TextStyles.body),
                ],
        );
      },
    );
  }
}
