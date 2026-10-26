import 'dart:math';

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import 'AppTheme.dart';

enum AppButtonKind { Filled, Outlined, Tonal, Text }

class AppButton extends StatelessWidget {
  const AppButton({super.key, required this.Label, required this.OnPressed, this.Kind = AppButtonKind.Filled, this.StartIcon, this.Enabled = true, this.Full = false});

  final String Label;
  final VoidCallback OnPressed;
  final AppButtonKind Kind;
  final IconData? StartIcon;
  final bool Enabled;
  final bool Full;

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    final Foreground = Enabled
        ? Kind == AppButtonKind.Filled
            ? Scheme.onPrimary
            : Kind == AppButtonKind.Tonal
                ? Scheme.onSecondaryContainer
                : Scheme.primary
        : Scheme.onSurface.withValues(alpha: 0.38);
    final Background = !Enabled
        ? (Kind == AppButtonKind.Filled || Kind == AppButtonKind.Tonal ? Scheme.onSurface.withValues(alpha: 0.12) : Colors.transparent)
        : Kind == AppButtonKind.Filled
            ? Scheme.primary
            : Kind == AppButtonKind.Tonal
                ? Scheme.secondaryContainer
                : Colors.transparent;
    final Border = Kind == AppButtonKind.Outlined
        ? BorderSide(color: Enabled ? Scheme.outline : Scheme.onSurface.withValues(alpha: 0.12))
        : BorderSide.none;
    final Horizontal = Kind == AppButtonKind.Text ? 12.0 : 24.0;
    final Button = SizedBox(
      height: 40,
      child: Material(
        color: Background,
        shape: StadiumBorder(side: Border),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: Enabled ? OnPressed : null,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: Horizontal),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                if (StartIcon != null) ...<Widget>[
                  Icon(StartIcon, size: 18, color: Foreground),
                  const SizedBox(width: 8),
                ],
                Text(Label, style: AppTheme.Style(Size: 14, Weight: FontWeight.w500, ColorValue: Foreground, Height: 1)),
              ],
            ),
          ),
        ),
      ),
    );
    return Full
        ? SizedBox(width: double.infinity, child: Button)
        : ConstrainedBox(constraints: const BoxConstraints(minWidth: 48), child: Button);
  }
}

class AppIconButton extends StatelessWidget {
  const AppIconButton({super.key, required this.Glyph, required this.OnPressed, this.Enabled = true, this.Tooltip});

  final IconData Glyph;
  final VoidCallback OnPressed;
  final bool Enabled;
  final String? Tooltip;

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    final Widget Button = IconButton(
      onPressed: Enabled ? OnPressed : null,
      icon: Icon(Glyph),
      iconSize: 24,
      color: Scheme.onSurfaceVariant,
      disabledColor: Scheme.onSurface.withValues(alpha: 0.38),
      splashRadius: 22,
      tooltip: Tooltip,
    );
    return Button;
  }
}

class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.Value, required this.OnChanged, this.Enabled = true});

  final bool Value;
  final ValueChanged<bool> OnChanged;
  final bool Enabled;

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: 0.9,
      child: Switch(value: Value, onChanged: Enabled ? OnChanged : null),
    );
  }
}

class AppTextField extends StatefulWidget {
  const AppTextField({
    super.key,
    required this.Label,
    this.Value,
    this.OnChanged,
    this.OnSubmitted,
    this.Placeholder,
    this.ReadOnly = false,
    this.Enabled = true,
    this.OnIcon,
    this.OnIconTap,
    this.Obscure = false,
    this.MaxLines = 1,
    this.Controller,
  });

  final String Label;
  final String? Value;
  final ValueChanged<String>? OnChanged;
  final ValueChanged<String>? OnSubmitted;
  final String? Placeholder;
  final bool ReadOnly;
  final bool Enabled;
  final IconData? OnIcon;
  final VoidCallback? OnIconTap;
  final bool Obscure;
  final int MaxLines;
  final TextEditingController? Controller;

  @override
  State<AppTextField> createState() => AppTextFieldState();
}

class AppTextFieldState extends State<AppTextField> {
  late TextEditingController _Controller;
  late bool _Owned;

  @override
  void initState() {
    super.initState();
    _Owned = widget.Controller == null;
    _Controller = widget.Controller ?? TextEditingController(text: widget.Value ?? '');
  }

  @override
  void didUpdateWidget(covariant AppTextField Old) {
    super.didUpdateWidget(Old);
    if (widget.Controller != Old.Controller) {
      if (_Owned) _Controller.dispose();
      _Owned = widget.Controller == null;
      _Controller = widget.Controller ?? TextEditingController(text: widget.Value ?? '');
    } else if (widget.Value != Old.Value && widget.Value != _Controller.text) {
      _Controller.text = widget.Value ?? '';
    }
  }

