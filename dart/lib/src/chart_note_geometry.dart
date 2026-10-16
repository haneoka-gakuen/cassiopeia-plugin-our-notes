import 'dart:math' as math;
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

/// Geometry producer follows matching Haneoka NoteLayer/StageProjector contracts.
/// Source arrays are the current actual note-skin archive, not invented sprites.
final class ChartNotePart {
  const ChartNotePart(this.geometry, {this.alpha = 1});
  final NativeSpriteGeometry geometry;
  final double alpha;
}

final class ChartNoteGeometry {
  ChartNoteGeometry(this.archive, this.textureWidth, this.textureHeight);
  final Map<String, Object?> archive;
  final int textureWidth, textureHeight;
  final Map<String, NativeAtlasRegion> _regions = {};
  final Float32List _scalar = Float32List(1);
  double f(num value) {
    _scalar[0] = value.toDouble();
    return _scalar[0];
  }

  double boundsWidth(NativeAtlasRegion region) =>
      f(f(region.sourceWidth) / f(region.pixelsPerUnit));
  NativeAtlasRegion region(String name) => _regions.putIfAbsent(
    name,
    () => readProjectedAtlasRegion(archive, name, textureWidth, textureHeight),
  );

  Map definition(String kind) {
    final defs = archive['notes'];
    final value = defs is Map ? defs[kind == 'guide' ? 'trace' : kind] : null;
    if (value is! Map) throw UnsupportedError('native_note_skin_kind:$kind');
    return value;
  }

  /// Each returned entry retains separate body/mark/arrow source role.
  Map<String, ChartNotePart> note({
    required String kind,
    required int direction,
    required double lane,
    required double laneWidth,
    required double timeSeconds,
    bool flat = false,
  }) {
    if (kind == 'flick') {
      kind = direction == 1
          ? 'flick-left'
          : direction == 2
          ? 'flick-right'
          : kind;
    }
    final def = definition(kind), parts = def['parts'] as List;
    int tilt(double distance) {
      final index = [0, 2, 4, 6, 8, 10, 12].indexWhere((v) => v >= distance);
      return index < 0 ? 6 : index;
    }

    Map part(int t) => parts.cast<Map>().singleWhere((p) => p['tilt'] == t);
    final leftTilt = tilt((lane - 12).abs()),
        rightTilt = tilt((lane + laneWidth - 12).abs());
    final center = lane + (laneWidth - 1) / 2;
    late final Map left, right;
    late final bool flipLeft, flipRight;
    if (flat) {
      left = part(0);
      right = part(0);
      flipLeft = false;
      flipRight = false;
    } else if (lane < 12 && lane + laneWidth > 12) {
      left = part(leftTilt);
      right = part(rightTilt);
      flipLeft = true;
      flipRight = false;
    } else if (center < 11.5) {
      left = part(leftTilt);
      right = part(rightTilt);
      flipLeft = true;
      flipRight = true;
    } else {
      left = part(leftTilt);
      right = part(rightTilt);
      flipLeft = false;
      flipRight = false;
    }
    final leftName = flipLeft ? left['rightSprite'] : left['leftSprite'];
    final rightName = flipRight ? right['leftSprite'] : right['rightSprite'];
    if (leftName is! String || rightName is! String) {
      throw UnsupportedError('native_note_authored_cap_missing');
    }
    final l = region(leftName),
        r = region(rightName),
        m = region(def['mainSprite'] as String);
    final lo = f(left[flipLeft ? 'rightOverhang' : 'leftOverhang'] as num);
    final ro = f(right[flipRight ? 'leftOverhang' : 'rightOverhang'] as num);
    final viewWidth = laneWidth / 24 * 15.416889634999361;
    final leftWidth = flat ? l.width : boundsWidth(l),
        rightWidth = flat ? r.width : boundsWidth(r);
    final rawMainWidth = f(
      f(f(f(ro + lo) + viewWidth) - leftWidth) - rightWidth,
    );
    final mainWidth = flat ? math.max(.001, rawMainWidth) : rawMainWidth,
        mainX = f(f(f(ro - lo) * .5) + f(f(leftWidth - rightWidth) * .5));
    final rawLeft = m.borderLeft / m.pixelsPerUnit,
        rawRight = m.borderRight / m.pixelsPerUnit;
    final factor = rawLeft + rawRight > mainWidth
        ? mainWidth / (rawLeft + rawRight)
        : 1.0;
    final lb = rawLeft * factor,
        rb = rawRight * factor,
        middle = math.max(0.0, mainWidth - lb - rb);
    final leftEnd = (m.borderLeft - m.offsetX).clamp(0.0, m.tightWidth);
    final rightStart = (m.sourceWidth - m.borderRight - m.offsetX).clamp(
      leftEnd,
      m.tightWidth,
    );
    final output = <String, ChartNotePart>{};
    output['body-main-left'] = ChartNotePart(
      quad(
        m,
        mainX - mainWidth / 2 + lb / 2,
        0,
        lb,
        m.height,
        0,
        leftEnd / m.tightWidth,
      ),
    );
    output['body-main-middle'] = ChartNotePart(
      quad(
        m,
        mainX + (lb - rb) / 2,
        0,
        middle,
        m.height,
        leftEnd / m.tightWidth,
        (rightStart - leftEnd) / m.tightWidth,
      ),
    );
    output['body-main-right'] = ChartNotePart(
      quad(
        m,
        mainX + mainWidth / 2 - rb / 2,
        0,
        rb,
        m.height,
        rightStart / m.tightWidth,
        (m.tightWidth - rightStart) / m.tightWidth,
      ),
    );
    output['body-cap-left'] = ChartNotePart(
      cap(
        l,
        f(f(f(leftWidth * .5) - f(viewWidth * .5)) - lo) +
            (flipLeft ? -l.centerX : l.centerX),
        l.centerY,
        flipLeft,
      ),
    );
    output['body-cap-right'] = ChartNotePart(
      cap(
        r,
        f(ro + f(f(viewWidth * .5) - f(rightWidth * .5))) +
            (flipRight ? -r.centerX : r.centerX),
        r.centerY,
        flipRight,
      ),
    );
    final mark = def['centerMarkSprite'];
    if (kind != 'slide-end' && mark is String) {
      output['mark'] = ChartNotePart(region(mark).geometry);
    }
    final arrows = def['arrows'] as List;
    if (arrows.isNotEmpty) {
      final arrow = arrows.cast<Map>().firstWhere(
        (a) => laneWidth < (a['maxWidth'] as num),
        orElse: () => arrows.last as Map,
      );
      final name = arrow['sprite'];
      if (name is! String) {
        // Formal skin002/W12 has a null Sprite reference. Both source views
        // retain the body and decoration and omit this authored empty arrow.
        if (arrow.containsKey('sprite') && name == null) return output;
        throw UnsupportedError('native_note_authored_arrow_missing');
      }
      final a = region(name), animation = def['arrowAnimation'];
      final duration = animation is Map
          ? (animation['duration'] as num).toDouble()
          : 0.0;
      final t = duration > 0 ? timeSeconds % duration : 0.0;
      double curve(String key, double fallback) {
        if (animation is! Map) return fallback;
        final value = animation[key];
        if (value is num) return value.toDouble();
        if (value is! List || value.isEmpty) {
          throw UnsupportedError('native_note_arrow_curve');
        }
        var row = value.first as Map;
        for (final item in value.skip(1)) {
          if ((item as Map)['time'] > t) break;
          row = item;
        }
        final d = math.max(0.0, t - (row['time'] as num).toDouble());
        return (((row['a'] as num) * d + (row['b'] as num)) * d +
                    (row['c'] as num)) *
                d +
            (row['d'] as num);
      }

      final upper = name.startsWith('notes_flick_arrow_upper_'),
          parent = upper ? 0.800000011920929 : 1.0;
      final sx = parent * curve('scaleX', 1), sy = parent * curve('scaleY', 1);
      final rotation = !upper && direction == 1 ? math.pi : 0.0;
      final c = math.cos(rotation),
          s = math.sin(rotation),
          cx = a.centerX * sx,
          cy = a.centerY * sy;
      final tx = curve('x', 0) * parent + cx * c - cy * s;
      final ty =
          (upper ? 0.3499999940395355 : 0) +
          curve('y', 1) * parent +
          cx * s +
          cy * c;
      final xyz = Float32List(a.geometry.positions.length);
      for (var i = 0; i < xyz.length ~/ 3; i++) {
        final x = (a.geometry.positions[i * 3] - a.centerX) * sx,
            y = (a.geometry.positions[i * 3 + 1] - a.centerY) * sy;
        xyz[i * 3] = tx + x * c - y * s;
        xyz[i * 3 + 1] = ty + x * s + y * c;
        xyz[i * 3 + 2] = a.geometry.positions[i * 3 + 2];
      }
      // Arrow alpha is returned separately by actual source curve at this timestamp.
      output['arrow'] = ChartNotePart(
        NativeSpriteGeometry(
          positions: xyz,
          uv: a.geometry.uv,
          indices: a.geometry.indices,
        ),
        alpha: curve('alpha', 1).clamp(0.0, 1.0),
      );
    }
    return output;
  }

