import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../adpcm.dart';
import '../ai/understanding.dart' show itemKinds;
import '../conversations.dart';
import '../db.dart';
import '../ui/format.dart';
import '../ui/painters.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Opens the conversation holding [chunkId], playing from [seekMs] into that chunk.
void openConversationAt(BuildContext context, AppDb db, Listenable transcriber, int chunkId, int seekMs) {
  final v = groupConversations(db.chunks()).where((v) => v.chunks.any((c) => c.id == chunkId)).firstOrNull;
  if (v == null) return;
  Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ConversationScreen(db: db, transcriber: transcriber, conversation: v, chunkId: chunkId, seekMs: seekMs)));
}

/// One conversation: its transcript and playback across all its chunks.
class ConversationScreen extends StatefulWidget {
  const ConversationScreen(
      {super.key, required this.db, required this.transcriber, required this.conversation, this.chunkId, this.seekMs = 0});

  final AppDb db;
  final Listenable transcriber; // rebuilds the transcript as chunks finish transcribing
  final Conversation conversation;
  final int? chunkId; // open at this chunk...
  final int seekMs; // ...and this offset into it

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _player = AudioPlayer();
  final _temp = <File>[];
  late final List<int> _offsets; // start of each chunk on the conversation's timeline
  String? _error;

  List<Chunk> get _chunks => widget.conversation.chunks;

  @override
  void initState() {
    super.initState();
    var t = 0;
    _offsets = [for (final c in _chunks) (t += c.durationMs) - c.durationMs];
    _load();
  }

  Future<void> _load() async {
    try {
      final dir = (await getTemporaryDirectory()).path;
      final sources = <AudioSource>[];
      for (final c in _chunks) {
        final f = File('$dir/playback_${c.id}.wav');
        // A top-level tear-off: a closure here would drag this State (player, db) into the isolate message.
        await f.writeAsBytes(await compute(chunkToPcmWav, await File(c.path).readAsBytes()), flush: true);
        _temp.add(f);
        sources.add(AudioSource.file(f.path));
      }
      final i = _chunks.indexWhere((c) => c.id == widget.chunkId);
      await _player.setAudioSources(sources,
          initialIndex: i < 0 ? 0 : i, initialPosition: Duration(milliseconds: widget.seekMs));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _player.dispose();
    for (final f in _temp) {
      f.delete().catchError((_) => f);
    }
    super.dispose();
  }

  int get _total => widget.conversation.durationMs;

  int _at(Duration pos) => _offsets[_player.currentIndex ?? 0] + pos.inMilliseconds;

  void _seek(int ms) {
    final t = ms.clamp(0, _total);
    final i = _offsets.lastIndexWhere((o) => o <= t);
    _player.seek(Duration(milliseconds: t - _offsets[i]), index: i);
  }

  Widget _panel() => ControlPanel(
        child: StreamBuilder<Duration>(
          stream: _player.positionStream,
          builder: (context, pos) {
            final at = _at(pos.data ?? Duration.zero).clamp(0, _total);
            return Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Text(formatDuration(at), style: TextStyles.caption.copyWith(color: Palette.textMid)),
                const Spacer(),
                Text(formatDuration(_total), style: TextStyles.caption.copyWith(color: Palette.textMid)),
              ]),
              DottedTrack(
                value: _total == 0 ? 0 : at / _total,
                marks: [
                  for (var i = 0; i < _chunks.length; i++)
                    for (final b in _chunks[i].bookmarksMs) (_offsets[i] + b) / _total,
                ],
                onChanged: (f) => _seek((f * _total).round()),
              ),
              StreamBuilder<PlayerState>(
                stream: _player.playerStateStream,
                builder: (context, snap) {
                  final playing = snap.data?.playing ?? false;
                  return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    CircleIconButton(
                        icon: Icons.replay_10_rounded, tooltip: 'Back 10 seconds', onPressed: () => _seek(at - 10000)),
                    PillButton(
                      label: playing ? 'Pause' : 'Play',
                      icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      onPressed: playing ? _player.pause : _player.play,
                    ),
                    CircleIconButton(
                        icon: Icons.forward_10_rounded, tooltip: 'Forward 10 seconds', onPressed: () => _seek(at + 10000)),
                  ]);
                },
              ),
            ]);
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    final v = widget.conversation;
    final start = v.startMs;
    return ListenableBuilder(
      listenable: widget.transcriber,
      builder: (context, _) {
        final lines = <Widget>[], found = <Widget>[];
        var pending = 0;
        for (var i = 0; i < _chunks.length; i++) {
          final c = _chunks[i];
          for (final item in widget.db.chunkItems(c.id)) {
            found.add(ListRow(
              marked: true,
              onTap: () => _seek(_offsets[i] + item.atMs),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(itemKinds[item.kind]!, style: TextStyles.caption),
                const SizedBox(height: 2),
                Text(item.text, style: TextStyles.label),
              ]),
            ));
          }
          final segments = widget.db.segments(c.id);
          if (segments.isEmpty && !widget.db.isTranscribed(c.id)) pending++;
          for (final s in segments) {
            final ms = s['start_ms'] as int;
            final at = _offsets[i] + ms;
            final cs = c.startMs;
            // Lines in the 30 s before a bookmark are what the bookmark was about.
            final marked = c.bookmarksMs.any((b) => ms <= b && ms >= b - 30000);
            lines.add(ListRow(
              marked: marked,
              onTap: () => _seek(at),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${s['speaker'] ?? 'Unknown'} · ${cs == null ? formatDuration(at) : clockTime(context, cs + ms)}',
                    style: TextStyles.caption),
                const SizedBox(height: 4),
                Text(s['text'] as String, style: TextStyles.body.copyWith(color: Palette.textHi)),
              ]),
            ));
          }
        }
        return ScreenFrame(
          title: start == null ? 'Conversation' : clockTime(context, start),
          wash: headerBlue,
          panel: _panel(),
          children: [
            Text(
                [
                  talkTime(v.durationMs),
                  v.hasSpeech ? 'speech' : 'quiet',
                  if (v.bookmarks > 0) '${v.bookmarks} bookmark(s)',
                ].join(' · '),
                textAlign: TextAlign.center,
                style: TextStyles.caption),
            if (_error != null) Text('Cannot play: $_error', style: TextStyles.body.copyWith(color: Palette.danger)),
            if (found.isNotEmpty) ...[const SectionHeader('Pulled out'), ...found, const SectionHeader('Transcript')]
            else
              const SizedBox(height: 16),
            ...lines,
            if (pending > 0)
              Text('$pending of ${_chunks.length} minute(s) not transcribed yet.', style: TextStyles.caption)
            else if (lines.isEmpty)
              const Text('No speech found.', style: TextStyles.body),
          ],
        );
      },
    );
  }
}
