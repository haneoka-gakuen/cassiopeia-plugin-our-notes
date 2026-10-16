import 'dart:typed_data';

import 'package:render_contracts/line_geometry.dart';

import 'chart_projection.dart';

import 'package:haneoka_render_profile/core.dart';

/// Native line profiles from the actual LiveLaneLineView source contract.
/// RGBA is interpolated per vertex, equivalent to its near/far shader fields.
Map<String, ProjectedMesh> nativeStageLineMeshes(
  NativeChartProjection projection, {
  int guidelineCount = 6,
  double opacity = .25,
}) {
  const outsideWidth = .15000000596046448;
  const laneWidth = 19.1200008392334;
  const lineLength = 217.60000610351562;
  final specs = <String, List<(double, double, double)>>{
    'outside': [
      for (final side in [-1, 1])
        (side * projection.f(laneWidth / 2 + outsideWidth / 2), 0, lineLength),
    ],
    'main': [],
    'space': [],
  };
  final mainDivisor = guidelineCount > 0 ? (24 / guidelineCount).truncate() : 0;
  final spaceDivisor = guidelineCount <= 6 ? 2 : 0;
  final laneStep = projection.f(laneWidth / 24);
  var x = projection.f(-laneWidth / 2);
  for (var index = 1; index < 24; index++) {
    x = projection.f(x + laneStep);
    final main = mainDivisor > 0 && index % mainDivisor == 0;
    final space = !main && spaceDivisor > 0 && index % spaceDivisor == 0;
    if (main) {
      specs['main']!.add((x, 0, lineLength));
    } else if (space) {
      specs['space']!.add((
        x,
        projection.f(9.619999885559082 - 1.2999999523162842 / 2),
        projection.f(9.619999885559082 + 1.2999999523162842 / 2),
      ));
    }
  }
  final output = <String, ProjectedMesh>{};
  final matrix = projection.worldClip;
  for (final entry in specs.entries) {
    if (entry.value.isEmpty || (opacity <= 0 && entry.key != 'outside')) {
      continue;
    }
    final outside = entry.key == 'outside', space = entry.key == 'space';
    final nearWidth = outside ? outsideWidth : .15000000596046448,
        farWidth = !outside && !space ? .30000001192092896 : nearWidth;
    final near = outside
        ? 1.0
        : space
        ? .6117647290229797
        : .6132075786590576;
    final far = outside
        ? 1.0
        : space
        ? .6117647290229797
        : .615686297416687;
    // LiveLineRendererAlphaController replaces both inner gradient alphas.
    // The outside renderers retain their own gradient independently.
    final alpha = outside ? 1.0 : opacity;
    final geometry = buildViewFacingLineStrips(
      [
        for (final spec in entry.value)
          ViewFacingLineSpec(
            from: Float32List.fromList([spec.$1, 0, spec.$2]),
            to: Float32List.fromList([spec.$1, 0, spec.$3]),
            widthNear: nearWidth,
            widthFar: !outside && !space && spec.$1.abs() < 1e-6
                ? farWidth * 2
                : farWidth,
            rgbaNear: Float32List.fromList([near, near, near, alpha]),
            rgbaFar: Float32List.fromList([far, far, far, outside ? 0 : alpha]),
            // LineRenderer Stretch: U follows length, V spans the width.
            // Flip V when sampling the exported top-left PNG.
            uvCorners: Float32List.fromList([0, 1, 0, 0, 1, 1, 1, 0]),
          ),
      ],
      cameraPosition: Float32List.fromList([0, 10, 0]),
      clipFromWorld: matrix,
    );
    output[entry.key] = ProjectedMesh(geometry.vertices, geometry.indices);
  }
  return output;
}
