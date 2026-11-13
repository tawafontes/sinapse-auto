import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChrome, SystemUiMode;

import '../../widgets/dashboard/dashboard_tile_context_menu.dart';

/// Immersive, YouTube-style fullscreen view for a single dashboard widget —
/// "Colocar em tela cheia" from the long-press menu. [content] is a
/// freshly-built sensor widget (its own stream subscription, not the one
/// already mounted in the tile, both reading from the very same
/// `DashboardSensorStreams` the caller already owns — no new sensor
/// subscriptions, no duplicate Telemetry Engine, no risk of "Stream has
/// already been listened to."); persisted state (peak G, altitude min/max,
/// calibration) re-seeds identically either way, only unpersisted visual
/// accumulation (fade trails, rolling history) restarts empty for this
/// temporary view.
///
/// The instrument is the only permanent thing on screen: no AppBar, system
/// status/navigation bars hidden via the official [SystemChrome] immersive
/// API. A single tap anywhere reveals a temporary top bar (back, label,
/// options) that auto-hides again after [_controlsAutoHideDuration] of no
/// interaction, or immediately on another tap while visible — see
/// [_ControlsVisibility] for that whole mechanism. A double-tap returns to
/// the dashboard ([confirmExit] may ask first), and a long-press opens the
/// instrument's calibrate/reset action (see `_showQuickActions`).
///
/// [onDelete]/[onChangeStyle]/[onResetRecords] mirror the exact callbacks
/// the Dashboard tile's own long-press menu already uses (see
/// `dashboard_screen.dart`'s `_contextMenuParamsFor`) — the options button
/// here opens the very same [showDashboardTileContextMenu] component, not a
/// second, independent implementation. Deleting or changing style pops this
/// screen back to the Dashboard afterward (the content built here would
/// otherwise keep showing a now-stale widget); resetting/calibrating does
/// not, since the live stream already reflects the change immediately, the
/// same "no navigation needed" behavior the Dashboard itself has.
class SensorFullscreenScreen extends StatefulWidget {
  const SensorFullscreenScreen({
    super.key,
    required this.label,
    required this.icon,
    required this.content,
    this.onDelete,
    this.onChangeStyle,
    this.onResetRecords,
    this.resetRecordsLabel = 'Resetar registros',
    this.resetRecordsIcon = Icons.restart_alt,
    this.confirmExit,
    this.fullBleed = false,
  });

  /// Content that is an image rather than an instrument (the dashcam's
  /// camera, 2026-11-13): it gets the whole screen — no margin, no SafeArea —
  /// and paints its own ground, keeping its own text and controls clear of a
  /// cutout. The theme's surface around it showed as a light frame around the
  /// camera's black bars, and a fixed black ground hid the dashcam's
  /// idle-state text, drawn for the theme's surface.
  final bool fullBleed;

  /// Asked on a double-tap before returning to the dashboard — `true` leaves.
  /// `null` leaves right away. The dashcam uses it to offer ending a recording
  /// first ("Deseja encerrar a gravação?").
  final Future<bool> Function(BuildContext context)? confirmExit;

  final String label;
  final IconData icon;
  final Widget content;

  /// Null for content with no "delete" concept (e.g. the Dashcam live
  /// preview, Fase 15) — every sensor-tile call site still passes a real
  /// callback.
  final VoidCallback? onDelete;
  final VoidCallback? onChangeStyle;
  final VoidCallback? onResetRecords;
  final String resetRecordsLabel;
  final IconData resetRecordsIcon;

  @override
  State<SensorFullscreenScreen> createState() => _SensorFullscreenScreenState();
}

class _SensorFullscreenScreenState extends State<SensorFullscreenScreen> {
  static const _controlsAutoHideDuration = Duration(seconds: 3);
  static const _controlsFadeDuration = Duration(milliseconds: 200);

