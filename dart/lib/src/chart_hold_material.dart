import 'dart:math' as math;
import 'dart:typed_data';

import 'chart_hold_geometry.dart';
import 'chart_projection.dart';
import 'package:haneoka_render_profile/core.dart';

/// Authored gradient keys produce the same native RGBA8 256×3 LUT.
/// Numeric texels use the official raw GPU copy path, not UIImage conversion.
final class NativeHoldMaterialStyle {
  NativeHoldMaterialStyle(this.source);
  final Map source;
  NativeTextureData? _cachedGradient;
  double get widthScale => (source['widthScale'] as num).toDouble();
  double get glowRange => (source['glowRangeScale'] as num).toDouble();
  double get normalAlphaScale {
    final alpha = (source['normal'] as Map)['alpha'] as List;
    final maximum = math.max(
      (alpha[1] as num).toDouble(),
      (alpha[3] as num).toDouble(),
    );
    return maximum > 0 ? 1 / maximum : 1;
  }

  NativeTextureData gradient() => _cachedGradient ??= _makeGradient();
  NativeTextureData _makeGradient() {
    final bytes = Uint8List(256 * 3 * 4);
    for (final (row, name) in ['disabled', 'normal', 'pressed'].indexed) {
      final gradient = source[name] as Map, colors = gradient['colors'] as List;
      final alpha = gradient['alpha'] as List;
      for (var column = 0; column < 256; column++) {
        final time = column / 255;
        var left = colors.first as List, right = left;
        for (final entry in colors.skip(1)) {
          right = entry as List;
          if (time <= (right[0] as num)) break;
          left = right;
        }
        final amount =
            ((time - (left[0] as num)) /
                    math.max(1e-5, (right[0] as num) - (left[0] as num)))
                .clamp(0.0, 1.0);
        final offset = (row * 256 + column) * 4;
        for (var channel = 0; channel < 3; channel++) {
          final value =
              (left[channel + 1] as num) +
              ((right[channel + 1] as num) - (left[channel + 1] as num)) *
                  amount;
          bytes[offset + channel] = (value.clamp(0.0, 1.0) * 255).round();
        }
        final alphaAmount =
            ((time - (alpha[0] as num)) /
                    math.max(1e-5, (alpha[2] as num) - (alpha[0] as num)))
                .clamp(0.0, 1.0);
        final value =
            (alpha[1] as num) +
            ((alpha[3] as num) - (alpha[1] as num)) * alphaAmount;
        bytes[offset + 3] = (value.clamp(0.0, 1.0) * 255).round();
      }
    }
    return NativeTextureData(width: 256, height: 3, rgba: bytes);
  }

  Float32List uniforms({required bool guide, required bool active}) {
    final glow = source['glow'] as Map;
    return Float32List.fromList([
      guide ? 1 : normalAlphaScale,
      active ? 2 : 1,
      guide ? 1 : 0,
      0,
      ...((glow['color'] as List).map((v) => (v as num).toDouble())),
      (glow['intensity'] as num).toDouble(),
      (glow['falloff'] as num).toDouble(),
      (glow['width'] as num).toDouble(),
      (glow['disabledScale'] as num).toDouble(),
      (glow['enabledScale'] as num).toDouble(),
      (glow['pressedScale'] as num).toDouble(),
      0,
      217.60000610351562,
      ...((source['guide'] as List).map((v) => (v as num).toDouble())),
    ]);
  }
}

/// Per-column fields retain the actual authored border/clip/glow quantities.
ProjectedMesh nativeHoldProjectedMesh(
  NativeHoldGeometrySource geometry,
  NativeChartProjection projection,
  int mediaUs, {
  double opacity = .6,
  double glowRange = 2.5,
  double widthScale = .9,
}) {
  final vertices = Float32List(geometry.visiblePoints.length * 4 * 17);
  final indices = Uint16List(
    math.max(0, geometry.visiblePoints.length - 1) * 18,
  );
  final matrix = projection.screenClip;
  final inset = math.min(
    math.max(0.0, 6 * (1 - widthScale)),
    geometry.minimumWidth / 2,
  );
  for (final (sample, point) in geometry.visiblePoints.indexed) {
    final progress = projection.progress(
      (point.timeUs - mediaUs) / (projection.viewTimeMs * 1000),
    );
    final columns = [
      for (var c = 0; c < 4; c++)
        geometry.screenPositions[(sample * 4 + c) * 3].toDouble(),
    ];
    final glow = math.min(
      progress * glowRange / 2,
      math.max(
            0.0,
            projection.laneX(math.max(0.0, point.width - inset)) -
                projection.laneX(0),
          ) *
          progress /
          2,
    );
    final leftAmount = glow >= 1e-6
        ? ((columns[1] - columns[0]) / glow).clamp(0.0, 1.0)
        : 0.0;
    final rightAmount = glow >= 1e-6
        ? ((columns[3] - columns[2]) / glow).clamp(0.0, 1.0)
        : 0.0;
    final leftInner = .5 + (.125 - .5) * leftAmount,
        rightInner = .5 + (.875 - .5) * rightAmount;
    final approach = (point.timeUs - mediaUs) / (projection.viewTimeMs * 1000);
    final fade = approach <= 1
        ? 1.0
        : 1 - ((approach - 1) / .01).clamp(0.0, 1.0);
    for (var column = 0; column < 4; column++) {
      final vertex = sample * 4 + column, offset = vertex * 17;
      final x = columns[column], y = projection.y(progress), z = 10.6077995;
      for (var row = 0; row < 4; row++) {
        vertices[offset + row] =
            matrix[row] * x +
            matrix[row + 4] * y +
            matrix[row + 8] * z +
            matrix[row + 12];
      }
      vertices[offset + 4] = x;
      vertices[offset + 5] = y;
      vertices[offset + 6] = 0;
      vertices[offset + 7] = point.lineProgress;
      vertices[offset + 8] = column == 0 || column == 3 ? 1 : 0;
      vertices[offset + 9] = [
        0.0,
        .125,
        .875,
        1.0,
      ][column]; // Static guide UV, distinct from border clipping.
      vertices[offset + 10] = opacity * fade;
      final left = column < 2;
      vertices[offset + 11] = left ? columns[0] : columns[2];
      vertices[offset + 12] = left ? columns[1] : columns[3];
      vertices[offset + 13] = left ? .5 * (1 - leftAmount) : rightInner;
      vertices[offset + 14] = left ? leftInner : .5 + .5 * rightAmount;
      vertices[offset + 15] = .5;
      vertices[offset + 16] = .833333373;
    }
  }
  for (var sample = 0; sample < geometry.visiblePoints.length - 1; sample++) {
    final near = sample * 4, far = near + 4;
    for (var strip = 0; strip < 3; strip++) {
      indices.setRange(sample * 18 + strip * 6, sample * 18 + strip * 6 + 6, [
        near + strip,
        far + strip,
        near + strip + 1,
        far + strip,
        far + strip + 1,
        near + strip + 1,
      ]);
    }
  }
  return ProjectedMesh(vertices, indices, layout: NativeMeshLayout.hold17);
}
