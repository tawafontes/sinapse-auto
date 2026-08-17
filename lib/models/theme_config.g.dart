// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'theme_config.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ThemeConfigAdapter extends TypeAdapter<ThemeConfig> {
  @override
  final int typeId = 9;

  @override
  ThemeConfig read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ThemeConfig(
      screenMode: fields[0] as ScreenMode,
      colorPalette: fields[1] as String,
      fontFamily: fields[2] as String,
    );
  }

  @override
  void write(BinaryWriter writer, ThemeConfig obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.screenMode)
      ..writeByte(1)
      ..write(obj.colorPalette)
      ..writeByte(2)
      ..write(obj.fontFamily);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ThemeConfigAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class ScreenModeAdapter extends TypeAdapter<ScreenMode> {
  @override
  final int typeId = 8;

  @override
  ScreenMode read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return ScreenMode.dark;
      case 1:
        return ScreenMode.light;
      case 2:
        return ScreenMode.auto;
      default:
        return ScreenMode.dark;
    }
  }

  @override
  void write(BinaryWriter writer, ScreenMode obj) {
    switch (obj) {
      case ScreenMode.dark:
        writer.writeByte(0);
        break;
      case ScreenMode.light:
        writer.writeByte(1);
        break;
      case ScreenMode.auto:
        writer.writeByte(2);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScreenModeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
