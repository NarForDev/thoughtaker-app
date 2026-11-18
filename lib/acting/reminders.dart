import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../db.dart';

const _details = NotificationDetails(
  android: AndroidNotificationDetails('reminders', 'Reminders', importance: Importance.high, priority: Priority.high),
);

// The buttons open the app: answering needs the database, which lives in the app's isolate.
const _voiceDetails = NotificationDetails(
  android: AndroidNotificationDetails('voice_checks', 'Voice checks', actions: [
    AndroidNotificationAction('yes', 'Yes, me', showsUserInterface: true),
    AndroidNotificationAction('no', 'Not me', showsUserInterface: true),
  ]),
);
const _voiceCheckId = 0x40000000; // apart from item ids, which are reminder ids
const _voicePrefix = 'voice:';

/// Local notifications: reminders for items (the notification id is the item id; its payload opens the item's
/// moment) and "Is this you?" voice checks.
class Reminders {
  Reminders(this.db, {required this.onOpen, required this.onVoiceCheck});

  final AppDb db;
  final void Function(int itemId) onOpen;
  final void Function(int segmentId, bool? mine) onVoiceCheck; // mine is null when tapped without answering
  final _plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: _open,
    );
    final launch = await _plugin.getNotificationAppLaunchDetails();
    final response = launch?.notificationResponse;
    if ((launch?.didNotificationLaunchApp ?? false) && response != null) _open(response);
    // Drop reminders whose item was finished, dismissed or deleted while the app was closed.
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final i in db.items()) {
      final at = i.remindMs;
      if (at != null && (i.state != 'open' || at < now)) await cancel(i.id);
    }
  }

  void _open(NotificationResponse r) {
    final payload = r.payload ?? '';
    if (payload.startsWith(_voicePrefix)) {
      final id = int.tryParse(payload.substring(_voicePrefix.length));
      if (id != null) onVoiceCheck(id, switch (r.actionId) { 'yes' => true, 'no' => false, _ => null });
      return;
    }
    final id = int.tryParse(payload);
    if (id != null) onOpen(id);
  }

  /// Asks whether the line [segmentId] was the user speaking. One at a time: a new question replaces the last.
  Future<void> askAboutVoice(int segmentId, String quote) => _plugin.show(
      id: _voiceCheckId,
      title: 'Is this you?',
      body: '“$quote”',
      notificationDetails: _voiceDetails,
      payload: '$_voicePrefix$segmentId');

  Future<bool> notificationsAllowed() async =>
      await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.areNotificationsEnabled() ??
      false;

  /// Asks to show notifications. False if the user said no.
  Future<bool> requestPermission() async =>
      await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission() !=
      false;

  /// Schedules a reminder for [i] at [atMs]. False if the user refused notifications.
  Future<bool> schedule(Item i, int atMs) async {
    if (!await requestPermission()) return false;
    // UTC is enough for a one-shot reminder: it fires at the same instant in any zone.
    await _plugin.zonedSchedule(
      id: i.id,
      scheduledDate: tz.TZDateTime.fromMillisecondsSinceEpoch(tz.UTC, atMs),
      notificationDetails: _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      title: i.text,
      body: i.quote,
      payload: '${i.id}',
    );
    db.setReminder(i.id, atMs);
    return true;
  }

  Future<void> cancel(int itemId) async {
    await _plugin.cancel(id: itemId);
    db.setReminder(itemId, null);
  }
}
