import 'package:material_ui/material_ui.dart';

import '../pendant.dart';

class DeviceScreen extends StatelessWidget {
  const DeviceScreen({super.key, required this.pendant});

  final PendantController pendant;

  static String _gb(int kib) => '${(kib / 1048576).toStringAsFixed(1)} GB';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pendant')),
      body: ListenableBuilder(
        listenable: pendant,
        builder: (context, _) {
          final p = pendant;
          final s = p.status;
          final idle = !p.busy;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: ListTile(
                  leading: Icon(p.connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled),
                  title: Text(p.connected ? 'Connected' : 'Not connected'),
                  subtitle: Text(p.message),
                ),
              ),
              if (p.syncing) LinearProgressIndicator(value: p.pullProgress),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(
                  onPressed: idle ? p.syncNow : null,
                  icon: const Icon(Icons.sync),
                  label: Text(p.connected ? 'Sync now' : (p.hasDevice ? 'Connect' : 'Pair pendant')),
                ),
                if (p.connected) OutlinedButton(onPressed: p.disconnect, child: const Text('Disconnect')),
                if (!p.connected && p.hasDevice && idle) TextButton(onPressed: p.forget, child: const Text('Forget')),
              ]),
              if (s != null) ...[
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('Mute'),
                  subtitle: const Text('Stops the microphone'),
                  value: s.muted,
                  onChanged: p.connected && idle ? p.setMute : null,
                ),
                SwitchListTile(
                  title: const Text('Wake word'),
                  subtitle: const Text('Say it to bookmark a moment'),
                  value: s.wakeWord,
                  onChanged: p.connected && idle ? p.setWakeWord : null,
                ),
                ListTile(
                  title: const Text('Recording'),
                  trailing: Text(s.recording ? 'Yes' : 'No'),
                ),
                ListTile(
                  title: const Text('Storage'),
                  trailing: Text('${_gb(s.freeKib)} free of ${_gb(s.totalKib)}'),
                ),
                ListTile(title: const Text('Waiting to sync'), trailing: Text('${s.pendingChunks} chunks')),
                ListTile(
                  title: const Text('Battery'),
                  trailing: Text(s.batteryPct == 0xFF ? 'Unknown' : '${s.batteryPct}%'),
                ),
                if (s.storageFull)
                  const ListTile(
                    leading: Icon(Icons.warning_amber),
                    title: Text('Storage full: recording stopped until you sync'),
                  ),
                if (s.sdError)
                  const ListTile(leading: Icon(Icons.error_outline), title: Text('SD card error on the pendant')),
              ],
            ],
          );
        },
      ),
    );
  }
}
