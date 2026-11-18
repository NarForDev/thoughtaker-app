import 'package:material_ui/material_ui.dart';

import '../ai/understanding.dart' show dayKey;
import '../conversations.dart';
import '../services.dart';
import '../ui/format.dart';
import '../ui/painters.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'conversation_screen.dart';
import 'device_screen.dart';

class TimelineScreen extends StatefulWidget {
  const TimelineScreen({super.key, required this.s, this.day, this.showBack = true});

  final Services s;
  final String? day; // show only this day (YYYY-MM-DD), e.g. from a topic search
  final bool showBack;

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  late List<Conversation> _all;
  int _seen = -1;
  bool _onlyBookmarks = false;

  void _open(Conversation v) => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ConversationScreen(s: widget.s, conversation: v)));

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
            Text(
                v.hasSpeech
                    ? '${talkTime(v.durationMs)} conversation${v.bookmarks > 0 ? ', ${v.bookmarks} bookmarked' : ''}'
                    : '${talkTime(v.durationMs)} quiet',
                style: TextStyles.caption),
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
      listenable: widget.s.changes,
      builder: (context, _) {
        // Re-query only when a chunk was committed, not on every progress tick.
        if (_seen != widget.s.pendant.chunksStored) {
          _seen = widget.s.pendant.chunksStored;
          _all = groupConversations(widget.s.db.chunks());
        }
        final summaries = widget.s.db.summaries();
        final day = widget.day;
        final shown = [
          for (final v in _all)
            if ((!_onlyBookmarks || v.bookmarked) && (day == null || (v.startMs != null && dayKey(v.startMs!) == day))) v,
        ];
        // One section per local day: date, talk time, then the day's summary when there is one.
        final days = <String?, List<Conversation>>{};
        for (final v in shown) {
          days.putIfAbsent(v.startMs == null ? null : dayKey(v.startMs!), () => []).add(v);
        }
        final rows = <Widget>[];
        for (final MapEntry(key: key, value: list) in days.entries) {
          final talk = list.where((v) => v.hasSpeech);
          final ms = talk.fold(0, (t, v) => t + v.durationMs);
          final label = key == null ? 'Time unknown' : loc.formatFullDate(DateTime.parse(key));
          rows.add(SectionHeader(label, trailing: Text('${talkTime(ms)} talked', style: TextStyles.caption)));
          final summary = key == null ? null : summaries[key]?.text;
          if (summary != null && summary.isNotEmpty) {
            rows.add(Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text(summary, style: TextStyles.body),
            ));
          }
          rows.addAll(list.map(_row));
        }
        final p = widget.s.pendant;
        return ScreenFrame(
          title: day == null ? 'Timeline' : loc.formatMediumDate(DateTime.parse(day)),
          showBack: widget.showBack,
          onRefresh: p.hasDevice ? p.syncNow : null,
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
                  Text(
                      _onlyBookmarks
                          ? 'No bookmarked conversations.'
                          : p.hasDevice
                              ? 'No conversations yet. Pull down to sync.'
                              : 'No conversations yet. Pair your pendant to start.',
                      textAlign: TextAlign.center,
                      style: TextStyles.body),
                  if (!p.hasDevice && !_onlyBookmarks) ...[
                    const SizedBox(height: 16),
                    Center(
                      child: PillButton(
                        label: 'Pair pendant',
                        light: true,
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (_) => DeviceScreen(
                                pendant: p, transcriber: widget.s.transcriber, understanding: widget.s.understanding))),
                      ),
                    ),
                  ],
                ],
        );
      },
    );
  }
}
