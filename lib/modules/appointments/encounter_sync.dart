import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kendra_hms/core/core.dart';

import 'appointment_service.dart';

/// Keeps stored appointment statuses in step with the OPD visit they led
/// to: when OPD calls the patient in, the appointment becomes "with doctor";
/// when the consultation ends it becomes "done". Plain bookkeeping, done by
/// the device that holds the data. Screens also derive the status on the
/// fly, so nothing looks stale in between.
class EncounterSync {
  EncounterSync(this.ctx);
  final ModuleContext ctx;
  StreamSubscription<Object?>? _sub;
  bool _running = false;
  bool _again = false;

  void start() {
    if (!ctx.isDataHost || _sub != null) return;
    _sub = ctx.services.store.changes.where((c) => c.collection == Col.encounters).listen((_) => _run().ignore());
    _run().ignore();
  }

  Future<void> _run() async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        await AppointmentService.syncWithEncounters(ctx.systemDb);
      } while (_again);
    } on StateError {
      // The database was closed (app shutting down).
    } catch (e) {
      debugPrint('appointments: could not sync with visits: $e');
    } finally {
      _running = false;
    }
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }
}
