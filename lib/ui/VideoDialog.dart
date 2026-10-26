import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../format/Formats.dart';
import '../ui/AppTheme.dart';
import '../ui/Controls.dart';

class VideoDialog extends StatefulWidget {
  const VideoDialog({super.key, required this.Title, required this.Path});

  final String Title;
  final String Path;

  @override
  State<VideoDialog> createState() => VideoDialogState();
}

class VideoDialogState extends State<VideoDialog> {
  late final Player PlayerRef;
  late final VideoController Controller;

  @override
  void initState() {
    super.initState();
    MediaKit.ensureInitialized();
    PlayerRef = Player();
    Controller = VideoController(PlayerRef);
    PlayerRef.open(Media(widget.Path));
  }

  @override
  void dispose() {
    PlayerRef.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(48),
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
            Text(widget.Title, style: AppTheme.Style(Size: 24)),
            const SizedBox(height: 16),
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Video(controller: Controller),
              ),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: AppButton(Label: '关闭', Kind: AppButtonKind.Text, OnPressed: () => Navigator.of(context).pop()),
            ),
          ]),
        ),
      ),
    );
  }
}

Future<void> ShowVideoDialog(BuildContext Context, String Path, String Kind, int EndAt) {
  return showDialog<void>(
    context: Context,
    barrierColor: Colors.black54,
    builder: (Context) => VideoDialog(Title: '${Formats.Kind(Kind)}-${Formats.DateTimeText(EndAt)}', Path: Path),
  );
}









