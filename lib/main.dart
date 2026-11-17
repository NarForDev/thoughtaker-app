import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'ai/on_device_transcription.dart';
import 'db.dart';
import 'pendant.dart';
import 'screens/home_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final docs = await getApplicationDocumentsDirectory();
  final chunks = await Directory('${docs.path}/chunks').create(recursive: true);
  final partial = await Directory('${docs.path}/partial').create(recursive: true);
  final db = AppDb(sqlite3.open('${docs.path}/thoughtaker.db'));
  final transcriber =
      OnDeviceTranscriptionService(db, Directory('${(await getApplicationSupportDirectory()).path}/models'))..start();
  final pendant = PendantController(db, transcriber.kick, chunksDir: chunks, partialDir: partial)..startAutoSync();
  runApp(ThoughtakerApp(db: db, pendant: pendant, transcriber: transcriber));
}

class ThoughtakerApp extends StatelessWidget {
  const ThoughtakerApp({super.key, required this.db, required this.pendant, required this.transcriber});

  final AppDb db;
  final PendantController pendant;
  final OnDeviceTranscriptionService transcriber;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Thoughtaker',
      theme: appTheme,
      home: HomeScreen(db: db, pendant: pendant, transcriber: transcriber),
    );
  }
}
