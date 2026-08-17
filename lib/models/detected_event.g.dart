// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'detected_event.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class EventSeverityAdapter extends TypeAdapter<EventSeverity> {
  @override
  final int typeId = 14;

  @override
  EventSeverity read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return EventSeverity.info;
      case 1:
        return EventSeverity.warning;
      case 2:
        return EventSeverity.high;
      case 3:
        return EventSeverity.critical;
      default:
        return EventSeverity.info;
    }
  }

  @override
  void write(BinaryWriter writer, EventSeverity obj) {
    switch (obj) {
      case EventSeverity.info:
        writer.writeByte(0);
        break;
      case EventSeverity.warning:
        writer.writeByte(1);
        break;
      case EventSeverity.high:
        writer.writeByte(2);
        break;
      case EventSeverity.critical:
        writer.writeByte(3);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EventSeverityAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
