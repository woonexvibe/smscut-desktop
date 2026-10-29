import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/project.dart';

/// Shows [controller]'s video, visually cropped to [crop] (normalized).
/// The parent should size this widget to the cropped aspect ratio.
class CroppedVideo extends StatelessWidget {
  const CroppedVideo({super.key, required this.controller, this.crop});

  final VideoPlayerController controller;
  final CropRect? crop;

  @override
  Widget build(BuildContext context) {
    final c = crop;
    if (c == null) return VideoPlayer(controller);
    return LayoutBuilder(builder: (context, box) {
      final fullW = box.maxWidth / c.w;
      final fullH = box.maxHeight / c.h;
      return ClipRect(
        child: Stack(
          children: [
            Positioned(
              left: -c.l * fullW,
              top: -c.t * fullH,
              width: fullW,
              height: fullH,
              child: VideoPlayer(controller),
            ),
          ],
        ),
      );
    });
  }
}
