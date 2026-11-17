import 'package:material_ui/material_ui.dart';

String formatDuration(int ms) {
  final s = ms ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Local clock time of an epoch [ms], in the device's 12/24 h format.
String clockTime(BuildContext context, int ms) =>
    MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(ms)));

/// "1 h 05 min" style talk time.
String talkTime(int ms) {
  final m = ms ~/ 60000;
  return m < 60 ? '$m min' : '${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')} min';
}
