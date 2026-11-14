import 'package:flutter/widgets.dart';
import 'package:hive/hive.dart';

import '../hive_boxes.dart';

/// The OBD-II adapter choice and switches (phase 1, owner decisions of
/// 2026-11-11/13): which paired adapter, whether the app connects to it on its
/// own, and whether a car that starts answering starts a driving session.
///
/// Persisted as plain keys of the untyped `app_settings` box, like
/// [AlertPreferences] — nothing here needs a typeId. Reactive, so the adapter
/// screen and [ObdService] see a change the moment it is made.
class ObdPreferences extends ChangeNotifier {
  ObdPreferences()
      : _address = _box.get(_addressKey) as String?,
        _name = _box.get(_nameKey) as String?,
        _autoConnect = (_box.get(_autoConnectKey) as bool?) ?? true,
        _autoStartSession = (_box.get(_autoStartSessionKey) as bool?) ?? false;

  static Box get _box => Hive.box(HiveBoxNames.appSettings);
  static const _addressKey = 'obdAdapterAddress';
  static const _nameKey = 'obdAdapterName';
  static const _autoConnectKey = 'obdAutoConnect';
  static const _autoStartSessionKey = 'obdAutoStartSession';

  String? _address;
  String? _name;
  bool _autoConnect;
  bool _autoStartSession;

  /// The adapter's Bluetooth address; `null` until one is chosen.
  String? get adapterAddress => _address;

  /// The name Android showed when it was chosen ("V-LINK").
  String? get adapterName => _name;

  bool get hasAdapter => _address != null;

  /// Connect silently when the app opens or comes back (on by default).
  bool get autoConnect => _autoConnect;

  /// Start a driving session when the car starts answering and moving (off by
  /// default — owner decision).
  bool get autoStartSession => _autoStartSession;

  Future<void> setAdapter({required String address, required String name}) async {
    if (_address == address && _name == name) return;
    _address = address;
    _name = name;
    notifyListeners();
    await _box.put(_addressKey, address);
    await _box.put(_nameKey, name);
  }

  Future<void> clearAdapter() async {
    if (_address == null) return;
    _address = null;
    _name = null;
    notifyListeners();
    await _box.delete(_addressKey);
    await _box.delete(_nameKey);
  }

  Future<void> setAutoConnect(bool value) async {
    if (_autoConnect == value) return;
    _autoConnect = value;
    notifyListeners();
    await _box.put(_autoConnectKey, value);
  }

  Future<void> setAutoStartSession(bool value) async {
    if (_autoStartSession == value) return;
    _autoStartSession = value;
    notifyListeners();
    await _box.put(_autoStartSessionKey, value);
  }
}
