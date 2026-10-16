import 'dart:math' as math;
import 'dart:typed_data';

import 'chart_projection.dart';

final class NativeHoldSourcePoint {
  const NativeHoldSourcePoint({
    required this.nativeId,
    required this.timeUs,
    required this.lane,
    required this.width,
    required this.leftEase,
    required this.rightEase,
  });
  final int nativeId, timeUs, leftEase, rightEase;
  final double lane, width;
}

final class NativeHoldPreparedPoint {
  const NativeHoldPreparedPoint(
    this.timeUs,
    this.lane,
    this.width,
    this.lineProgress,
  );
  final double timeUs, lane, width, lineProgress;
}

final class NativeHoldGeometrySource {
  const NativeHoldGeometrySource({
    required this.visiblePoints,
    required this.screenPositions,
    required this.minimumWidth,
    required this.sourcePointIds,
  });
  final List<NativeHoldPreparedPoint> visiblePoints;

  /// Authored four-column ribbon geometry before camera projection/material attrs.
  /// Retained even while its specialised GPU material is unsupported.
  final Float32List screenPositions;
  final double minimumWidth;
  final List<int> sourcePointIds;
}

NativeHoldGeometrySource prepareNativeHoldGeometry(
  List<NativeHoldSourcePoint> source,
  NativeChartProjection projection,
  int mediaUs, {
  double widthScale = .9,
  double glowRangeScale = 2.5,
}) {
  if (source.length < 2) throw ArgumentError('native_hold_source_points');
  final ordered = [for (final (index, point) in source.indexed) (index, point)]
    ..sort(
      (a, b) => a.$2.timeUs.compareTo(b.$2.timeUs) != 0
          ? a.$2.timeUs.compareTo(b.$2.timeUs)
          : a.$1.compareTo(b.$1),
    );
  final authored = ordered.map((p) => p.$2).toList();
  final begin = authored.first.timeUs, end = authored.last.timeUs;
  if (end <= begin) throw ArgumentError('native_hold_source_time');
  double ease(double t, int value) => switch (value) {
    0 => t,
    2 => t * t,
    1 => 1 - (1 - t) * (1 - t),
    _ => throw UnsupportedError('native_hold_ease:$value'),
  };
  NativeHoldPreparedPoint sample(double time) {
    var next = authored.indexWhere((p) => p.timeUs >= time);
    if (next == 0) {
      final p = authored.first;
      return NativeHoldPreparedPoint(
        time,
        p.lane,
        p.width,
        (time - begin) / (end - begin),
      );
    }
    if (next < 0) {
      final p = authored.last;
      return NativeHoldPreparedPoint(
        time,
        p.lane,
        p.width,
        (time - begin) / (end - begin),
      );
    }
    final a = authored[next - 1], b = authored[next];
    final t = ((time - a.timeUs) / (b.timeUs - a.timeUs)).clamp(0.0, 1.0);
    final left = a.lane + (b.lane - a.lane) * ease(t, a.leftEase);
    final right =
        a.lane +
        a.width +
        (b.lane + b.width - a.lane - a.width) * ease(t, a.rightEase);
    return NativeHoldPreparedPoint(
      time,
      left,
      right - left,
      (time - begin) / (end - begin),
    );
  }

  final visibleStart = math.max(begin, mediaUs).toDouble(),
      visibleEnd = math
          .min(end, mediaUs + projection.viewTimeMs * 1100)
          .toDouble();
  final visible = <NativeHoldPreparedPoint>[];
  if (visibleEnd > visibleStart) {
    visible.add(sample(visibleStart));
    for (var i = 0; i < authored.length - 1; i++) {
      final a = authored[i], b = authored[i + 1];
      final steps = math.max(1, ((b.timeUs - a.timeUs) / 45000).ceil());
      for (var step = 0; step <= steps; step++) {
        if (i > 0 && step == 0) continue;
        final t = a.timeUs + (b.timeUs - a.timeUs) * step / steps;
        if (t > visibleStart && t < visibleEnd) visible.add(sample(t));
      }
    }
    visible.add(sample(visibleEnd));
  }
  final minimum = authored.map((p) => p.width).reduce(math.min),
      inset = math.min(math.max(0.0, 6 * (1 - widthScale)), minimum / 2);
  final xyz = Float32List(visible.length * 4 * 3);
  for (final (i, point) in visible.indexed) {
    final approach = (point.timeUs - mediaUs) / (projection.viewTimeMs * 1000),
        progress = projection.progress(approach);
    final center = point.lane + point.width / 2,
        w = math.max(0.0, point.width - inset);
    final left = projection.laneX(center - w / 2) * progress,
        right = projection.laneX(center + w / 2) * progress;
    final glow = math.min(progress * glowRangeScale / 2, (right - left) / 2);
    final boundaryLeft = projection.laneX(0) * progress,
        boundaryRight = projection.laneX(24) * progress;
    final columns = [
      left.clamp(boundaryLeft, boundaryRight),
      (left + glow).clamp(boundaryLeft, boundaryRight),
      (right - glow).clamp(boundaryLeft, boundaryRight),
      right.clamp(boundaryLeft, boundaryRight),
    ];
    for (var col = 0; col < 4; col++) {
      final j = (i * 4 + col) * 3;
      xyz[j] = columns[col];
      xyz[j + 1] = projection.y(progress);
      xyz[j + 2] = 10.6077995;
    }
  }
  return NativeHoldGeometrySource(
    visiblePoints: List.unmodifiable(visible),
    screenPositions: xyz.asUnmodifiableView(),
    minimumWidth: minimum,
    sourcePointIds: List.unmodifiable(authored.map((p) => p.nativeId)),
  );
}
