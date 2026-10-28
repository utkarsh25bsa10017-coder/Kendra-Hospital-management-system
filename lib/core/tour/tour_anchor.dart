import 'package:flutter/widgets.dart';

import '../services/app_services.dart';
import 'tour_controller.dart';

/// Marks a widget the walkthrough can point at: `TourAnchor(id: 'billing.new', child: ...)`.
class TourAnchor extends StatefulWidget {
  const TourAnchor({super.key, required this.id, required this.child});
  final String id;
  final Widget child;

  @override
  State<TourAnchor> createState() => _TourAnchorState();
}

class _TourAnchorState extends State<TourAnchor> {
  final _key = GlobalKey();
  TourController? _tour;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tour = AppScope.of(context).tour..register(widget.id, _key);
  }

  @override
  void didUpdateWidget(TourAnchor old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) {
      _tour?.unregister(old.id, _key);
      _tour?.register(widget.id, _key);
    }
  }

  @override
  void dispose() {
    _tour?.unregister(widget.id, _key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => KeyedSubtree(key: _key, child: widget.child);
}