  @override
  void dispose() {
    if (_Owned) _Controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: TextField(
        controller: _Controller,
        readOnly: widget.ReadOnly,
        enabled: widget.Enabled,
        obscureText: widget.Obscure,
        maxLines: widget.MaxLines,
        onChanged: widget.OnChanged,
        onSubmitted: widget.OnSubmitted,
        style: AppTheme.Style(Size: 14, ColorValue: Theme.of(context).colorScheme.onSurface),
        decoration: InputDecoration(
          labelText: widget.Label,
          hintText: widget.Placeholder,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          suffixIcon: widget.OnIcon == null ? null : IconButton(onPressed: widget.OnIconTap, icon: Icon(widget.OnIcon), iconSize: 20),
        ),
      ),
    );
  }
}

class AppSelect<T> extends StatelessWidget {
  const AppSelect({super.key, required this.Label, required this.Value, required this.Items, required this.OnChanged, this.Enabled = true, this.Display});

  final String Label;
  final T Value;
  final List<T> Items;
  final ValueChanged<T> OnChanged;
  final bool Enabled;
  final String Function(T)? Display;

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    final SafeValue = Items.contains(Value) ? Value : (Items.isEmpty ? Value : Items.first);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: DropdownButtonFormField<T>(
        initialValue: SafeValue,
        isExpanded: true,
        dropdownColor: Scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        menuMaxHeight: 280,
        style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurface),
        icon: Icon(Icons.arrow_drop_down, color: Scheme.onSurfaceVariant),
        decoration: InputDecoration(labelText: Label, contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20)),
        items: Items.map((Item) => DropdownMenuItem<T>(value: Item, child: Text(Display?.call(Item) ?? '$Item', overflow: TextOverflow.ellipsis))).toList(),
        onChanged: Enabled ? (Next) { if (Next != null) OnChanged(Next); } : null,
      ),
    );
  }
}

class AppLinearProgress extends StatelessWidget {
  const AppLinearProgress({super.key, this.Value, this.Indeterminate = false});

  final double? Value;
  final bool Indeterminate;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(value: Indeterminate ? null : Value, minHeight: 4),
    );
  }
}

class AppSectionTitle extends StatelessWidget {
  const AppSectionTitle(this.Content, {super.key});

  final String Content;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 8),
      child: Text(Content, style: AppTheme.Style(Size: 16, Weight: FontWeight.w600)),
    );
  }
}

class AppPageTitle extends StatelessWidget {
  const AppPageTitle(this.Content, {super.key});

  final String Content;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Text(Content, style: AppTheme.Style(Size: 22, Weight: FontWeight.w600)),
    );
  }
}

class AppStatusItem extends StatelessWidget {
  const AppStatusItem({super.key, required this.Label, required this.Value});

  final String Label;
  final Widget Value;

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Scheme.outlineVariant))),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(Label, style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurfaceVariant)),
          const SizedBox(width: 16),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: DefaultTextStyle.merge(
                style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurface),
                textAlign: TextAlign.right,
                child: Value,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AppStatusText extends StatelessWidget {
  const AppStatusText(this.Content, {super.key});

  final String Content;

  @override
  Widget build(BuildContext context) {
    return Text(Content, textAlign: TextAlign.right, style: AppTheme.Style(Size: 14, ColorValue: Theme.of(context).colorScheme.onSurface));
  }
}

class AppHint extends StatelessWidget {
  const AppHint(this.Content, {super.key, this.Error = false});

  final String Content;
  final bool Error;

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(Content, style: AppTheme.Style(Size: 12, ColorValue: Error ? Scheme.error : Scheme.onSurfaceVariant, Height: 1.5)),
    );
  }
}

class AppEmpty extends StatelessWidget {
  const AppEmpty(this.Content, {super.key});

  final String Content;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Text(Content, style: AppTheme.Style(Size: 14, ColorValue: Theme.of(context).colorScheme.onSurfaceVariant)),
      ),
    );
  }
}

class AppFormSwitch extends StatelessWidget {
  const AppFormSwitch({super.key, required this.Label, this.Note, this.Value, required this.OnChanged, this.Enabled = true, this.Wide = false});

  final String Label;
  final String? Note;
  final bool? Value;
  final ValueChanged<bool> OnChanged;
  final bool Enabled;
  final bool Wide;

  @override
  Widget build(BuildContext context) {
    final Scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(Label, style: AppTheme.Style(Size: 14, ColorValue: Scheme.onSurface)),
                if (Note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(Note!, style: AppTheme.Style(Size: 12, ColorValue: Scheme.onSurfaceVariant, Height: 1.5)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          AppSwitch(Value: Value ?? false, OnChanged: OnChanged, Enabled: Enabled),
        ],
      ),
    );
  }
}

