import 'package:material_ui/material_ui.dart';

import '../acting/actions.dart';
import '../acting/calendar.dart';
import '../ai/understanding.dart';
import '../db.dart';
import '../services.dart';
import '../ui/format.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'conversation_screen.dart';

/// "18 Nov, 9:00", or just the date when no time was said.
String formatDue(BuildContext context, int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final date = MaterialLocalizations.of(context).formatShortMonthDay(d);
  return d.hour == 0 && d.minute == 0 ? date : '$date, ${clockTime(context, ms)}';
}

void _say(BuildContext context, String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

/// Marks an item done, dismissed or open again; its reminder and calendar event follow.
Future<void> setItemState(Services s, Item i, String state) async {
  s.db.setItemState(i.id, state);
  if (state != 'open' && i.remindMs != null) await s.reminders.cancel(i.id);
  await s.calendar.sync();
}

/// Sets a reminder at the suggested time, or asks for one when there is no sensible default.
Future<void> remindItem(BuildContext context, Services s, Item i) async {
  var at = defaultReminder(i, DateTime.now());
  if (at == null) {
    final now = DateTime.now();
    final day = await showDatePicker(context: context, firstDate: now, lastDate: DateTime(now.year + 2), initialDate: now);
    if (day == null || !context.mounted) return;
    final time = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 9, minute: 0));
    if (time == null) return;
    at = DateTime(day.year, day.month, day.day, time.hour, time.minute).millisecondsSinceEpoch;
  }
  final ok = await s.reminders.schedule(i, at);
  if (context.mounted) _say(context, ok ? 'Reminder set for ${formatDue(context, at)}' : 'Allow notifications to get reminders');
}

/// Everything you can do about one item.
void showItemActions(BuildContext context, Services s, Item i) {
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
            Text(itemKinds[i.kind]!, style: TextStyles.caption),
            const SizedBox(height: 4),
            Text(i.text, style: TextStyles.title),
            const SizedBox(height: 8),
            Text('“${i.quote}”', style: TextStyles.body),
            const SizedBox(height: 20),
            Wrap(spacing: 8, runSpacing: 8, children: [
              PillButton(
                  label: 'Play the moment',
                  icon: Icons.play_arrow_rounded,
                  onPressed: () => run(() async => openConversationAt(context, s, i.chunkId, i.atMs))),
              if (i.state == 'open') ...[
                PillButton(
                    label: 'Done', icon: Icons.check_rounded, light: true, onPressed: () => run(() => setItemState(s, i, 'done'))),
                PillButton(
                    label: i.remindMs == null ? 'Remind me' : 'Change reminder',
                    icon: Icons.notifications_rounded,
                    onPressed: () => run(() => remindItem(context, s, i))),
                if (i.eventId case final event?)
                  PillButton(
                      label: 'In your calendar',
                      icon: Icons.event_available_rounded,
                      onPressed: () => run(() async {
                            if (!await s.calendar.open(event) && context.mounted) _say(context, 'No calendar app found');
                          }))
                else if (belongsInCalendar(i, DateTime.now()) && !s.calendar.hasAccess)
                  PillButton(
                      label: 'Connect calendar', icon: Icons.event_rounded, onPressed: () => run(s.calendar.connect))
                else if (i.kind == 'event' || i.dueMs != null)
                  PillButton(
                      label: 'Add to calendar',
                      icon: Icons.event_rounded,
                      onPressed: () => run(() async {
                            if (!await addToCalendar(i) && context.mounted) _say(context, 'No calendar app found');
                          })),
                if (draft != null) ...[
                  PillButton(label: 'Send message', icon: Icons.send_rounded, onPressed: () => run(() => shareText(draft))),
                  PillButton(
                      label: 'Email',
                      icon: Icons.mail_rounded,
                      onPressed: () => run(() async {
                            if (!await composeEmail(i.text, draft) && context.mounted) _say(context, 'No mail app found');
                          })),
                ],
                PillButton(label: 'Dismiss', danger: true, onPressed: () => run(() => setItemState(s, i, 'dismissed'))),
              ] else
                PillButton(label: 'Reopen', onPressed: () => run(() => setItemState(s, i, 'open'))),
            ]),
          ]),
        ),
      );
    },
  );
}

