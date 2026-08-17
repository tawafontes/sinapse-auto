// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'dashcam_clip_record.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class DashcamClipRecordAdapter extends TypeAdapter<DashcamClipRecord> {
  @override
  final int typeId = 15;

  @override
  DashcamClipRecord read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DashcamClipRecord(
      filePath: fields[0] == null ? '' : fields[0] as String,
      recordedAt: fields[1] as DateTime,
      durationSeconds: fields[2] == null ? 0 : fields[2] as int,
      sizeBytes: fields[3] == null ? 0 : fields[3] as int,
      isProtected: fields[4] == null ? false : fields[4] as bool,
      resolution: fields[5] == null
          ? VideoResolution.hd720
          : fields[5] as VideoResolution,
      audioEnabled: fields[6] == null ? false : fields[6] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, DashcamClipRecord obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.filePath)
      ..writeByte(1)
      ..write(obj.recordedAt)
      ..writeByte(2)
      ..write(obj.durationSeconds)
      ..writeByte(3)
      ..write(obj.sizeBytes)
      ..writeByte(4)
      ..write(obj.isProtected)
      ..writeByte(5)
      ..write(obj.resolution)
      ..writeByte(6)
      ..write(obj.audioEnabled);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DashcamClipRecordAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
