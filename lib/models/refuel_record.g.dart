// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'refuel_record.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class RefuelRecordAdapter extends TypeAdapter<RefuelRecord> {
  @override
  final int typeId = 19;

  @override
  RefuelRecord read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return RefuelRecord(
      id: fields[0] as String,
      date: fields[1] as DateTime,
      odometerKm: fields[2] as double,
      liters: fields[3] as double,
      pricePerLiter: fields[4] as double,
      fuel: fields[5] as FuelType,
      fullTank: fields[6] as bool,
      usedFuelSinceLast: fields[7] as bool?,
      panelFuelRangeBeforeKm: fields[8] as double?,
      panelFuelRangeAfterKm: fields[9] as double?,
    );
  }

  @override
  void write(BinaryWriter writer, RefuelRecord obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.date)
      ..writeByte(2)
      ..write(obj.odometerKm)
      ..writeByte(3)
      ..write(obj.liters)
      ..writeByte(4)
      ..write(obj.pricePerLiter)
      ..writeByte(5)
      ..write(obj.fuel)
      ..writeByte(6)
      ..write(obj.fullTank)
      ..writeByte(7)
      ..write(obj.usedFuelSinceLast)
      ..writeByte(8)
      ..write(obj.panelFuelRangeBeforeKm)
      ..writeByte(9)
      ..write(obj.panelFuelRangeAfterKm);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RefuelRecordAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
