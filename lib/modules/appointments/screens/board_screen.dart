import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kendra_hms/core/core.dart';

import '../appointment_service.dart';
import 'queue_screen.dart';

/// The waiting-room TV: who is being seen now, by which doctor, in which
/// room. Tokens only, no patient names. Updates live.
class QueueBoardScreen extends StatefulWidget {
  const QueueBoardScreen({super.key, this.fullScreen = false});

  /// Pushed over the whole app (from "Show on TV") rather than inside it.
  final bool fullScreen;

  @override
  State<QueueBoardScreen> createState() => _QueueBoardScreenState();
}

class _QueueBoardScreenState extends State<QueueBoardScreen> {
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
    if (widget.fullScreen) SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _clock?.cancel();
    if (widget.fullScreen) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final colors = _BoardColors(
      bg: dark ? cs.surface : cs.inverseSurface,
      fg: dark ? cs.onSurface : cs.onInverseSurface,
      accent: dark ? cs.primary : cs.inversePrimary,
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: colors.bg,
          body: SafeArea(
            child: LiveBuilder<QueueData>(
              watch: const {Col.encounters, ApptCol.schedules},
              loading: Center(child: CircularProgressIndicator(color: colors.accent)),
              load: QueueData.load,
              builder: (context, data) => _Board(data: data, colors: colors, fullScreen: widget.fullScreen),
            ),
          ),
        ),
      ),
    );
  }
}

class _BoardColors {
  const _BoardColors({required this.bg, required this.fg, required this.accent});
  final Color bg;
  final Color fg;
  final Color accent;
  Color get muted => fg.withValues(alpha: 0.68);
  Color get panel => fg.withValues(alpha: 0.06);
  Color get line => fg.withValues(alpha: 0.14);
}

class _Board extends StatelessWidget {
  const _Board({required this.data, required this.colors, required this.fullScreen});
  final QueueData data;
  final _BoardColors colors;
  final bool fullScreen;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final size = MediaQuery.sizeOf(context);
    final scale = size.width < 700 ? 0.62 : (size.width < 1100 ? 0.8 : 1.0);
    final queues = data.queues;
    final hospital = context.app.settings.hospitalName;
    final pad = 32.0 * scale;

    final controls = fullScreen
        ? IconButton(
            tooltip: 'Close (Esc)',
            color: colors.muted,
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).maybePop(),
          )
        : FilledButton.tonalIcon(
            onPressed: () => openTvBoard(context),
            icon: const Icon(Icons.fullscreen),
            label: const Text('Full screen'),
          );

    final name = Text(hospital,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colors.fg, fontSize: 30 * scale, fontWeight: FontWeight.w700));
    final date = Text('OPD waiting room · ${weekdayName(now.weekday)}, ${formatDate(now)}',
        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: colors.muted, fontSize: 20 * scale));
    final clock = Text(formatTime(now),
        style: TextStyle(
            color: colors.fg,
            fontSize: 44 * scale,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()]));
    final header = size.width < 700
        ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [Expanded(child: name), controls]),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Expanded(child: date), clock]),
          ])
        : Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [name, date])),
            clock,
            SizedBox(width: 16 * scale),
            controls,
          ]);

    return Padding(
      padding: EdgeInsets.all(pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          SizedBox(height: 24 * scale),
          Expanded(
            child: queues.isEmpty
                ? Center(
                    child: Text('No OPD running right now',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.muted, fontSize: 40 * scale, fontWeight: FontWeight.w600)),
                  )
                : LayoutBuilder(builder: (context, c) {
                    // One row of tall panels when it fits; otherwise rows of wide, short ones.
                    final cols = math.max(1, math.min(queues.length, (c.maxWidth / (300 * scale)).floor()));
                    final rows = (queues.length / cols).ceil();
                    final gap = 20.0 * scale;
                    return Column(
                      children: [
                        for (var r = 0; r < rows; r++) ...[
                          if (r > 0) SizedBox(height: gap),
                          Expanded(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var i = 0; i < cols; i++) ...[
                                  if (i > 0) SizedBox(width: gap),
                                  Expanded(
                                    child: r * cols + i < queues.length
                                        ? _DoctorPanel(queue: queues[r * cols + i], colors: colors, scale: scale)
                                        : const SizedBox.shrink(),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ],
                    );
                  }),
          ),
          SizedBox(height: 20 * scale),
          Text(
            'Please wait for your token number to appear. Thank you for your patience.',
            textAlign: TextAlign.center,
            maxLines: 2,
            style: TextStyle(color: colors.muted, fontSize: 22 * scale),
          ),
        ],
      ),
    );
  }
}

class _DoctorPanel extends StatelessWidget {
  const _DoctorPanel({required this.queue, required this.colors, required this.scale});
  final DoctorQueue queue;
  final _BoardColors colors;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final q = queue;
    final now = q.withDoctor.isEmpty ? null : q.withDoctor.last.integer('token_no');
    final next = q.waiting.take(4).map((e) => e.integer('token_no')).toList();
    TextStyle label() =>
        TextStyle(color: colors.muted, fontSize: 18 * scale, letterSpacing: 2, fontWeight: FontWeight.w700);

    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(q.doctor.str('display_name'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.fg, fontSize: 32 * scale, fontWeight: FontWeight.w700)),
        Text([q.doctor.str('department'), q.room].where((s) => s.isNotEmpty).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.muted, fontSize: 22 * scale)),
      ],
    );
    final seeing = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('NOW SEEING', style: label()),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                now == null ? '—' : '$now',
                style: TextStyle(
                  color: now == null ? colors.muted : colors.accent,
                  fontSize: 150 * scale,
                  height: 1.05,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ],
    );
    final upNext = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('NEXT', style: label()),
        SizedBox(height: 8 * scale),
        SizedBox(
          height: 56 * scale,
          child: next.isEmpty
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: Text('No one waiting', style: TextStyle(color: colors.muted, fontSize: 24 * scale)),
                )
              : FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: [
                      for (final (i, t) in next.indexed) ...[
                        if (i > 0) SizedBox(width: 12 * scale),
                        Container(
                          constraints: BoxConstraints(minWidth: 64 * scale),
                          padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 6 * scale),
                          decoration: BoxDecoration(
                            border: Border.all(color: colors.line),
                            borderRadius: BorderRadius.circular(12 * scale),
                          ),
                          alignment: Alignment.center,
                          child: Text('$t',
                              style: TextStyle(
                                  color: colors.fg,
                                  fontSize: 32 * scale,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: const [FontFeature.tabularFigures()])),
                        ),
                      ],
                      if (q.waiting.length > next.length) ...[
                        SizedBox(width: 12 * scale),
                        Text('+${q.waiting.length - next.length}',
                            style: TextStyle(color: colors.muted, fontSize: 26 * scale)),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );

    return Container(
      padding: EdgeInsets.all(24 * scale),
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(20 * scale),
      ),
      child: LayoutBuilder(builder: (context, c) {
        if (c.maxHeight >= 400 * scale) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              SizedBox(height: 16 * scale),
              Expanded(child: seeing),
              Divider(color: colors.line, height: 24 * scale),
              upNext,
            ],
          );
        }
        // Short panel (several rows of doctors): the token sits on the right.
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [header, const Spacer(), upNext],
              ),
            ),
            SizedBox(width: 16 * scale),
            Expanded(flex: 2, child: seeing),
          ],
        );
      }),
    );
  }
}
