import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/project.dart';
import '../services/media_import.dart';
import '../services/project_store.dart';
import 'editor_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Project>? _projects;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await ProjectStore.instance.loadAll();
    if (!mounted) return;
    setState(() => _projects = list);
  }

  Future<void> _createProject() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: true,
    );
    final paths = result?.paths.whereType<String>().toList() ?? [];
    if (paths.isEmpty || !mounted) return;

    final project = Project.create(name: 'Project ${(_projects?.length ?? 0) + 1}');

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      for (final path in paths) {
        project.clips.add(await importVideo(project.id, path));
      }
      await ProjectStore.instance.save(project);
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // close progress dialog
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not import video: $e')));
      return;
    }
    if (!mounted) return;
    Navigator.pop(context); // close progress dialog
    await _open(project);
  }

  Future<void> _open(Project project) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => EditorScreen(project: project)),
    );
    _load();
  }

  Future<void> _rename(Project project) async {
    final controller = TextEditingController(text: project.name);
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
    if (name == null || name.isEmpty) return;
    project.name = name;
    project.updatedAt = DateTime.now();
    await ProjectStore.instance.save(project);
    _load();
  }

  Future<void> _delete(Project project) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete project?'),
        content: Text('"${project.name}" and its imported media will be removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await ProjectStore.instance.delete(project.id);
    _load();
  }

  String _fmtDuration(int ms) {
    final s = (ms / 1000).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final projects = _projects;
    return Scaffold(
      appBar: AppBar(title: const Text('SMSCut')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createProject,
        icon: const Icon(Icons.add),
        label: const Text('New project'),
      ),
      body: projects == null
          ? const Center(child: CircularProgressIndicator())
          : projects.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No projects yet.\nTap "New project" and pick one or more videos.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                  itemCount: projects.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final p = projects[i];
                    return Card(
                      child: ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.movie_outlined)),
                        title: Text(p.name),
                        subtitle: Text(
                          '${p.clips.length} clip(s) · ${_fmtDuration(p.totalMs)} · ${_fmtDate(p.updatedAt)}',
                        ),
                        onTap: () => _open(p),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) => v == 'rename' ? _rename(p) : _delete(p),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'rename', child: Text('Rename')),
                            PopupMenuItem(value: 'delete', child: Text('Delete')),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
