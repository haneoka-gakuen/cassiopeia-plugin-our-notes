import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

enum NativeComboTier { normal, fullCombo, allPerfect }

/// Authored UGUI sprite rectangles retain their untrimmed layout footprint.
final class NativeChartHud {
  NativeChartHud(this.source);
  final Map source;

  Map<String, String> texturePaths(String server) => {
    if (source['judgement'] case final Map judgement)
      for (final kind in ['perfect', 'just'])
        if (judgement[kind] case final Map sprite)
          'hud:judgement:$kind': _path(server, sprite['path'] as String),
    for (final tier in (source['tiers'] as Map).values)
      for (final entry in (tier as Map).entries)
        'hud:${entry.key}': _path(
          server,
          (entry.value as Map)['path'] as String,
        ),
  };

  String _path(String server, String path) => path.startsWith('assets/')
      ? '/assets/$server/${path.substring(7)}'
      : path.startsWith('runtime/')
      ? '/runtime/$server/${path.substring(8)}'
      : '/$path';

  List<NativeDraw> drawJudgement({
    required int sinceJudgementUs,
    required bool hasJudgement,
    int judgementValue = 5,
    required double width,
    required double height,
    required double screenScale,
    required Map<String, ProjectedMesh> meshes,
    required Map<String, NativeMaterial> materials,
  }) {
    final judgement = source['judgement'];
    if (judgement is! Map || !hasJudgement) return const [];
    final age = sinceJudgementUs / 1000000;
    if (age < 0 || age >= (judgement['showDuration'] as num)) return const [];
    final duration = (judgement['punchDuration'] as num).toDouble();
    final rise = (judgement['punchRiseDuration'] as num).toDouble();
    double outQuad(double time) => 1 - (1 - time) * (1 - time);
    final punch = age >= duration
        ? 0.0
        : age <= rise
        ? outQuad(age / rise)
        : 1 - outQuad((age - rise) / (duration - rise));
    final scale = screenScale * (1 + (judgement['punchScale'] as num) * punch);
    final kind = judgementValue == 6 ? 'just' : 'perfect';
    final sprite = judgement[kind] as Map?;
    if (sprite == null) throw StateError('chart_hud_judgement_source:$kind');
    final size = sprite['fullRect'] as List;
    final trim = sprite['trimSize'] as List;
    final offset = sprite['offsetBottomLeft'] as List;
    final centerX = width / 2;
    final centerY =
        height / 2 + (judgement['centerOffsetY'] as num) * screenScale;
    final left =
        centerX - (size[0] as num) * scale / 2 + (offset[0] as num) * scale;
    final bottom =
        centerY - (size[1] as num) * scale / 2 + (offset[1] as num) * scale;
    final right = left + (trim[0] as num) * scale;
    final top = bottom + (trim[1] as num) * scale;
    const key = 'hud:judgement';
    meshes[key] = ProjectedMesh(
      Float32List.fromList([
        for (final point in [
          (left, bottom),
          (right, bottom),
          (left, top),
          (right, top),
        ]) ...[
          2 * point.$1 / width - 1,
          2 * point.$2 / height - 1,
          0,
          1,
          point.$1 == left ? 0 : 1,
          point.$2 == bottom ? 1 : 0,
          1,
          1,
          1,
          1,
        ],
      ]),
      Uint16List.fromList([0, 1, 2, 2, 1, 3]),
    );
    materials[key] = NativeMaterial(
      texture: 'hud:judgement:$kind',
      textureAlpha: NativeTextureAlpha.premultiplied,
    );
    return const [NativeDraw(mesh: key, material: key)];
  }

