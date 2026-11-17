import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'ai/on_device_transcription.dart';
import 'ai/understanding.dart';
import 'acting/reminders.dart';
import 'db.dart';
import 'pendant.dart';
import 'screens/conversation_screen.dart';
import 'screens/home_screen.dart';
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
  // A reminder tap opens the moment the item was said.
  final reminders = Reminders(db, onOpen: (id) {
    final i = db.item(id), context = navigator.currentContext;
    if (i != null && context != null) openConversationAt(context, db, transcriber, i.chunkId, i.atMs);
  });
  final pendant = PendantController(db, transcriber.kick, chunksDir: chunks, partialDir: partial)..startAutoSync();
  runApp(ThoughtakerApp(
      db: db,
      pendant: pendant,
      transcriber: transcriber,
      understanding: understanding,
      reminders: reminders,
      navigator: navigator));
  await reminders.init(); // after runApp, so a launch from a notification can navigate
}

class ThoughtakerApp extends StatelessWidget {
  const ThoughtakerApp(
      {super.key,
      required this.db,
      required this.pendant,
      required this.transcriber,
      required this.understanding,
      required this.reminders,
      required this.navigator});

  final AppDb db;
  final PendantController pendant;
  final OnDeviceTranscriptionService transcriber;
  final UnderstandingService understanding;
  final Reminders reminders;
  final GlobalKey<NavigatorState> navigator;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Thoughtaker',
      theme: appTheme,
      navigatorKey: navigator,
      home: HomeScreen(
          db: db, pendant: pendant, transcriber: transcriber, understanding: understanding, reminders: reminders),
    );
  }
}
