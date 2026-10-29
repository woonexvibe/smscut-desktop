import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/project.dart';
import 'project_store.dart';

/// Holds the project being edited. Every change is auto-saved (debounced).
class EditorController extends ChangeNotifier {
  EditorController(this.project);

  final Project project;
  int selected = 0;
  Timer? _saveTimer;

  static const int minClipMs = 300;

  VideoClip? get current {
    if (project.clips.isEmpty) return null;
    return project.clips[selected.clamp(0, project.clips.length - 1)];
  }

  void _changed() {
    project.updatedAt = DateTime.now();
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), flush);
  }

  Future<void> flush() {
    _saveTimer?.cancel();
    return ProjectStore.instance.save(project);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    unawaited(ProjectStore.instance.save(project));
    super.dispose();
  }

  // ------------------------------------------------------------------ clips

  void select(int i) {
    if (i < 0 || i >= project.clips.length) return;
    selected = i;
    notifyListeners();
  }

  void _replaceCurrent(VideoClip Function(VideoClip) fn) {
    final c = current;
    if (c == null) return;
    project.clips[selected] = fn(c);
    _changed();
  }

  void setTrim(int startMs, int endMs) =>
      _replaceCurrent((c) => c.copyWith(trimStartMs: startMs, trimEndMs: endMs));

  void setSpeed(double speed) => _replaceCurrent((c) => c.copyWith(speed: speed));

  void setCrop(CropRect? crop) => _replaceCurrent(
        (c) => crop == null ? c.copyWith(clearCrop: true) : c.copyWith(crop: crop),
      );

  /// Splits the selected clip at [sourceMs] (position in the source file).
  bool split(int sourceMs) {
    final c = current;
    if (c == null) return false;
    if (sourceMs < c.trimStartMs + minClipMs || sourceMs > c.trimEndMs - minClipMs) {
      return false;
    }
    final first = c.copyWith(trimEndMs: sourceMs);
    final second = c.copyWith(id: newId(), trimStartMs: sourceMs);
    project.clips
      ..[selected] = first
      ..insert(selected + 1, second);
    _changed();
    return true;
  }

  void duplicateSelected() {
    final c = current;
    if (c == null) return;
    project.clips.insert(selected + 1, c.copyWith(id: newId()));
    selected += 1;
    _changed();
  }

  void deleteSelected() {
    if (current == null) return;
    project.clips.removeAt(selected);
    if (selected >= project.clips.length) selected = project.clips.length - 1;
    if (selected < 0) selected = 0;
    _changed();
  }

  void reorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final selectedId = current?.id;
    final item = project.clips.removeAt(oldIndex);
    project.clips.insert(newIndex, item);
    if (selectedId != null) {
      selected = project.clips.indexWhere((c) => c.id == selectedId);
    }
    _changed();
  }

  void addClip(VideoClip clip) {
    project.clips.add(clip);
    selected = project.clips.length - 1;
    _changed();
  }

  // --------------------------------------------------------------- settings

  void rename(String name) {
    project.name = name;
    _changed();
  }

  void setAspect(AspectPreset a) {
    project.aspect = a;
    _changed();
  }

  void setMusic(MusicTrack? m) {
    project.music = m;
    _changed();
  }

  void addText(TextOverlay t) {
    project.texts.add(t);
    _changed();
  }

  void updateText(TextOverlay t) {
    final i = project.texts.indexWhere((x) => x.id == t.id);
    if (i < 0) return;
    project.texts[i] = t;
    _changed();
  }

  void removeText(String id) {
    project.texts.removeWhere((t) => t.id == id);
    _changed();
  }
}
