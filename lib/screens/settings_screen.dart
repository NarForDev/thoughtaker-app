import 'package:material_ui/material_ui.dart';

import '../ai/download.dart' show wifiOnlyKey;
import '../ai/understanding.dart' show dayKey;
import '../conversations.dart';
import '../services.dart';
import '../ui/format.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.s});

  final Services s;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Services get s => widget.s;

  void _say(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _deleteDay() async {
    final loc = MaterialLocalizations.of(context);
    final days = <String, int>{}; // day -> talk time
    for (final v in groupConversations(s.db.chunks())) {
      final at = v.startMs;
      if (at != null) days.update(dayKey(at), (t) => t + v.durationMs, ifAbsent: () => v.durationMs);
    }
    final day = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Palette.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (sheet) => SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 24, 16, 16), shrinkWrap: true, children: [
          const Padding(padding: EdgeInsets.fromLTRB(4, 0, 4, 16), child: Text('Which day?', style: TextStyles.title)),
          if (days.isEmpty) const Text('There are no recorded days.', style: TextStyles.body),
          for (final MapEntry(key: d, value: ms) in days.entries)
            ListRow(
              onTap: () => Navigator.pop(sheet, d),
              child: Row(children: [
                Expanded(child: Text(loc.formatFullDate(DateTime.parse(d)), style: TextStyles.label)),
                Text(talkTime(ms), style: TextStyles.caption),
              ]),
            ),
        ]),
      ),
    );
    if (day == null || !mounted) return;
    final ok = await confirmSheet(context,
        title: 'Delete ${loc.formatMediumDate(DateTime.parse(day))}?',
        body: 'Every conversation from that day is removed from this phone: audio, transcripts, items and their '
            'calendar events. Anything still on the pendant syncs later.',
        confirm: 'Delete day');
    if (!ok) return;
    await s.deleteChunks(s.chunksOnDay(day));
    _say('Day deleted');
  }

  Future<void> _deleteEverything() async {
    final ok = await confirmSheet(context,
        title: 'Delete everything?',
        body: 'All conversations, transcripts, items, their calendar events, summaries and your voice profile are '
            'removed from this phone. The pendant stays paired, and anything still on it syncs later.',
        confirm: 'Delete everything');
    if (!ok) return;
    await s.deleteEverything();
    _say('Everything deleted');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s.changes,
      builder: (context, _) {
        final wifiOnly = s.db.setting(wifiOnlyKey) != '0';
        return ScreenFrame(
          title: 'Settings',
          children: [
            const SectionHeader('Processing'),
            PillToggle(
                label: 'Transcribe and understand only while charging',
                value: s.transcriber.onlyWhileCharging,
                onChanged: (v) => s.transcriber.onlyWhileCharging = v),
            const SizedBox(height: 8),
            PillToggle(
                label: 'Download models on Wi-Fi only',
                value: wifiOnly,
                onChanged: (v) => setState(() => s.db.setSetting(wifiOnlyKey, v ? null : '0'))),
            const SectionHeader('Calendar'),
            PillToggle(
                label: 'Add dated items to my calendar',
                value: s.calendar.enabled,
                onChanged: (v) => s.calendar.enabled = v),
            const SizedBox(height: 8),
            if (s.calendar.enabled && !s.calendar.hasAccess)
              Row(children: [
                const Expanded(
                    child: Text('Allow calendar access so tasks, promises and events with a date show up there.',
                        style: TextStyles.caption)),
                const SizedBox(width: 12),
                PillButton(label: 'Connect', light: true, onPressed: s.calendar.connect),
              ])
            else if (s.calendar.enabled)
              const Text('Done or dismissed items are removed from your calendar again.', style: TextStyles.caption),
            const SectionHeader('Wake word'),
            const PillToggle(label: 'Bookmark by saying "Perthro mark"', value: false),
            const SizedBox(height: 6),
            const Text('Needs the pendant\'s wake-word firmware, which is still being trained.', style: TextStyles.caption),
            const SectionHeader('Voice profile'),
            Text(
                s.db.voiceSampleCount() == 0
                    ? 'Not set up. In a conversation, long-press one of your own lines and choose "That\'s me".'
                    : '${s.db.voiceSampleCount()} samples of your voice. Your lines are labelled "You".',
                style: TextStyles.body),
            const SectionHeader('Delete'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              PillButton(label: 'Delete a day', icon: Icons.event_busy_rounded, onPressed: _deleteDay),
              PillButton(label: 'Delete everything', danger: true, onPressed: _deleteEverything),
            ]),
            const SizedBox(height: 32),
            const Text(
                'The link between pendant and phone is encrypted. Audio on the pendant\'s card is not encrypted '
                'until it syncs, and is deleted from the card once the phone has it.',
                style: TextStyles.caption),
          ],
        );
      },
    );
  }
}
