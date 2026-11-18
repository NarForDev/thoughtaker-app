import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';

import '../ai/on_device_transcription.dart' show noiseTag;
import '../ai/understanding.dart' show dayKey;
import '../conversations.dart';
import '../db.dart';
import '../services.dart';
import '../ui/format.dart';
import '../ui/painters.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'conversation_screen.dart';
import 'device_screen.dart';
import 'items_screen.dart';
import 'settings_screen.dart';
import 'voice_check_screen.dart';
import 'voices_screen.dart';

const _actionable = {'task', 'my_promise', 'their_promise', 'event'};

/// Speech time and chunk count for the local day of [now], using the times [placeChunks] gave each chunk.
({int speechMs, int chunks}) todayTotals(List<(Chunk, int?)> placed, DateTime now) {
  final from = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
  final to = DateTime(now.year, now.month, now.day + 1).millisecondsSinceEpoch;
  var speechMs = 0, chunks = 0;
  for (final (c, at) in placed) {
    if (at == null || at < from || at >= to) continue;
    chunks++;
    if (c.hasSpeech) speechMs += c.durationMs;
  }
  return (speechMs: speechMs, chunks: chunks);
}

/// Your day at a glance, with every part of the app one tap away.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.s, required this.openTab});

  final Services s;
  final ValueChanged<int> openTab; // 1 Timeline, 2 To-dos, 3 Search

  @override
  Widget build(BuildContext context) {
    void push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    final device = DeviceScreen(pendant: s.pendant, transcriber: s.transcriber, understanding: s.understanding);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        body: Stack(children: [
          Container(
              height: MediaQuery.sizeOf(context).height * 0.45, decoration: const BoxDecoration(gradient: headerViolet)),
          SafeArea(
            child: ListenableBuilder(
              listenable: s.changes,
              builder: (context, _) {
                final now = DateTime.now();
                final p = s.pendant;
                final conversations = groupConversations(s.db.chunks());
                final today = [
                  for (final v in conversations)
                    if (v.hasSpeech && v.startMs != null && dayKey(v.startMs!) == dayKey(now.millisecondsSinceEpoch)) v,
                ];
                final open = s.db.items(state: 'open');
                return refreshable(p.hasDevice ? p.syncNow : null, ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    Row(children: [
                      _StatusChip(s: s, onTap: () => push(device)),
                      const Spacer(),
                      CircleIconButton(
                          icon: Icons.settings_rounded, tooltip: 'Settings', onPressed: () => push(SettingsScreen(s: s))),
                    ]),
                    const SizedBox(height: 24),
                    Text(_greeting(now), style: TextStyles.display),
                    const SizedBox(height: 4),
                    Text(MaterialLocalizations.of(context).formatFullDate(now),
                        style: TextStyles.body.copyWith(color: Palette.textHi)),
                    const SizedBox(height: 24),
                    ..._setup(context, push, device),
                    _TodayCard(s: s, today: today, onTap: () => openTab(1)),
                    SectionHeader('Due next', trailing: TextLink('All to-dos', onTap: () => openTab(2))),
                    _DueNext(s: s, items: [for (final i in open) if (_actionable.contains(i.kind)) i]),
                    const SizedBox(height: 8),
                    if (s.voiceChecks.value.length case final n when n > 0)
                      Tile(
                        label: 'Is this you?',
                        onTap: () => push(VoiceCheckScreen(s: s)),
                        child: Text(
                            '${n == 1 ? '1 line' : '$n lines'} to check. Each answer makes voice recognition better.',
                            style: TextStyles.body),
                      ),
                    SectionHeader('Recent conversations',
                        trailing: TextLink('Timeline', onTap: () => openTab(1))),
                    if (conversations.isEmpty)
                      Text(
                          p.hasDevice
                              ? 'Your conversations show up here after the pendant syncs. Pull down to sync now.'
                              : 'Your conversations show up here once a pendant is paired.',
                          style: TextStyles.body)
                    else
                      for (final v in conversations.where((v) => v.hasSpeech).take(3)) _ConversationRow(s: s, v: v),
                    const SizedBox(height: 16),
                    _SearchPill(onTap: () => openTab(3)),
                    const SizedBox(height: 16),
                    _PendantTile(s: s, onTap: () => push(device)),
                  ],
                ));
              },
            ),
          ),
        ]),
      ),
    );
  }

  static String _greeting(DateTime now) =>
      now.hour < 12 ? 'Good morning' : (now.hour < 18 ? 'Good afternoon' : 'Good evening');

  /// One card listing what is left to set up, in the order it unlocks features. Downloads run in place.
  List<Widget> _setup(BuildContext context, void Function(Widget) push, Widget device) {
    final t = s.transcriber, u = s.understanding;
    String pct(double p) => '${(p * 100).floor()}%';
    final steps = <(String, VoidCallback?)>[
      if (!s.pendant.hasDevice) ('Pair your pendant', () => push(device)),
      if (!t.modelsReady)
        t.downloading ? ('Speech models ${pct(t.downloadProgress)}', null) : ('Download speech models', t.downloadModels),
      if (!u.modelReady)
        u.downloading ? ('AI model ${pct(u.downloadProgress)}', null) : ('Download the AI model', u.downloadModel),
      if (s.calendar.enabled && !s.calendar.hasAccess) ('Connect your calendar', () => s.calendar.connect()),
      if (s.db.voiceSampleCount() == 0 && s.db.speakerSamples().isNotEmpty)
        ('Teach it your voice', () => push(VoicesScreen(s: s))),
    ];
    if (steps.isEmpty) return const [];
    return [
      Tile(
        label: 'Finish setting up',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (i, (label, go)) in steps.indexed) PillButton(label: label, light: i == 0, onPressed: go),
          ]),
          if (t.error ?? u.error case final e?) ...[
            const SizedBox(height: 8),
            Text(e, style: TextStyles.caption.copyWith(color: Palette.danger)),
          ],
        ]),
      ),
      const SizedBox(height: 16),
    ];
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.s, required this.onTap});

  final Services s;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = s.pendant;
    final last = p.lastSyncMs;
    final mins = last == null ? null : DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(last)).inMinutes;
    final text = p.syncing
        ? 'Syncing'
        : !p.hasDevice
            ? 'No pendant'
            : mins == null
                ? (p.connected ? 'Connected' : 'Not synced yet')
                : mins < 1
                    ? 'Synced just now'
                    : mins < 60
                        ? 'Synced $mins min ago'
                        : 'Synced ${mins ~/ 60} h ago';
    return Semantics(
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
              color: const Color(0x33000000), borderRadius: BorderRadius.circular(999), border: Border.all(color: Palette.stroke)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    shape: BoxShape.circle, color: p.connected ? Palette.signal : Palette.textLo)),
            const SizedBox(width: 8),
            Text(text, style: TextStyles.label),
          ]),
        ),
      ),
    );
  }
}

