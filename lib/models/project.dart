import 'dart:math' as math;

String newId() =>
    '${DateTime.now().microsecondsSinceEpoch}${math.Random().nextInt(9999)}';

enum AspectPreset {
  original('Original', null),
  square('1:1', 1.0),
  portrait('9:16', 9 / 16),
  landscape('16:9', 16 / 9),
  insta('4:5', 4 / 5),
  classic('4:3', 4 / 3);

  const AspectPreset(this.label, this.ratio);
  final String label;
  final double? ratio;
}

/// Crop rectangle in normalized (0..1) coordinates of the source frame.
class CropRect {
  const CropRect(this.l, this.t, this.r, this.b);
  final double l, t, r, b;

  double get w => r - l;
  double get h => b - t;

  Map<String, dynamic> toJson() => {'l': l, 't': t, 'r': r, 'b': b};

  factory CropRect.fromJson(Map<String, dynamic> j) => CropRect(
        (j['l'] as num).toDouble(),
        (j['t'] as num).toDouble(),
        (j['r'] as num).toDouble(),
        (j['b'] as num).toDouble(),
      );
}

class VideoClip {
  const VideoClip({
    required this.id,
    required this.path,
    required this.durationMs,
    required this.width,
    required this.height,
    required this.hasAudio,
    required this.trimStartMs,
    required this.trimEndMs,
    this.speed = 1.0,
    this.crop,
  });

  final String id;
  final String path;
  final int durationMs;
  final int width;
  final int height;
  final bool hasAudio;
  final int trimStartMs;
  final int trimEndMs;
  final double speed;
  final CropRect? crop;

  int get trimmedMs => trimEndMs - trimStartMs;
  int get outputMs => (trimmedMs / speed).round();

  /// Width / height of the frame after cropping.
  double get cropAspect {
    final cw = (crop?.w ?? 1.0) * width;
    final ch = (crop?.h ?? 1.0) * height;
    return ch == 0 ? 1.0 : cw / ch;
  }

  VideoClip copyWith({
    String? id,
    int? trimStartMs,
    int? trimEndMs,
    double? speed,
    CropRect? crop,
    bool clearCrop = false,
  }) =>
      VideoClip(
        id: id ?? this.id,
        path: path,
        durationMs: durationMs,
        width: width,
        height: height,
        hasAudio: hasAudio,
        trimStartMs: trimStartMs ?? this.trimStartMs,
        trimEndMs: trimEndMs ?? this.trimEndMs,
        speed: speed ?? this.speed,
        crop: clearCrop ? null : (crop ?? this.crop),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'durationMs': durationMs,
        'width': width,
        'height': height,
        'hasAudio': hasAudio,
        'trimStartMs': trimStartMs,
        'trimEndMs': trimEndMs,
        'speed': speed,
        'crop': crop?.toJson(),
      };

  factory VideoClip.fromJson(Map<String, dynamic> j) => VideoClip(
        id: j['id'] as String,
        path: j['path'] as String,
        durationMs: j['durationMs'] as int,
        width: j['width'] as int,
        height: j['height'] as int,
        hasAudio: j['hasAudio'] as bool,
        trimStartMs: j['trimStartMs'] as int,
        trimEndMs: j['trimEndMs'] as int,
        speed: (j['speed'] as num).toDouble(),
        crop: j['crop'] == null
            ? null
            : CropRect.fromJson(j['crop'] as Map<String, dynamic>),
      );
}

class TextOverlay {
  const TextOverlay({
    required this.id,
    required this.text,
    required this.startMs,
    required this.endMs,
    this.position = 2,
    this.sizePct = 6,
    this.colorRgb = 0xFFFFFF,
  });

  final String id;
  final String text;
  final int startMs;
  final int endMs;

  /// 0 = top, 1 = center, 2 = bottom.
  final int position;

  /// Font size as a percentage of the output height.
  final double sizePct;

  /// 0xRRGGBB
  final int colorRgb;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'startMs': startMs,
        'endMs': endMs,
        'position': position,
        'sizePct': sizePct,
        'colorRgb': colorRgb,
      };

  factory TextOverlay.fromJson(Map<String, dynamic> j) => TextOverlay(
        id: j['id'] as String,
        text: j['text'] as String,
        startMs: j['startMs'] as int,
        endMs: j['endMs'] as int,
        position: j['position'] as int,
        sizePct: (j['sizePct'] as num).toDouble(),
        colorRgb: j['colorRgb'] as int,
      );
}

class MusicTrack {
  const MusicTrack({
    required this.path,
    required this.name,
    this.volume = 0.8,
    this.originalVolume = 1.0,
  });

  final String path;
  final String name;
  final double volume;
  final double originalVolume;

  MusicTrack copyWith({double? volume, double? originalVolume}) => MusicTrack(
        path: path,
        name: name,
        volume: volume ?? this.volume,
        originalVolume: originalVolume ?? this.originalVolume,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'name': name,
        'volume': volume,
        'originalVolume': originalVolume,
      };

  factory MusicTrack.fromJson(Map<String, dynamic> j) => MusicTrack(
        path: j['path'] as String,
        name: j['name'] as String,
        volume: (j['volume'] as num).toDouble(),
        originalVolume: (j['originalVolume'] as num).toDouble(),
      );
}

class Project {
  Project({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    List<VideoClip>? clips,
    List<TextOverlay>? texts,
    this.music,
    this.aspect = AspectPreset.original,
    this.exportShortSide = 720,
  })  : clips = clips ?? [],
        texts = texts ?? [];

  factory Project.create({required String name}) {
    final now = DateTime.now();
    return Project(id: newId(), name: name, createdAt: now, updatedAt: now);
  }

  final String id;
  String name;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<VideoClip> clips;
  final List<TextOverlay> texts;
  MusicTrack? music;
  AspectPreset aspect;
  int exportShortSide;

  /// Total length of the edited video, in milliseconds.
  int get totalMs => clips.fold(0, (sum, c) => sum + c.outputMs);

  double get canvasAspect {
    final r = aspect.ratio;
    if (r != null) return r;
    if (clips.isEmpty) return 16 / 9;
    return clips.first.cropAspect;
  }

  /// Output size (always even numbers) for the given short side, e.g. 720.
  (int, int) canvasSize(int shortSide) {
    int even(double v) => (v / 2).round() * 2;
    final a = canvasAspect;
    if (a >= 1) {
      return (even(shortSide * a), even(shortSide.toDouble()));
    }
    return (even(shortSide.toDouble()), even(shortSide / a));
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'clips': clips.map((c) => c.toJson()).toList(),
        'texts': texts.map((t) => t.toJson()).toList(),
        'music': music?.toJson(),
        'aspect': aspect.name,
        'exportShortSide': exportShortSide,
      };

  factory Project.fromJson(Map<String, dynamic> j) => Project(
        id: j['id'] as String,
        name: j['name'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        updatedAt: DateTime.parse(j['updatedAt'] as String),
        clips: (j['clips'] as List)
            .map((e) => VideoClip.fromJson(e as Map<String, dynamic>))
            .toList(),
        texts: (j['texts'] as List)
            .map((e) => TextOverlay.fromJson(e as Map<String, dynamic>))
            .toList(),
        music: j['music'] == null
            ? null
            : MusicTrack.fromJson(j['music'] as Map<String, dynamic>),
        aspect: AspectPreset.values.firstWhere(
          (a) => a.name == j['aspect'],
          orElse: () => AspectPreset.original,
        ),
        exportShortSide: j['exportShortSide'] as int,
      );
}
