import 'package:material_ui/material_ui.dart';

import '../services.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'conversation_screen.dart';
import 'voice_check_screen.dart';

/// Every voice heard, so you can say which one is yours and name the others.
class VoicesScreen extends StatelessWidget {
  const VoicesScreen({super.key, required this.s});

  final Services s;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s.changes,
      builder: (context, _) {
        final voices = s.db.speakerSamples();
        final samples = s.db.voiceSampleCount();
        return ScreenFrame(
          title: "Who's speaking",
          children: [
            Text(
                samples == 0
                    ? 'Find a voice that is yours and tap "That\'s me". Your lines are then labelled You, and only '
                        'conversations you take part in become to-dos.'
                    : 'Your voice is set up. Name the others so you can search what they said.',
                style: TextStyles.body),
            if (s.voiceChecks.value.length case final n when n > 0) ...[
              const SizedBox(height: 16),
              PillButton(
                  label: n == 1 ? 'Check 1 line' : 'Check $n lines',
                  icon: Icons.fact_check_rounded,
                  light: true,
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => VoiceCheckScreen(s: s)))),
            ],
            const SizedBox(height: 16),
            if (voices.isEmpty) ...[
              Text(
                  !s.transcriber.modelsReady
                      ? 'Voices are recognised once the speech models are downloaded.'
                      : s.transcriber.working
                          ? 'Listening through your conversations for voices…'
                          : 'No voices yet. They show up as conversations are transcribed.',
                  style: TextStyles.body),
              // Conversations transcribed before the voice model existed never get voices on their own.
              if (s.transcriber.modelsReady && !s.transcriber.working && s.db.spokenChunkIds().isNotEmpty) ...[
                const SizedBox(height: 16),
                PillButton(
                    label: 'Find voices in older conversations',
                    icon: Icons.record_voice_over_rounded,
                    light: true,
                    onPressed: () {
                      s.db.relabelOlder();
                      s.transcriber.kick();
                    }),
              ],
            ]
            else
              for (final v in voices) _row(context, v['speaker_id'] as int, v['speaker'] as String?, v['lines'] as int,
                  v['text'] as String, v['segment_id'] as int, v['chunk_id'] as int, v['start_ms'] as int),
            if (samples > 0) ...[
              const SizedBox(height: 24),
              PillButton(
                label: 'Reset my voice',
                danger: true,
                onPressed: () async {
                  final ok = await confirmSheet(context,
                      title: 'Reset your voice?',
                      body: 'Your lines stop being labelled You until you mark them again.',
                      confirm: 'Reset');
                  if (!ok) return;
                  s.db.resetVoiceProfile();
                  s.pendant.dataChanged();
                },
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _row(BuildContext context, int speakerId, String? name, int lines, String sample, int segmentId, int chunkId,
      int atMs) {
    final me = name == 'You';
    return ListRow(
      marked: me,
      onTap: () => openConversationAt(context, s, chunkId, atMs),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(name ?? 'Unknown', style: TextStyles.label)),
          Text(lines == 1 ? '1 line' : '$lines lines', style: TextStyles.caption),
        ]),
        const SizedBox(height: 4),
        Text('“$sample”', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyles.body),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (!me)
            PillButton(
                label: "That's me",
                icon: Icons.record_voice_over_rounded,
                light: true,
                onPressed: () => s.answerVoiceCheck(segmentId, true)),
          PillButton(
              label: 'Rename',
              icon: Icons.edit_rounded,
              onPressed: () async {
                final n = await askSpeakerName(context, name);
                if (n == null) return;
                s.db.renameSpeaker(speakerId, n);
                s.pendant.dataChanged();
              }),
        ]),
      ]),
    );
  }
}