  NativeSpriteGeometry cap(
    NativeAtlasRegion region,
    double cx,
    double cy,
    bool flip,
  ) {
    final xyz = Float32List(region.geometry.positions.length);
    final ox = cx - (flip ? -region.centerX : region.centerX),
        oy = cy - region.centerY;
    for (var i = 0; i < xyz.length ~/ 3; i++) {
      xyz[i * 3] = ox + (flip ? -1 : 1) * region.geometry.positions[i * 3];
      xyz[i * 3 + 1] = oy + region.geometry.positions[i * 3 + 1];
      xyz[i * 3 + 2] = region.geometry.positions[i * 3 + 2];
    }
    return NativeSpriteGeometry(
      positions: xyz,
      uv: region.geometry.uv,
      indices: region.geometry.indices,
    );
  }

  NativeSpriteGeometry quad(
    NativeAtlasRegion region,
    double cx,
    double cy,
    double w,
    double h,
    double u,
    double uw,
  ) {
    final uv = [
      region.uvAt(u, 0),
      region.uvAt(u + uw, 0),
      region.uvAt(u, 1),
      region.uvAt(u + uw, 1),
    ];
    return NativeSpriteGeometry(
      positions: Float32List.fromList([
        cx - w / 2,
        cy - h / 2,
        0,
        cx + w / 2,
        cy - h / 2,
        0,
        cx - w / 2,
        cy + h / 2,
        0,
        cx + w / 2,
        cy + h / 2,
        0,
      ]),
      uv: Float32List.fromList([
        for (final p in uv) ...[p.$1, p.$2],
      ]),
      indices: Uint16List.fromList([0, 1, 2, 2, 1, 3]),
    );
  }
}