class AppDialog extends StatelessWidget {
  const AppDialog({super.key, required this.Title, required this.Content, this.Actions = const <Widget>[], this.Description});

  final String Title;
  final Widget Content;
  final List<Widget> Actions;
  final String? Description;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(48),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(Title, style: AppTheme.Style(Size: 24)),
              if (Description != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(Description!, style: AppTheme.Style(Size: 14, ColorValue: Theme.of(context).colorScheme.onSurfaceVariant, Height: 1.5)),
                ),
              const SizedBox(height: 12),
              Flexible(child: SingleChildScrollView(child: Content)),
              if (Actions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: Actions),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class AppSnack {
  static void Show(BuildContext Context, String Message) {
    final Messenger = ScaffoldMessenger.maybeOf(Context);
    if (Messenger == null) return;
    Messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(Message, style: AppTheme.Style(Size: 14, ColorValue: Theme.of(Context).colorScheme.onInverseSurface)),
        duration: const Duration(seconds: 5),
      ));
  }
}

class QrView extends StatelessWidget {
  const QrView({super.key, required this.Data, this.Size = 220});

  final String Data;
  final double Size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: Size,
      height: Size,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: CustomPaint(painter: QrPainter(Data)),
    );
  }
}

class QrPainter extends CustomPainter {
  QrPainter(this.Data);

  final String Data;

  @override
  void paint(Canvas Canvas, Size Size) {
    if (Data.isEmpty) return;
    final Code = QrCode(payload: QrPayload.fromString(Data), errorCorrectLevel: QrErrorCorrectLevel.low);
    final Image = QrImage(Code);
    final Count = Image.moduleCount;
    final Cell = Size.width / Count;
    final PaintRef = Paint()..color = Colors.black;
    for (var Row = 0; Row < Count; Row++) {
      for (var Col = 0; Col < Count; Col++) {
        if (Image.isDark(Row, Col)) {
          Canvas.drawRect(Rect.fromLTWH(Col * Cell, Row * Cell, Cell, Cell), PaintRef);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant QrPainter Old) => Old.Data != Data;
}

class AppColorDot extends StatelessWidget {
  const AppColorDot({super.key, required this.ColorValue, required this.Active, required this.OnTap});

  final Color ColorValue;
  final bool Active;
  final VoidCallback OnTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: OnTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: ColorValue,
          shape: BoxShape.circle,
          border: Border.all(color: Active ? Theme.of(context).colorScheme.onSurface : Colors.transparent, width: 2),
          boxShadow: Active ? <BoxShadow>[BoxShadow(color: Theme.of(context).colorScheme.surface, spreadRadius: 3)] : <BoxShadow>[],
        ),
      ),
    );
  }
}

class AppSpinner extends StatelessWidget {
  const AppSpinner({super.key, this.Size = 20});

  final double Size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(width: Size, height: Size, child: CircularProgressIndicator(strokeWidth: 2));
  }
}

IconData IconFor(String Name) {
  const Map<String, IconData> Values = <String, IconData>{
    'monitor': Icons.monitor,
    'link': Icons.link,
    'movie': Icons.movie,
    'settings': Icons.settings,
    'info': Icons.info,
    'videocam': Icons.videocam,
    'cast': Icons.cast,
    'update': Icons.system_update_alt,
    'refresh': Icons.refresh,
    'folder': Icons.folder,
    'delete': Icons.delete,
    'copy': Icons.content_copy,
    'blur': Icons.blur_on,
    'top': Icons.arrow_upward,
    'play': Icons.play_arrow,
    'stop': Icons.stop,
    'pip': Icons.picture_in_picture_alt,
    'external': Icons.open_in_new,
  };
  return Values[Name] ?? Icons.info;
}

double ClampNum(num Value, double Min, double Max) => min(max(Value.toDouble(), Min), Max);



class StatusGrid extends StatelessWidget {
  const StatusGrid({super.key, required this.Children});

  final List<Widget> Children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (Context, Constraints) {
      final Count = (Constraints.maxWidth / 244).floor().clamp(1, 4);
      return Column(
        children: <Widget>[
          for (var Index = 0; Index < Children.length; Index += Count)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (var Slot = 0; Slot < Count; Slot++)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: Slot == Count - 1 ? 0 : 24),
                      child: Index + Slot < Children.length ? Children[Index + Slot] : const SizedBox.shrink(),
                    ),
                  ),
              ],
            ),
        ],
      );
    });
  }
}









