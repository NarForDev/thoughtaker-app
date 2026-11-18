import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';

import '../ai/on_device_transcription.dart' show modelBytes;
import '../ai/understanding.dart' show llmModel;
import '../services.dart';
import '../ui/painters.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'app_shell.dart';

const onboardedKey = 'onboarded';

/// First run, one step per screen: welcome, pair, download the on-phone AI, reminders and calendar.
/// Every step after the welcome can be skipped; Home lists whatever is left.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.s});

  final Services s;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _steps = 4;
  int _step = 0;
  bool? _notifications; // null until asked

  Services get s => widget.s;

  void _next() {
    if (_step == _steps - 1) return _finish();
    setState(() => _step++);
    if (_step == 1 && !s.pendant.hasDevice && !s.pendant.busy) s.pendant.scan();
  }

  void _finish() {
    s.db.setSetting(onboardedKey, '1');
    Navigator.of(context)
        .pushAndRemoveUntil(MaterialPageRoute<void>(builder: (_) => AppShell(s: s)), (_) => false);
  }

  Future<void> _downloadAll() async {
    if (!s.transcriber.modelsReady) await s.transcriber.downloadModels();
    if (!s.understanding.modelReady) await s.understanding.downloadModel();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        body: Stack(children: [
          Container(
              height: MediaQuery.sizeOf(context).height * 0.45, decoration: const BoxDecoration(gradient: headerViolet)),
          SafeArea(
            child: ListenableBuilder(
              listenable: s.changes,
              builder: (context, _) {
                final (title, body, content, primary, onPrimary) = switch (_step) {
                  0 => _welcome(),
                  1 => _pair(),
                  2 => _ai(),
                  _ => _reminders(),
                };
                return Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(
                      height: 44,
                      child: Row(children: [
                        for (var i = 0; i < _steps; i++)
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            margin: const EdgeInsets.only(right: 6),
                            width: i == _step ? 20 : 6,
                            height: 6,
                            decoration: BoxDecoration(
                                color: i <= _step ? Palette.textHi : Palette.stroke,
                                borderRadius: BorderRadius.circular(999)),
                          ),
                        const Spacer(),
                        if (_step > 0 && _step < _steps - 1) TextLink('Not now', onTap: _next),
                      ]),
                    ),
                    const SizedBox(height: 32),
                    Text(title, style: TextStyles.display),
                    const SizedBox(height: 12),
                    Text(body, style: TextStyles.body.copyWith(color: Palette.textHi)),
                    const SizedBox(height: 24),
                    Expanded(child: ListView(padding: EdgeInsets.zero, children: content)),
                    SizedBox(
                      width: double.infinity,
                      child: PillButton(label: primary, light: true, onPressed: onPrimary),
                    ),
                  ]),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  (String, String, List<Widget>, String, VoidCallback?) _welcome() => (
        'Your conversations, remembered',
        'Wear the pendant and talk as usual. This phone turns what was said into transcripts, to-dos and reminders. '
            'Everything stays on this phone.',
        [const SizedBox(height: 24), const Center(child: HalftoneSphere(size: 180, lit: true))],
        'Get started',
        _next,
      );

  (String, String, List<Widget>, String, VoidCallback?) _pair() {
    final p = s.pendant;
    return (
      'Pair your pendant',
      'Switch it on and keep it close. If it does not show up, hold its button for 3 seconds and search again.',
      [
        if (p.hasDevice)
          Tile(label: p.connected ? 'Connected' : 'Paired', glow: glowBlue, child: Text(p.message, style: TextStyles.body))
        else ...[
          Text(p.message, style: TextStyles.caption),
          const SizedBox(height: 12),
          for (final d in p.found)
            ListRow(
              onTap: p.busy ? null : () => p.pair(d.deviceId),
              child: Row(children: [
                Expanded(child: Text(d.name ?? 'Pendant', style: TextStyles.label)),
                const Text('Pair', style: TextStyles.label),
              ]),
            ),
        ],
      ],
      p.hasDevice ? 'Continue' : (p.busy ? 'Searching…' : 'Search again'),
      p.hasDevice ? _next : (p.busy ? null : p.scan),
    );
  }

  (String, String, List<Widget>, String, VoidCallback?) _ai() {
    final t = s.transcriber, u = s.understanding;
    final ready = t.modelsReady && u.modelReady, busy = t.downloading || u.downloading;
    final gb = ((modelBytes + llmModel.size) / 1e9).toStringAsFixed(1);
    Widget row(String label, bool done, bool downloading, double progress) => ListRow(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(label, style: TextStyles.label)),
              Text(done ? 'Ready' : (downloading ? '${(progress * 100).floor()}%' : 'Not downloaded'),
                  style: TextStyles.caption),
            ]),
            if (downloading) ...[const SizedBox(height: 8), DottedTrack(value: progress)],
          ]),
        );
    return (
      'Get the on-phone AI',
      'Speech recognition, voices and the AI that finds to-dos run on this phone. One download of about $gb GB; '
          'use Wi-Fi.',
      [
        row('Speech and voices', t.modelsReady, t.downloading, t.downloadProgress),
        row('To-dos and summaries', u.modelReady, u.downloading, u.downloadProgress),
        if (t.error ?? u.error case final e?) Text(e, style: TextStyles.body.copyWith(color: Palette.danger)),
        if (busy) const Text('You can carry on; the download continues in the background.', style: TextStyles.caption),
      ],
      ready || busy ? 'Continue' : 'Download',
      ready || busy ? _next : _downloadAll,
    );
  }

  (String, String, List<Widget>, String, VoidCallback?) _reminders() {
    final c = s.calendar;
    Widget row(String label, String caption, bool? on, String action, VoidCallback go) => ListRow(
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: TextStyles.label),
                const SizedBox(height: 4),
                Text(caption, style: TextStyles.caption),
              ]),
            ),
            const SizedBox(width: 12),
            if (on == true)
              const Icon(Icons.check_rounded, color: Palette.signal)
            else
              PillButton(label: on == false ? 'Try again' : action, onPressed: go),
          ]),
        );
    return (
      'Reminders and calendar',
      'Plans and deadlines you say a date for go into your calendar with an alert. Nothing else does.',
      [
        row('Notifications', 'For reminders you set on a to-do.', _notifications, 'Allow', () async {
          final ok = await s.reminders.requestPermission();
          if (mounted) setState(() => _notifications = ok);
        }),
        row('Calendar', 'Your own calendar app, synced to your account.', c.hasAccess ? true : null, 'Connect',
            c.connect),
      ],
      'Done',
      _finish,
    );
  }
}
