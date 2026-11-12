// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sensor_widget_config.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class WidgetPositionAdapter extends TypeAdapter<WidgetPosition> {
  @override
  final int typeId = 2;

  @override
  WidgetPosition read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return WidgetPosition(
      x: fields[0] as double,
      y: fields[1] as double,
    );
  }

  @override
  void write(BinaryWriter writer, WidgetPosition obj) {
    writer
      ..writeByte(2)
      ..writeByte(0)
      ..write(obj.x)
      ..writeByte(1)
      ..write(obj.y);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WidgetPositionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class WidgetSizeAdapter extends TypeAdapter<WidgetSize> {
  @override
  final int typeId = 3;

  @override
  WidgetSize read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return WidgetSize(
      width: fields[0] as double,
      height: fields[1] as double,
    );
  }

  @override
  void write(BinaryWriter writer, WidgetSize obj) {
    writer
      ..writeByte(2)
      ..writeByte(0)
      ..write(obj.width)
      ..writeByte(1)
      ..write(obj.height);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WidgetSizeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class SensorWidgetConfigAdapter extends TypeAdapter<SensorWidgetConfig> {
  @override
  final int typeId = 4;

  @override
  SensorWidgetConfig read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return SensorWidgetConfig(
      sensorType: fields[0] as SensorType,
      displayStyle: fields[1] as DisplayStyle,
      position: fields[2] as WidgetPosition,
      size: fields[3] as WidgetSize,
      page: fields[4] == null ? 0 : fields[4] as int,
    );
  }

  @override
  void write(BinaryWriter writer, SensorWidgetConfig obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.sensorType)
      ..writeByte(1)
      ..write(obj.displayStyle)
      ..writeByte(2)
      ..write(obj.position)
      ..writeByte(3)
      ..write(obj.size)
      ..writeByte(4)
      ..write(obj.page);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SensorWidgetConfigAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class DisplayStyleAdapter extends TypeAdapter<DisplayStyle> {
  @override
  final int typeId = 1;

  @override
  DisplayStyle read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 3:
        return DisplayStyle.numericWithHistory;
      case 6:
        return DisplayStyle.lineChart;
      case 7:
        return DisplayStyle.gForceMeter;
      case 8:
        return DisplayStyle.artificialHorizon;
      case 9:
        return DisplayStyle.refuelSummary;
      default:
        return DisplayStyle.numericWithHistory;
    }
  }

  @override
  void write(BinaryWriter writer, DisplayStyle obj) {
    switch (obj) {
      case DisplayStyle.numericWithHistory:
        writer.writeByte(3);
        break;
      case DisplayStyle.lineChart:
        writer.writeByte(6);
        break;
      case DisplayStyle.gForceMeter:
        writer.writeByte(7);
        break;
      case DisplayStyle.artificialHorizon:
        writer.writeByte(8);
        break;
      case DisplayStyle.refuelSummary:
        writer.writeByte(9);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DisplayStyleAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
