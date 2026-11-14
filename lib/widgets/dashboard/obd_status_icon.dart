import 'dart:async';

import 'package:flutter/material.dart';

import '../../screens/vehicle/obd_adapter_screen.dart';
import '../../services/obd/obd_service.dart';

/// The OBD-II icon in the dashboard's top bar, next to REC (owner decision,
/// 2026-11-11): grey when off, blinking while connecting or reconnecting,
/// amber waiting for the car, green receiving, red on failure. A tap opens
/// the adapter screen.
class ObdStatusIcon extends StatefulWidget {
  const ObdStatusIcon({super.key, required this.service});

  final ObdService service;

  @override
  State<ObdStatusIcon> createState() => _ObdStatusIconState();
}

class _ObdStatusIconState extends State<ObdStatusIcon> {
  Timer? _blink;
  bool _on = true;

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_changed);
    _syncBlink();
  }

  @override
  void didUpdateWidget(ObdStatusIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      oldWidget.service.removeListener(_changed);
      widget.service.addListener(_changed);
      _syncBlink();
    }
  }

  bool get _blinking => widget.service.state == ObdLinkState.connecting || widget.service.state == ObdLinkState.reconnecting;

  void _changed() {
    _syncBlink();
    if (mounted) setState(() {});
  }

  void _syncBlink() {
    if (_blinking) {
      _blink ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() => _on = !_on);
      });
    } else {
      _blink?.cancel();
      _blink = null;
      _on = true;
    }
  }

  @override
  void dispose() {
    widget.service.removeListener(_changed);
    _blink?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.service.state;
    final color = obdLinkStateColor(state, Theme.of(context).colorScheme);
    return IconButton(
      key: const ValueKey('obdStatusIcon'),
      tooltip: 'OBD-II: ${obdLinkStateLabels[state]}',
      icon: Opacity(
        opacity: _on ? 1 : 0.25,
        child: Icon(Icons.settings_input_component, color: color),
      ),
      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ObdAdapterScreen())),
    );
  }
}
