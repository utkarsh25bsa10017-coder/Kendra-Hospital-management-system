import 'package:flutter/material.dart';

/// Spacing scale. Use these instead of magic numbers.
abstract final class Gap {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;

  static const h4 = SizedBox(width: 4);
  static const h8 = SizedBox(width: 8);
  static const h12 = SizedBox(width: 12);
  static const h16 = SizedBox(width: 16);
  static const h24 = SizedBox(width: 24);
  static const v4 = SizedBox(height: 4);
  static const v8 = SizedBox(height: 8);
  static const v12 = SizedBox(height: 12);
  static const v16 = SizedBox(height: 16);
  static const v24 = SizedBox(height: 24);
  static const v32 = SizedBox(height: 32);
}

abstract final class Radii {
  static const sm = 6.0;
  static const md = 10.0;
  static const lg = 14.0;
  static const xl = 20.0;
}

/// Layout breakpoints (logical pixels).
/// compact: phones · medium: tablets / small windows · expanded: desktop.
enum WindowSize { compact, medium, expanded }

extension WindowSizeOf on BuildContext {
  WindowSize get windowSize {
    final w = MediaQuery.sizeOf(this).width;
    if (w < 640) return WindowSize.compact;
    if (w < 1100) return WindowSize.medium;
    return WindowSize.expanded;
  }

  bool get isCompact => windowSize == WindowSize.compact;
  bool get isExpanded => windowSize == WindowSize.expanded;

  /// Padding around page content.
  double get pagePadding => switch (windowSize) {
        WindowSize.compact => 16,
        WindowSize.medium => 24,
        WindowSize.expanded => 32,
      };
}

/// Semantic colours for status chips, badges and tiles.
enum Tone { neutral, info, success, warning, danger, agent, board }

class ToneColors {
  const ToneColors(this.background, this.foreground, this.border);
  final Color background;
  final Color foreground;
  final Color border;

  static ToneColors of(BuildContext context, Tone tone) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    return switch (tone) {
      Tone.neutral => ToneColors(cs.surfaceContainerHigh, cs.onSurfaceVariant, cs.outlineVariant),
      Tone.info || Tone.agent => dark
          ? const ToneColors(Color(0xFF0F2E31), Color(0xFF7FD6DB), Color(0xFF1E5A5F))
          : const ToneColors(Color(0xFFE1F0F0), Color(0xFF0B5A61), Color(0xFFB7DADB)),
      Tone.success => dark
          ? const ToneColors(Color(0xFF18301B), Color(0xFF8FD394), Color(0xFF2E5532))
          : const ToneColors(Color(0xFFE3F0E1), Color(0xFF26602C), Color(0xFFBCD9B8)),
      Tone.warning || Tone.board => dark
          ? const ToneColors(Color(0xFF36280F), Color(0xFFEDBB6C), Color(0xFF5E4519))
          : const ToneColors(Color(0xFFFBEFD9), Color(0xFF7D4B06), Color(0xFFEBD3A5)),
      Tone.danger => dark
          ? const ToneColors(Color(0xFF3A1D18), Color(0xFFF59A89), Color(0xFF66332A))
          : const ToneColors(Color(0xFFFCE6E1), Color(0xFF9A2F1F), Color(0xFFF0C2B8)),
    };
  }
}

/// Maps a severity name (info/low/medium/high/critical) to a tone.
Tone toneForSeverity(String? severity) => switch (severity) {
      'critical' || 'high' => Tone.danger,
      'medium' => Tone.warning,
      'low' => Tone.info,
      _ => Tone.neutral,
    };
