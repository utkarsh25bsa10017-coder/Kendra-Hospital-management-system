import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_services.dart';
import '../ui/tokens.dart';
import 'tour_controller.dart';

/// Dims the screen, cuts a spotlight around the current step's anchor and
/// shows the explanation card next to it.
class TourOverlay extends StatefulWidget {
  const TourOverlay({super.key, required this.child});
  final Widget child;

  @override
  State<TourOverlay> createState() => _TourOverlayState();
}

class _TourOverlayState extends State<TourOverlay> {
  TourController? _tour;
  Rect? _rect;
  String? _shownStep;
  Timer? _settle;
  final _focus = FocusNode(debugLabel: 'tour');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final t = AppScope.of(context).tour;
    if (t != _tour) {
      _tour?.removeListener(_changed);
      _tour = t..addListener(_changed);
    }
  }

  @override
  void dispose() {
    _tour?.removeListener(_changed);
    _settle?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _changed() {
    final step = _tour!.step;
    if (step == null) {
      setState(() {
        _rect = null;
        _shownStep = null;
      });
      return;
    }
    if (step.id == _shownStep) return;
    _shownStep = step.id;
    final app = AppScope.of(context);
    if (step.routeId != null && app.nav.current != step.routeId) app.nav.open(step.routeId!);
    setState(() => _rect = null);
    // Give the screen a moment to build before measuring the anchor.
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 350), _measure);
    _focus.requestFocus();
  }

  void _measure() {
    if (!mounted) return;
    final step = _tour?.step;
    final r = _tour?.anchorRect(step?.anchorId);
    final box = context.findRenderObject() as RenderBox?;
    Rect? local;
    if (r != null && box != null && box.hasSize) {
      final o = box.globalToLocal(r.topLeft);
      local = o & r.size;
      if (!(Offset.zero & box.size).overlaps(local)) local = null;
    }
    setState(() => _rect = local);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final t = _tour!;
    if (e.logicalKey == LogicalKeyboardKey.arrowRight || e.logicalKey == LogicalKeyboardKey.enter) {
      t.next();
    } else if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      t.back();
    } else if (e.logicalKey == LogicalKeyboardKey.escape) {
      t.finish();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final t = _tour!;
    final step = t.step;
    return Stack(
      children: [
        widget.child,
        if (step != null)
          Positioned.fill(
            child: Focus(
              focusNode: _focus,
              autofocus: true,
              onKeyEvent: _onKey,
              child: LayoutBuilder(builder: (context, c) {
                // Re-measure after window resizes.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  final r = t.anchorRect(step.anchorId);
                  if ((r == null) != (_rect == null)) _measure();
                });
                return Stack(children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {},
                      child: CustomPaint(painter: _Spotlight(_rect, Theme.of(context).colorScheme.primary)),
                    ),
                  ),
                  _card(context, c.biggest, t),
                ]);
              }),
            ),
          ),
      ],
    );
  }

  Widget _card(BuildContext context, Size screen, TourController t) {
    final step = t.step!;
    final theme = Theme.of(context);
    final width = math.min(360.0, screen.width - 32);
    const estHeight = 220.0;
    double left, top;
    final r = _rect;
    if (r == null) {
      left = (screen.width - width) / 2;
      top = (screen.height - estHeight) / 2;
    } else if (r.right + 20 + width < screen.width) {
      left = r.right + 20;
      top = r.height > screen.height * 0.6 ? r.top + 24 : r.top;
    } else if (r.bottom + 20 + estHeight < screen.height) {
      left = r.left;
      top = r.bottom + 20;
    } else if (r.top - 20 - estHeight > 0) {
      left = r.left;
      top = r.top - 20 - estHeight;
    } else {
      left = r.left - 20 - width;
      top = r.top;
    }
    left = left.clamp(16.0, math.max(16.0, screen.width - width - 16));
    top = top.clamp(16.0, math.max(16.0, screen.height - estHeight - 16));
    final last = t.index == t.steps.length - 1;

    return Positioned(
      left: left,
      top: top,
      width: width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(Radii.lg),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 24, offset: Offset(0, 8))],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text('${t.index + 1} of ${t.steps.length}',
                      style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close tour (Esc)',
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: t.finish,
                  ),
                ],
              ),
              Text(step.title, style: theme.textTheme.titleMedium),
              Gap.v8,
              Text(step.body, style: theme.textTheme.bodyMedium),
              Gap.v16,
              Row(
                children: [
                  _Dots(count: t.steps.length, index: t.index),
                  const Spacer(),
                  if (t.index > 0) TextButton(onPressed: t.back, child: const Text('Back')),
                  Gap.h8,
                  FilledButton(onPressed: t.next, child: Text(last ? 'Done' : 'Next')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index});
  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (count > 12) return const SizedBox.shrink();
    return Row(children: [
      for (var i = 0; i < count; i++)
        Container(
          width: i == index ? 14 : 6,
          height: 6,
          margin: const EdgeInsets.only(right: 4),
          decoration: BoxDecoration(
            color: i == index ? cs.primary : cs.outlineVariant,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
    ]);
  }
}

class _Spotlight extends CustomPainter {
  _Spotlight(this.rect, this.ring);
  final Rect? rect;
  final Color ring;

  @override
  void paint(Canvas canvas, Size size) {
    final scrim = Paint()..color = Colors.black.withValues(alpha: 0.55);
    final full = Path()..addRect(Offset.zero & size);
    final r = rect;
    if (r == null) {
      canvas.drawPath(full, scrim);
      return;
    }
    final hole = RRect.fromRectAndRadius(r.inflate(6), const Radius.circular(12));
    canvas.drawPath(Path.combine(PathOperation.difference, full, Path()..addRRect(hole)), scrim);
    canvas.drawRRect(
        hole,
        Paint()
          ..color = ring
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);
  }

  @override
  bool shouldRepaint(_Spotlight old) => old.rect != rect || old.ring != ring;
}
