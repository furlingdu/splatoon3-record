import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../media/capture/mobile/MobileMedia.dart';
import 'Controls.dart';

Future<void> SaveToGallery(BuildContext Context, String Path) async {
  if (!FileReady(Path)) {
    AppSnack.Show(Context, '录像文件不存在');
    return;
  }
  var Ok = false;
  try {
    Ok = await MobileMedia.SaveVideo(Path);
  } catch (_) {}
  if (!Context.mounted) return;
  AppSnack.Show(Context, Ok ? '已保存到相册' : '保存到相册失败，请检查相册权限');
}

Future<void> ShareVideo(BuildContext Context, String Path, String Title) async {
  await ShareFile(Context, Path, Title, 'video/mp4');
}

Future<void> ShareText(BuildContext Context, String Path, String Title) async {
  await ShareFile(Context, Path, Title, 'text/plain');
}

Future<void> ShareFile(BuildContext Context, String Path, String Title, String MimeType) async {
  if (!FileReady(Path)) {
    AppSnack.Show(Context, '文件不存在');
    return;
  }
  final Box = Context.findRenderObject();
  final Rect? Origin = Box is RenderBox && Box.hasSize ? Box.localToGlobal(Offset.zero) & Box.size : null;
  try {
    await SharePlus.instance.share(ShareParams(
      files: <XFile>[XFile(Path, mimeType: MimeType)],
      subject: Title,
      text: Title,
      sharePositionOrigin: Origin,
    ));
  } catch (Cause) {
    if (Context.mounted) AppSnack.Show(Context, '分享失败：$Cause');
  }
}

bool FileReady(String Path) {
  if (Path.isEmpty) return false;
  try {
    final FileRef = File(Path);
    return FileRef.existsSync() && FileRef.lengthSync() > 0;
  } catch (_) {
    return false;
  }
}
