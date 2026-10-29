import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/project.dart';

class ExportCancelled implements Exception {
  const ExportCancelled();
  @override
  String toString() => 'Export cancelled';
}

class FfmpegService {
  FfmpegService._();

  /// If your FFmpeg build has no libx264, switch this to 'h264_mediacodec'
  /// (hardware encoder) and replace '-crf', '23' below with '-b:v', '6M'.
  static const String videoEncoder = 'libx264';

  static Future<bool> hasAudio(String path) async {
    final session = await FFprobeKit.getMediaInformation(path);
    final streams = session.getMediaInformation()?.getStreams() ?? [];
    return streams.any((s) => s.getType() == 'audio');
  }

  static void cancel() => FFmpegKit.cancel();

  /// Renders the project to an .mp4 and returns its path.
  ///
  /// Pipeline:
  ///  1. every clip -> its own normalized segment (trim, crop, speed, scale+pad
  ///     to the output canvas, 30 fps, AAC stereo)
  ///  2. segments are joined with the concat demuxer
  ///  3. text overlays and background music are applied in the final pass
  static Future<String> export(
    Project project, {
    required void Function(double progress) onProgress,
  }) async {
    if (project.clips.isEmpty) throw Exception('Add at least one clip first.');

    final tmp = await getTemporaryDirectory();
    final work = Directory(p.join(tmp.path, 'export_${project.id}'));
    if (await work.exists()) await work.delete(recursive: true);
    await work.create(recursive: true);

    try {
      final (w, h) = project.canvasSize(project.exportShortSide);
      final steps = project.clips.length + 1;
      final segments = <String>[];

      for (var i = 0; i < project.clips.length; i++) {
        final clip = project.clips[i];
        final out = p.join(work.path, 'seg_$i.mp4');
        await _run(
          _segmentArgs(clip, out, w, h),
          totalMs: clip.outputMs,
          onProgress: (f) => onProgress((i + f) / steps),
        );
        segments.add(out);
      }

      final listFile = File(p.join(work.path, 'list.txt'));
      await listFile.writeAsString(
        segments.map((s) => "file '${s.replaceAll("'", r"'\''")}'").join('\n'),
      );

      final docs = await getApplicationDocumentsDirectory();
      final exports = Directory(p.join(docs.path, 'exports'));
      await exports.create(recursive: true);
      final safeName = project.name.replaceAll(RegExp(r'[^\w\-]+'), '_');
      final output = p.join(
        exports.path,
        '${safeName}_${DateTime.now().millisecondsSinceEpoch}.mp4',
      );

      final finalArgs = await _finalArgs(project, listFile.path, output, h, work);
      await _run(
        finalArgs,
        totalMs: project.totalMs,
        onProgress: (f) => onProgress((project.clips.length + f) / steps),
      );
      onProgress(1.0);
      return output;
    } finally {
      if (await work.exists()) await work.delete(recursive: true);
    }
  }

  // ---------------------------------------------------------------- segments

  static List<String> _segmentArgs(VideoClip c, String out, int w, int h) {
    final outSec = (c.outputMs / 1000).toStringAsFixed(3);
    final args = <String>[
      '-y',
      '-ss', (c.trimStartMs / 1000).toStringAsFixed(3),
      '-t', (c.trimmedMs / 1000).toStringAsFixed(3),
      '-i', c.path,
    ];
    // Clips without an audio track get silence so every segment has audio.
    if (!c.hasAudio) {
      args.addAll(['-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=stereo']);
    }

    final vf = <String>[];
    final crop = c.crop;
    if (crop != null) {
      String ev(double v) => v.toStringAsFixed(5);
      vf.add('crop=trunc(iw*${ev(crop.w)}/2)*2:trunc(ih*${ev(crop.h)}/2)*2'
          ':trunc(iw*${ev(crop.l)}/2)*2:trunc(ih*${ev(crop.t)}/2)*2');
    }
    vf.addAll([
      'setpts=(PTS-STARTPTS)/${c.speed.toStringAsFixed(4)}',
      'scale=$w:$h:force_original_aspect_ratio=decrease',
      'pad=$w:$h:(ow-iw)/2:(oh-ih)/2:black',
      'setsar=1',
      'fps=30',
      'format=yuv420p',
    ]);

    final af = <String>[];
    if (c.hasAudio) {
      af.add('asetpts=PTS-STARTPTS');
      af.addAll(_atempoChain(c.speed));
    } else {
      af.add('atrim=0:$outSec');
    }
    af.addAll([
      'aresample=44100',
      'aformat=sample_fmts=fltp:channel_layouts=stereo',
    ]);

    final audioInput = c.hasAudio ? '0:a' : '1:a';
    args.addAll([
      '-filter_complex',
      '[0:v]${vf.join(',')}[v];[$audioInput]${af.join(',')}[a]',
      '-map', '[v]',
      '-map', '[a]',
      '-c:v', videoEncoder,
      '-preset', 'veryfast',
      '-crf', '23',
      '-c:a', 'aac',
      '-b:a', '128k',
      '-t', outSec,
      '-movflags', '+faststart',
      out,
    ]);
    return args;
  }

