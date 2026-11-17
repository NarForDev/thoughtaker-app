import 'package:material_ui/material_ui.dart';

import '../conversations.dart';
import '../db.dart';
import '../pendant.dart';
import '../ui/format.dart';
import '../ui/painters.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'conversation_screen.dart';

class TimelineScreen extends StatefulWidget {
  const TimelineScreen({super.key, required this.db, required this.pendant, required this.transcriber});

  final AppDb db;
  final PendantController pendant;
  final Listenable transcriber;

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  late List<Conversation> _all;
  int _seen = -1;
  bool _onlyBookmarks = false;

  void _open(Conversation v) => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ConversationScreen(db: widget.db, transcriber: widget.transcriber, conversation: v)));

  Widget _row(Conversation v) {
    final start = v.startMs;
    return ListRow(
      marked: v.bookmarked,
      dim: !v.hasSpeech,
      onTap: () => _open(v),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(start == null ? 'Time unknown' : clockTime(context, start), style: TextStyles.label),
            const SizedBox(height: 2),
            Text([
              talkTime(v.durationMs),
              v.hasSpeech ? 'conversation' : 'quiet',
              if (v.bookmarks > 0) '${v.bookmarks} bookmark(s)',
            ].join(' · '), style: TextStyles.caption),
          ]),
        ),
        if (v.bookmarked) const Icon(Icons.star_rounded, size: 18, color: Palette.signal),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = MaterialLocalizations.of(context);
    return ListenableBuilder(
      listenable: widget.pendant,
      builder: (context, _) {
        // Re-query only when a chunk was committed, not on every progress tick.
        if (_seen != widget.pendant.chunksStored) {
          _seen = widget.pendant.chunksStored;
          _all = groupConversations(widget.db.chunks());
        }
        final shown = _onlyBookmarks ? _all.where((v) => v.bookmarked).toList() : _all;
        // One section per local day, with the day's talk time and counts in the header.
        final days = <String, List<Conversation>>{};
        for (final v in shown) {
          final s = v.startMs;
          days.putIfAbsent(s == null ? 'Time unknown' : loc.formatFullDate(DateTime.fromMillisecondsSinceEpoch(s)), () => []).add(v);
        }
        final rows = <Widget>[];
        for (final MapEntry(key: day, value: list) in days.entries) {
          final talk = list.where((v) => v.hasSpeech);
          final ms = talk.fold(0, (t, v) => t + v.durationMs);
          final marks = list.fold(0, (n, v) => n + v.bookmarks);
          rows.add(SectionHeader(day,
              trailing: Text(
                  '${talkTime(ms)} · ${talk.length} conv.${marks > 0 ? ' · $marks ★' : ''}', style: TextStyles.caption)));
          rows.addAll(list.map(_row));
        }
        return ScreenFrame(
          title: 'Timeline',
          action: CircleIconButton(
            icon: _onlyBookmarks ? Icons.star_rounded : Icons.star_outline_rounded,
            tooltip: _onlyBookmarks ? 'Show all' : 'Only bookmarked',
            onPressed: () => setState(() => _onlyBookmarks = !_onlyBookmarks),
          ),
          children: rows.isNotEmpty
              ? rows
              : [
                  const SizedBox(height: 48),
                  const Center(child: HalftoneSphere(size: 160)),
                  const SizedBox(height: 24),
                  Text(_onlyBookmarks ? 'No bookmarked conversations.' : 'No conversations yet.\nPair the pendant from Home.',
                      textAlign: TextAlign.center, style: TextStyles.body),
                ],
        );
      },
    );
  }
}