/// The one loud element: today's talk time in dot numerals, with the day's summary.
class _TodayCard extends StatelessWidget {
  const _TodayCard({required this.s, required this.today, required this.onTap});

  final Services s;
  final List<Conversation> today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ms = today.fold(0, (t, v) => t + v.durationMs);
    final m = ms ~/ 60000;
    final marks = today.fold(0, (n, v) => n + v.bookmarks);
    final summary = s.db.summaries()[dayKey(DateTime.now().millisecondsSinceEpoch)]?.text ?? '';
    return GlowCard(
      glow: glowMagenta,
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Today', style: TextStyles.label),
          const Spacer(),
          Text(today.length == 1 ? '1 conversation' : '${today.length} conversations',
              style: TextStyles.caption.copyWith(color: Palette.textHi)),
        ]),
        const SizedBox(height: 28),
        Center(child: DotMatrixText(m < 60 ? '$m' : '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}')),
        const SizedBox(height: 10),
        Center(
          child: Text(m < 60 ? 'minutes talked' : 'hours talked', style: TextStyles.caption.copyWith(color: Palette.textHi)),
        ),
        const SizedBox(height: 28),
        Text(
          summary.isNotEmpty
              ? summary
              : today.isEmpty
                  ? 'Nothing recorded yet today. Wear the pendant and talk as usual.'
                  : 'A summary of today appears once your conversations are understood.',
          style: TextStyles.body.copyWith(color: Palette.textHi),
        ),
        if (marks > 0) ...[
          const SizedBox(height: 8),
          Text(marks == 1 ? '1 bookmarked moment' : '$marks bookmarked moments',
              style: TextStyles.caption.copyWith(color: Palette.textHi)),
        ],
      ]),
    );
  }
}

