import 'package:material_ui/material_ui.dart';

import '../ai/on_device_transcription.dart';
import '../pendant.dart';

class DeviceScreen extends StatelessWidget {
  const DeviceScreen({super.key, required this.pendant, required this.transcriber});

  final PendantController pendant;
  final OnDeviceTranscriptionService transcriber;

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
                  onPressed: idle ? (p.hasDevice ? p.syncNow : p.scan) : null,
                  icon: Icon(p.hasDevice ? Icons.sync : Icons.bluetooth_searching),
                  label: Text(p.connected ? 'Sync now' : (p.hasDevice ? 'Connect' : 'Find pendants')),
                ),
                if (p.connected) OutlinedButton(onPressed: p.disconnect, child: const Text('Disconnect')),
                if (!p.connected && p.hasDevice && idle) TextButton(onPressed: p.forget, child: const Text('Forget')),
              ]),
              if (!p.hasDevice)
                for (final d in p.found)
                  ListTile(
                    leading: const Icon(Icons.bluetooth),
                    title: Text(d.name ?? 'Unnamed'),
                    subtitle: Text(d.deviceId),
                    trailing: const Text('Pair'),
                    onTap: idle ? () => p.pair(d.deviceId) : null,
                  ),
              if (s != null) ...[
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('Mute'),
                  subtitle: const Text('Stops the microphone'),
                  value: s.muted,
                  onChanged: p.connected && idle ? p.setMute : null,
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
              const SizedBox(height: 12),
              ListenableBuilder(
                listenable: transcriber,
                builder: (context, _) {
                  final t = transcriber;
                  final pending = t.db.untranscribedCount();
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Transcription', style: Theme.of(context).textTheme.titleSmall),
                    if (!t.modelsReady) ...[
                      ListTile(
                        title: const Text('Speech models'),
                        subtitle: Text(t.downloading
                            ? 'Downloading ${(t.downloadProgress * 100).floor()}%'
                            : 'Needed once, ${(modelBytes / 1e6).round()} MB. Use Wi-Fi.'),
                        trailing: FilledButton(
                            onPressed: t.downloading ? null : t.downloadModels, child: const Text('Download')),
                      ),
                      if (t.downloading) LinearProgressIndicator(value: t.downloadProgress),
                    ],
                    SwitchListTile(
                      title: const Text('Transcribe only while charging'),
                      value: t.onlyWhileCharging,
                      onChanged: (v) => t.onlyWhileCharging = v,
                    ),
                    ListTile(
                      title: const Text('Waiting to transcribe'),
                      subtitle: t.working ? const Text('Transcribing…') : null,
                      trailing: Text('$pending chunks'),
                    ),
                    if (t.error != null) ListTile(leading: const Icon(Icons.error_outline), title: Text(t.error!)),
                  ]);
                },
              ),
            ],
          );
        },
      ),
    );
  }
}
