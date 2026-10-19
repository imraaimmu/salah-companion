import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Live camera preview for the placement check (Android).
///
/// A Flutter platform view (`AndroidView`) hosting CameraX's `PreviewView` in
/// COMPATIBLE (TextureView) mode. It shows the camera only while an
/// [AndroidPoseEngine] session is running; it adds a Preview use case to that
/// session's camera, so mounting or removing it re-binds the camera briefly
/// (a short gap, covered by heartbeats). Remove it before the prayer starts:
/// the dark prayer screen needs no preview. No image data reaches Dart.
class PosePreview extends StatelessWidget {
  static const String viewType = 'salah_companion/pose/preview';

  const PosePreview({super.key});

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }
    return const AndroidView(viewType: viewType);
  }
}
