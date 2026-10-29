import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import '../models/project.dart';
import '../services/editor_controller.dart';
import '../services/media_import.dart';
import '../services/project_store.dart';
import '../widgets/cropped_video.dart';
import 'crop_screen.dart';
import 'export_flow.dart';

String _fmt(int ms) {
  final s = ms / 1000;
  final m = s ~/ 60;
  final rest = (s - m * 60).toStringAsFixed(1).padLeft(4, '0');
  return '$m:$rest';
}

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.project});

  final Project project;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final EditorController ctl;
  VideoPlayerController? _vc;
  String? _loadedClipId;

  @override
  void initState() {
    super.initState();
    ctl = EditorController(widget.project)..addListener(_syncVideo);
    _syncVideo();
  }

  @override
  void dispose() {
    ctl.removeListener(_syncVideo);
    _vc?.removeListener(_tick);
    _vc?.dispose();
    ctl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ video player

  Future<void> _syncVideo() async {
    final c = ctl.current;
    if (c == null) {
      _loadedClipId = null;
      await _releaseVideo();
      return;
    }
    if (_loadedClipId == c.id) {
      _vc?.setPlaybackSpeed(c.speed);
      return;
    }
    _loadedClipId = c.id;
    await _releaseVideo();
    final vc = VideoPlayerController.file(File(c.path));
    _vc = vc;
    try {
      await vc.initialize();
    } catch (_) {
      return;
    }
    if (!mounted || _vc != vc) {
      return;
    }
    vc.addListener(_tick);
    await vc.seekTo(Duration(milliseconds: c.trimStartMs));
    await vc.setPlaybackSpeed(c.speed);
    if (mounted) setState(() {});
  }

  Future<void> _releaseVideo() async {
    final old = _vc;
    _vc = null;
    if (old == null) return;
    old.removeListener(_tick);
    if (mounted) setState(() {});
    // Let the frame that stops using the controller finish before disposing it.
    await WidgetsBinding.instance.endOfFrame;
    await old.dispose();
  }

  void _tick() {
    final vc = _vc;
    final c = ctl.current;
    if (vc == null || c == null) return;
    final pos = vc.value.position.inMilliseconds;
    if (vc.value.isPlaying && pos >= c.trimEndMs) {
      vc.pause();
      vc.seekTo(Duration(milliseconds: c.trimStartMs));
    }
    if (mounted) setState(() {});
  }

  void _togglePlay() {
    final vc = _vc;
    final c = ctl.current;
    if (vc == null || c == null) return;
    if (vc.value.isPlaying) {
      vc.pause();
      return;
    }
    final pos = vc.value.position.inMilliseconds;
    if (pos < c.trimStartMs || pos >= c.trimEndMs - 50) {
      vc.seekTo(Duration(milliseconds: c.trimStartMs));
    }
    vc.play();
  }

  // ----------------------------------------------------------------- actions

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _addClip() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: true,
    );
    final paths = result?.paths.whereType<String>().toList() ?? [];
    if (paths.isEmpty || !mounted) return;
    _snack('Importing…');
    try {
      for (final path in paths) {
        ctl.addClip(await importVideo(ctl.project.id, path));
      }
    } catch (e) {
      if (mounted) _snack('Could not import video: $e');
    }
  }

  void _split() {
    final pos = _vc?.value.position.inMilliseconds;
    if (pos == null || !ctl.split(pos)) {
      _snack('Move the playhead inside the clip (not at the very start or end) to split.');
    }
  }

  Future<void> _crop() async {
    final c = ctl.current;
    if (c == null) return;
    _vc?.pause();
    final result = await Navigator.push<CropResult>(
      context,
      MaterialPageRoute(builder: (_) => CropScreen(clip: c)),
    );
    if (result != null) ctl.setCrop(result.crop);
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: ctl.project.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename project'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) ctl.rename(name);
  }

  Future<void> _export() async {
    if (ctl.project.clips.isEmpty) {
      _snack('Add a clip first.');
      return;
    }
    _vc?.pause();
    await ctl.flush();
    if (!mounted) return;
    await showExportFlow(context, ctl.project);
    await ctl.flush();
  }

  // ------------------------------------------------------------------ sheets

  void _showSheet(Widget Function(BuildContext) builder) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: ctl,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: builder(context),
          ),
        ),
      ),
    );
  }

  void _speedSheet() {
    if (ctl.current == null) return;
    _showSheet((_) {
      final speed = ctl.current?.speed ?? 1.0;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Speed', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final s in const [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0])
                ChoiceChip(
                  label: Text('${s}x'),
                  selected: (speed - s).abs() < 0.001,
                  onSelected: (_) => ctl.setSpeed(s),
                ),
            ],
          ),
        ],
      );
    });
  }

  void _aspectSheet() {
    _showSheet((_) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Aspect ratio', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final a in AspectPreset.values)
                  ChoiceChip(
                    label: Text(a.label),
                    selected: ctl.project.aspect == a,
                    onSelected: (_) => ctl.setAspect(a),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('Clips that do not fill the frame get black bars.'),
          ],
        ));
  }

  Future<void> _pickMusic() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.audio);
    final path = result?.files.single.path;
    if (path == null) return;
    final local = await ProjectStore.instance.importMedia(ctl.project.id, path);
    ctl.setMusic(MusicTrack(path: local, name: p.basename(path)));
  }

  void _musicSheet() {
    _showSheet((_) {
      final m = ctl.project.music;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Music', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (m == null)
            FilledButton.icon(
              onPressed: _pickMusic,
              icon: const Icon(Icons.library_music_outlined),
              label: const Text('Pick an audio file'),
            )
          else ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.music_note),
              title: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => ctl.setMusic(null),
              ),
            ),
            const Text('Music volume'),
            Slider(
              value: m.volume,
              onChanged: (v) => ctl.setMusic(m.copyWith(volume: v)),
            ),
            const Text('Original video volume'),
            Slider(
              value: m.originalVolume,
              onChanged: (v) => ctl.setMusic(m.copyWith(originalVolume: v)),
            ),
            const Text('Music loops if it is shorter than the video.'),
          ],
        ],
      );
    });
  }

  void _textSheet() {
    _showSheet((ctx) {
      final texts = ctl.project.texts;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Text', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          if (texts.isEmpty) const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No text yet.'),
          ),
          for (final t in texts)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.text, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${_fmt(t.startMs)} – ${_fmt(t.endMs)}'),
              onTap: () => _editText(t),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => ctl.removeText(t.id),
              ),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => _editText(null),
            icon: const Icon(Icons.add),
            label: const Text('Add text'),
          ),
          const SizedBox(height: 4),
          const Text('Text appears in the exported video (not in this preview).'),
        ],
      );
    });
  }

  Future<void> _editText(TextOverlay? existing) async {
    final total = ctl.project.totalMs;
    if (total <= 0) {
      _snack('Add a clip first.');
      return;
    }
    final controller = TextEditingController(text: existing?.text ?? '');
    var range = RangeValues(
      (existing?.startMs ?? 0).toDouble().clamp(0.0, total.toDouble()),
      (existing?.endMs ?? total).toDouble().clamp(0.0, total.toDouble()),
    );
    var position = existing?.position ?? 2;
    var size = existing?.sizePct ?? 6.0;
    var color = existing?.colorRgb ?? 0xFFFFFF;
    const palette = [0xFFFFFF, 0xFFEB3B, 0xFF5252, 0x69F0AE, 0x40C4FF, 0x000000];

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(existing == null ? 'Add text' : 'Edit text'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Your text'),
                ),
                const SizedBox(height: 16),
                Text('Shown from ${_fmt(range.start.round())} to ${_fmt(range.end.round())}'),
                RangeSlider(
                  values: range,
                  min: 0,
                  max: total.toDouble(),
                  onChanged: (v) => setLocal(() => range = v),
                ),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('Top')),
                    ButtonSegment(value: 1, label: Text('Middle')),
                    ButtonSegment(value: 2, label: Text('Bottom')),
                  ],
                  selected: {position},
                  onSelectionChanged: (s) => setLocal(() => position = s.first),
                ),
                const SizedBox(height: 8),
                const Text('Size'),
                Slider(
                  value: size,
                  min: 3,
                  max: 14,
                  onChanged: (v) => setLocal(() => size = v),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final c in palette)
                      GestureDetector(
                        onTap: () => setLocal(() => color = c),
                        child: CircleAvatar(
                          radius: 14,
                          backgroundColor: Color(0xFF000000 | c),
                          child: color == c
                              ? Icon(Icons.check,
                                  size: 16, color: c == 0x000000 ? Colors.white : Colors.black)
                              : null,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );

    final text = controller.text.trim();
    if (saved != true || text.isEmpty) return;
    final overlay = TextOverlay(
      id: existing?.id ?? newId(),
      text: text,
      startMs: range.start.round(),
      endMs: range.end.round(),
      position: position,
      sizePct: size,
      colorRgb: color,
    );
    existing == null ? ctl.addText(overlay) : ctl.updateText(overlay);
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await ctl.flush();
        if (context.mounted) Navigator.pop(context);
      },
      child: ListenableBuilder(
        listenable: ctl,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
            title: GestureDetector(
              onTap: _rename,
              child: Text(ctl.project.name, overflow: TextOverflow.ellipsis),
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton.icon(
                  onPressed: _export,
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: const Text('Export'),
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(child: _preview()),
                _transport(),
                _timeline(),
                _trimControls(),
                _toolbar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _preview() {
    final c = ctl.current;
    final vc = _vc;
    if (c == null) {
      return Center(
        child: FilledButton.icon(
          onPressed: _addClip,
          icon: const Icon(Icons.add),
          label: const Text('Add a video'),
        ),
      );
    }
    if (vc == null || !vc.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Center(
        child: AspectRatio(
          aspectRatio: ctl.project.canvasAspect,
          child: ColoredBox(
            color: Colors.black,
            child: Center(
              child: AspectRatio(
                aspectRatio: c.cropAspect,
                child: CroppedVideo(controller: vc, crop: c.crop),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _transport() {
    final c = ctl.current;
    final vc = _vc;
    final pos = vc == null || c == null
        ? 0
        : (vc.value.position.inMilliseconds - c.trimStartMs).clamp(0, c.trimmedMs);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          IconButton(
            onPressed: c == null ? null : _togglePlay,
            icon: Icon(
              vc?.value.isPlaying == true ? Icons.pause_circle : Icons.play_circle,
              size: 36,
            ),
          ),
          Text(c == null ? '--' : '${_fmt(pos)} / ${_fmt(c.trimmedMs)}'),
          const Spacer(),
          Text('Total ${_fmt(ctl.project.totalMs)}',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _timeline() {
    final clips = ctl.project.clips;
    return SizedBox(
      height: 84,
      child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        buildDefaultDragHandles: true,
        itemCount: clips.length,
        onReorder: ctl.reorder,
        footer: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: SizedBox(
            width: 64,
            child: OutlinedButton(
              onPressed: _addClip,
              child: const Icon(Icons.add),
            ),
          ),
        ),
        itemBuilder: (context, i) {
          final c = clips[i];
          final selected = i == ctl.selected;
          final scheme = Theme.of(context).colorScheme;
          return Padding(
            key: ValueKey(c.id),
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => ctl.select(i),
              child: Container(
                width: 92,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: selected ? scheme.primaryContainer : scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected ? scheme.primary : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('#${i + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(_fmt(c.outputMs)),
                    Text(
                      [
                        if (c.speed != 1.0) '${c.speed}x',
                        if (c.crop != null) 'crop',
                      ].join(' · '),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _trimControls() {
    final c = ctl.current;
    if (c == null) return const SizedBox(height: 8);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          RangeSlider(
            values: RangeValues(c.trimStartMs.toDouble(), c.trimEndMs.toDouble()),
            min: 0,
            max: c.durationMs.toDouble(),
            onChanged: (v) {
              var start = v.start.round();
              var end = v.end.round();
              final startMoved = start != c.trimStartMs;
              if (end - start < EditorController.minClipMs) {
                if (startMoved) {
                  start = end - EditorController.minClipMs;
                } else {
                  end = start + EditorController.minClipMs;
                }
              }
              start = start.clamp(0, c.durationMs);
              end = end.clamp(0, c.durationMs);
              ctl.setTrim(start, end);
              _vc?.seekTo(Duration(milliseconds: startMoved ? start : end - 100));
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Trim start ${_fmt(c.trimStartMs)}',
                  style: Theme.of(context).textTheme.bodySmall),
              Text('end ${_fmt(c.trimEndMs)}',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }

  Widget _toolbar() {
    final hasClip = ctl.current != null;
    Widget tool(IconData icon, String label, VoidCallback? onTap) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: onTap == null ? Colors.white24 : null),
                const SizedBox(height: 2),
                Text(label, style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
        );

    return SizedBox(
      height: 64,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          tool(Icons.content_cut, 'Split', hasClip ? _split : null),
          tool(Icons.crop, 'Crop', hasClip ? _crop : null),
          tool(Icons.speed, 'Speed', hasClip ? _speedSheet : null),
          tool(Icons.copy, 'Duplicate', hasClip ? ctl.duplicateSelected : null),
          tool(Icons.delete_outline, 'Delete', hasClip ? ctl.deleteSelected : null),
          tool(Icons.aspect_ratio, 'Ratio', _aspectSheet),
          tool(Icons.music_note, 'Music', _musicSheet),
          tool(Icons.text_fields, 'Text', _textSheet),
        ],
      ),
    );
  }
}
