// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'charge_record.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ChargeRecordAdapter extends TypeAdapter<ChargeRecord> {
  @override
  final int typeId = 21;

  @override
  ChargeRecord read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ChargeRecord(
      id: fields[0] as String,
      date: fields[1] as DateTime,
      odometerKm: fields[2] as double,
      startPercent: fields[3] as double,
      endPercent: fields[4] as double,
      chargerKwh: fields[5] as double?,
      pricePerKwh: fields[6] as double,
      wallKwh: fields[7] as double,
      usedFuelSinceLast: fields[8] as bool,
      panelFuelRangeKm: fields[9] as double?,
    );
  }

  @override
  void write(BinaryWriter writer, ChargeRecord obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.date)
      ..writeByte(2)
      ..write(obj.odometerKm)
      ..writeByte(3)
      ..write(obj.startPercent)
      ..writeByte(4)
      ..write(obj.endPercent)
      ..writeByte(5)
      ..write(obj.chargerKwh)
      ..writeByte(6)
      ..write(obj.pricePerKwh)
      ..writeByte(7)
      ..write(obj.wallKwh)
      ..writeByte(8)
      ..write(obj.usedFuelSinceLast)
      ..writeByte(9)
      ..write(obj.panelFuelRangeKm);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChargeRecordAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
