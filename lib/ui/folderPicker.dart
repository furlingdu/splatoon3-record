import 'dart:io';

import 'package:flutter/material.dart';

import 'controls.dart';
import 'theme.dart';

/// In-app directory browser.
///
/// The platform folder dialog (file_selector) opens a modal OS window on top of
/// a running capture session, which can freeze the window on Windows and cannot
/// be validated before use, so the app browses the file system itself.
Future<String?> ShowFolderPicker(BuildContext Context, {String Initial = ''}) {
  return showDialog<String>(
    context: Context,
    builder: (BuildContext Dialog) => FolderPickerDialog(Initial: Initial),
  );
}

class FolderPickerDialog extends StatefulWidget {
  const FolderPickerDialog({super.key, this.Initial = ''});

  final String Initial;

  @override
  State<FolderPickerDialog> createState() => FolderPickerDialogState();
}

class FolderPickerDialogState extends State<FolderPickerDialog> {
  static const int Limit = 300;

  String Path = '';
  List<Directory> Entries = <Directory>[];
  List<String> Drives = <String>[];
  String? Error;
  bool Loading = false;
  bool Truncated = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      for (var Code = 0x43; Code <= 0x5A; Code++) {
        final Letter = String.fromCharCode(Code);
        var Exists = false;
        try {
          Exists = Directory('$Letter:\\').existsSync();
        } catch (_) {
          Exists = false;
        }
        if (Exists) Drives.add(Letter);
      }
    }
    Open(Start());
  }

  String Start() {
    final Candidates = <String>[widget.Initial.trim(), Platform.environment['USERPROFILE'] ?? '', Platform.environment['HOME'] ?? ''];
    for (final Item in Candidates) {
      if (Item.isEmpty) continue;
      try {
        if (Directory(Item).existsSync()) return Item;
      } catch (_) {}
    }
    return Directory.current.path;
  }

  String Name(Directory Item) {
    final Parts = Item.uri.pathSegments.where((String Part) => Part.isNotEmpty).toList();
    return Parts.isEmpty ? Item.path : Parts.last;
  }

  bool IsRoot(String Value) {
    try {
      final Absolute = Directory(Value).absolute;
      return Absolute.parent.path == Absolute.path;
    } catch (_) {
      return false;
    }
  }

  Future<void> Open(String Target) async {
    if (mounted) {
      setState(() {
        Loading = true;
        Error = null;
      });
    }
    final Items = <Directory>[];
    String? Failure;
    var Cut = false;
    try {
      final Folder = Directory(Target);
      if (!Folder.existsSync()) throw StateError('目录不存在');
      for (final Item in Folder.listSync(followLinks: false)) {
        if (Item is! Directory) continue;
        final FolderName = Name(Item);
        if (FolderName.isEmpty || FolderName.startsWith('.')) continue;
        Items.add(Item);
        if (Items.length >= Limit) {
          Cut = true;
          break;
        }
      }
      Items.sort((Directory Left, Directory Right) => Name(Left).toLowerCase().compareTo(Name(Right).toLowerCase()));
    } catch (Cause) {
      Failure = '无法打开该目录：$Cause';
    }
    if (!mounted) return;
    setState(() {
      Path = Target;
      Entries = Items;
      Error = Failure;
      Truncated = Cut;
      Loading = false;
    });
  }

  void Up() {
    final Absolute = Directory(Path).absolute;
    final Parent = Absolute.parent.path;
    if (Parent == Absolute.path) return;
    Open(Parent);
  }

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    final Height = MediaQuery.sizeOf(context).height;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 320, maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('选择保存目录', style: AppTheme.Style(Size: 24)),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(color: Scheme.onSurface.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(14)),
                child: Text(Path, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppTheme.Style(Size: 13, ColorValue: Scheme.onSurfaceVariant, Height: 1.4)),
              ),
              if (Drives.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: Drives.map((String Letter) => AppButton(Label: '$Letter:', Kind: AppButtonKind.Outlined, OnPressed: () => Open('$Letter:\\'))).toList(),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: SizedBox(
                  height: Height < 560 ? 200 : 300,
                  child: Container(
                    decoration: BoxDecoration(border: Border.all(color: Scheme.outlineVariant), borderRadius: BorderRadius.circular(14)),
                    clipBehavior: Clip.antiAlias,
                    child: Loading
                        ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
                        : Entries.isEmpty
                            ? AppEmpty(Error ?? '该目录下没有子文件夹')
                            : ListView.builder(
                                padding: EdgeInsets.zero,
                                itemCount: Entries.length,
                                itemBuilder: (BuildContext Context, int Index) {
                                  final Item = Entries[Index];
                                  return InkWell(
                                    onTap: () => Open(Item.path),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                      child: Row(
                                        children: <Widget>[
                                          Icon(Icons.folder_outlined, size: 20, color: Scheme.onSurfaceVariant),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(Name(Item), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurface)),
                                          ),
                                          Icon(Icons.chevron_right, size: 20, color: Scheme.onSurfaceVariant),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                  ),
                ),
              ),
              if (Truncated) AppHint('目录过多，仅显示前 $Limit 个'),
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Row(
                  children: <Widget>[
                    AppButton(Label: '上一级', Kind: AppButtonKind.Text, Enabled: !IsRoot(Path), OnPressed: Up),
                    const Spacer(),
                    AppButton(Label: '取消', Kind: AppButtonKind.Text, OnPressed: () => Navigator.of(context).pop()),
                    const SizedBox(width: 8),
                    AppButton(Label: '选择此文件夹', Enabled: !Loading, OnPressed: () => Navigator.of(context).pop(Path)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
