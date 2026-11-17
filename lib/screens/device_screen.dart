import 'package:material_ui/material_ui.dart';

import '../ai/on_device_transcription.dart';
import '../pendant.dart';
import '../ui/painters.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

class DeviceScreen extends StatelessWidget {
  const DeviceScreen({super.key, required this.pendant, required this.transcriber});

  final PendantController pendant;
  final OnDeviceTranscriptionService transcriber;

  static String _gb(int kib) => (kib / 1048576).toStringAsFixed(1);

  Widget _stat(String label, String value, String unit) => Tile(
        label: label,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          DotMatrixText(value, height: 28),
          const SizedBox(height: 6),
          Text(unit, style: TextStyles.caption),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([pendant, transcriber]),
      builder: (context, _) {
        final p = pendant;
        final s = p.status;
        final idle = !p.busy;
        final t = transcriber;
        final pending = t.db.untranscribedCount();
        return ScreenFrame(
          title: 'Pendant',
          action: !p.connected && p.hasDevice && idle
              ? CircleIconButton(icon: Icons.link_off_rounded, tooltip: 'Forget pendant', onPressed: p.forget)
              : null,
          panel: ControlPanel(
            child: Row(children: [
              Expanded(
                child: PillButton(
                  light: true,
                  label: p.connected ? 'Sync now' : (p.hasDevice ? 'Connect' : 'Find pendants'),
                  icon: p.hasDevice ? Icons.sync_rounded : Icons.bluetooth_searching_rounded,
                  onPressed: idle ? (p.hasDevice ? p.syncNow : p.scan) : null,
                ),
              ),
              if (p.connected) ...[
                const SizedBox(width: 12),
                CircleIconButton(icon: Icons.bluetooth_disabled_rounded, tooltip: 'Disconnect', onPressed: p.disconnect),
              ],
            ]),
          ),
          children: [
            const SizedBox(height: 8),
            Center(child: HalftoneSphere(size: 150, lit: p.connected)),
            const SizedBox(height: 16),
            Text(p.connected ? 'Connected' : 'Not connected', textAlign: TextAlign.center, style: TextStyles.title),
            const SizedBox(height: 4),
            Text(p.message, textAlign: TextAlign.center, style: TextStyles.body),
            if (p.syncing) ...[const SizedBox(height: 12), DottedTrack(value: p.pullProgress)],
            if (!p.hasDevice)
              for (final d in p.found)
                ListRow(
                  onTap: idle ? () => p.pair(d.deviceId) : null,
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(d.name ?? 'Unnamed', style: TextStyles.label),
                        Text(d.deviceId, style: TextStyles.caption),
                      ]),
                    ),
                    const Text('Pair', style: TextStyles.label),
                  ]),
                ),
            if (s != null) ...[
              const SizedBox(height: 24),
              IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(
                      child: _stat('Battery', s.batteryPct == 0xFF ? '-' : '${s.batteryPct}%',
                          s.batteryPct == 0xFF ? 'not measured' : 'charge')),
                  const SizedBox(width: 8),
                  Expanded(child: _stat('Storage', _gb(s.freeKib), 'GB free of ${_gb(s.totalKib)}')),
                ]),
              ),
              const SizedBox(height: 8),
              IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: _stat('Waiting to sync', '${s.pendingChunks}', 'chunks')),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Tile(
                      label: 'Recording',
                      child: Text(s.muted ? 'Muted' : (s.recording ? 'Listening' : 'Idle'), style: TextStyles.title),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 8),
              PillToggle(label: 'Mute microphone', value: s.muted, onChanged: p.connected && idle ? p.setMute : null),
              if (s.storageFull || s.sdError) ...[
                const SizedBox(height: 8),
                Tile(
                  label: s.sdError ? 'SD card error' : 'Storage full',
                  glow: glowEmber,
                  child: Text(s.sdError ? 'Check the card in the pendant.' : 'Recording stopped until you sync.',
                      style: TextStyles.body.copyWith(color: Palette.textHi)),
                ),
              ],
            ],
            const SectionHeader('Transcription'),
            if (!t.modelsReady)
              ListRow(
                onTap: t.downloading ? null : t.downloadModels,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Speech models', style: TextStyles.label),
                  const SizedBox(height: 4),
                  Text(
                      t.downloading
                          ? 'Downloading ${(t.downloadProgress * 100).floor()}%'
                          : 'Tap to download once, ${(modelBytes / 1e6).round()} MB. Use Wi-Fi.',
                      style: TextStyles.caption),
                  if (t.downloading) ...[const SizedBox(height: 8), DottedTrack(value: t.downloadProgress)],
                ]),
              ),
            PillToggle(
                label: 'Transcribe only while charging',
                value: t.onlyWhileCharging,
                onChanged: (v) => t.onlyWhileCharging = v),
            const SizedBox(height: 8),
            ListRow(
              child: Row(children: [
                Expanded(
                  child: Text(t.working ? 'Transcribing…' : 'Waiting to transcribe', style: TextStyles.label),
                ),
                Text('$pending chunks', style: TextStyles.caption),
              ]),
            ),
            if (t.error != null) Text(t.error!, style: TextStyles.body.copyWith(color: Palette.danger)),
          ],
        );
      },
    );
  }
}
