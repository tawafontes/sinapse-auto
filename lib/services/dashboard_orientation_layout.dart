import 'package:flutter/widgets.dart' show Orientation;

import '../models/sensor_widget_config.dart';

/// One widget's LANDSCAPE layout, presented as a [SensorWidgetConfig] whose
/// [position]/[size]/[page] are the landscape ones (owner request, 2026-11-12:
/// in landscape the widgets need their own, taller shapes and more of them side
/// by side, instead of the portrait layout squashed onto a short grid).
///
/// Being a [SensorWidgetConfig], it goes through the dashboard, the layout
/// engine and [SensorWidgetRepository] exactly like a portrait config — one
/// implementation of moving, resizing, placing and paging for both
/// orientations. Only persistence differs: [save] writes these three values
/// into [stored]'s landscape fields (leaving its portrait layout untouched) and
/// saves [stored]; [delete] deletes [stored] — the widget itself, as in
/// portrait. The sensor and the style are [stored]'s own, read through, so a
/// style changed in either orientation shows in both.
///
/// A widget with no landscape layout yet starts unplaced (the same (-1, -1)
/// sentinel a brand-new widget has), so the dashboard's placement gives it one.
class LandscapeWidgetLayout extends SensorWidgetConfig {
  LandscapeWidgetLayout(this.stored)
      : super(
          sensorType: stored.sensorType,
          displayStyle: stored.displayStyle,
          position: stored.landscapePosition ?? WidgetPosition(x: -1, y: -1),
          size: stored.landscapeSize ?? WidgetSize(width: 1, height: 1),
          page: stored.landscapePage ?? 0,
        );

  /// The persisted widget this is the landscape layout of.
  final SensorWidgetConfig stored;

  @override
  SensorType get sensorType => stored.sensorType;

  @override
  set sensorType(SensorType value) => stored.sensorType = value;

  @override
  DisplayStyle get displayStyle => stored.displayStyle;

  @override
  set displayStyle(DisplayStyle value) => stored.displayStyle = value;

  @override
  Future<void> save() {
    stored
      ..landscapePosition = WidgetPosition(x: position.x, y: position.y)
      ..landscapeSize = WidgetSize(width: size.width, height: size.height)
      ..landscapePage = page;
    return stored.save();
  }

  @override
  Future<void> delete() => stored.delete();
}

/// The configs the dashboard lays out in [orientation]: [stored] itself in
/// portrait, or one [LandscapeWidgetLayout] per widget in landscape.
///
/// In landscape they come in the portrait reading order (page, then row, then
/// column; widgets not placed in portrait yet last), so the widgets that have
/// no landscape layout yet are placed in that order — the landscape dashboard
/// first appears with the same sequence the user arranged in portrait.
List<SensorWidgetConfig> dashboardLayoutFor(Orientation orientation, List<SensorWidgetConfig> stored) {
  if (orientation == Orientation.portrait) return stored;
  final indexed = [for (var i = 0; i < stored.length; i++) (i, stored[i])];
  indexed.sort((a, b) {
    final ca = a.$2;
    final cb = b.$2;
    final placedA = ca.position.x >= 0 && ca.position.y >= 0;
    final placedB = cb.position.x >= 0 && cb.position.y >= 0;
    if (placedA != placedB) return placedA ? -1 : 1;
    if (placedA) {
      for (final (x, y) in [(ca.page, cb.page), (ca.position.y, cb.position.y), (ca.position.x, cb.position.x)]) {
        final c = x.compareTo(y);
        if (c != 0) return c;
      }
    }
    return a.$1.compareTo(b.$1); // stable
  });
  return [for (final (_, config) in indexed) LandscapeWidgetLayout(config)];
}