  List<NativeDraw> draw({
    required int combo,
    required int sinceComboUs,
    required NativeComboTier tier,
    required bool continuation,
    required double width,
    required double height,
    required double screenScale,
    required Map<String, ProjectedMesh> meshes,
    required Map<String, NativeMaterial> materials,
  }) {
    if (combo < 1) return const [];
    final selected = continuation ? tier : NativeComboTier.normal;
    final prefix = switch (selected) {
      NativeComboTier.normal => 'n',
      NativeComboTier.fullCombo => 'fc',
      NativeComboTier.allPerfect => 'ap',
    };
    final tierName = switch (selected) {
      NativeComboTier.normal => 'normal',
      NativeComboTier.fullCombo => 'fullCombo',
      NativeComboTier.allPerfect => 'allPerfect',
    };
    final sprites = (source['tiers'] as Map)[tierName] as Map;
    final layout = source['layout'] as Map;
    double value(String name) => (layout[name] as num).toDouble();
    final scaleKeys = (source['animation'] as Map)['scaleKeys'] as List;
    final seconds = sinceComboUs / 1000000;
    var pulse = 1.0;
    for (var index = 1; index < scaleKeys.length; index++) {
      final left = scaleKeys[index - 1] as List;
      final right = scaleKeys[index] as List;
      if (seconds <= (right[0] as num)) {
        final t =
            ((seconds - (left[0] as num)) /
                    ((right[0] as num) - (left[0] as num)))
                .clamp(0.0, 1.0);
        final smooth = t * t * (3 - 2 * t);
        pulse =
            (left[1] as num).toDouble() +
            ((right[1] as num) - (left[1] as num)) * smooth;
        break;
      }
    }
    final rootX = width / 2 + value('rootFromHorizontalCenter') * screenScale;
    final rootY = height - value('rootTopY') * screenScale;
    final clip = Float32List.fromList([
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
      -1,
      -1,
      0,
      1,
    ]);
    final draws = <NativeDraw>[];
    void sprite(
      String name,
      String key,
      double x,
      double y,
      double rectWidth,
      double rectHeight,
      double alpha,
    ) {
      final data = sprites[name] as Map;
      final full = data['fullRect'] as List;
      final trim = data['trimSize'] as List;
      final offset = data['offsetBottomLeft'] as List;
      final sx = rectWidth / (full[0] as num);
      final sy = rectHeight / (full[1] as num);
      final left = x - rectWidth / 2 + (offset[0] as num) * sx;
      final bottom = y - rectHeight / 2 + (offset[1] as num) * sy;
      final right = left + (trim[0] as num) * sx;
      final top = bottom + (trim[1] as num) * sy;
      final geometry = NativeSpriteGeometry(
        positions: Float32List.fromList([
          left,
          bottom,
          0,
          right,
          bottom,
          0,
          left,
          top,
          0,
          right,
          top,
          0,
        ]),
        uv: Float32List.fromList([0, 1, 1, 1, 0, 0, 1, 0]),
        indices: Uint16List.fromList([0, 1, 2, 2, 1, 3]),
      );
      meshes[key] = projectSprite(
        geometry,
        clip,
        Float32List.fromList([1, 1, 1, alpha]),
      );
      materials[key] = NativeMaterial(
        texture: 'hud:$name',
        textureAlpha: NativeTextureAlpha.premultiplied,
      );
      draws.add(NativeDraw(mesh: key, material: key));
    }

    final digits = combo.toString().split('');
    final digitWidth = value('digitWidth');
    final spacing = value('digitSpacing');
    final countWidth =
        digits.length * digitWidth + (digits.length - 1) * spacing;
    final pulseScale = screenScale * pulse;
    final countY = rootY - value('countRootOffsetY') * screenScale;
    if (selected != NativeComboTier.normal) {
      sprite(
        'SP_combo_${prefix}_glow',
        'hud:glow',
        rootX + value('glowOffsetX') * screenScale,
        rootY - value('glowOffsetY') * screenScale,
        (countWidth + value('glowWidthMargin')) * pulseScale,
        value('glowHeight') * pulseScale,
        value('glowAlpha'),
      );
    }
    for (final layer in ['base', 'fill']) {
      for (final (index, digit) in digits.indexed) {
        final x =
            rootX +
            (-countWidth / 2 +
                    digitWidth / 2 +
                    index * (digitWidth + spacing)) *
                pulseScale;
        sprite(
          'SP_combo_${prefix}_${digit}_$layer',
          'hud:$layer:$index',
          x,
          countY,
          digitWidth * pulseScale,
          160 * pulseScale,
          1,
        );
      }
    }
    sprite(
      'SP_combo_${prefix}_title',
      'hud:title',
      rootX,
      rootY -
          value('titleTopOffsetY') * screenScale -
          value('titleHeight') * value('titleScale') * screenScale / 2,
      value('titleWidth') * value('titleScale') * screenScale,
      value('titleHeight') * value('titleScale') * screenScale,
      1,
    );
    return draws;
  }
}
