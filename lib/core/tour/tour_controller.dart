import 'package:flutter/material.dart';

import '../contracts/collections.dart';
import '../modules/module.dart';

/// Runs the guided walkthrough. Screens mark the parts worth pointing at
/// with [TourAnchor]; steps come from core and from every active module.
class TourController extends ChangeNotifier {
  final _anchors = <String, GlobalKey>{};
  List<TourStep> _steps = const [];
  int _index = 0;
  bool _active = false;
  void Function(List<String> seenIds)? _onFinish;

  bool get active => _active;
  List<TourStep> get steps => _steps;
  int get index => _index;
  TourStep? get step => _active && _index < _steps.length ? _steps[_index] : null;

  void register(String id, GlobalKey key) => _anchors[id] = key;
  void unregister(String id, GlobalKey key) {
    if (_anchors[id] == key) _anchors.remove(id);
  }

  /// Where the anchor is on screen right now, if it is visible.
  Rect? anchorRect(String? id) {
    if (id == null) return null;
    final ctx = _anchors[id]?.currentContext;
    final box = ctx?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    final offset = box.localToGlobal(Offset.zero);
    return offset & box.size;
  }

  void start(List<TourStep> steps, {void Function(List<String> seenIds)? onFinish}) {
    if (steps.isEmpty) return;
    _steps = steps;
    _index = 0;
    _active = true;
    _onFinish = onFinish;
    notifyListeners();
  }

  void next() {
    if (_index < _steps.length - 1) {
      _index++;
      notifyListeners();
    } else {
      finish();
    }
  }

  void back() {
    if (_index > 0) {
      _index--;
      notifyListeners();
    }
  }

  /// Ends the tour. Skipping still counts the steps as seen, so the user is
  /// not asked again; they can replay it from the profile menu.
  void finish() {
    final seen = _steps.map((s) => s.id).toList();
    _active = false;
    _steps = const [];
    notifyListeners();
    _onFinish?.call(seen);
    _onFinish = null;
  }
}

/// Steps every user sees, whatever modules are switched on.
const coreTourSteps = <TourStep>[
  TourStep(
    id: 'core.welcome',
    order: 0,
    title: 'Welcome to Kendra',
    body: 'This short tour shows where things are. It takes about a minute. '
        'Use the arrow keys or the buttons below, and press Esc to skip.',
  ),
  TourStep(
    id: 'core.nav',
    order: 1,
    anchorId: 'shell.nav',
    title: 'Everything you can use',
    body: 'Your screens are listed here, grouped by department. You only see '
        'what your role allows.',
  ),
  TourStep(
    id: 'core.palette',
    order: 2,
    anchorId: 'shell.palette',
    title: 'Jump anywhere',
    body: 'Press Ctrl + K (⌘ K on a Mac) to search screens and actions, '
        'such as "new patient" or "bill".',
  ),
  TourStep(
    id: 'core.bell',
    order: 3,
    anchorId: 'shell.bell',
    title: 'Things that need you',
    body: 'Approvals, alerts from the monitoring agents and messages for you '
        'appear here. The agents never change data on their own; a person '
        'always decides.',
  ),
  TourStep(
    id: 'core.profile',
    order: 900,
    anchorId: 'shell.profile',
    title: 'Your account',
    body: 'Change your password, switch light or dark mode, lock the screen, '
        'or take this tour again from here.',
  ),
];

/// Ids already seen by the user, from their user_prefs record.
List<String> seenTourSteps(Map<String, Object?>? prefs) {
  final v = prefs?['seen_tour_steps'];
  return v is List ? v.whereType<String>().toList() : const [];
}

const userPrefsCollection = Col.userPrefs;
