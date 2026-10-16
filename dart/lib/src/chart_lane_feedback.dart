import 'dart:math' as math;
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

enum ChartLaneFeedbackKind {
  inVain,
  normal,
  slide,
  flick,
  flickLeft,
  flickRight,
  gekisou,
}

ChartLaneFeedbackKind? chartLaneFeedbackKind(int operateType, int direction) =>
    switch (operateType) {
      1 || 101 => ChartLaneFeedbackKind.normal,
      20 || 22 => ChartLaneFeedbackKind.slide,
      40 || 41 || 42 || 102 => switch (direction) {
        1 => ChartLaneFeedbackKind.flickLeft,
        2 => ChartLaneFeedbackKind.flickRight,
        _ => ChartLaneFeedbackKind.flick,
      },
      _ => null,
    };

int _roundToEven(double value) {
  final floor = value.floor(), fraction = value - value.floorToDouble();
  return fraction < .5 || (fraction == .5 && floor.isEven) ? floor : floor + 1;
}

/// Source rules and numeric particle samples, independent of a renderer or UI.
final class ChartLaneFeedbackProfile {
  ChartLaneFeedbackProfile(Map source)
    : laneCount = source['chartLaneCount'] as int,
      laneWidth = (source['laneWidth'] as num).toDouble(),
      judgementRootZ = (source['judgementRootZ'] as num).toDouble() {
    if (source['schema'] != 'our-notes-lane-feedback-source-v1' ||
        laneCount <= 0 ||
        laneWidth <= 0) {
      throw const FormatException('chart_lane_feedback_source');
    }
    final rows = source['effects'] as Map;
    for (final kind in ChartLaneFeedbackKind.values) {
      final row = rows[kind.name];
      if (row is Map) {
        _effects[kind] = _LaneProfile(row);
      } else if (kind != ChartLaneFeedbackKind.gekisou) {
        throw FormatException('chart_lane_feedback_missing:${kind.name}');
      }
    }
  }
  final int laneCount;
  final double laneWidth, judgementRootZ;
  final _effects = <ChartLaneFeedbackKind, _LaneProfile>{};
  bool supports(ChartLaneFeedbackKind kind) => _effects.containsKey(kind);

  double occupancySeconds(ChartLaneFeedbackKind kind) =>
      _effects[kind]!.occupancy;

  /// SetWidth replaces startSizeX with one of the runtime's 24 lane widths.
  GeometryShape? shape(ChartLaneFeedbackKind kind, double age, int lane) {
    final profile = _effects[kind]!;
    if (age < 0 || age >= profile.lifetime) return null;
    final q = (age / profile.lifetime).clamp(0.0, 1.0);
    final sx = laneWidth / laneCount * profile.size('curve', q);
    final sy = profile.initialSizeY * profile.size('y', q);
    final matrix = Float32List.fromList(profile.matrix);
    matrix[12] += (lane + .5 - laneCount / 2) * laneWidth / laneCount;
    matrix[14] += judgementRootZ;
    final positions = Float32List(12);
    for (var vertex = 0; vertex < 4; vertex++) {
      final x = (vertex.isOdd ? .5 : -.5) * sx,
          y = (vertex >= 2 ? .5 : -.5) * sy;
      for (var axis = 0; axis < 3; axis++) {
        positions[vertex * 3 + axis] =
            matrix[axis] * x + matrix[4 + axis] * y + matrix[12 + axis];
      }
    }
    return GeometryShape(
      positions: positions,
      uv: Float32List.fromList([0, 1, 1, 1, 0, 0, 1, 0]),
      indices: Uint16List.fromList([0, 1, 2, 2, 1, 3]),
    );
  }

  Float32List color(ChartLaneFeedbackKind kind, double age) {
    final profile = _effects[kind]!;
    final value = profile.color.sample(age / profile.lifetime, 0);
    return Float32List.fromList([
      for (var channel = 0; channel < 4; channel++)
        quantizeAuthoredParticleChannel(
          profile.initialColor[channel] * value[channel],
        ),
    ]);
  }
}