/// Open items as a row of cards you can act on in place.
class _DueNext extends StatelessWidget {
  const _DueNext({required this.s, required this.items});

  final Services s;
  final List<Item> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const ListRow(
        child: Text(
            'Tasks, promises and plans from your conversations land here, with reminders and calendar entries.',
            style: TextStyles.body),
      );
    }
    return SizedBox(
      height: 176,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: items.length.clamp(0, 8),
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, n) {
          final i = items[n];
          return SizedBox(
            width: 240,
            child: GlowCard(
              glow: tilePlain,
              radius: 24,
              padding: const EdgeInsets.all(16),
              onTap: () => showItemActions(context, s, i),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(itemStatus(context, i), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyles.caption),
                const SizedBox(height: 6),
                Expanded(
                  child: Text(i.text,
                      maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyles.body.copyWith(color: Palette.textHi)),
                ),
                Row(children: [
                  CircleIconButton(
                      size: 36, icon: Icons.check_rounded, tooltip: 'Done', light: true, onPressed: () => setItemState(s, i, 'done')),
                  const SizedBox(width: 8),
                  CircleIconButton(
                      size: 36, icon: Icons.notifications_rounded, tooltip: 'Remind me', onPressed: () => remindItem(context, s, i)),
                  const SizedBox(width: 8),
                  CircleIconButton(
                      size: 36,
                      icon: Icons.play_arrow_rounded,
                      tooltip: 'Play the moment',
                      onPressed: () => openConversationAt(context, s, i.chunkId, i.atMs)),
                ]),
              ]),
            ),
          );
        },
      ),
    );
  }
}

class _ConversationRow extends StatelessWidget {
  const _ConversationRow({required this.s, required this.v});

  final Services s;
  final Conversation v;

  @override
  Widget build(BuildContext context) {
    final start = v.startMs;
    // First real line; Whisper writes non-speech as tags like "[Music]".
    final first = [for (final c in v.chunks.take(3)) ...s.db.segments(c.id)]
        .where((l) => !noiseTag.hasMatch(l['text'] as String))
        .firstOrNull;
    return ListRow(
      marked: v.bookmarked,
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => ConversationScreen(s: s, conversation: v))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(start == null ? 'Time unknown' : clockTime(context, start), style: TextStyles.label)),
          Text(talkTime(v.durationMs), style: TextStyles.caption),
        ]),
        if (first != null) ...[
          const SizedBox(height: 4),
          Text('${first['speaker'] ?? 'Someone'}: ${first['text']}',
              maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyles.body),
        ],
      ]),
    );
  }
}

class _PendantTile extends StatelessWidget {
  const _PendantTile({required this.s, required this.onTap});

  final Services s;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = s.pendant;
    final st = p.status;
    Widget stat(String value, String label) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: TextStyles.title),
            Text(label, style: TextStyles.caption),
          ]),
        );
    final warning = st == null ? null : (st.sdError ? 'SD card error' : (st.storageFull ? 'Storage full' : null));
    return Tile(
      label: warning ?? 'Pendant',
      glow: warning == null ? tilePlain : glowEmber,
      onTap: onTap,
      child: Column(children: [
        if (st == null)
          Text(p.hasDevice ? p.message : 'Tap to pair your pendant.', style: TextStyles.body)
        else ...[
          Row(children: [
            stat(st.batteryPct == 0xFF ? '-' : '${st.batteryPct}%', 'battery'),
            stat('${(st.freeKib / 1048576).toStringAsFixed(1)} GB', 'free'),
            stat('${st.pendingChunks}', 'to sync'),
          ]),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: Text(recordingLabel(st), style: TextStyles.label)),
          const SizedBox(height: 8),
          PillToggle(label: 'Mute microphone', value: st.muted, onChanged: p.connected && !p.busy ? p.setMute : null),
        ],
        if (p.syncing) ...[const SizedBox(height: 12), DottedTrack(value: p.pullProgress)],
      ]),
    );
  }
}

/// Looks like the search box; opens Search, where the real field is.
class _SearchPill extends StatelessWidget {
  const _SearchPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: Palette.surfaceHigh,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Palette.stroke),
            ),
            child: const Row(children: [
              Expanded(child: Text('Search words, people or topics', style: TextStyles.body)),
              Icon(Icons.search_rounded, size: 18, color: Palette.textMid),
            ]),
          ),
        ),
      );
}
