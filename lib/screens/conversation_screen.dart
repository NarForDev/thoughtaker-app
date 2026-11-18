import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../adpcm.dart';
import '../ai/on_device_transcription.dart' show noiseTag;
import '../ai/understanding.dart' show itemKinds;
import '../conversations.dart';
import '../db.dart';
import '../services.dart';
import '../ui/format.dart';
import '../ui/painters.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'items_screen.dart' show showItemActions;

/// Opens the conversation holding [chunkId], playing from [seekMs] into that chunk.
void openConversationAt(BuildContext context, Services s, int chunkId, int seekMs) {
  final v = groupConversations(s.db.chunks()).where((v) => v.chunks.any((c) => c.id == chunkId)).firstOrNull;
  if (v == null) return;
  Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ConversationScreen(s: s, conversation: v, chunkId: chunkId, seekMs: seekMs)));
}

/// Asks for a speaker's name in a sheet. Null when cancelled or left empty.
Future<String?> askSpeakerName(BuildContext context, String? current) async {
  final name = TextEditingController(text: current); // not disposed: the closing sheet still reads it
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Palette.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (sheet) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheet).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Rename speaker', style: TextStyles.title),
            const SizedBox(height: 8),
            const Text('Give two speakers the same name to treat them as one person.', style: TextStyles.body),
            const SizedBox(height: 16),
            PillInput(hint: 'Name', controller: name, autofocus: true, onSubmitted: (_) => Navigator.pop(sheet, true)),
            const SizedBox(height: 24),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              PillButton(label: 'Cancel', onPressed: () => Navigator.pop(sheet, false)),
              const SizedBox(width: 8),
              PillButton(label: 'Save', light: true, onPressed: () => Navigator.pop(sheet, true)),
            ]),
          ]),
        ),
      ),
    ),
  );
  final n = name.text.trim();
  return ok == true && n.isNotEmpty ? n : null;
}

/// One conversation: its transcript and playback across all its chunks.
class ConversationScreen extends StatefulWidget {
  const ConversationScreen(
      {super.key, required this.s, required this.conversation, this.chunkId, this.seekMs = 0});

  final Services s;
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

  Future<void> _delete() async {
    final ok = await confirmSheet(context,
        title: 'Delete this conversation?',
        body: 'Its audio, transcript and items are removed from this phone, along with their calendar events.',
        confirm: 'Delete');
    if (!ok || !mounted) return;
    await _player.stop();
    await widget.s.deleteChunks(_chunks);
    if (mounted) Navigator.of(context).pop();
  }

  int _at(Duration pos) => _offsets[_player.currentIndex ?? 0] + pos.inMilliseconds;

  void _seek(int ms) {
    final t = ms.clamp(0, _total);
    final i = _offsets.lastIndexWhere((o) => o <= t);
    _player.seek(Duration(milliseconds: t - _offsets[i]), index: i);
  }

  Future<void> _voiceActions(int segmentId, String? speaker) => showModalBottomSheet<void>(
        context: context,
        backgroundColor: Palette.surface,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
        builder: (sheet) {
          final speakerId = widget.s.db.lineSpeaker(segmentId);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(speaker ?? 'Unknown speaker', style: TextStyles.title),
                const SizedBox(height: 8),
                if (speakerId == null)
                  const Text('This line is too short to recognise the voice.', style: TextStyles.body)
                else if (speaker == 'You')
                  const Text('Recognised as your voice. Reset it in Settings, under Voice profile, if that is wrong.',
                      style: TextStyles.body)
                else
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    PillButton(
                        label: "That's me",
                        icon: Icons.record_voice_over_rounded,
                        light: true,
                        onPressed: () {
                          Navigator.pop(sheet);
                          setState(() => widget.s.db.markAsMe(segmentId));
                        }),
                    PillButton(
                        label: 'Rename speaker',
                        icon: Icons.edit_rounded,
                        onPressed: () {
                          Navigator.pop(sheet);
                          _rename(speakerId, speaker);
                        }),
                  ]),
              ]),
            ),
          );
        },
      );

  Future<void> _rename(int speakerId, String? current) async {
    final n = await askSpeakerName(context, current);
    if (n != null && mounted) setState(() => widget.s.db.renameSpeaker(speakerId, n));
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
      listenable: widget.s.changes, // transcript and items fill in as they are made
      builder: (context, _) {
        final lines = <Widget>[], found = <Widget>[];
        var pending = 0;
        for (var i = 0; i < _chunks.length; i++) {
          final c = _chunks[i];
          for (final item in widget.s.db.chunkItems(c.id)) {
            found.add(ListRow(
              marked: true,
              onTap: () => showItemActions(context, widget.s, item),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(itemKinds[item.kind]!, style: TextStyles.caption),
                const SizedBox(height: 2),
                Text(item.text, style: TextStyles.label),
              ]),
            ));
          }
          final segments = widget.s.db.segments(c.id);
          if (segments.isEmpty && !widget.s.db.isTranscribed(c.id)) pending++;
          for (final s in segments) {
            if (noiseTag.hasMatch(s['text'] as String)) continue; // "[Music]" from before captions were dropped
            final ms = s['start_ms'] as int;
            final at = _offsets[i] + ms;
            final cs = c.startMs;
            // Lines in the 30 s before a bookmark are what the bookmark was about.
            final marked = c.bookmarksMs.any((b) => ms <= b && ms >= b - 30000);
            lines.add(ListRow(
              marked: marked,
              onTap: () => _seek(at),
              onLongPress: () => _voiceActions(s['id'] as int, s['speaker'] as String?),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${s['speaker'] ?? 'Someone'} · ${cs == null ? formatDuration(at) : clockTime(context, cs + ms)}',
                    style: TextStyles.caption),
                const SizedBox(height: 4),
                Text(s['text'] as String, style: TextStyles.body.copyWith(color: Palette.textHi)),
              ]),
            ));
          }
        }
        return ScreenFrame(
          title: start == null ? 'Conversation' : clockTime(context, start),
          action: CircleIconButton(icon: Icons.delete_outline_rounded, tooltip: 'Delete conversation', onPressed: _delete),
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
