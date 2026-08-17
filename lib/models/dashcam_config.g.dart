// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'dashcam_config.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class DashcamConfigAdapter extends TypeAdapter<DashcamConfig> {
  @override
  final int typeId = 7;

  @override
  DashcamConfig read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DashcamConfig(
      cameraSelection: fields[0] as CameraSelection,
      storageQuotaMb: fields[1] as int,
      audioEnabled: fields[2] as bool,
      resolution: fields[3] as VideoResolution,
      frameRate: fields[4] as int,
      enabled: fields[5] == null ? false : fields[5] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, DashcamConfig obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.cameraSelection)
      ..writeByte(1)
      ..write(obj.storageQuotaMb)
      ..writeByte(2)
      ..write(obj.audioEnabled)
      ..writeByte(3)
      ..write(obj.resolution)
      ..writeByte(4)
      ..write(obj.frameRate)
      ..writeByte(5)
      ..write(obj.enabled);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DashcamConfigAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class CameraSelectionAdapter extends TypeAdapter<CameraSelection> {
  @override
  final int typeId = 5;

  @override
  CameraSelection read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return CameraSelection.rear;
      case 1:
        return CameraSelection.front;
      case 2:
        return CameraSelection.both;
      default:
        return CameraSelection.rear;
    }
  }

  @override
  void write(BinaryWriter writer, CameraSelection obj) {
    switch (obj) {
      case CameraSelection.rear:
        writer.writeByte(0);
        break;
      case CameraSelection.front:
        writer.writeByte(1);
        break;
      case CameraSelection.both:
        writer.writeByte(2);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraSelectionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class VideoResolutionAdapter extends TypeAdapter<VideoResolution> {
  @override
  final int typeId = 6;

  @override
  VideoResolution read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return VideoResolution.sd480;
      case 1:
        return VideoResolution.hd720;
      case 2:
        return VideoResolution.fhd1080;
      case 3:
        return VideoResolution.uhd4k;
      default:
        return VideoResolution.sd480;
    }
  }

  @override
  void write(BinaryWriter writer, VideoResolution obj) {
    switch (obj) {
      case VideoResolution.sd480:
        writer.writeByte(0);
        break;
      case VideoResolution.hd720:
        writer.writeByte(1);
        break;
      case VideoResolution.fhd1080:
        writer.writeByte(2);
        break;
      case VideoResolution.uhd4k:
        writer.writeByte(3);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoResolutionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
