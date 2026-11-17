import 'package:flutter/services.dart';

import '../db.dart';

const _intents = MethodChannel('thoughtaker/intents');

/// A message the user can send about [i], or null when the kind has nothing to send.
/// shortcut: fixed templates; an LLM could word these per person once drafts prove useful.
String? draftFor(Item i) => switch (i.kind) {
      'my_promise' => 'Hi! As promised: ${i.text}.',
      'their_promise' => 'Hi! Just checking in on this: ${i.text}. Thanks!',
      'task' || 'event' => i.text,
      _ => null,
    };

/// Default reminder time: 1 h before a timed deadline, 09:00 on a date-only one, and two days later
/// at 09:00 to follow up on a promise made to you. Null when there is nothing sensible to suggest.
int? defaultReminder(Item i, DateTime now) {
  final due = i.dueMs == null ? null : DateTime.fromMillisecondsSinceEpoch(i.dueMs!);
  DateTime? at;
  if (due != null) {
    final dateOnly = due.hour == 0 && due.minute == 0;
    at = dateOnly ? DateTime(due.year, due.month, due.day, 9) : due.subtract(const Duration(hours: 1));
  } else if (i.kind == 'their_promise') {
    at = DateTime(now.year, now.month, now.day + 2, 9);
  }
  if (at == null) return null;
  return at.isAfter(now) ? at.millisecondsSinceEpoch : null;
}

/// Opens the calendar app with the event prefilled. False if no calendar app is installed.
Future<bool> addToCalendar(Item i) async =>
    await _intents.invokeMethod<bool>('insertEvent', {
      'title': i.text,
      'beginMs': i.dueMs,
      'allDay': i.dueMs != null && DateTime.fromMillisecondsSinceEpoch(i.dueMs!).hour == 0,
    }) ??
    false;

Future<bool> composeEmail(String subject, String body) async =>
    await _intents.invokeMethod<bool>('composeEmail', {'subject': subject, 'body': body}) ?? false;

Future<bool> shareText(String text) async => await _intents.invokeMethod<bool>('shareText', {'text': text}) ?? false;
