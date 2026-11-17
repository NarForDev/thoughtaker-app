import 'dart:io';
import 'dart:isolate';

import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../adpcm.dart';
import '../db.dart';
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
      final wav = await Isolate.run(() => chunkToPcmWav(bytes));
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

  @override
  Widget build(BuildContext context) {
    final c = widget.chunk;
    final segments = widget.db.segments(c.id);
    final start = c.startMs;
    return Scaffold(
      appBar: AppBar(
        title: Text(start == null
            ? 'Chunk #${c.seq}'
            : MaterialLocalizations.of(context)
                .formatTimeOfDay(TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(start)))),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null) Text('Cannot play: $_error'),
          StreamBuilder<PlayerState>(
            stream: _player.playerStateStream,
            builder: (context, snap) {
              final playing = snap.data?.playing ?? false;
              return Row(children: [
                IconButton.filled(
                  tooltip: playing ? 'Pause' : 'Play',
                  icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  onPressed: playing ? _player.pause : _player.play,
                ),
                Expanded(
                  child: StreamBuilder<Duration>(
                    stream: _player.positionStream,
                    builder: (context, pos) {
                      final max = c.durationMs.toDouble();
                      final at = (pos.data?.inMilliseconds ?? 0).toDouble().clamp(0.0, max);
                      return Slider(value: at, max: max, onChanged: (v) => _seek(v.toInt()));
                    },
                  ),
                ),
              ]);
            },
          ),
          Text('${formatDuration(c.durationMs)} · ${c.hasSpeech ? 'speech' : 'quiet'}'),
          if (c.bookmarksMs.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              for (final b in c.bookmarksMs)
                ActionChip(
                  avatar: const Icon(Icons.bookmark),
                  label: Text(formatDuration(b)),
                  onPressed: () => _seek(b),
                ),
            ]),
          ],
          const SizedBox(height: 12),
          if (segments.isEmpty)
            Text(widget.db.isTranscribed(c.id) ? 'No speech found.' : 'No transcript yet.')
          else
            for (final s in segments)
              ListTile(
                title: Text(s['text'] as String),
                subtitle: Text('${s['speaker'] ?? 'Unknown'} · ${formatDuration(s['start_ms'] as int)}'),
                onTap: () => _seek(s['start_ms'] as int),
              ),
        ],
      ),
    );
  }
}