  bool _controlsVisible = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    // Hides both the status and navigation bars — the official Flutter API
    // for this, not a manually-painted overlay. "immersiveSticky" (rather
    // than plain "immersive") is the mode meant for exactly this kind of
    // full-screen instrument display: the bars can still be revealed
    // temporarily by a swipe in from a screen edge (standard Android
    // behavior, outside this app's own control) and auto-hide again on
    // their own, entirely independent of this screen's own tap-to-reveal
    // controls below.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    // Restores the normal, edge-to-edge system UI regardless of *how* this
    // screen is left — the explicit "Sair da tela cheia" menu action, the
    // OS back gesture/button, or anything else that pops this route —
    // dispose() fires for all of them, so this can't be skipped by exiting
    // a way the menu action alone wouldn't have caught.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _showControls() {
    _hideTimer?.cancel();
    setState(() => _controlsVisible = true);
    _hideTimer = Timer(_controlsAutoHideDuration, () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _hideControls() {
    _hideTimer?.cancel();
    setState(() => _controlsVisible = false);
  }

  void _handleTap() {
    if (_controlsVisible) {
      _hideControls();
    } else {
      _showControls();
    }
  }

  /// Double-tap anywhere: back to the dashboard, as it was — after
  /// [SensorFullscreenScreen.confirmExit] agrees, when there is one.
  Future<void> _handleDoubleTap() async {
    final confirmExit = widget.confirmExit;
    if (confirmExit != null && !await confirmExit(context)) return;
    if (mounted) Navigator.of(context).pop();
  }

  /// Long-press anywhere: the instrument's own quick action — calibrate,
  /// reset its records, or protect the current clip for the dashcam — in the
  /// SAME centralized menu the options button opens, trimmed to that action
  /// (plus "Sair da tela cheia"). Delete/style stay behind the options button.
  Future<void> _showQuickActions() async {
    _hideControls();
    await showDashboardTileContextMenu(
      context: context,
      icon: widget.icon,
      label: widget.label,
      onFullscreen: () => Navigator.of(context).pop(),
      isFullscreen: true,
      onResetRecords: widget.onResetRecords,
      resetRecordsLabel: widget.resetRecordsLabel,
      resetRecordsIcon: widget.resetRecordsIcon,
    );
  }

  Future<void> _showOptions() async {
    // Pausing the auto-hide timer while the (modal) options sheet is open
    // isn't needed: showModalBottomSheet's own barrier already captures
    // every touch for itself until dismissed (see
    // showDashboardTileContextMenu's own doc), so this screen's tap
    // handler simply never fires while it's up — no risk of the top bar
    // hiding out from under an open menu, and no separate "menu open" flag
    // needed here.
    await showDashboardTileContextMenu(
      context: context,
      icon: widget.icon,
      label: widget.label,
      onDelete: widget.onDelete == null
          ? null
          : () {
              widget.onDelete!();
              Navigator.of(context).pop();
            },
      onChangeStyle: widget.onChangeStyle == null
          ? null
          : () {
              widget.onChangeStyle!();
              Navigator.of(context).pop();
            },
      onFullscreen: () => Navigator.of(context).pop(),
      isFullscreen: true,
      onResetRecords: widget.onResetRecords,
      resetRecordsLabel: widget.resetRecordsLabel,
      resetRecordsIcon: widget.resetRecordsIcon,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Stack(
        children: [
          // The instrument itself: the only permanent element, using the
          // full available area (SafeArea still applied so it's never
          // drawn under a display cutout, even with the system bars
          // hidden) — every sensor widget already scales its own content
          // to whatever space it's given (LayoutBuilder-based internally),
          // so no fixed sizing is introduced here.
          //
          // The gestures wrap the instrument only, NOT the top bar: a
          // double-tap recognizer holds the gesture arena for the whole
          // double-tap window after a first tap, so as an ancestor of the bar
          // it would delay its back/options buttons by that window. Hidden,
          // the bar ignores pointers, so a touch there still lands here.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _handleTap,
              onDoubleTap: _handleDoubleTap,
              onLongPress: _showQuickActions,
              child: widget.fullBleed
                  ? widget.content
                  : SafeArea(
                      child: Padding(padding: const EdgeInsets.all(16), child: widget.content),
                    ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              opacity: _controlsVisible ? 1 : 0,
              duration: _controlsFadeDuration,
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: _TopBar(label: widget.label, icon: widget.icon, onOptions: _showOptions),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The temporary top bar shown while [_SensorFullscreenScreenState._controlsVisible]
/// is true — a translucent, gradient-backed strip (readable over any
/// instrument content beneath it) with a back button, the sensor's own
/// label/icon, and an options button that reuses the exact same menu the
/// Dashboard tile's long-press already opens.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.label, required this.icon, required this.onOptions});

  final String label;
  final IconData icon;
  final VoidCallback onOptions;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0.55), Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                tooltip: 'Voltar',
                onPressed: () => Navigator.of(context).pop(),
              ),
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.more_vert, color: Colors.white),
                tooltip: 'Opções',
                onPressed: onOptions,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
