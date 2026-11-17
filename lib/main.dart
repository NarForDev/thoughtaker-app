import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'ai/transcription_service.dart';
import 'db.dart';
import 'pendant.dart';
import 'screens/device_screen.dart';
import 'screens/search_screen.dart';
import 'screens/timeline_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final docs = await getApplicationDocumentsDirectory();
  final chunks = await Directory('${docs.path}/chunks').create(recursive: true);
  final partial = await Directory('${docs.path}/partial').create(recursive: true);
  final db = AppDb(sqlite3.open('${docs.path}/thoughtaker.db'));
  final pendant = PendantController(db, NoopTranscriptionService(), chunksDir: chunks, partialDir: partial);
  runApp(ThoughtakerApp(db: db, pendant: pendant));
}

class ThoughtakerApp extends StatelessWidget {
  const ThoughtakerApp({super.key, required this.db, required this.pendant});

  final AppDb db;
  final PendantController pendant;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Thoughtaker',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
      darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark)),
      home: HomeShell(db: db, pendant: pendant),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.db, required this.pendant});

  final AppDb db;
  final PendantController pendant;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _tab, children: [
        TimelineScreen(db: widget.db, pendant: widget.pendant),
        SearchScreen(db: widget.db),
        DeviceScreen(pendant: widget.pendant),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.timeline), label: 'Timeline'),
          NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
          NavigationDestination(icon: Icon(Icons.bluetooth), label: 'Device'),
        ],
      ),
    );
  }
}
