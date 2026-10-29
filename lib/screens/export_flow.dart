import 'package:flutter/material.dart';
import 'package:gal/gal.dart';

import '../models/project.dart';
import '../services/ffmpeg_service.dart';

/// Asks for the export quality, then renders the project and saves it to the gallery.
Future<void> showExportFlow(BuildContext context, Project project) async {
  final quality = await showDialog<int>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Export quality'),
      children: [
        for (final q in const [480, 720, 1080])
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, q),
            child: Row(
              children: [
                Expanded(child: Text('${q}p${q == project.exportShortSide ? '  (last used)' : ''}')),
                Text(
                  switch (q) { 480 => 'smallest', 720 => 'balanced', _ => 'best' },
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ),
          ),
      ],
    ),
  );
  if (quality == null || !context.mounted) return;
  project.exportShortSide = quality;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ExportDialog(project: project),
  );
}

enum _Phase { running, done, failed, cancelled }

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.project});
  final Project project;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  final ValueNotifier<double> _progress = ValueNotifier(0);
  _Phase _phase = _Phase.running;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final path = await FfmpegService.export(
        widget.project,
        onProgress: (p) => _progress.value = p,
      );
      var saved = 'Saved in the app: $path';
      try {
        if (!await Gal.hasAccess()) await Gal.requestAccess();
        await Gal.putVideo(path);
        saved = 'Saved to your gallery.';
      } catch (_) {
        // Keep the app-private copy and tell the user where it is.
      }
      if (!mounted) return;
      setState(() {
        _phase = _Phase.done;
        _message = saved;
      });
    } on ExportCancelled {
      if (!mounted) return;
      setState(() => _phase = _Phase.cancelled);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _message = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(switch (_phase) {
        _Phase.running => 'Exporting…',
        _Phase.done => 'Export finished',
        _Phase.failed => 'Export failed',
        _Phase.cancelled => 'Export cancelled',
      }),
      content: switch (_phase) {
        _Phase.running => ValueListenableBuilder<double>(
            valueListenable: _progress,
            builder: (_, v, __) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: v == 0 ? null : v),
                const SizedBox(height: 12),
                Text('${(v * 100).round()}%'),
              ],
            ),
          ),
        _Phase.cancelled => const Text('Nothing was saved.'),
        _ => SingleChildScrollView(child: SelectableText(_message)),
      },
      actions: [
        if (_phase == _Phase.running)
          TextButton(onPressed: FfmpegService.cancel, child: const Text('Cancel'))
        else
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}
