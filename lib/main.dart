import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'ai/on_device_transcription.dart';
import 'ai/understanding.dart';
import 'acting/calendar.dart';
import 'acting/reminders.dart';
import 'db.dart';
import 'pendant.dart';
import 'screens/conversation_screen.dart';
import 'services.dart';
import 'screens/app_shell.dart';
import 'screens/onboarding_screen.dart';
import 'screens/voice_check_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final docs = await getApplicationDocumentsDirectory();
  final chunks = await Directory('${docs.path}/chunks').create(recursive: true);
  final partial = await Directory('${docs.path}/partial').create(recursive: true);
  final db = AppDb(sqlite3.open('${docs.path}/thoughtaker.db'));
  final models = Directory('${(await getApplicationSupportDirectory()).path}/models');
  final transcriber = OnDeviceTranscriptionService(db, models)..start();
  final understanding = UnderstandingService(db, models, mayRunNow: transcriber.mayRunNow)..start();
  transcriber.addListener(understanding.kick); // a finished transcript is new work for understanding
  final navigator = GlobalKey<NavigatorState>();
  late final Services services;
  // A reminder tap opens the moment the item was said.
  final reminders = Reminders(db, onOpen: (id) {
    final i = db.item(id), context = navigator.currentContext;
    if (i != null && context != null) openConversationAt(context, services, i.chunkId, i.atMs);
  }, onVoiceCheck: (segmentId, mine) {
    // An answer from the notification's buttons counts at once; the screen then offers the rest.
    if (mine != null) services.answerVoiceCheck(segmentId, mine);
    navigator.currentState?.push(MaterialPageRoute<void>(builder: (_) => VoiceCheckScreen(s: services)));
  });
  final calendar = CalendarSync(db);
  understanding.addListener(() {
    if (!understanding.downloading) calendar.sync(); // new or changed items go to the calendar
  });
  final pendant = PendantController(db, transcriber.kick, chunksDir: chunks, partialDir: partial)..startAutoSync();
  services = Services(
    db: db,
    pendant: pendant,
    transcriber: transcriber,
    understanding: understanding,
    reminders: reminders,
    calendar: calendar,
    partialDir: partial,
  );
  // New transcripts bring new lines to check once a batch is done.
  transcriber.addListener(() {
    if (!transcriber.working) services.refreshVoiceChecks();
  });
  runApp(ThoughtakerApp(s: services, navigator: navigator));
  await reminders.init(); // after runApp, so a launch from a notification can navigate
  await services.refreshVoiceChecks();
  await calendar.sync();
}

class ThoughtakerApp extends StatelessWidget {
  const ThoughtakerApp({super.key, required this.s, required this.navigator});

  final Services s;
  final GlobalKey<NavigatorState> navigator;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Thoughtaker',
      theme: appTheme,
      navigatorKey: navigator,
      home: s.db.setting(onboardedKey) == null ? OnboardingScreen(s: s) : AppShell(s: s),
    );
  }
}
