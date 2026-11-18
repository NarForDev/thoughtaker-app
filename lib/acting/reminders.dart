import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../db.dart';

const _details = NotificationDetails(
  android: AndroidNotificationDetails('reminders', 'Reminders', importance: Importance.high, priority: Priority.high),
);

/// Local notifications for items. The notification id is the item id; its payload opens the item's moment.
class Reminders {
  Reminders(this.db, {required this.onOpen});

  final AppDb db;
  final void Function(int itemId) onOpen;
  final _plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: (r) => _open(r.payload),
    );
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) _open(launch!.notificationResponse?.payload);
    // Drop reminders whose item was finished, dismissed or deleted while the app was closed.
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final i in db.items()) {
      final at = i.remindMs;
      if (at != null && (i.state != 'open' || at < now)) await cancel(i.id);
    }
  }

  void _open(String? payload) {
    final id = int.tryParse(payload ?? '');
    if (id != null) onOpen(id);
  }

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
