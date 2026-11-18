import 'package:material_ui/material_ui.dart';

import '../protocol.dart';

String formatDuration(int ms) {
  final s = ms ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Local clock time of an epoch [ms], in the device's 12/24 h format.
String clockTime(BuildContext context, int ms) =>
    MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(ms)));

/// What the pendant is doing with sound (protocol 4.2): muted, keeping audio, or waiting for its wake word.
String recordingLabel(DeviceStatus s) => s.muted
    ? 'Muted'
    : s.recording
        ? 'Recording'
        : s.wakeWord
            ? 'Waiting for "Perthro"'
            : 'Not recording';

/// "1 h 05 min" style talk time.
String talkTime(int ms) {
  final m = ms ~/ 60000;
  return m < 60 ? '$m min' : '${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')} min';
}