final class _LaneProfile {
  _LaneProfile(Map row) {
    final data = (row['particleSystem'] as Map)['data'] as Map;
    final owner = (row['parentSystem'] as Map)['data'] as Map;
    final initial = data['InitialModule'] as Map;
    final renderer = (row['renderer'] as Map)['data'] as Map;
    final sizeModule = data['SizeModule'] as Map;
    const supported = {
      'InitialModule',
      'EmissionModule',
      'ColorModule',
      'SizeModule',
      'CustomDataModule',
    };
    for (final entry in data.entries) {
      if (entry.value is Map &&
          (entry.value as Map)['enabled'] == true &&
          !supported.contains(entry.key)) {
        throw FormatException('chart_lane_feedback_active_module:${entry.key}');
      }
    }
    final bursts = (data['EmissionModule'] as Map)['m_Bursts'] as List;
    if (data['looping'] != false ||
        (data['ShapeModule'] as Map)['enabled'] != false ||
        (initial['startSpeed'] as Map)['scalar'] != 0 ||
        (initial['startSpeed'] as Map)['minMaxState'] != 0 ||
        (initial['startRotation'] as Map)['scalar'] != 0 ||
        initial['rotation3D'] != false ||
        (initial['startColor'] as Map)['minMaxState'] != 0 ||
        (initial['gravityModifier'] as Map)['scalar'] != 0 ||
        (data['startDelay'] as Map)['scalar'] != 0 ||
        (owner['startDelay'] as Map)['scalar'] != 0 ||
        (initial['startLifetime'] as Map)['minMaxState'] != 0 ||
        owner['looping'] != false ||
        owner['stopAction'] != 3 ||
        renderer['m_RenderMode'] != 4 ||
        renderer['m_RenderAlignment'] != 2 ||
        (renderer['m_Pivot'] as Map).values.any((value) => value != 0) ||
        (renderer['m_Flip'] as Map).values.any((value) => value != 0) ||
        (renderer['m_Mesh'] as Map)['m_PathID'].toString() != '10210' ||
        renderer['m_Enabled'] != true ||
        sizeModule['separateAxes'] != true ||
        bursts.length != 1 ||
        (bursts.single as Map)['time'] != 0 ||
        ((bursts.single as Map)['countCurve'] as Map)['scalar'] != 1) {
      throw const FormatException('chart_lane_feedback_unsupported_source');
    }
    lifetime =
        (initial['startLifetime'] as Map)['scalar'] / data['simulationSpeed'];
    occupancy = owner['lengthInSec'] / owner['simulationSpeed'];
    initialSizeY = NativeAuthoredMinMaxCurve(initial['startSizeY'] as Map)
        .sample(0, 0);
    initialColor = NativeAuthoredMinMaxGradient(initial['startColor'] as Map)
        .sample(0, 0)
        .map(quantizeAuthoredParticleChannel)
        .toList();
    color = NativeAuthoredMinMaxGradient(
      (data['ColorModule'] as Map)['gradient'] as Map,
    );
    for (final key in ['curve', 'y']) {
      curves[key] = NativeAuthoredMinMaxCurve(sizeModule[key] as Map);
    }
    final graph = NativeAuthoredEffectGraph({
      'schema': 'haneoka-native-fx-shared-render-data-v1',
      'objects': row['transforms'],
    });
    matrix = graph.worldMatrix(graph.objects[row['particleTransform']]!);
  }
  late final double lifetime, occupancy, initialSizeY;
  late final List<double> initialColor;
  late final NativeAuthoredMinMaxGradient color;
  late final Float32List matrix;
  final curves = <String, NativeAuthoredMinMaxCurve>{};
  double size(String name, double q) => curves[name]!.sample(q, 0);
}

final class ChartLaneFeedback {
  ChartLaneFeedback(this.profile)
    : _slots = List.filled(profile.laneCount, null);
  final ChartLaneFeedbackProfile profile;
  final List<({ChartLaneFeedbackKind kind, int atUs})?> _slots;
  int activations = 0, suppressedEmpty = 0;
  void clear() => _slots.fillRange(0, _slots.length, null);
  void trigger(
    ChartLaneFeedbackKind kind,
    double lane,
    double width,
    int atUs,
  ) {
    final first = _roundToEven(lane), count = math.max(1, _roundToEven(width));
    for (
      var index = math.max(0, first);
      index < math.min(profile.laneCount, first + count);
      index++
    ) {
      final old = _slots[index];
      if (old != null && atUs < old.atUs) continue;
      // Source reduces all requests for this update to the greatest enum.
      if (old != null && atUs == old.atUs && old.kind.index >= kind.index) {
        continue;
      }
      if (kind == ChartLaneFeedbackKind.inVain &&
          old != null &&
          old.kind != ChartLaneFeedbackKind.inVain &&
          atUs - old.atUs < profile.occupancySeconds(old.kind) * 1000000) {
        suppressedEmpty++;
        continue;
      }
      _slots[index] = (kind: kind, atUs: atUs);
      activations++;
    }
  }

  Iterable<({int lane, ChartLaneFeedbackKind kind, double age})> visible(
    int atUs,
  ) sync* {
    for (var index = 0; index < _slots.length; index++) {
      final slot = _slots[index];
      if (slot == null) continue;
      final age = (atUs - slot.atUs) / 1000000;
      if (age >= profile.occupancySeconds(slot.kind)) {
        _slots[index] = null;
      } else if (age >= 0 && age < profile._effects[slot.kind]!.lifetime) {
        yield (lane: index, kind: slot.kind, age: age);
      }
    }
  }
}
