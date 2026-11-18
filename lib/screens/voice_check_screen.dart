import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sql show Row;

import '../adpcm.dart';
import '../services.dart';
import '../ui/format.dart';
import '../ui/painters.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// "Is this you?": the lines the app is least sure about, one at a time with their audio. Every answer is a new
/// sample for the voice profile, so recognition keeps improving as you use it.
class VoiceCheckScreen extends StatefulWidget {
  const VoiceCheckScreen({super.key, required this.s});

  final Services s;

  @override
  State<VoiceCheckScreen> createState() => _VoiceCheckScreenState();
}

class _VoiceCheckScreenState extends State<VoiceCheckScreen> {
  final _player = AudioPlayer();
  final _skipped = <int>{};
  File? _clip;
  int _answered = 0;

  Services get s => widget.s;

  @override
  void initState() {
    super.initState();
    s.voiceChecks.value = s.db.voiceChecks(); // fresh list, without a notification about this very screen
  }

  @override
  void dispose() {
    _player.dispose();
    _clip?.delete().catchError((_) => _clip!);
    super.dispose();
  }

  Future<void> _play(sql.Row line) async {
    final chunk = s.db.chunk(line['chunk_id'] as int);
    if (chunk == null) return;
    final f = _clip ??= File('${(await getTemporaryDirectory()).path}/voice_check.wav');
    await f.writeAsBytes(await compute(chunkToPcmWav, await File(chunk.path).readAsBytes()), flush: true);
    await _player.setAudioSource(ClippingAudioSource(
        child: AudioSource.file(f.path),
        start: Duration(milliseconds: line['start_ms'] as int),
        end: Duration(milliseconds: line['end_ms'] as int)));
    await _player.play();
  }

  void _answer(sql.Row line, bool mine) {
    _player.stop();
    s.answerVoiceCheck(line['segment_id'] as int, mine);
    setState(() => _answered++);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<sql.Row>>(
      valueListenable: s.voiceChecks,
      builder: (context, lines, _) {
        final left = [for (final l in lines) if (!_skipped.contains(l['segment_id'])) l];
        final line = left.firstOrNull;
        return ScreenFrame(
          title: 'Is this you?',
          wash: headerViolet,
          children: line == null ? _done() : _ask(line, left.length),
        );
      },
    );
  }

  List<Widget> _ask(sql.Row line, int left) {
    final chunk = s.db.chunk(line['chunk_id'] as int);
    final start = chunk?.startMs;
    final said = start == null ? 'Time unknown' : clockTime(context, start + (line['start_ms'] as int));
    return [
      const SizedBox(height: 8),
      Text(left == 1 ? '1 line to check' : '$left lines to check', style: TextStyles.caption),
      const SizedBox(height: 16),
      GlowCard(
        glow: glowMagenta,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(said, style: TextStyles.label)),
            CircleIconButton(
                icon: Icons.play_arrow_rounded, tooltip: 'Play this line', light: true, onPressed: () => _play(line)),
          ]),
          const SizedBox(height: 20),
          Text('“${line['text']}”', style: TextStyles.title),
          const SizedBox(height: 12),
          Text(
              line['speaker'] == 'You'
                  ? 'Labelled as you, but the voice is not a clear match.'
                  : 'Labelled ${line['speaker'] ?? 'Someone'}, but it sounds a little like you.',
              style: TextStyles.body.copyWith(color: Palette.textHi)),
        ]),
      ),
      const SizedBox(height: 24),
      Row(children: [
        Expanded(child: PillButton(label: 'Not me', onPressed: () => _answer(line, false))),
        const SizedBox(width: 12),
        Expanded(child: PillButton(label: 'Yes, me', light: true, onPressed: () => _answer(line, true))),
      ]),
      const SizedBox(height: 8),
      Center(child: TextLink('Skip', onTap: () => setState(() => _skipped.add(line['segment_id'] as int)))),
    ];
  }

  List<Widget> _done() => [
        const SizedBox(height: 48),
        const Center(child: HalftoneSphere(size: 160, lit: true)),
        const SizedBox(height: 24),
        Text(
            s.db.voiceSampleCount() == 0
                ? 'Nothing to check yet. Pick your voice in Who\'s speaking first.'
                : _answered == 0
                    ? 'Nothing to check. You\'ll get a notification when there is.'
                    : 'Thanks. Recognition learns from every answer.',
            textAlign: TextAlign.center,
            style: TextStyles.body),
        const SizedBox(height: 16),
        Center(child: PillButton(label: 'Done', light: true, onPressed: () => Navigator.of(context).maybePop())),
      ];
}
