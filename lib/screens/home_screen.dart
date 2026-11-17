import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';

import '../ai/on_device_transcription.dart';
import '../conversations.dart';
import '../db.dart';
import '../pendant.dart';
import '../ui/painters.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'device_screen.dart';
import 'search_screen.dart';
import 'timeline_screen.dart';

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

/// The hub: today's numbers, and tiles that open Timeline, Pendant and Search.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.db, required this.pendant, required this.transcriber});

  final AppDb db;
  final PendantController pendant;
  final OnDeviceTranscriptionService transcriber;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  ({int speechMs, int chunks}) _today = (speechMs: 0, chunks: 0);
  int _seen = -1;

  void _push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  void _openTimeline() =>
      _push(TimelineScreen(db: widget.db, pendant: widget.pendant, transcriber: widget.transcriber));

  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour < 12 ? 'Good morning' : (hour < 18 ? 'Good afternoon' : 'Good evening');
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light, // no AppBar to set light status-bar icons on the dark background
      child: Scaffold(
        body: Stack(children: [
          Container(
              height: MediaQuery.sizeOf(context).height * 0.45,
              decoration: const BoxDecoration(gradient: headerViolet)),
          SafeArea(
            child: ListenableBuilder(
              listenable: widget.pendant,
              builder: (context, _) {
                final p = widget.pendant;
                final s = p.status;
                // Re-query only when a chunk was committed, not on every progress tick.
                // shortcut: after midnight "today" resets on the next commit or reopen, add a day timer if that shows.
                if (_seen != p.chunksStored) {
                  _seen = p.chunksStored;
                  _today = todayTotals(placeChunks(widget.db.chunks()), DateTime.now());
                }
                final m = _today.speechMs ~/ 60000;
                final warning =
                    s == null ? null : (s.sdError ? 'SD card error' : (s.storageFull ? 'Storage full' : null));
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
                  children: [
                    Text(greeting, style: TextStyles.display),
                    Text("Here's your day.", style: TextStyles.display.copyWith(color: Palette.textMid)),
                    const SizedBox(height: 24),
                    GlowCard(
                      glow: glowMagenta,
                      onTap: _openTimeline,
                      child: Column(children: [
                        const Align(alignment: Alignment.centerLeft, child: Text('Today', style: TextStyles.label)),
                        const SizedBox(height: 40),
                        DotMatrixText(m < 60 ? '$m' : '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}'),
                        const SizedBox(height: 10),
                        Text(m < 60 ? 'minutes of speech' : 'hours of speech',
                            style: TextStyles.caption.copyWith(color: Palette.textHi)),
                        const SizedBox(height: 40),
                      ]),
                    ),
                    const SizedBox(height: 8),
                    IntrinsicHeight(
                      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Expanded(
                          child: Tile(
                            label: 'Timeline',
                            onTap: _openTimeline,
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${_today.chunks}', style: TextStyles.title),
                              const Text('recordings today', style: TextStyles.caption),
                            ]),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Tile(
                            label: warning ?? 'Pendant',
                            glow: warning == null ? tilePlain : glowEmber,
                            onTap: () => _push(DeviceScreen(pendant: p, transcriber: widget.transcriber)),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(p.connected ? 'Connected' : 'Not connected',
                                  style: TextStyles.body.copyWith(color: Palette.textHi)),
                              Text(p.message,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyles.caption.copyWith(color: Palette.textMid)),
                              if (p.syncing) ...[const SizedBox(height: 8), DottedTrack(value: p.pullProgress)],
                            ]),
                          ),
                        ),
                      ]),
                    ),
                    if (s != null) ...[
                      const SizedBox(height: 8),
                      PillToggle(label: 'Mute', value: s.muted, onChanged: p.connected && !p.busy ? p.setMute : null),
                    ],
                    const SizedBox(height: 24),
                    _SearchPill(onTap: () => _push(SearchScreen(db: widget.db, transcriber: widget.transcriber))),
                  ],
                );
              },
            ),
          ),
        ]),
      ),
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
              Expanded(child: Text('Search everything you said…', style: TextStyles.body)),
              Icon(Icons.search_rounded, size: 18, color: Palette.textMid),
            ]),
          ),
        ),
      );
}
