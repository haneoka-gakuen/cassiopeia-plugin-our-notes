import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cassiopeia_runtime/cassiopeia_runtime.dart';
import 'package:haneoka_render_profile/core.dart';

/// Source header presentation. Runtime score/life arrive unchanged from Cassiopeia.
final class NativeChartHeader {
  NativeChartHeader(this.source) {
    if (source['schema'] != 'our-notes-header-v1')
      throw const FormatException('chart_header_source');
    for (final p in (font['pairs'] as List)) {
      _pairs['${p[0]}:${p[1]}'] = p;
    }
  }
  final Map source;
  Map get font => source['font'] as Map;
  Map get sprites => source['sprites'] as Map;
  final _pairs = <String, List>{};
  final _geometry = <String, ({String signature, ProjectedMesh mesh})>{};
  String? _lastDrawKey;
  Map<String, ProjectedMesh> _lastMeshes = const {};
  Map<String, NativeMaterial> _lastMaterials = const {};
  List<NativeDraw> _lastDraws = const [];

  Map<String, String> texturePaths(String server) => {
    for (final e in sprites.entries)
      'header:${e.key}': _path(server, (e.value as Map)['path'] as String),
    'header:font': _path(server, font['path'] as String),
  };

  /// SDF atlases carry an independent distance channel and retain raw RGBA.
  Map<String, String> independentTexturePaths(String server) => {
    'header:font': _path(server, font['path'] as String),
  };

  String _path(String server, String path) => path.startsWith('assets/')
      ? '/assets/$server/${path.substring(7)}'
      : path.startsWith('runtime/')
      ? '/runtime/$server/${path.substring(8)}'
      : '/$path';

  ({double left, double top, double width, double height}) pauseHitBounds({
    required double width,
    required double height,
    double minimumSize = 48,
  }) {
    final frame = ((source['pause'] as Map)['frame'] as List).cast<num>();
    final scale = math.min(width / 1920, height / 1080);
    final hitWidth = math.min(math.max(minimumSize, frame[2] * scale), width);
    final hitHeight = math.min(math.max(minimumSize, frame[3] * scale), height);
    return (
      left: (width - (frame[0] - frame[2] / 2) * scale - hitWidth / 2).clamp(
        0.0,
        width - hitWidth,
      ),
      top: ((frame[1] + frame[3] / 2) * scale - hitHeight / 2).clamp(
        0.0,
        height - hitHeight,
      ),
      width: hitWidth,
      height: hitHeight,
    );
  }

  ({String rank, double progress}) rank(int score, List<int>? values) {
    final fallback = (source['rankFallback'] as List).cast<int>();
    final candidate = values ?? fallback;
    var valid = candidate.length == 5;
    var previous = 0;
    for (final n in candidate) {
      if (n <= previous) valid = false;
      previous = n;
    }
    final thresholds = valid ? candidate : fallback;
    // Web's deck-independent domain uses the source SS field's 1.2 scaling.
    final maximum = math.max(thresholds.last, (thresholds.last * 1.2).round());
    final nativeScore = score.clamp(0, 1000000) / 1000000 * maximum;
    var index = 0;
    while (index < 5 && nativeScore >= thresholds[index]) index++;
    final positions = (source['rankPositions'] as List).cast<num>();
    final loScore = index == 0 ? 0 : thresholds[index - 1],
        hiScore = index < 5 ? thresholds[index] : maximum;
    final loPos = index == 0 ? 0 : positions[index - 1],
        hiPos = index < 5 ? positions[index] : 502;
    final fraction = hiScore <= loScore
        ? 1.0
        : ((nativeScore - loScore) / (hiScore - loScore)).clamp(0, 1);
    return (
      rank: (source['rankLabels'] as List)[index] as String,
      progress: ((loPos + (hiPos - loPos) * fraction) / 502.0001)
          .clamp(0, 1)
          .toDouble(),
    );
  }

