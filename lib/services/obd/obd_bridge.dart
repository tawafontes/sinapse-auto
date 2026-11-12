import 'dart:io';

import 'package:flutter/services.dart';

/// A Bluetooth device Android already paired with.
typedef PairedDevice = ({String name, String address});

/// How a link was opened: which of the RFCOMM methods the adapter accepted, and
/// how long it took.
typedef ObdConnection = ({String method, int millis});

/// One command's answer: the raw text the adapter sent before its `>` prompt.
typedef ObdReply = ({String response, int millis, bool timedOut});

/// The link to an ELM327 adapter (OBD-II phase 0, 2026-11-12). Implemented
/// natively (`ObdBridge.kt`, Bluetooth Classic SPP); an interface so the phase 0
/// runner can be tested against a scripted fake car.
abstract interface class ObdBridge {
  Future<List<PairedDevice>> pairedDevices();
  Future<ObdConnection> connect(String address);
  Future<ObdReply> send(String command, {Duration timeout});
  Future<void> disconnect();
}

/// Raised by [MethodChannelObdBridge] with the native error code
/// (`permission`, `disabled`, `unavailable`, `connect_failed`, `not_connected`,
/// `closed`, `io`).
class ObdBridgeException implements Exception {
  const ObdBridgeException(this.code, this.message);

  final String code;
  final String? message;

  @override
  String toString() => 'ObdBridgeException($code): $message';
}

class MethodChannelObdBridge implements ObdBridge {
  const MethodChannelObdBridge();

  static const _channel = MethodChannel('com.synapseauto.synapse_auto/obd');

  static bool get isSupported => Platform.isAndroid;

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw ObdBridgeException(e.code, e.message);
    }
  }

  @override
  Future<List<PairedDevice>> pairedDevices() async {
    final list = await _call<List<Object?>>('bondedDevices') ?? const [];
    return [
      for (final item in list.cast<Map<Object?, Object?>>())
        (name: item['name'] as String? ?? '', address: item['address'] as String),
    ];
  }

  @override
  Future<ObdConnection> connect(String address) async {
    final map = (await _call<Map<Object?, Object?>>('connect', {'address': address}))!;
    return (method: map['method'] as String, millis: (map['millis'] as num).toInt());
  }

  @override
  Future<ObdReply> send(String command, {Duration timeout = const Duration(seconds: 2)}) async {
    final map = (await _call<Map<Object?, Object?>>('send', {'command': command, 'timeoutMs': timeout.inMilliseconds}))!;
    return (
      response: map['response'] as String,
      millis: (map['millis'] as num).toInt(),
      timedOut: map['timedOut'] as bool,
    );
  }

  @override
  Future<void> disconnect() => _call<void>('disconnect');
}
