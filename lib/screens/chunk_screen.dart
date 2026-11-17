import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../adpcm.dart';
import '../db.dart';
import '../ui/painters.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'timeline_screen.dart';

class ChunkScreen extends StatefulWidget {
  const ChunkScreen({super.key, required this.db, required this.chunk, this.seekMs = 0});

  final AppDb db;
  final Chunk chunk;
  final int seekMs;

  @override
  State<ChunkScreen> createState() => _ChunkScreenState();
}

class _ChunkScreenState extends State<ChunkScreen> {
  final _player = AudioPlayer();
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await File(widget.chunk.path).readAsBytes();
      // A top-level tear-off: a closure here would drag this State (player, db) into the isolate message.
      final wav = await compute(chunkToPcmWav, bytes);
      final tmp = File('${(await getTemporaryDirectory()).path}/playback.wav');
      await tmp.writeAsBytes(wav, flush: true);
      await _player.setFilePath(tmp.path);
      if (widget.seekMs > 0) await _player.seek(Duration(milliseconds: widget.seekMs));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  void _seek(int ms) => _player.seek(Duration(milliseconds: ms));

  Widget _panel(Chunk c) => ControlPanel(
        child: StreamBuilder<Duration>(
          stream: _player.positionStream,
          builder: (context, pos) {
            final at = (pos.data?.inMilliseconds ?? 0).clamp(0, c.durationMs);
            return Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Text(formatDuration(at), style: TextStyles.caption.copyWith(color: Palette.textMid)),
                const Spacer(),
                Text(formatDuration(c.durationMs), style: TextStyles.caption.copyWith(color: Palette.textMid)),
              ]),
              DottedTrack(
                value: c.durationMs == 0 ? 0 : at / c.durationMs,
                marks: [for (final b in c.bookmarksMs) b / c.durationMs],
                onChanged: (f) => _seek((f * c.durationMs).round()),
              ),
              StreamBuilder<PlayerState>(
                stream: _player.playerStateStream,
                builder: (context, snap) {
                  final playing = snap.data?.playing ?? false;
                  return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    CircleIconButton(
                        icon: Icons.replay_10_rounded,
                        tooltip: 'Back 10 seconds',
                        onPressed: () => _seek((at - 10000).clamp(0, c.durationMs))),
                    PillButton(
                      label: playing ? 'Pause' : 'Play',
                      icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      onPressed: playing ? _player.pause : _player.play,
                    ),
                    CircleIconButton(
                        icon: Icons.forward_10_rounded,
                        tooltip: 'Forward 10 seconds',
                        onPressed: () => _seek((at + 10000).clamp(0, c.durationMs))),
                  ]);
                },
              ),
            ]);
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = widget.chunk;
    final segments = widget.db.segments(c.id);
    final start = c.startMs;
    return ScreenFrame(
      title: start == null ? 'Chunk #${c.seq}' : clockTime(context, start),
      wash: headerBlue,
      panel: _panel(c),
      children: [
        Text('${formatDuration(c.durationMs)} · ${c.hasSpeech ? 'speech' : 'quiet'}', style: TextStyles.caption),
        if (_error != null) Text('Cannot play: $_error', style: TextStyles.body.copyWith(color: Palette.danger)),
        if (c.bookmarksMs.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final b in c.bookmarksMs)
              PillButton(label: formatDuration(b), icon: Icons.star_rounded, onPressed: () => _seek(b)),
          ]),
        ],
        const SizedBox(height: 16),
        if (segments.isEmpty)
          Text(widget.db.isTranscribed(c.id) ? 'No speech found.' : 'No transcript yet.', style: TextStyles.body)
        else
          for (final s in segments)
            ListRow(
              onTap: () => _seek(s['start_ms'] as int),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${s['speaker'] ?? 'Unknown'} · ${formatDuration(s['start_ms'] as int)}', style: TextStyles.caption),
                const SizedBox(height: 4),
                Text(s['text'] as String, style: TextStyles.body.copyWith(color: Palette.textHi)),
              ]),
            ),
      ],
    );
  }
}