  List<NativeDraw> draw({
    required CassiopeiaSessionSnapshot snapshot,
    CassiopeiaJudgementEvent? lastEvent,
    required int mediaUs,
    List<int>? rankScores,
    required double width,
    required double height,
    double pixelRatio = 1,
    required Map<String, ProjectedMesh> meshes,
    required Map<String, NativeMaterial> materials,
  }) {
    final delta =
        lastEvent != null &&
            mediaUs >= lastEvent.judgedAtMicros &&
            mediaUs - lastEvent.judgedAtMicros < 450000
        ? lastEvent.scoreDelta
        : 0;
    final drawKey =
        '$width/$height/$pixelRatio/${snapshot.score}/${snapshot.life}/$rankScores/$delta';
    if (drawKey == _lastDrawKey) {
      meshes.addAll(_lastMeshes);
      materials.addAll(_lastMaterials);
      return _lastDraws;
    }
    final scale = math.min(width / 1920, height / 1080),
        logicalWidth = width / scale;
    final result = <NativeDraw>[];
    List<double> rgba(num r, num g, num b, [num a = 1]) => [
      r.toDouble(),
      g.toDouble(),
      b.toDouble(),
      a.toDouble(),
    ];
    List<double> mix(List<double> a, List<double> b, double t) => [
      for (var i = 0; i < 4; i++) a[i] + (b[i] - a[i]) * t,
    ];
    void put(
      String role,
      List<double> vertices,
      List<int> indices,
      String texture, {
      double? fontSize,
    }) {
      final key = 'header:$role';
      final signature = '$width/$height/$pixelRatio/$vertices/$indices';
      var cached = _geometry[key];
      if (cached?.signature != signature) {
        cached = (
          signature: signature,
          mesh: ProjectedMesh(
            Float32List.fromList(vertices),
            Uint16List.fromList(indices),
          ),
        );
        _geometry[key] = cached;
      }
      meshes[key] = cached!.mesh;
      if (fontSize == null) {
        materials[key] = NativeMaterial(
          texture: texture,
          textureAlpha: NativeTextureAlpha.premultiplied,
        );
      } else {
        final distanceScale = math.max(
          1.0,
          ((font['padding'] as num) + 1) *
              fontSize /
              (font['size'] as num) *
              (font['scale'] as num) *
              scale *
              pixelRatio,
        );
        materials[key] = NativeMaterial(
          texture: texture,
          recipe: NativeMaterialRecipe.sdfText,
          textureAlpha: NativeTextureAlpha.independent,
          uniformFloats: Float32List.fromList([
            1,
            1,
            1,
            1,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            .5,
            0,
            0,
            1 / distanceScale,
            0,
            0,
            .5,
            0,
            0,
            0,
            0,
            0,
          ]),
        );
      }
      result.add(NativeDraw(mesh: key, material: key));
    }

    void vertex(
      List<double> output,
      double x,
      double y,
      double u,
      double v,
      List<double> c,
    ) {
      output.addAll([
        2 * x * scale / width - 1,
        1 - 2 * y * scale / height,
        0,
        1,
        u,
        v,
        ...c,
      ]);
    }

    void box(
      String role,
      double x,
      double y,
      double w,
      double h,
      List<double> color, {
      List<List<double>>? gradient,
      List<double>? stops,
    }) {
      final verts = <double>[], indices = <int>[];
      final colors = gradient ?? [color, color], keys = stops ?? [0.0, 1.0];
      for (var i = 0; i < keys.length; i++) {
        final xx = x + w * keys[i];
        vertex(verts, xx, y, 0, 0, colors[i]);
        vertex(verts, xx, y + h, 0, 1, colors[i]);
        if (i > 0) {
          final a = (i - 1) * 2;
          indices.addAll([a, a + 2, a + 1, a + 1, a + 2, a + 3]);
        }
      }
      put(role, verts, indices, 'header:white');
    }

    void image(
      String role,
      String sprite,
      double x,
      double y,
      double w,
      double h, {
      List<double>? color,
      List<double>? border,
      double ppu = 1,
      double? clipRight,
      List<List<double>>? gradient,
      List<double>? stops,
    }) {
      final raw = sprites[sprite] as Map,
          rect = (raw['rect'] as List).cast<num>(),
          trim = (raw['trim'] as List).cast<num>(),
          offset = (raw['offset'] as List).cast<num>();
      final xs = <double>[], ys = <double>[], us = <double>[], vs = <double>[];
      if (border != null) {
        var l = border[0] / ppu,
            r = border[2] / ppu,
            t = border[3] / ppu,
            b = border[1] / ppu;
        final sx = l + r > w ? w / (l + r) : 1.0,
            sy = t + b > h ? h / (t + b) : 1.0;
        l *= sx;
        r *= sx;
        t *= sy;
        b *= sy;
        xs.addAll([x, x + l, x + w - r, x + w]);
        ys.addAll([y, y + t, y + h - b, y + h]);
        us.addAll([0, border[0] / trim[0], 1 - border[2] / trim[0], 1]);
        vs.addAll([0, border[3] / trim[1], 1 - border[1] / trim[1], 1]);
      } else {
        xs.addAll([
          x + offset[0] / rect[0] * w,
          x + (offset[0] + trim[0]) / rect[0] * w,
        ]);
        ys.addAll([
          y + (rect[1] - offset[1] - trim[1]) / rect[1] * h,
          y + (rect[1] - offset[1]) / rect[1] * h,
        ]);
        us.addAll([0, 1]);
        vs.addAll([0, 1]);
      }
      List<double> at(double xx) {
        if (gradient == null || stops == null) return color ?? rgba(1, 1, 1);
        final q = ((xx - x) / w).clamp(0, 1);
        var i = 1;
        while (i < stops.length - 1 && stops[i] < q) i++;
        return mix(
          gradient[i - 1],
          gradient[i],
          ((q - stops[i - 1]) / (stops[i] - stops[i - 1])).clamp(0, 1),
        );
      }

      // Split at colour keys as well as Source nine-slice borders.
      if (stops != null) {
        for (final q in stops) {
          final xx = x + q * w;
          if (xx <= xs.first || xx >= xs.last || xs.contains(xx)) continue;
          var i = 1;
          while (xs[i] < xx) i++;
          final u =
              us[i - 1] +
              (us[i] - us[i - 1]) * (xx - xs[i - 1]) / (xs[i] - xs[i - 1]);
          xs.insert(i, xx);
          us.insert(i, u);
        }
      }
      final verts = <double>[], indices = <int>[];
      for (var row = 0; row < ys.length - 1; row++)
        for (var col = 0; col < xs.length - 1; col++) {
          var right = xs[col + 1], ur = us[col + 1];
          if (clipRight != null && right > clipRight) {
            right = clipRight;
            ur =
                us[col] +
                (ur - us[col]) * (right - xs[col]) / (xs[col + 1] - xs[col]);
          }
          if (right <= xs[col] || ys[row + 1] <= ys[row]) continue;
          final i = verts.length ~/ 10;
          vertex(verts, xs[col], ys[row], us[col], vs[row], at(xs[col]));
          vertex(verts, right, ys[row], ur, vs[row], at(right));
          vertex(
            verts,
            xs[col],
            ys[row + 1],
            us[col],
            vs[row + 1],
            at(xs[col]),
          );
          vertex(verts, right, ys[row + 1], ur, vs[row + 1], at(right));
          indices.addAll([i, i + 1, i + 2, i + 2, i + 1, i + 3]);
        }
      if (indices.isNotEmpty) put(role, verts, indices, 'header:$sprite');
    }

    void text(
      String role,
      String value,
      double x,
      double centerY,
      double size, {
      String align = 'left',
      List<double>? color,
      int leadingZeros = 0,
    }) {
      final characters = font['characters'] as Map,
          glyphs = font['glyphs'] as Map,
          entries =
              <({Map glyph, double characterScale, List<double> adjust})>[];
      for (final rune in value.runes) {
        final c = characters['$rune'] as List?;
        if (c == null) throw FormatException('header_glyph:$rune');
        entries.add((
          glyph: glyphs['${c[0]}'] as Map,
          characterScale: (c[1] as num).toDouble(),
          adjust: [0, 0, 0],
        ));
      }
      for (var i = 0; i < entries.length - 1; i++) {
        final first = characters['${value.codeUnitAt(i)}'] as List,
            second = characters['${value.codeUnitAt(i + 1)}'] as List;
        final pair = _pairs['${first[0]}:${second[0]}'];
        if (pair != null) {
          for (var k = 0; k < 3; k++) {
            entries[i].adjust[k] += (pair[2][k] as num).toDouble();
            entries[i + 1].adjust[k] += (pair[3][k] as num).toDouble();
          }
        }
      }
      final fontScale = size / (font['size'] as num) * (font['scale'] as num);
      double advance(int i) {
        final e = entries[i];
        return (e.glyph['metrics'][4] as num) *
                fontScale *
                e.characterScale *
                (e.glyph['scale'] as num) +
            e.adjust[2] * fontScale +
            (i + 1 < entries.length ? 1 : 0);
      }

      var pen = x;
      final textWidth = List.generate(
        entries.length,
        advance,
      ).fold(0.0, (a, b) => a + b);
      if (align == 'center') pen -= textWidth / 2;
      if (align == 'right') pen -= textWidth;
      final baseline =
          centerY +
          ((font['ascent'] as num) + (font['descent'] as num)) * fontScale / 2;
      final verts = <double>[], indices = <int>[];
      for (var index = 0; index < entries.length; index++) {
        final e = entries[index],
            m = (e.glyph['metrics'] as List).cast<num>(),
            r = (e.glyph['rect'] as List).cast<num>();
        final s = fontScale * e.characterScale * (e.glyph['scale'] as num);
        if (r[2] > 0 && r[3] > 0 && m[0] > 0 && m[1] > 0) {
          final left = pen + e.adjust[0] * fontScale + m[2] * s,
              top = baseline - e.adjust[1] * fontScale - m[3] * s,
              w = m[0] * s,
              h = m[1] * s;
          final u0 = r[0] / (font['width'] as num),
              u1 = (r[0] + r[2]) / (font['width'] as num),
              v0 = 1 - (r[1] + r[3]) / (font['height'] as num),
              v1 = 1 - r[1] / (font['height'] as num);
          final c = index < leadingZeros
              ? rgba(177 / 255, 175 / 255, 193 / 255)
              : (color ?? rgba(1, 1, 1));
          final i = verts.length ~/ 10;
          vertex(verts, left, top, u0, v0, c);
          vertex(verts, left + w, top, u1, v0, c);
          vertex(verts, left, top + h, u0, v1, c);
          vertex(verts, left + w, top + h, u1, v1, c);
          indices.addAll([i, i + 1, i + 2, i + 2, i + 1, i + 3]);
        }
        pen += advance(index);
      }
      if (indices.isNotEmpty)
        put(role, verts, indices, 'header:font', fontSize: size);
    }

    final headerColors = <List<double>>[
      for (final q in [0.0, .6, .9, 1.0])
        rgba(
          .1921569 * q,
          .0588235 + (.2235294 - .0588235) * q,
          .2 + (.4039216 - .2) * q,
          q == 0
              ? 1
              : q == .6
              ? .698039
              : q == .9
              ? .4
              : 0,
        ),
    ];
    box(
      'background',
      20,
      0,
      660,
      146,
      rgba(1, 1, 1),
      gradient: headerColors,
      stops: [0, .6, .9, 1],
    );
    image('rank-base', 'rankBase', 6, 0, 149, 160, border: [26, 25, 26, 4]);
    text('rank-caption', 'RANK', 80.5, 31, 24, align: 'center');
    final rankState = rank(snapshot.score, rankScores);
    image('rank-icon', 'rank${rankState.rank}', 23, 41.5, 115, 95);
    image('rank-outline', 'round', 158, 66, 506, 28, border: [14, 14, 14, 14]);
    image(
      'rank-empty',
      'round',
      160,
      68,
      502,
      24,
      border: [14, 14, 14, 14],
      ppu: 7 / 6,
      color: rgba(24 / 255, 18 / 255, 41 / 255, .698039),
    );
    if (rankState.progress > 0)
      image(
        'rank-filled',
        'round',
        160,
        68,
        502,
        24,
        border: [14, 14, 14, 14],
        ppu: 7 / 6,
        clipRight: 160 + 502 * rankState.progress,
        stops: [
          0,
          9175 / 65535,
          19661 / 65535,
          30801 / 65535,
          41942 / 65535,
          53083 / 65535,
          1,
        ],
        gradient: [
          rgba(163 / 255, 224 / 255, 1),
          rgba(162 / 255, 1, 183 / 255),
          rgba(247 / 255, 1, 154 / 255),
          rgba(1, 204 / 255, 162 / 255),
          rgba(1, 136 / 255, 155 / 255),
          rgba(1, 166 / 255, 227 / 255),
          rgba(154 / 255, 125 / 255, 250 / 255),
        ],
      );
    for (final (i, x) in [248.0, 335, 424, 512, 600].indexed)
      box('separator$i', x - 1.5, 68, 3, 24, rgba(1, 1, 1));
    for (final (i, x) in [248.0, 337, 424, 512, 599].indexed)
      text(
        'rank-label$i',
        ['C', 'B', 'A', 'S', 'SS'][i],
        x.toDouble(),
        43,
        30,
        align: 'center',
      );
    final rawScore = '${snapshot.score}', padded = rawScore.padLeft(8, '0');
    text(
      'score',
      padded,
      42,
      190,
      44,
      leadingZeros: padded.length - rawScore.length,
    );
    image('score-star', 'star', 20, 202.8, 16.65, 16.2);
    box('score-line', 28.325, 209, 260, 2, rgba(1, 1, 1));
    text('score-caption', 'LIVE SCORE', 127, 230, 24, align: 'center');
    if (lastEvent != null &&
        lastEvent.scoreDelta != 0 &&
        mediaUs - lastEvent.judgedAtMicros >= 0 &&
        mediaUs - lastEvent.judgedAtMicros < 450000)
      text('score-delta', '+${lastEvent.scoreDelta}', 271.28845, 196.9, 24);
    final statusColors = <List<double>>[
      for (final q in [0.0, .1, .4, 1.0])
        rgba(
          .1921569 * (1 - q),
          .2235294 + (.0588235 - .2235294) * q,
          .4039216 + (.2 - .4039216) * q,
          q == 0
              ? 0
              : q == .1
              ? .4
              : q == .4
              ? .698039
              : 1,
        ),
    ];
    image(
      'status',
      'status',
      logicalWidth - 420,
      19,
      400,
      80,
      border: [0, 0, 60, 0],
      ppu: 1.5,
      gradient: statusColors,
      stops: [0, .1, .4, 1],
    );
    image(
      'life-empty',
      'round',
      logicalWidth - 400,
      62,
      284,
      16,
      border: [14, 14, 14, 14],
      ppu: 1.75,
      color: rgba(5 / 255, 18 / 255, 51 / 255),
    );
    final danger = snapshot.life <= 300,
        over = snapshot.life > 1000,
        lifeColor = danger
            ? rgba(1, 77 / 255, 77 / 255)
            : over
            ? rgba(198 / 255, 1, 234 / 255)
            : rgba(1, 1, 1);
    if (snapshot.life > 0)
      image(
        'life-filled',
        'round',
        logicalWidth - 400,
        64,
        280,
        12,
        border: [14, 14, 14, 14],
        ppu: 7 / 3,
        color: danger ? lifeColor : rgba(102 / 255, 1, 140 / 255),
        clipRight:
            logicalWidth - 400 + 280 * (snapshot.life / 1000).clamp(0, 1),
      );
    if (over)
      image(
        'life-over',
        'round',
        logicalWidth - 400,
        64,
        280,
        12,
        border: [14, 14, 14, 14],
        ppu: 7 / 3,
        color: lifeColor,
        clipRight:
            logicalWidth -
            400 +
            280 * ((snapshot.life - 1000) / 1000).clamp(0, 1),
      );
    image(
      'life-icon',
      danger
          ? 'lifeDanger'
          : over
          ? 'lifeOver'
          : 'lifeNormal',
      logicalWidth - 220,
      34.5,
      30,
      27,
    );
    text(
      'life',
      '${snapshot.life}',
      logicalWidth - 117.5,
      48,
      30,
      align: 'right',
      color: lifeColor,
    );
    final pause = source['pause'] as Map;
    for (final layer in ['shadow', 'frame', 'icon']) {
      final slot = (pause[layer] as List).cast<num>();
      final sprite = 'pause${layer[0].toUpperCase()}${layer.substring(1)}';
      image(
        'pause-$layer',
        sprite,
        logicalWidth - slot[0],
        slot[1].toDouble(),
        slot[2].toDouble(),
        slot[3].toDouble(),
        border: layer == 'icon'
            ? null
            : ((sprites[sprite] as Map)['border'] as List)
                  .map((v) => (v as num).toDouble())
                  .toList(),
      );
    }
    _lastDrawKey = drawKey;
    _lastDraws = List.unmodifiable(result);
    _lastMeshes = {for (final d in result) d.mesh: meshes[d.mesh]!};
    _lastMaterials = {
      for (final d in result) d.material: materials[d.material]!,
    };
    return _lastDraws;
  }
}
