import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/project.dart';

/// Result of the crop screen. [crop] is null when the full frame is kept.
/// (Popping with no result at all means the user cancelled.)
class CropResult {
  const CropResult(this.crop);
  final CropRect? crop;
}

/// Lets the user drag a crop rectangle over a frame of the clip.
/// Pops with a [CropResult] when the user confirms.
class CropScreen extends StatefulWidget {
  const CropScreen({super.key, required this.clip});

  final VideoClip clip;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  VideoPlayerController? _vc;
  Rect _rect = const Rect.fromLTRB(0, 0, 1, 1);

  /// Locked crop aspect (width / height in pixels), or null for free-form.
  double? _lock;

  /// 0 TL, 1 TR, 2 BL, 3 BR, 4 move, -1 none
  int _drag = -1;

  static const double _hit = 36;
  static const double _minSize = 0.08;

  static const _presets = <String, double?>{
    'Free': null,
    '1:1': 1.0,
    '9:16': 9 / 16,
    '16:9': 16 / 9,
    '4:5': 4 / 5,
    '4:3': 4 / 3,
  };
  String _preset = 'Free';

  @override
  void initState() {
    super.initState();
    final c = widget.clip.crop;
    if (c != null) _rect = Rect.fromLTRB(c.l, c.t, c.r, c.b);
    _initVideo();
  }

  Future<void> _initVideo() async {
    final vc = VideoPlayerController.file(File(widget.clip.path));
    await vc.initialize();
    await vc.seekTo(Duration(milliseconds: widget.clip.trimStartMs));
    await vc.pause();
    if (!mounted) {
      await vc.dispose();
      return;
    }
    setState(() => _vc = vc);
  }

  @override
  void dispose() {
    _vc?.dispose();
    super.dispose();
  }

  double get _vw => widget.clip.width.toDouble();
  double get _vh => widget.clip.height.toDouble();

  void _applyPreset(String name) {
    final ratio = _presets[name];
    setState(() {
      _preset = name;
      _lock = ratio;
      if (ratio == null) return;
      // Largest centered rect with this pixel aspect ratio.
      var w = 1.0;
      var h = _vw / (ratio * _vh);
      if (h > 1) {
        h = 1;
        w = ratio * _vh / _vw;
      }
      _rect = Rect.fromLTWH((1 - w) / 2, (1 - h) / 2, w, h);
    });
  }

  void _reset() => setState(() {
        _rect = const Rect.fromLTRB(0, 0, 1, 1);
        _preset = 'Free';
        _lock = null;
      });

  int _pickHandle(Offset pos, Size size) {
    final r = Rect.fromLTRB(
      _rect.left * size.width,
      _rect.top * size.height,
      _rect.right * size.width,
      _rect.bottom * size.height,
    );
    final corners = [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight];
    for (var i = 0; i < 4; i++) {
      if ((corners[i] - pos).distance <= _hit) return i;
    }
    return r.contains(pos) ? 4 : -1;
  }

  Rect _resize(Rect r, int corner, Offset d) {
    final anchor = switch (corner) {
      0 => r.bottomRight,
      1 => r.bottomLeft,
      2 => r.topRight,
      _ => r.topLeft,
    };
    final moving = switch (corner) {
      0 => r.topLeft,
      1 => r.topRight,
      2 => r.bottomLeft,
      _ => r.bottomRight,
    };
    var m = Offset(
      (moving.dx + d.dx).clamp(0.0, 1.0),
      (moving.dy + d.dy).clamp(0.0, 1.0),
    );
    var w = (m.dx - anchor.dx).abs();
    var h = (m.dy - anchor.dy).abs();

    final lock = _lock;
    if (lock != null) {
      final k = _vw / (lock * _vh); // h = w * k
      final sx = m.dx >= anchor.dx ? 1.0 : -1.0;
      final sy = m.dy >= anchor.dy ? 1.0 : -1.0;
      final maxW = sx > 0 ? 1 - anchor.dx : anchor.dx;
      final maxH = sy > 0 ? 1 - anchor.dy : anchor.dy;
      h = w * k;
      if (w > maxW) {
        w = maxW;
        h = w * k;
      }
      if (h > maxH) {
        h = maxH;
        w = h / k;
      }
      m = Offset(anchor.dx + sx * w, anchor.dy + sy * h);
    }
    if (w < _minSize || h < _minSize) return r;
    return Rect.fromPoints(anchor, m);
  }

  void _onPanUpdate(DragUpdateDetails d, Size size) {
    final delta = Offset(d.delta.dx / size.width, d.delta.dy / size.height);
    setState(() {
      if (_drag == 4) {
        var dx = delta.dx;
        var dy = delta.dy;
        dx = dx.clamp(-_rect.left, 1 - _rect.right);
        dy = dy.clamp(-_rect.top, 1 - _rect.bottom);
        _rect = _rect.shift(Offset(dx, dy));
      } else if (_drag >= 0) {
        _rect = _resize(_rect, _drag, delta);
      }
    });
  }

  void _done() {
    final full = _rect.left < 0.005 &&
        _rect.top < 0.005 &&
        _rect.right > 0.995 &&
        _rect.bottom > 0.995;
    Navigator.pop<CropResult>(
      context,
      CropResult(
        full ? null : CropRect(_rect.left, _rect.top, _rect.right, _rect.bottom),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vc = _vc;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Crop'),
        actions: [
          TextButton(onPressed: _reset, child: const Text('Reset')),
          IconButton(onPressed: _done, icon: const Icon(Icons.check)),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: vc == null
                  ? const Center(child: CircularProgressIndicator())
                  : Center(
                      child: AspectRatio(
                        aspectRatio: vc.value.aspectRatio,
                        child: LayoutBuilder(builder: (context, box) {
                          final size = box.biggest;
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanStart: (d) => _drag = _pickHandle(d.localPosition, size),
                            onPanUpdate: (d) => _onPanUpdate(d, size),
                            onPanEnd: (_) => _drag = -1,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                VideoPlayer(vc),
                                CustomPaint(painter: _CropPainter(_rect)),
                              ],
                            ),
                          );
                        }),
                      ),
                    ),
            ),
          ),
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final name in _presets.keys)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(name),
                      selected: _preset == name,
                      onSelected: (_) => _applyPreset(name),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.rect);

  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(
      rect.left * size.width,
      rect.top * size.height,
      rect.right * size.width,
      rect.bottom * size.height,
    );

    final dim = Path()
      ..addRect(Offset.zero & size)
      ..addRect(r)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(dim, Paint()..color = const Color(0x99000000));

    canvas.drawRect(
      r,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    final grid = Paint()
      ..color = const Color(0x66FFFFFF)
      ..strokeWidth = 0.8;
    for (var i = 1; i <= 2; i++) {
      final x = r.left + r.width * i / 3;
      final y = r.top + r.height * i / 3;
      canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), grid);
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), grid);
    }

    final handle = Paint()..color = Colors.white;
    for (final c in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      canvas.drawCircle(c, 8, handle);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.rect != rect;
}
