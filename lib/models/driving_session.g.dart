// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'driving_session.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class DrivingSessionAdapter extends TypeAdapter<DrivingSession> {
  @override
  final int typeId = 10;

  @override
  DrivingSession read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DrivingSession(
      id: fields[0] as String,
      startTime: fields[1] as DateTime,
      distanceMeters: fields[3] as double,
      maxSpeedKmh: fields[4] as double?,
      avgSpeedKmh: fields[5] as double?,
      maxAltitudeMeters: fields[6] as double?,
      minAltitudeMeters: fields[7] as double?,
      maxAccelerationG: fields[8] as double?,
      maxDecelerationG: fields[9] as double?,
      initialAltitudeMeters: fields[10] as double?,
      finalAltitudeMeters: fields[11] as double?,
      initialHeadingDegrees: fields[12] as double?,
      finalHeadingDegrees: fields[13] as double?,
      maxLateralG: fields[14] as double?,
      maxGForceMagnitude: fields[15] as double?,
      sampleCount: fields[16] == null ? 0 : fields[16] as int,
      initialLatitude: fields[17] as double?,
      initialLongitude: fields[18] as double?,
      finalLatitude: fields[19] as double?,
      finalLongitude: fields[20] as double?,
      avgGnssQualityIndex: fields[21] as double?,
      altitudeGainMeters: fields[22] == null ? 0 : fields[22] as double,
      altitudeLossMeters: fields[23] == null ? 0 : fields[23] as double,
      events: fields[24] == null
          ? []
          : (fields[24] as List?)?.cast<DrivingSessionEvent>(),
      deletionPending: fields[25] == null ? false : fields[25] as bool,
      dashcamTelemetryOutcomeCode: fields[26] as int?,
      dashcamTelemetryAcceptedCount: fields[27] as int?,
      dashcamTelemetryPersistedCount: fields[28] as int?,
      dashcamTelemetryRefusedCount: fields[29] as int?,
    ).._storedEndTime = fields[2] as DateTime?;
  }

  @override
  void write(BinaryWriter writer, DrivingSession obj) {
    writer
      ..writeByte(30)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.startTime)
      ..writeByte(2)
      ..write(obj._storedEndTime)
      ..writeByte(3)
      ..write(obj.distanceMeters)
      ..writeByte(4)
      ..write(obj.maxSpeedKmh)
      ..writeByte(5)
      ..write(obj.avgSpeedKmh)
      ..writeByte(6)
      ..write(obj.maxAltitudeMeters)
      ..writeByte(7)
      ..write(obj.minAltitudeMeters)
      ..writeByte(8)
      ..write(obj.maxAccelerationG)
      ..writeByte(9)
      ..write(obj.maxDecelerationG)
      ..writeByte(10)
      ..write(obj.initialAltitudeMeters)
      ..writeByte(11)
      ..write(obj.finalAltitudeMeters)
      ..writeByte(12)
      ..write(obj.initialHeadingDegrees)
      ..writeByte(13)
      ..write(obj.finalHeadingDegrees)
      ..writeByte(14)
      ..write(obj.maxLateralG)
      ..writeByte(15)
      ..write(obj.maxGForceMagnitude)
      ..writeByte(16)
      ..write(obj.sampleCount)
      ..writeByte(17)
      ..write(obj.initialLatitude)
      ..writeByte(18)
      ..write(obj.initialLongitude)
      ..writeByte(19)
      ..write(obj.finalLatitude)
      ..writeByte(20)
      ..write(obj.finalLongitude)
      ..writeByte(21)
      ..write(obj.avgGnssQualityIndex)
      ..writeByte(22)
      ..write(obj.altitudeGainMeters)
      ..writeByte(23)
      ..write(obj.altitudeLossMeters)
      ..writeByte(24)
      ..write(obj.events)
      ..writeByte(25)
      ..write(obj.deletionPending)
      ..writeByte(26)
      ..write(obj.dashcamTelemetryOutcomeCode)
      ..writeByte(27)
      ..write(obj.dashcamTelemetryAcceptedCount)
      ..writeByte(28)
      ..write(obj.dashcamTelemetryPersistedCount)
      ..writeByte(29)
      ..write(obj.dashcamTelemetryRefusedCount);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DrivingSessionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
