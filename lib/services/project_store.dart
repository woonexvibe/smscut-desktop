import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/project.dart';

/// Saves every project on disk:
///   <app documents>/projects/<id>/project.json
///   <app documents>/projects/<id>/media/...   (copies of imported videos/music)
class ProjectStore {
  ProjectStore._();
  static final ProjectStore instance = ProjectStore._();

  Directory? _root;

  Future<Directory> _projectsRoot() async {
    if (_root != null) return _root!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'projects'));
    await dir.create(recursive: true);
    return _root = dir;
  }

  Future<Directory> _projectDir(String id) async {
    final dir = Directory(p.join((await _projectsRoot()).path, id));
    await dir.create(recursive: true);
    return dir;
  }

  Future<List<Project>> loadAll() async {
    final root = await _projectsRoot();
    final projects = <Project>[];
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final file = File(p.join(entity.path, 'project.json'));
      if (!await file.exists()) continue;
      try {
        final json = jsonDecode(await file.readAsString());
        projects.add(Project.fromJson(json as Map<String, dynamic>));
      } catch (_) {
        // Skip corrupted project files instead of crashing the home screen.
      }
    }
    projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return projects;
  }

  /// Writes to a temp file first, then renames, so a crash can't corrupt the save.
  Future<void> save(Project project) async {
    final dir = await _projectDir(project.id);
    final tmp = File(p.join(dir.path, 'project.json.tmp'));
    await tmp.writeAsString(jsonEncode(project.toJson()), flush: true);
    await tmp.rename(p.join(dir.path, 'project.json'));
  }

  Future<void> delete(String id) async {
    final dir = Directory(p.join((await _projectsRoot()).path, id));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Copies a picked file into the project's own media folder so the project
  /// keeps working even if the picker's cache or the original file goes away.
  Future<String> importMedia(String projectId, String sourcePath) async {
    final dir = await _projectDir(projectId);
    final media = Directory(p.join(dir.path, 'media'));
    await media.create(recursive: true);
    final target = p.join(
      media.path,
      '${DateTime.now().microsecondsSinceEpoch}_${p.basename(sourcePath)}',
    );
    await File(sourcePath).copy(target);
    return target;
  }
}
