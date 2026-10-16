import 'dart:math' as math;
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

final class NativeBackgroundPixels {
  const NativeBackgroundPixels(this.width, this.height, this.rgba);
  final int width, height;
  final Uint8List rgba;
}

/// FullInitialize's static ARGB32 composite and four RGB565 blur passes.
final class NativeChartBackground {
  NativeChartBackground(this.source);
  final Map source;
  int get width => source['width'] as int;
  int get height => source['height'] as int;
  String baseWhitePath(String server) =>
      (source['baseWhitePath'] as String).replaceFirst('{server}', server);

  NativeTextureData build(Map<String, NativeBackgroundPixels> textures) {
    final composite = Uint8List(width * height * 4);
    final values = Float64List(4), f32 = Float32List(1);
    double f(double value) {
      f32[0] = value;
      return f32[0];
    }

    for (final layer in (source['layers'] as List).cast<Map>()) {
      final image = textures[layer['texture']];
      final size = (layer['size'] as List).cast<num>();
      final scale = (layer['scale'] as List).cast<num>();
      final position = (layer['position'] as List).cast<num>();
      final tint = (layer['tint'] as List).cast<num>();
      final w = f(size[0].toDouble() * scale[0].toDouble());
      final h = f(size[1].toDouble() * scale[1].toDouble());
      final x0 = width / 2 + position[0] - w / 2;
      final y0 = height / 2 - position[1] - h / 2;
      final xMin = math.max(0, (x0 - .5).ceil());
      final xMax = math.min(width, (x0 + w - .5).floor() + 1);
      final yMin = math.max(0, (y0 - .5).ceil());
      final yMax = math.min(height, (y0 + h - .5).floor() + 1);
      for (var y = yMin; y < yMax; y++) {
        final sy = image == null ? 0.0 : (y + .5 - y0) / h * image.height - .5;
        final iy = sy.floor(), fy = sy - sy.floor();
        final row0 = image == null
            ? 0
            : iy.clamp(0, image.height - 1) * image.width * 4;
        final row1 = image == null
            ? 0
            : (iy + 1).clamp(0, image.height - 1) * image.width * 4;
        for (var x = xMin; x < xMax; x++) {
          final sx = image == null ? 0.0 : (x + .5 - x0) / w * image.width - .5;
          final ix = sx.floor(), fx = sx - sx.floor();
          final col0 = image == null ? 0 : ix.clamp(0, image.width - 1) * 4;
          final col1 = image == null
              ? 0
              : (ix + 1).clamp(0, image.width - 1) * 4;
          final pixel = (y * width + x) * 4;
          values.fillRange(0, 4, 1);
          if (image != null) {
            for (var c = 0; c < 4; c++) {
              final top =
                  image.rgba[row0 + col0 + c] * (1 - fx) +
                  image.rgba[row0 + col1 + c] * fx;
              final bottom =
                  image.rgba[row1 + col0 + c] * (1 - fx) +
                  image.rgba[row1 + col1 + c] * fx;
              values[c] = (top * (1 - fy) + bottom * fy) / 255;
            }
          }
          final alpha = values[3] * tint[3];
          for (var c = 0; c < 4; c++) {
            composite[pixel + c] =
                ((values[c] * tint[c] * alpha +
                                composite[pixel + c] / 255 * (1 - alpha))
                            .clamp(0.0, 1.0) *
                        255)
                    .round();
          }
        }
      }
    }
    const levels = [31, 63, 31];
    var rgb = Uint16List(width * height * 3);
    var temporary = Uint16List(rgb.length);
    for (var p = 0; p < width * height; p++) {
      for (var c = 0; c < 3; c++) {
        rgb[p * 3 + c] = (composite[p * 4 + c] * levels[c] / 255).round();
      }
    }
    final blur = source['blur'] as Map;
    final weights = (blur['weights'] as List).cast<num>();
    for (
      var iteration = 0;
      iteration < (blur['iterations'] as int);
      iteration++
    ) {
      for (final horizontal in [true, false]) {
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final p = (y * width + x) * 3;
            final before = horizontal
                ? (y * width + math.max(0, x - 1)) * 3
                : (math.max(0, y - 1) * width + x) * 3;
            final after = horizontal
                ? (y * width + math.min(width - 1, x + 1)) * 3
                : (math.min(height - 1, y + 1) * width + x) * 3;
            for (var c = 0; c < 3; c++) {
              temporary[p + c] =
                  (rgb[before.toInt() + c] * weights[0] +
                          rgb[p + c] * weights[1] +
                          rgb[after.toInt() + c] * weights[2])
                      .round();
            }
          }
        }
        final old = rgb;
        rgb = temporary;
        temporary = old;
      }
    }
    for (var p = 0; p < width * height; p++) {
      for (var c = 0; c < 3; c++)
        composite[p * 4 + c] = (rgb[p * 3 + c] * 255 / levels[c]).round();
      composite[p * 4 + 3] = 255;
    }
    return NativeTextureData(width: width, height: height, rgba: composite);
  }
}
