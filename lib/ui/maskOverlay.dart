import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Draws the nickname blur on top of a live preview.
///
/// The rectangles are sampled from the detection loop a few times per second
/// (same cadence as the mask that is pushed to the streaming pipeline). The
/// video underneath keeps its original frame rate: only the overlay is updated
/// per sample, so no per-frame inference or frame copying happens here.
class MaskOverlay extends StatelessWidget {
  const MaskOverlay({super.key, required this.Mask});

  /// Normalized (0..1) rectangles in capture order, top-left origin.
  final ValueListenable<List<Rect>> Mask;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Rect>>(
      valueListenable: Mask,
      builder: (Context, Rects, _) {
        if (Rects.isEmpty) return const SizedBox.shrink();
        return LayoutBuilder(
          builder: (Context, Constraints) {
            final Width = Constraints.maxWidth;
            final Height = Constraints.maxHeight;
            if (Width <= 1 || Height <= 1) return const SizedBox.shrink();
            final Shape = Path();
            for (final Item in Rects) {
              final Left = Item.left.clamp(0.0, 1.0) * Width;
              final Top = Item.top.clamp(0.0, 1.0) * Height;
              final Right = Item.right.clamp(0.0, 1.0) * Width;
              final Bottom = Item.bottom.clamp(0.0, 1.0) * Height;
              if (Right - Left < 2 || Bottom - Top < 2) continue;
              Shape.addRRect(RRect.fromRectAndRadius(Rect.fromLTRB(Left, Top, Right, Bottom), const Radius.circular(4)));
            }
            if (Shape.getBounds().isEmpty) return const SizedBox.shrink();
            // Roughly the same relative radius the Electron build used for its
            // 1280 wide live canvas.
            final Sigma = (Width / 1280 * 10).clamp(3.0, 16.0);
            return ClipPath(
              clipper: PathClipper(Shape),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: Sigma, sigmaY: Sigma, tileMode: TileMode.decal),
                child: const SizedBox.expand(),
              ),
            );
          },
        );
      },
    );
  }
}

class PathClipper extends CustomClipper<Path> {
  const PathClipper(this.Shape);

  final Path Shape;

  @override
  Path getClip(Size size) => Shape;

  @override
  bool shouldReclip(PathClipper Old) => Old.Shape != Shape;
}
