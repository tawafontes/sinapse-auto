// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'driving_session_event.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class DrivingSessionEventAdapter extends TypeAdapter<DrivingSessionEvent> {
  @override
  final int typeId = 13;

  @override
  DrivingSessionEvent read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DrivingSessionEvent(
      type: fields[0] as DrivingSessionEventType,
      timestamp: fields[1] as DateTime,
      magnitude: fields[2] as double?,
      id: fields[3] as String?,
      durationMs: fields[4] as int?,
      latitude: fields[5] as double?,
      longitude: fields[6] as double?,
      speedKmh: fields[7] as double?,
      altitudeMeters: fields[8] as double?,
      longitudinalG: fields[9] as double?,
      lateralG: fields[10] as double?,
      resultantG: fields[11] as double?,
      severity:
          fields[12] == null ? EventSeverity.info : fields[12] as EventSeverity,
    );
  }

  @override
  void write(BinaryWriter writer, DrivingSessionEvent obj) {
    writer
      ..writeByte(13)
      ..writeByte(0)
      ..write(obj.type)
      ..writeByte(1)
      ..write(obj.timestamp)
      ..writeByte(2)
      ..write(obj.magnitude)
      ..writeByte(3)
      ..write(obj.id)
      ..writeByte(4)
      ..write(obj.durationMs)
      ..writeByte(5)
      ..write(obj.latitude)
      ..writeByte(6)
      ..write(obj.longitude)
      ..writeByte(7)
      ..write(obj.speedKmh)
      ..writeByte(8)
      ..write(obj.altitudeMeters)
      ..writeByte(9)
      ..write(obj.longitudinalG)
      ..writeByte(10)
      ..write(obj.lateralG)
      ..writeByte(11)
      ..write(obj.resultantG)
      ..writeByte(12)
      ..write(obj.severity);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DrivingSessionEventAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class DrivingSessionEventTypeAdapter
    extends TypeAdapter<DrivingSessionEventType> {
  @override
  final int typeId = 12;

  @override
  DrivingSessionEventType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return DrivingSessionEventType.hardAcceleration;
      case 1:
        return DrivingSessionEventType.hardBraking;
      case 2:
        return DrivingSessionEventType.hardCornering;
      case 3:
        return DrivingSessionEventType.gnssLost;
      case 4:
        return DrivingSessionEventType.gnssRecovered;
      case 5:
        return DrivingSessionEventType.hardCorneringLeft;
      case 6:
        return DrivingSessionEventType.hardCorneringRight;
      case 7:
        return DrivingSessionEventType.highResultantG;
      case 8:
        return DrivingSessionEventType.speedLimitExceeded;
      case 9:
        return DrivingSessionEventType.stopped;
      case 10:
        return DrivingSessionEventType.resumed;
      case 11:
        return DrivingSessionEventType.altitudeRisingSignificant;
      case 12:
        return DrivingSessionEventType.altitudeFallingSignificant;
      default:
        return DrivingSessionEventType.hardAcceleration;
    }
  }

  @override
  void write(BinaryWriter writer, DrivingSessionEventType obj) {
    switch (obj) {
      case DrivingSessionEventType.hardAcceleration:
        writer.writeByte(0);
        break;
      case DrivingSessionEventType.hardBraking:
        writer.writeByte(1);
        break;
      case DrivingSessionEventType.hardCornering:
        writer.writeByte(2);
        break;
      case DrivingSessionEventType.gnssLost:
        writer.writeByte(3);
        break;
      case DrivingSessionEventType.gnssRecovered:
        writer.writeByte(4);
        break;
      case DrivingSessionEventType.hardCorneringLeft:
        writer.writeByte(5);
        break;
      case DrivingSessionEventType.hardCorneringRight:
        writer.writeByte(6);
        break;
      case DrivingSessionEventType.highResultantG:
        writer.writeByte(7);
        break;
      case DrivingSessionEventType.speedLimitExceeded:
        writer.writeByte(8);
        break;
      case DrivingSessionEventType.stopped:
        writer.writeByte(9);
        break;
      case DrivingSessionEventType.resumed:
        writer.writeByte(10);
        break;
      case DrivingSessionEventType.altitudeRisingSignificant:
        writer.writeByte(11);
        break;
      case DrivingSessionEventType.altitudeFallingSignificant:
        writer.writeByte(12);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DrivingSessionEventTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
