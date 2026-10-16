import 'dart:math' as math;
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

/// Exact source camera/progress constants from the matched live asset manifest.
final class NativeChartProjection {
  NativeChartProjection(
    this.width,
    this.height, {
    double? logicalWidth,
    double? logicalHeight,
    this.noteSpeed = 5,
  }) : logicalWidth = logicalWidth ?? width.toDouble(),
       logicalHeight = logicalHeight ?? height.toDouble() {
    if (width <= 0 ||
        height <= 0 ||
        !this.logicalWidth.isFinite ||
        !this.logicalHeight.isFinite ||
        this.logicalWidth <= 0 ||
        this.logicalHeight <= 0) {
      throw ArgumentError('native_chart_viewport');
    }
    if (!noteSpeed.isFinite || noteSpeed < 1 || noteSpeed > 12) {
      throw ArgumentError('native_chart_note_speed');
    }
  }
  final int width, height;
  final double logicalWidth, logicalHeight;
  final double noteSpeed;
  double get aspect => logicalWidth / logicalHeight;
  final Float32List _f32 = Float32List(1);
  double f(num value) {
    _f32[0] = value.toDouble();
    return _f32[0];
  }

  double get viewTimeMs {
    final normalized = (noteSpeed - 1) / 11;
    final eased = 1 - math.pow(1 - normalized, 1.30999994);
    return (1000 * (4 + (0.35 - 4) * eased)).ceilToDouble();
  }

  double progress(double approach) {
    final value = f(approach.clamp(-0.16, 1.0));
    final raw = f(1 - value), exponent = f(f(raw - 1) * f(45));
    return f(math.pow(f(1.065), exponent));
  }

  double laneX(double lane) =>
      2.384185791015625e-7 + (lane / 24 - 0.5) * 15.416889634999361;
  double y(double p) => 6 + (-3.16 - 6) * p;

  /// Same aspect compensation as OurNotesRenderer.resize: retain reference
  /// horizontal FOV below 16:9, while wider screens retain the authored vertical FOV.
  double get fieldOfViewRadians {
    final boundedAspect = math.min(aspect, 16 / 9);
    return 2 *
        math.atan(math.tan(54 * math.pi / 360) * (16 / 9) / boundedAspect);
  }

  double get _focal => 1 / math.tan(fieldOfViewRadians / 2);
  Float32List get screenClip {
    final focal = _focal, aspect = this.aspect;
    return Float32List.fromList([
      focal / aspect,
      0,
      0,
      0,
      0,
      focal,
      0,
      0,
      0,
      0,
      5000 / (5000 - .1),
      1,
      0,
      0,
      -5000 * .1 / (5000 - .1),
      0,
    ]);
  }

  NativeSpriteGeometry placeNote(
    NativeSpriteGeometry shape,
    double lane,
    double laneWidth,
    double approach, {
    double scale = 1,
  }) {
    final p = progress(approach),
        cx = laneX(lane + laneWidth / 2) * p,
        cy = y(p),
        xyz = Float32List(shape.positions.length);
    for (var i = 0; i < xyz.length ~/ 3; i++) {
      xyz[i * 3] = cx + shape.positions[i * 3] * p * scale;
      xyz[i * 3 + 1] = cy + shape.positions[i * 3 + 1] * p * scale;
      xyz[i * 3 + 2] = 10.6077995 + shape.positions[i * 3 + 2] * p * scale;
    }
    return NativeSpriteGeometry(
      positions: xyz,
      uv: shape.uv,
      indices: shape.indices,
    );
  }

  Float32List get worldClip {
    final focal = _focal,
        aspect = this.aspect,
        a = 5000 / (5000 - .1),
        b = -5000 * .1 / (5000 - .1);
    final pitch = 29.60445665468814 * math.pi / 180,
        c = math.cos(pitch),
        s = math.sin(pitch);
    return Float32List.fromList([
      focal / aspect,
      0,
      0,
      0,
      0,
      c * focal,
      -s * a,
      -s,
      0,
      s * focal,
      c * a,
      c,
      0,
      -10 * c * focal,
      10 * s * a + b,
      10 * s,
    ]);
  }

  Float32List screenPixelClip(double cx, double cy, double w, double h) =>
      Float32List.fromList([
        2 / width,
        0,
        0,
        0,
        0,
        2 / height,
        0,
        0,
        0,
        0,
        1,
        0,
        2 * cx / width - 1,
        2 * cy / height - 1,
        0,
        1,
      ]);
}
