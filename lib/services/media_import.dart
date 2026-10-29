import 'dart:io';

import 'package:video_player/video_player.dart';

import '../models/project.dart';
import 'ffmpeg_service.dart';
import 'project_store.dart';

/// Copies a picked video into the project folder and reads its metadata.
Future<VideoClip> importVideo(String projectId, String sourcePath) async {
  final local = await ProjectStore.instance.importMedia(projectId, sourcePath);
  final controller = VideoPlayerController.file(File(local));
  try {
    await controller.initialize();
    final durationMs = controller.value.duration.inMilliseconds;
    final size = controller.value.size; // already accounts for rotation
    final hasAudio = await FfmpegService.hasAudio(local);
    return VideoClip(
      id: newId(),
      path: local,
      durationMs: durationMs,
      width: size.width.round(),
      height: size.height.round(),
      hasAudio: hasAudio,
      trimStartMs: 0,
      trimEndMs: durationMs,
    );
  } finally {
    await controller.dispose();
  }
}
