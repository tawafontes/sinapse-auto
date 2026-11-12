// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'vehicle_profile.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class VehicleProfileAdapter extends TypeAdapter<VehicleProfile> {
  @override
  final int typeId = 18;

  @override
  VehicleProfile read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return VehicleProfile(
      nickname: fields[0] as String?,
      fuelSystem: fields[1] as VehicleFuelSystem,
      tankCapacityLiters: fields[2] as double,
      kmPerLiterGasoline: fields[3] as double?,
      kmPerLiterEthanol: fields[4] as double?,
      kmPerLiterDiesel: fields[5] as double?,
      defaultFuel: fields[6] as FuelType,
      propulsion: fields[7] == null
          ? VehiclePropulsion.combustion
          : fields[7] as VehiclePropulsion,
      batteryCapacityKwh: fields[8] as double?,
      electricRangeKm: fields[9] as double?,
      autoUpdateReferences: fields[10] == null ? true : fields[10] as bool,
      defaultPricePerKwh: fields[11] as double?,
    );
  }

  @override
  void write(BinaryWriter writer, VehicleProfile obj) {
    writer
      ..writeByte(12)
      ..writeByte(0)
      ..write(obj.nickname)
      ..writeByte(1)
      ..write(obj.fuelSystem)
      ..writeByte(2)
      ..write(obj.tankCapacityLiters)
      ..writeByte(3)
      ..write(obj.kmPerLiterGasoline)
      ..writeByte(4)
      ..write(obj.kmPerLiterEthanol)
      ..writeByte(5)
      ..write(obj.kmPerLiterDiesel)
      ..writeByte(6)
      ..write(obj.defaultFuel)
      ..writeByte(7)
      ..write(obj.propulsion)
      ..writeByte(8)
      ..write(obj.batteryCapacityKwh)
      ..writeByte(9)
      ..write(obj.electricRangeKm)
      ..writeByte(10)
      ..write(obj.autoUpdateReferences)
      ..writeByte(11)
      ..write(obj.defaultPricePerKwh);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VehicleProfileAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class FuelTypeAdapter extends TypeAdapter<FuelType> {
  @override
  final int typeId = 16;

  @override
  FuelType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return FuelType.gasoline;
      case 1:
        return FuelType.ethanol;
      case 2:
        return FuelType.diesel;
      default:
        return FuelType.gasoline;
    }
  }

  @override
  void write(BinaryWriter writer, FuelType obj) {
    switch (obj) {
      case FuelType.gasoline:
        writer.writeByte(0);
        break;
      case FuelType.ethanol:
        writer.writeByte(1);
        break;
      case FuelType.diesel:
        writer.writeByte(2);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FuelTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class VehicleFuelSystemAdapter extends TypeAdapter<VehicleFuelSystem> {
  @override
  final int typeId = 17;

  @override
  VehicleFuelSystem read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return VehicleFuelSystem.flex;
      case 1:
        return VehicleFuelSystem.gasoline;
      case 2:
        return VehicleFuelSystem.ethanol;
      case 3:
        return VehicleFuelSystem.diesel;
      default:
        return VehicleFuelSystem.flex;
    }
  }

  @override
  void write(BinaryWriter writer, VehicleFuelSystem obj) {
    switch (obj) {
      case VehicleFuelSystem.flex:
        writer.writeByte(0);
        break;
      case VehicleFuelSystem.gasoline:
        writer.writeByte(1);
        break;
      case VehicleFuelSystem.ethanol:
        writer.writeByte(2);
        break;
      case VehicleFuelSystem.diesel:
        writer.writeByte(3);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VehicleFuelSystemAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class VehiclePropulsionAdapter extends TypeAdapter<VehiclePropulsion> {
  @override
  final int typeId = 20;

  @override
  VehiclePropulsion read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return VehiclePropulsion.combustion;
      case 1:
        return VehiclePropulsion.hybrid;
      case 2:
        return VehiclePropulsion.plugInHybrid;
      default:
        return VehiclePropulsion.combustion;
    }
  }

  @override
  void write(BinaryWriter writer, VehiclePropulsion obj) {
    switch (obj) {
      case VehiclePropulsion.combustion:
        writer.writeByte(0);
        break;
      case VehiclePropulsion.hybrid:
        writer.writeByte(1);
        break;
      case VehiclePropulsion.plugInHybrid:
        writer.writeByte(2);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VehiclePropulsionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
