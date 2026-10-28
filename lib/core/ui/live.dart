import 'dart:async';

import 'package:flutter/material.dart';

import '../data/db.dart';
import '../services/app_services.dart';
import 'widgets.dart';

/// Loads data and reloads it whenever any of [watch] changes — on this
/// device or, through the hub, on any other device.
///
/// ```dart
/// LiveBuilder<List<Rec>>(
///   watch: {Col.patients},
///   deps: [search],
///   load: (db) => db.query(Query(Col.patients).matching(search).take(50)),
///   builder: (context, patients) => ...,
/// )
/// ```
class LiveBuilder<T> extends StatefulWidget {
  const LiveBuilder({
    super.key,
    required this.watch,
    required this.load,
    required this.builder,
    this.deps = const [],
    this.loading,
  });

  final Set<String> watch;
  final Future<T> Function(ReadDb db) load;
  final Widget Function(BuildContext context, T data) builder;

  /// Reload when any of these values change (search text, filters, ids).
  final List<Object?> deps;
  final Widget? loading;

  @override
  State<LiveBuilder<T>> createState() => _LiveBuilderState<T>();
}

class _LiveBuilderState<T> extends State<LiveBuilder<T>> {
  StreamSubscription<void>? _sub;
  T? _data;
  bool _hasData = false;
  Object? _error;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sub == null) {
      _subscribe();
      _reload();
    }
  }

  void _subscribe() {
    _sub?.cancel();
    _sub = AppScope.of(context).readDb.watchCollections(widget.watch).listen((_) => _reload());
  }

  @override
  void didUpdateWidget(LiveBuilder<T> old) {
    super.didUpdateWidget(old);
    if (!_sameSet(old.watch, widget.watch)) _subscribe();
    if (!_sameList(old.deps, widget.deps)) _reload();
  }

  static bool _sameSet(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);
  static bool _sameList(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _reload() async {
    final gen = ++_generation;
    try {
      final d = await widget.load(AppScope.of(context).readDb);
      if (!mounted || gen != _generation) return;
      setState(() {
        _data = d;
        _hasData = true;
        _error = null;
      });
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null && !_hasData) return ErrorView(_error!, onRetry: _reload);
    if (!_hasData) return widget.loading ?? const LoadingView();
    return widget.builder(context, _data as T);
  }
}
