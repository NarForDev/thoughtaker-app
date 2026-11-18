import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../db.dart';

const calendarChannel = MethodChannel('thoughtaker/calendar');
const _syncKey = 'calendar_sync';

/// Worth a calendar entry: an open plan, task or promise of yours, for a day that was actually said, today or later.
/// Promises made to you stay in the app until you ask for a reminder.
bool belongsInCalendar(Item i, DateTime now) =>
    i.state == 'open' &&
    i.dueMs != null &&
    i.dueMs! >= DateTime(now.year, now.month, now.day).millisecondsSinceEpoch &&
    const {'task', 'my_promise', 'event'}.contains(i.kind);

/// Keeps the user's calendar in step with items: adds dated ones (with an alert an hour before a timed one),
/// removes them once done, dismissed or deleted. The calendar syncs them to the user's account.
class CalendarSync extends ChangeNotifier {
  CalendarSync(this.db);

  final AppDb db;
  bool hasAccess = false;
  Future<void>? _running;

  bool get enabled => db.setting(_syncKey) != '0';

  set enabled(bool v) {
    db.setSetting(_syncKey, v ? null : '0');
    notifyListeners();
    sync();
  }

  Future<void> refreshAccess() async {
    hasAccess = await calendarChannel.invokeMethod<bool>('hasAccess') ?? false;
    notifyListeners();
  }

  /// Asks for calendar permission, then syncs. False if the user said no.
  Future<bool> connect() async {
    hasAccess = await calendarChannel.invokeMethod<bool>('requestAccess') ?? false;
    notifyListeners();
    if (hasAccess) await sync();
    return hasAccess;
  }

  Future<void> sync() => _running ??= _sync().whenComplete(() => _running = null);

  Future<void> _sync() async {
    await refreshAccess();
    if (!hasAccess) return;
    final now = DateTime.now();
    for (final i in db.items()) {
      if (i.eventId == null) {
        if (!enabled || !belongsInCalendar(i, now)) continue;
        final id = await _insert(i);
        if (id != null) db.setEventId(i.id, id);
      } else if (!enabled || i.state != 'open') { // past entries stay as a record
        await remove(i);
      }
    }
    for (final id in db.staleEvents()) {
      await calendarChannel.invokeMethod<void>('delete', {'eventId': id});
      db.dropStaleEvent(id);
    }
    notifyListeners();
  }

  Future<void> remove(Item i) async {
    final id = i.eventId;
    if (id == null) return;
    await calendarChannel.invokeMethod<void>('delete', {'eventId': id});
    db.setEventId(i.id, null);
  }

  Future<int?> _insert(Item i) {
    final due = DateTime.fromMillisecondsSinceEpoch(i.dueMs!);
    final allDay = due.hour == 0 && due.minute == 0; // the model gave a date only
    return calendarChannel.invokeMethod<int>('insert', {
      'title': i.text,
      'description': '"${i.quote}"\nFrom Thoughtaker',
      // Android stores all-day events as UTC midnights.
      'beginMs': allDay ? DateTime.utc(due.year, due.month, due.day).millisecondsSinceEpoch : i.dueMs,
      'allDay': allDay,
      'alertMinutes': allDay ? null : 60,
    });
  }
}