  /// atempo only accepts 0.5..2.0 per instance, so chain them for 0.25x..4x.
  static List<String> _atempoChain(double speed) {
    final parts = <String>[];
    var s = speed;
    while (s > 2.0) {
      parts.add('atempo=2.0');
      s /= 2.0;
    }
    while (s < 0.5) {
      parts.add('atempo=0.5');
      s /= 0.5;
    }
    if ((s - 1.0).abs() > 0.0001 || parts.isEmpty) {
      parts.add('atempo=${s.toStringAsFixed(4)}');
    }
    return parts;
  }

  // ------------------------------------------------------------- final pass

  static Future<List<String>> _finalArgs(
    Project project,
    String listPath,
    String output,
    int canvasH,
    Directory work,
  ) async {
    final texts = project.texts.where((t) => t.text.trim().isNotEmpty).toList();
    final music = project.music;
    final args = <String>['-y', '-f', 'concat', '-safe', '0', '-i', listPath];

    if (texts.isEmpty && music == null) {
      args.addAll(['-c', 'copy', '-movflags', '+faststart', output]);
      return args;
    }

    final fc = <String>[];

    if (music != null) {
      args.addAll(['-stream_loop', '-1', '-i', music.path]);
      fc.add('[0:a]volume=${music.originalVolume.toStringAsFixed(2)}[a0]');
      fc.add('[1:a]volume=${music.volume.toStringAsFixed(2)}[a1]');
      fc.add('[a0][a1]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[a]');
    }

    if (texts.isNotEmpty) {
      final font = _findFont();
      if (font == null) {
        throw Exception(
            'No system font found for text overlays. Bundle a .ttf and point _findFont() at it.');
      }
      final draws = <String>[];
      for (var i = 0; i < texts.length; i++) {
        final t = texts[i];
        final textFile = File(p.join(work.path, 'text_$i.txt'));
        await textFile.writeAsString(t.text);
        final size = (canvasH * t.sizePct / 100).round();
        final y = switch (t.position) {
          0 => 'h*0.08',
          1 => '(h-text_h)/2',
          _ => 'h*0.92-text_h',
        };
        final color = t.colorRgb.toRadixString(16).padLeft(6, '0');
        final a = (t.startMs / 1000).toStringAsFixed(3);
        final b = (t.endMs / 1000).toStringAsFixed(3);
        draws.add('drawtext=fontfile=$font:textfile=${textFile.path}:reload=0'
            ':fontsize=$size:fontcolor=0x$color:borderw=2:bordercolor=black'
            ":x=(w-text_w)/2:y=$y:enable='between(t,$a,$b)'");
      }
      fc.add('[0:v]${draws.join(',')}[v]');
    }

    args.addAll(['-filter_complex', fc.join(';')]);
    args.addAll(['-map', texts.isNotEmpty ? '[v]' : '0:v']);
    args.addAll(['-map', music != null ? '[a]' : '0:a']);

    if (texts.isNotEmpty) {
      args.addAll(['-c:v', videoEncoder, '-preset', 'veryfast', '-crf', '23', '-pix_fmt', 'yuv420p']);
    } else {
      args.addAll(['-c:v', 'copy']);
    }
    if (music != null) {
      args.addAll(['-c:a', 'aac', '-b:a', '160k']);
    } else {
      args.addAll(['-c:a', 'copy']);
    }
    args.addAll([
      '-t', (project.totalMs / 1000).toStringAsFixed(3),
      '-movflags', '+faststart',
      output,
    ]);
    return args;
  }

  static String? _findFont() {
    const candidates = [
      '/system/fonts/Roboto-Regular.ttf',
      '/system/fonts/DroidSans.ttf',
      '/system/fonts/NotoSans-Regular.ttf',
    ];
    for (final f in candidates) {
      if (File(f).existsSync()) return f;
    }
    return null;
  }

  // ------------------------------------------------------------------ utils

  static Future<void> _run(
    List<String> args, {
    required int totalMs,
    required void Function(double) onProgress,
  }) {
    final done = Completer<void>();
    FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        final rc = await session.getReturnCode();
        if (ReturnCode.isSuccess(rc)) {
          done.complete();
        } else if (ReturnCode.isCancel(rc)) {
          done.completeError(const ExportCancelled());
        } else {
          final logs = await session.getAllLogsAsString() ?? '';
          done.completeError(
              Exception('FFmpeg failed (code ${rc?.getValue()}):\n${_tail(logs)}'));
        }
      },
      null,
      (stats) {
        if (totalMs <= 0) return;
        final t = stats.getTime().toDouble();
        onProgress((t / totalMs).clamp(0.0, 1.0));
      },
    );
    return done.future;
  }

  static String _tail(String s, [int lines = 12]) {
    final all = s.trim().split('\n');
    return all.sublist(all.length > lines ? all.length - lines : 0).join('\n');
  }
}
