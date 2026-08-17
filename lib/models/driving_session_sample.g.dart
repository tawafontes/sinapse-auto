// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'driving_session_sample.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class DrivingSessionSampleAdapter extends TypeAdapter<DrivingSessionSample> {
  @override
  final int typeId = 11;

  @override
  DrivingSessionSample read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DrivingSessionSample(
      timestamp: fields[0] as DateTime,
      latitude: fields[1] as double?,
      longitude: fields[2] as double?,
      speedKmh: fields[3] as double?,
      altitudeMeters: fields[4] as double?,
      longitudinalG: fields[5] as double?,
      lateralG: fields[6] as double?,
      verticalG: fields[7] as double?,
      pitchDegrees: fields[8] as double?,
      rollDegrees: fields[9] as double?,
    );
  }

  @override
  void write(BinaryWriter writer, DrivingSessionSample obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.timestamp)
      ..writeByte(1)
      ..write(obj.latitude)
      ..writeByte(2)
      ..write(obj.longitude)
      ..writeByte(3)
      ..write(obj.speedKmh)
      ..writeByte(4)
      ..write(obj.altitudeMeters)
      ..writeByte(5)
      ..write(obj.longitudinalG)
      ..writeByte(6)
      ..write(obj.lateralG)
      ..writeByte(7)
      ..write(obj.verticalG)
      ..writeByte(8)
      ..write(obj.pitchDegrees)
      ..writeByte(9)
      ..write(obj.rollDegrees);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DrivingSessionSampleAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
