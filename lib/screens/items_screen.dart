import 'package:material_ui/material_ui.dart';

import '../acting/actions.dart';
import '../acting/reminders.dart';
import '../ai/understanding.dart';
import '../db.dart';
import '../ui/format.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'conversation_screen.dart';

/// "Tue 18 Nov, 9:00", or just the date when no time was said.
String formatDue(BuildContext context, int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final date = MaterialLocalizations.of(context).formatShortMonthDay(d);
  return d.hour == 0 && d.minute == 0 ? date : '$date, ${clockTime(context, ms)}';
}

/// Everything pulled out of conversations, by kind, with what you can do about each one.
class ItemsScreen extends StatefulWidget {
  const ItemsScreen(
      {super.key, required this.db, required this.understanding, required this.transcriber, required this.reminders});

  final AppDb db;
  final Listenable understanding; // new items appear as conversations are processed
  final Listenable transcriber;
  final Reminders reminders;

  @override
  State<ItemsScreen> createState() => _ItemsScreenState();
}

class _ItemsScreenState extends State<ItemsScreen> {
  String? _kind; // null = all kinds
  bool _done = false;

  void _say(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _remind(Item i) async {
    var at = defaultReminder(i, DateTime.now());
    if (at == null) {
      final now = DateTime.now();
      final day = await showDatePicker(context: context, firstDate: now, lastDate: DateTime(now.year + 2), initialDate: now);
      if (day == null || !mounted) return;
      final time = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 9, minute: 0));
      if (time == null) return;
      at = DateTime(day.year, day.month, day.day, time.hour, time.minute).millisecondsSinceEpoch;
    }
    final ok = await widget.reminders.schedule(i, at);
    if (!mounted) return;
    _say(ok ? 'Reminder set for ${formatDue(context, at)}' : 'Allow notifications to get reminders');
    setState(() {});
  }

  Future<void> _setState(Item i, String state) async {
    widget.db.setItemState(i.id, state);
    if (i.remindMs != null) await widget.reminders.cancel(i.id);
    setState(() {});
  }

  void _actions(Item i) {
    final draft = draftFor(i);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Palette.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (sheet) {
        void run(Future<void> Function() f) {
          Navigator.pop(sheet);
          f();
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(i.text, style: TextStyles.title),
              const SizedBox(height: 8),
              Text('“${i.quote}”', style: TextStyles.body),
              const SizedBox(height: 20),
              Wrap(spacing: 8, runSpacing: 8, children: [
                PillButton(
                    label: 'Open moment',
                    icon: Icons.play_arrow_rounded,
                    onPressed: () => run(() async =>
                        openConversationAt(context, widget.db, widget.transcriber, i.chunkId, i.atMs))),
                if (i.state == 'open') ...[
                  PillButton(label: 'Done', icon: Icons.check_rounded, light: true, onPressed: () => run(() => _setState(i, 'done'))),
                  PillButton(
                      label: i.remindMs == null ? 'Remind me' : 'Change reminder',
                      icon: Icons.notifications_rounded,
                      onPressed: () => run(() => _remind(i))),
                  if (i.kind == 'event' || i.dueMs != null)
                    PillButton(
                        label: 'Add to calendar',
                        icon: Icons.event_rounded,
                        onPressed: () => run(() async {
                              if (!await addToCalendar(i)) _say('No calendar app found');
                            })),
                  if (draft != null) ...[
                    PillButton(label: 'Send message', icon: Icons.send_rounded, onPressed: () => run(() => shareText(draft))),
                    PillButton(
                        label: 'Email',
                        icon: Icons.mail_rounded,
                        onPressed: () => run(() async {
                              if (!await composeEmail(i.text, draft)) _say('No mail app found');
                            })),
                  ],
                  PillButton(label: 'Dismiss', danger: true, onPressed: () => run(() => _setState(i, 'dismissed'))),
                ] else
                  PillButton(label: 'Reopen', onPressed: () => run(() => _setState(i, 'open'))),
              ]),
            ]),
          ),
        );
      },
    );
  }

  Widget _row(Item i) {
    final due = i.dueMs;
    final said = i.saidMs;
    return ListRow(
      marked: i.remindMs != null,
      dim: i.state != 'open',
      onTap: () => _actions(i),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
            [
              itemKinds[i.kind]!,
              if (due != null) 'due ${formatDue(context, due)}',
              if (i.remindMs != null) 'reminder ${formatDue(context, i.remindMs!)}',
            ].join(' · '),
            style: TextStyles.caption),
        const SizedBox(height: 4),
        Text(i.text, style: TextStyles.body.copyWith(color: Palette.textHi)),
        const SizedBox(height: 4),
        Text('“${i.quote}”${said == null ? '' : ' · ${clockTime(context, said)}'}',
            maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyles.caption),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.understanding,
      builder: (context, _) {
        final all = widget.db.items().where((i) => _done ? i.state != 'open' : i.state == 'open');
        final shown = [for (final i in all) if (_kind == null || i.kind == _kind) i];
        return ScreenFrame(
          title: _done ? 'Done' : 'Items',
          wash: headerViolet,
          action: CircleIconButton(
            icon: _done ? Icons.inbox_rounded : Icons.done_all_rounded,
            tooltip: _done ? 'Show open items' : 'Show done and dismissed',
            onPressed: () => setState(() => _done = !_done),
          ),
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final (k, label) in [(null, 'All'), ...itemKinds.entries.map((e) => (e.key, e.value))])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: PillButton(label: label, light: _kind == k, onPressed: () => setState(() => _kind = k)),
                  ),
              ]),
            ),
            const SizedBox(height: 16),
            if (shown.isEmpty)
              Text(
                  _done
                      ? 'Nothing done yet.'
                      : 'Nothing here yet. Tasks, promises, plans and facts show up as conversations are understood.',
                  style: TextStyles.body)
            else
              ...shown.map(_row),
          ],
        );
      },
    );
  }
}
