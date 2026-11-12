import 'dart:ui' show ImageFilter, Path, Radius, RRect, Rect, Size, TileMode;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Draws the nickname blur on top of a live preview.
///
/// The rectangles are sampled from the detection loop a few times per second
/// (same cadence as the mask that is pushed to the streaming pipeline). The
/// video underneath keeps its original frame rate: only the overlay is updated
/// per sample, so no per-frame inference or frame copying happens here.
///
/// The preview texture is painted again inside [ImageFiltered] instead of using
/// a backdrop filter, because a filtered copy of the texture always blurs,
/// while a backdrop filter depends on the platform compositor picking up the
/// external texture in its backdrop.
class MaskOverlay extends StatelessWidget {
  const MaskOverlay({super.key, required this.Mask, required this.Child});

  /// Normalized (0..1) rectangles in capture order, top-left origin.
  final ValueListenable<List<Rect>> Mask;

  /// The preview itself, painted again and blurred inside the rectangles.
  final Widget Child;

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
            // The streaming pipeline blurs the 1280x720 stream with
            // boxblur=20:2, so the preview uses the same relative radius.
            final Sigma = (Width / 1280 * 16).clamp(4.0, 24.0);
            return ClipPath(
              clipper: PathClipper(Shape),
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: Sigma, sigmaY: Sigma, tileMode: TileMode.decal),
                child: Child,
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