/// One-line status of an item: kind, due date, and where it is synced.
String itemStatus(BuildContext context, Item i) {
  final due = i.dueMs, remind = i.remindMs;
  return [
    itemKinds[i.kind]!,
    if (due != null) 'due ${formatDue(context, due)}',
    if (i.eventId != null) 'in your calendar',
    if (remind != null) 'reminder ${formatDue(context, remind)}',
  ].join(', ');
}

/// Everything pulled out of conversations, by kind, with what you can do about each one.
class ItemsScreen extends StatefulWidget {
  const ItemsScreen({super.key, required this.s, this.kind, this.showBack = true});

  final Services s;
  final String? kind; // start filtered to this kind
  final bool showBack;

  @override
  State<ItemsScreen> createState() => _ItemsScreenState();
}

class _ItemsScreenState extends State<ItemsScreen> {
  late String? _kind = widget.kind; // null = all kinds
  bool _done = false;

  /// Open to-dos swipe right to done, with Undo, as in most mail and to-do apps.
  Widget _row(Item i) {
    if (i.state != 'open') return _card(i);
    final s = widget.s;
    return Dismissible(
      key: ValueKey(i.id),
      direction: DismissDirection.startToEnd,
      background: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.only(left: 20),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(color: Palette.signal, borderRadius: BorderRadius.circular(20)),
        child: const Icon(Icons.check_rounded, color: Palette.bg),
      ),
      onDismissed: (_) {
        setItemState(s, i, 'done');
        setState(() {}); // the DB changed synchronously; the swiped row must leave the list now
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
              content: const Text('Marked done'),
              action: SnackBarAction(label: 'Undo', onPressed: () => setItemState(s, i, 'open'))));
      },
      child: _card(i),
    );
  }

  Widget _card(Item i) {
    final said = i.saidMs;
    return ListRow(
      marked: i.remindMs != null || i.eventId != null,
      dim: i.state != 'open',
      onTap: () => showItemActions(context, widget.s, i),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(itemStatus(context, i), style: TextStyles.caption),
        const SizedBox(height: 4),
        Text(i.text, style: TextStyles.body.copyWith(color: Palette.textHi)),
        const SizedBox(height: 4),
        Text('“${i.quote}”${said == null ? '' : ', ${clockTime(context, said)}'}',
            maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyles.caption),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return ListenableBuilder(
      listenable: s.changes,
      builder: (context, _) {
        final all = s.db.items().where((i) => _done ? i.state != 'open' : i.state == 'open');
        final shown = [for (final i in all) if (_kind == null || i.kind == _kind) i];
        return ScreenFrame(
          title: _done ? 'Done' : 'To-dos',
          wash: headerViolet,
          showBack: widget.showBack,
          action: CircleIconButton(
            icon: _done ? Icons.inbox_rounded : Icons.done_all_rounded,
            tooltip: _done ? 'Show open items' : 'Show done and dismissed',
            onPressed: () => setState(() => _done = !_done),
          ),
          children: [
            if (s.calendar.enabled && !s.calendar.hasAccess) ...[
              Tile(
                label: 'Put dated items in your calendar',
                child: Row(children: [
                  const Expanded(
                      child: Text('Tasks, promises and events with a date show up there with an alert.',
                          style: TextStyles.caption)),
                  const SizedBox(width: 12),
                  PillButton(label: 'Connect', light: true, onPressed: s.calendar.connect),
                ]),
              ),
              const SizedBox(height: 16),
            ],
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
            if (shown.isEmpty) ...[
              Text(
                  _done
                      ? 'Nothing done yet. Swipe a to-do right to mark it done.'
                      : !s.understanding.modelReady
                          ? 'To-dos are found by the on-phone AI. Download it to start.'
                          : 'Nothing here yet. Tasks, promises and plans you talk about show up here.',
                  style: TextStyles.body),
              if (!_done && !s.understanding.modelReady) ...[
                const SizedBox(height: 16),
                PillButton(
                    label: s.understanding.downloading
                        ? 'Downloading ${(s.understanding.downloadProgress * 100).floor()}%'
                        : 'Download the AI model',
                    light: true,
                    onPressed: s.understanding.downloading ? null : s.understanding.downloadModel),
              ],
            ]
            else
              ...shown.map(_row),
          ],
        );
      },
    );
  }
}
