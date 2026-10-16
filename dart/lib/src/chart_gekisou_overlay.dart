import 'dart:math' as math;
import 'dart:typed_data';

import 'package:render_contracts/render_contracts.dart';

import 'chart_gekisou_presentation.dart';

typedef _Data = Map<String, dynamic>;

_Data _data(Object? value) => Map<String, dynamic>.from(value as Map);
List<_Data> _rows(Object? value) => (value as List).map(_data).toList();
double _number(Object? value) => (value as num).toDouble();
Float64List _vector(_Data value, [bool quaternion = false]) =>
    Float64List.fromList([
      _number(value['x']),
      _number(value['y']),
      _number(value['z']),
      if (quaternion) _number(value['w']),
    ]);

final class OurNotesGekisouOverlayViewport {
  const OurNotesGekisouOverlayViewport({
    required this.width,
    required this.height,
    required this.worldToClip,
    this.displayPositionChanged = false,
    this.displayScale = 1,
  });

  final double width, height, displayScale;
  final List<double> worldToClip;
  final bool displayPositionChanged;
}

/// Final clip-space geometry; hosts supply asset transfer and render passes.
final class OurNotesGekisouOverlaySprite {
  const OurNotesGekisouOverlaySprite({
    required this.id,
    required this.textureKey,
    required this.geometry,
    required this.screenSpace,
    required this.sortingOrder,
  });

  final String id, textureKey;
  final GeometryBuffer geometry;
  final bool screenSpace;
  final int sortingOrder;
}

final class _Pose {
  _Pose(_Data node, double alpha)
    : position = _vector(_data(node['position'])),
      rotation = _vector(_data(node['rotation']), true),
      scale = _vector(_data(node['scale'])),
      active = node['active'] as bool,
      alpha = alpha,
      rect = node['rect'] == null
          ? null
          : {
              for (final entry in (node['rect'] as Map).entries)
                entry.key as String: entry.value is Map
                    ? _data(entry.value)
                    : entry.value,
            };

  Float64List position, rotation, scale;
  bool active;
  double alpha;
  final _Data? rect;
}

final class _Mesh {
  _Mesh(this.vertices, this.topology);
  factory _Mesh.fromRaw(_Data source) => _Mesh(
    (source['vertices'] as List).map(_number).toList(),
    TriangleTopology(
      Uint16List.fromList((source['indices'] as List).cast<int>()),
    ),
  );
  final List<double> vertices;
  final TriangleTopology topology;
}

final _identity = Float64List.fromList([
  1,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  1,
]);

Float64List _multiply(List<double> a, List<double> b) {
  final output = Float64List(16);
  for (var column = 0; column < 4; column++) {
    for (var row = 0; row < 4; row++) {
      output[column * 4 + row] =
          a[row] * b[column * 4] +
          a[4 + row] * b[column * 4 + 1] +
          a[8 + row] * b[column * 4 + 2] +
          a[12 + row] * b[column * 4 + 3];
    }
  }
  return output;
}

Float64List _trs(List<double> p, List<double> q, List<double> s) {
  final xx = q[0] * q[0], yy = q[1] * q[1], zz = q[2] * q[2];
  final xy = q[0] * q[1], xz = q[0] * q[2], yz = q[1] * q[2];
  final wx = q[3] * q[0], wy = q[3] * q[1], wz = q[3] * q[2];
  return Float64List.fromList([
    (1 - 2 * (yy + zz)) * s[0],
    2 * (xy + wz) * s[0],
    2 * (xz - wy) * s[0],
    0,
    2 * (xy - wz) * s[1],
    (1 - 2 * (xx + zz)) * s[1],
    2 * (yz + wx) * s[1],
    0,
    2 * (xz + wy) * s[2],
    2 * (yz - wx) * s[2],
    (1 - 2 * (xx + yy)) * s[2],
    0,
    p[0],
    p[1],
    p[2],
    1,
  ]);
}

Float64List _eulerZxy(List<double> e) {
  final r = math.pi / 360;
  final sx = math.sin(e[0] * r), cx = math.cos(e[0] * r);
  final sy = math.sin(e[1] * r), cy = math.cos(e[1] * r);
  final sz = math.sin(e[2] * r), cz = math.cos(e[2] * r);
  return Float64List.fromList([
    sx * cy * cz + cx * sy * sz,
    cx * sy * cz - sx * cy * sz,
    cx * cy * sz - sx * sy * cz,
    cx * cy * cz + sx * sy * sz,
  ]);
}

double _sampleCurve(_Data curve, double time) {
  if (curve['constant'] is num) return _number(curve['constant']);
  final rows = curve['segments'] as List?;
  if (rows == null || rows.isEmpty) return 0;
  var low = 0, high = rows.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (_number((rows[middle] as Map)['time']) <= time) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  final row = rows[math.max(0, low - 1)] as Map;
  final coefficients = row['coefficients'] as List;
  final dt = time - _number(row['time']);
  return ((_number(coefficients[0]) * dt + _number(coefficients[1])) * dt +
              _number(coefficients[2])) *
          dt +
      _number(coefficients[3]);
}

_Mesh _sliced(
  double width,
  double height,
  double pivotX,
  double pivotY,
  _Data sprite,
  double pixelsPerUnit,
) {
  final border = _data(sprite['border']), rect = _data(sprite['rect']);
  final left = _number(border['x']), right = _number(border['z']);
  final bottom = _number(border['y']), top = _number(border['w']);
  final scaleX = math.min(
    1.0,
    width * pixelsPerUnit / math.max(2.220446049250313e-16, left + right),
  );
  final scaleY = math.min(
    1.0,
    height * pixelsPerUnit / math.max(2.220446049250313e-16, bottom + top),
  );
  final x = [
    -width * pivotX,
    -width * pivotX + left / pixelsPerUnit * scaleX,
    width * (1 - pivotX) - right / pixelsPerUnit * scaleX,
    width * (1 - pivotX),
  ];
  final y = [
    -height * pivotY,
    -height * pivotY + bottom / pixelsPerUnit * scaleY,
    height * (1 - pivotY) - top / pixelsPerUnit * scaleY,
    height * (1 - pivotY),
  ];
  final u = [
    0.0,
    left / _number(rect['width']),
    1 - right / _number(rect['width']),
    1.0,
  ];
  final v = [
    0.0,
    bottom / _number(rect['height']),
    1 - top / _number(rect['height']),
    1.0,
  ];
  final vertices = <double>[], indices = <int>[];
  for (var row = 0; row < 4; row++) {
    for (var column = 0; column < 4; column++) {
      vertices.addAll([x[column], y[row], 0, u[column], v[row]]);
    }
  }
  for (var row = 0; row < 3; row++) {
    for (var column = 0; column < 3; column++) {
      if (x[column] == x[column + 1] || y[row] == y[row + 1]) continue;
      final a = row * 4 + column;
      indices.addAll([a, a + 1, a + 5, a, a + 5, a + 4]);
    }
  }
  return _Mesh(vertices, TriangleTopology(Uint16List.fromList(indices)));
}

/// Source hierarchy, animation and UI policy shared by every renderer backend.
final class OurNotesGekisouOverlayProjector {
  OurNotesGekisouOverlayProjector(Map<String, Object?> profile)
    : _source = _data(profile) {
    _nodes = _rows(_source['nodes']);
    _visuals = _rows(_source['visuals']);
    _sprites = _rows(_source['sprites']);
    _spriteMeshes = [
      for (final sprite in _sprites) _Mesh.fromRaw(_data(sprite['mesh'])),
    ];
    _visualByNode = {
      for (var i = 0; i < _visuals.length; i++) _visuals[i]['node'] as int: i,
    };
    _unitByNode = {
      for (final value in _rows(_source['numberUnits']))
        value['node'] as int: value,
    };
    _clipByKey = {
      for (final value in _rows(_source['clips']))
        value['key'] as String: value,
    };
    _controllerByKey = {
      for (final value in _rows(_source['controllers']))
        value['sourceDescriptor'] as String: value,
    };
    _groups = {
      for (final value in _rows(_source['canvasGroups']))
        value['node'] as int: value,
    };
  }

  final _Data _source;
  late final List<_Data> _nodes, _visuals, _sprites;
  late final List<_Mesh> _spriteMeshes;
  late final Map<int, int> _visualByNode;
  late final Map<int, _Data> _unitByNode, _groups;
  late final Map<String, _Data> _clipByKey, _controllerByKey;
  final _descendants = <int, List<int>>{};
  final _visualClosures = <int, List<int>>{};
  final _sliceMeshes = <Object, _Mesh>{};

  List<Map<String, Object?>> get textureManifest => _rows(_source['textures']);

  ({bool displayPositionChanged, double displayScale}) get viewSettings {
    final settings = _source['viewSettings'] as Map;
    return (
      displayPositionChanged: settings['displayPositionChanged'] as bool,
      displayScale: _number(settings['displayScale']),
    );
  }

  Map<String, String> texturePaths(String server) => {
    for (final texture in textureManifest)
      texture['key'] as String: _path(server, texture['path'] as String),
  };

  String _path(String server, String path) => path.startsWith('assets/')
      ? '/assets/$server/${path.substring(7)}'
      : path.startsWith('runtime/')
      ? '/runtime/$server/${path.substring(8)}'
      : '/$path';

  bool _under(int node, int ancestor) {
    int? current = node;
    while (current != null) {
      if (current == ancestor) return true;
      current = _nodes[current]['parent'] as int?;
    }
    return false;
  }

  List<int> _closure(int root) => _descendants.putIfAbsent(
    root,
    () => [
      for (var i = 0; i < _nodes.length; i++)
        if (_under(i, root)) i,
    ],
  );

  List<OurNotesGekisouOverlaySprite> project(
    OurNotesGekisouPresentationFrame frame,
    OurNotesGekisouOverlayViewport viewport,
  ) {
    if (!frame.enabled) return const [];
    final prefix = viewport.displayPositionChanged ? 'canvas' : 'world';
    final countdown = frame.countdown;
    return [
      if (countdown.visible && countdown.clip != null)
        ..._drawRole(
          '${prefix}Countdown',
          viewport,
          mission: countdown.mission?.index,
          state:
              'gekisou_countdown_${countdown.clip == OurNotesGekisouCountdownClip.out ? 'out' : countdown.count}',
          seconds: countdown.clipTimeSeconds,
        ),
      if (frame.just.visible)
        ..._drawRole('${prefix}Just', viewport, count: frame.just.count),
    ];
  }

  List<OurNotesGekisouOverlaySprite> _drawRole(
    String name,
    OurNotesGekisouOverlayViewport viewport, {
    int? mission,
    String? state,
    double seconds = 0,
    int? count,
  }) {
    final role = (_source['roles'] as Map)[name] as int?;
    if (role == null) return const [];
    final screen = name.startsWith('canvas'), selected = _closure(role);
    final poses = <int, _Pose>{}, overrides = <int, int>{};
    final colorAlpha = <int, double>{}, positionAxes = <int, int>{};
    _Pose pose(int index) => poses.putIfAbsent(
      index,
      () => _Pose(_nodes[index], _number(_groups[index]?['alpha'] ?? 1)),
    );
    for (final index in selected) {
      pose(index);
    }
    for (
      int? index = role;
      index != null;
      index = _nodes[index]['parent'] as int?
    ) {
      pose(index).active = true;
    }
    pose(role).scale = Float64List.fromList(
      List.filled(3, viewport.displayScale),
    );
    if (state != null) {
      final animator = _rows(_source['animators'])
          .firstWhere((v) => _under(v['node'] as int, role));
      final controller = _controllerByKey[animator['controllerKey']]!;
      final animation = _rows(controller['states'])
          .firstWhere((v) => v['name'] == state);
      final clip = _clipByKey[(animation['clips'] as List).first]!;
      final targets = {
        for (final value in animator['pathNodes'] as List)
          (value as List)[0] as int: value[1] as int,
      };
      final stopTime = _number((clip['settings'] as Map)['m_StopTime']);
      final elapsed = math.max(
        0.0,
        seconds * _number(animation['speed']) +
            _number(animation['cycleOffset']) * stopTime,
      );
      final time = animation['loop'] == true && stopTime > 0
          ? elapsed % stopTime
          : math.min(elapsed, stopTime);
      for (final binding in _rows(clip['bindings'])) {
        final target = targets[binding['pathHash']];
        if (target == null) continue;
        final targetPose = pose(target);
        final values = [
          for (var i = 0; i < (binding['components'] as int); i++)
            _sampleCurve(
              _data(
                (clip['curves'] as List)[(binding['curveStart'] as int) + i],
              ),
              time,
            ),
        ];
        final type = binding['type'] as int,
            attribute = binding['attribute'] as int;
        if (type == 4) {
          final vector = Float64List.fromList(values.take(3).toList());
          if (attribute == 1) {
            targetPose.position = vector;
            positionAxes[target] = 7;
          } else if (attribute == 3) {
            targetPose.scale = vector;
          } else if (attribute == 4) {
            targetPose.rotation = _eulerZxy(vector);
          } else if (attribute == 2) {
            targetPose.rotation = Float64List.fromList(values);
          }
        } else if (type == 1 && attribute == 2086281974) {
          targetPose.active = values[0] >= .5;
        } else if (type == 225 && attribute == 1574349066) {
          targetPose.alpha = values[0].clamp(0, 1);
        } else if ((type == 212 || type == 114) && attribute == 304273561) {
          colorAlpha[target] = values[0];
        } else if (type == 224) {
          final axis = switch (attribute) {
            2537237887 => 0,
            3762036201 => 1,
            2033536083 => 2,
            _ => null,
          };
          if (axis != null) {
            targetPose.position[axis] = values[0];
            positionAxes[target] = (positionAxes[target] ?? 0) | (1 << axis);
          }
        }
      }
    }
    final binding = _data((_source['bindings'] as Map)[name]);
    if (mission != null && binding['missionVisual'] != null) {
      final sprite = (binding['missionSprites'] as Map)['$mission'] as int?;
      if (sprite != null) overrides[binding['missionVisual'] as int] = sprite;
    }
    if (count != null) {
      final numeric = _data(
        (_source['numeric'] as List)[binding['count'] as int],
      );
      final units = (numeric['units'] as List).cast<int>();
      final rawDigits = math.max(0, count).toString();
      final digits = rawDigits.substring(
        math.max(0, rawDigits.length - units.length),
      );
      for (var i = 0; i < units.length; i++) {
        final node = units[i];
        pose(node).active = i >= units.length - digits.length;
        if (!pose(node).active) continue;
        final digit = int.parse(digits[i - (units.length - digits.length)]);
        final sprite =
            ((_source['numberGlyphs'] as Map)['digits'] as List)[digit] as int;
        final imageNode = _unitByNode[node]!['imageNode'] as int;
        overrides[_visualByNode[imageNode]!] = sprite;
        final size = _data(_sprites[sprite]['rect']);
        for (final target in [node, imageNode]) {
          if (pose(target).rect case final rect?) {
            rect['m_SizeDelta'] = {'x': size['width'], 'y': size['height']};
          }
        }
      }
      pose(
        (_source['numeric'] as List)[binding['factor'] as int]['node'] as int,
      ).active = false;
      for (final index in selected) {
        if ((_nodes[index]['name'] as String).contains(
          'GekisouSkillAddedValueView',
        ))
          pose(index).active = false;
      }
      for (final layout in _rows(_source['layouts'])) {
        if (layout['node'] != _nodes[units[0]]['parent']) continue;
        final active = units.where((i) => pose(i).active).toList();
        final widths = [
          for (final node in active)
            _number(
              (_sprites[overrides[_visualByNode[_unitByNode[node]!['imageNode']]]!]['rect']
                  as Map)['width'],
            ),
        ];
        final spacing = _number(layout['spacing']),
            ppu = _number(layout['pixelsPerUnit']);
        final total =
            widths.fold(0.0, (sum, value) => sum + value) +
            spacing * (active.length - 1);
        var cursor = screen ? -total / 2 : -total / 2 / ppu;
        for (var i = 0; i < active.length; i++) {
          final row = pose(active[i]);
          if (screen && row.rect != null) {
            row.rect!['m_AnchorMin'] = {'x': .5, 'y': .5};
            row.rect!['m_AnchorMax'] = {'x': .5, 'y': .5};
            row.rect!['m_AnchoredPosition'] = {
              'x': cursor + widths[i] / 2,
              'y': 0.0,
            };
            cursor += widths[i] + spacing;
          } else {
            row.position[0] = cursor + widths[i] / 2 / ppu;
            cursor += (widths[i] + spacing) / ppu;
          }
        }
      }
    }
    final matrices = <int, Float64List>{};
    final sizes = <int, ({double x, double y, double pivotX, double pivotY})>{};
    final referenceSize = (_source['canvas'] as Map)['referenceSize'] as List;
    final canvasScale = math.min(
      viewport.width / _number(referenceSize[0]),
      viewport.height / _number(referenceSize[1]),
    );
    final cw = viewport.width / canvasScale, ch = viewport.height / canvasScale;
    Float64List matrix(int index) {
      final cached = matrices[index];
      if (cached != null) return cached;
      final node = _nodes[index], value = pose(index);
      final parentId = node['parent'] as int?;
      final parent = parentId == null ? _identity : matrix(parentId);
      var position = value.position, scale = value.scale;
      if (screen && value.rect != null) {
        final rect = value.rect!;
        final authoredScale = _data(node['scale']);
        final parentSize = sizes[parentId];
        if (authoredScale['x'] == 0 && authoredScale['y'] == 0 ||
            parentSize == null) {
          sizes[index] = (x: cw, y: ch, pivotX: 0, pivotY: 0);
          position = Float64List.fromList([-cw / 2, -ch / 2, 0]);
          scale = Float64List.fromList([1, 1, 1]);
        } else {
          final min = _data(rect['m_AnchorMin']),
              max = _data(rect['m_AnchorMax']);
          final size = _data(rect['m_SizeDelta']),
              pivot = _data(rect['m_Pivot']);
          final anchored = _data(rect['m_AnchoredPosition']);
          final width =
              parentSize.x * (_number(max['x']) - _number(min['x'])) +
              _number(size['x']);
          final height =
              parentSize.y * (_number(max['y']) - _number(min['y'])) +
              _number(size['y']);
          position = Float64List.fromList([
            parentSize.x *
                    (_number(min['x']) +
                        (_number(max['x']) - _number(min['x'])) *
                            _number(pivot['x']) -
                        parentSize.pivotX) +
                _number(anchored['x']),
            parentSize.y *
                    (_number(min['y']) +
                        (_number(max['y']) - _number(min['y'])) *
                            _number(pivot['y']) -
                        parentSize.pivotY) +
                _number(anchored['y']),
            value.position[2],
          ]);
          sizes[index] = (
            x: width,
            y: height,
            pivotX: _number(pivot['x']),
            pivotY: _number(pivot['y']),
          );
        }
        final flags = positionAxes[index] ?? 0;
        for (var axis = 0; axis < 3; axis++) {
          if (flags & (1 << axis) != 0) position[axis] = value.position[axis];
        }
      }
      return matrices[index] = _multiply(
        parent,
        _trs(position, value.rotation, scale),
      );
    }

    final visibleIndices = _visualClosures.putIfAbsent(
      role,
      () => [
        for (var i = 0; i < _visuals.length; i++)
          if (selected.contains(_visuals[i]['node'])) i,
      ],
    );
    final output = <OurNotesGekisouOverlaySprite>[];
    for (final visualIndex in visibleIndices) {
      final visual = _visuals[visualIndex];
      if (visual['enabled'] != true) continue;
      final nodeId = visual['node'] as int, color = _data(visual['color']);
      var visible = true, opacity = colorAlpha[nodeId] ?? _number(color['a']);
      for (
        int? current = nodeId;
        current != null;
        current = _nodes[current]['parent'] as int?
      ) {
        final value = pose(current);
        visible = visible && value.active;
        opacity *= value.alpha;
      }
      if (!visible || opacity <= 0) continue;
      final spriteIndex = overrides[visualIndex] ?? visual['sprite'] as int?;
      if (spriteIndex == null) continue;
      final sprite = _sprites[spriteIndex],
          world = matrix(nodeId),
          rect = sizes[nodeId];
      final transform = screen ? world : _multiply(viewport.worldToClip, world);
      final sourceRect = _data(sprite['rect']);
      var imageWidth = rect?.x ?? 0.0, imageHeight = rect?.y ?? 0.0;
      if (rect != null && visual['preserveAspect'] == true) {
        final scale = math.min(
          rect.x / _number(sourceRect['width']),
          rect.y / _number(sourceRect['height']),
        );
        imageWidth = _number(sourceRect['width']) * scale;
        imageHeight = _number(sourceRect['height']) * scale;
      }
      var mesh = _spriteMeshes[spriteIndex];
      if (visual['kind'] == 'canvasImage' && rect != null) {
        final offset = _data(sprite['textureRectOffset']),
            logical = sprite['textureLogicalSize'] as List;
        final left =
            -rect.pivotX * imageWidth +
            imageWidth * _number(offset['x']) / _number(sourceRect['width']);
        final bottom =
            -rect.pivotY * imageHeight +
            imageHeight * _number(offset['y']) / _number(sourceRect['height']);
        final right =
            left +
            imageWidth * _number(logical[0]) / _number(sourceRect['width']);
        final top =
            bottom +
            imageHeight * _number(logical[1]) / _number(sourceRect['height']);
        mesh = _Mesh([
          left,
          bottom,
          0,
          0,
          0,
          right,
          bottom,
          0,
          1,
          0,
          right,
          top,
          0,
          1,
          1,
          left,
          top,
          0,
          0,
          1,
        ], _quadTopology);
      }
      if (visual['drawMode'] == 1) {
        final width = screen && rect != null
            ? rect.x
            : _number((visual['size'] as Map)['x']);
        final height = screen && rect != null
            ? rect.y
            : _number((visual['size'] as Map)['y']);
        final pivot = _data(sprite['pivot']);
        final key = (
          spriteIndex,
          width,
          height,
          screen,
          rect?.pivotX,
          rect?.pivotY,
        );
        mesh = _sliceMeshes.putIfAbsent(
          key,
          () => _sliced(
            width,
            height,
            screen && rect != null ? rect.pivotX : _number(pivot['x']),
            screen && rect != null ? rect.pivotY : _number(pivot['y']),
            sprite,
            screen ? 1 : _number(sprite['pixelsToUnits']),
          ),
        );
      }
      final builder = SpriteGeometryBuilder(
        vertexCount: mesh.vertices.length ~/ 5,
        topology: mesh.topology,
      );
      for (var i = 0; i < mesh.vertices.length ~/ 5; i++) {
        final x = mesh.vertices[i * 5] * (visual['flipX'] == true ? -1 : 1);
        final y = mesh.vertices[i * 5 + 1] * (visual['flipY'] == true ? -1 : 1);
        final z = mesh.vertices[i * 5 + 2];
        final cx =
            transform[0] * x +
            transform[4] * y +
            transform[8] * z +
            transform[12];
        final cy =
            transform[1] * x +
            transform[5] * y +
            transform[9] * z +
            transform[13];
        final cz =
            transform[2] * x +
            transform[6] * y +
            transform[10] * z +
            transform[14];
        final w = screen
            ? 1.0
            : transform[3] * x +
                  transform[7] * y +
                  transform[11] * z +
                  transform[15];
        builder.setVertex(
          i,
          screen ? cx * 2 / cw : cx,
          screen ? cy * 2 / ch : cy,
          screen ? 0 : cz,
          w,
          mesh.vertices[i * 5 + 3],
          1 - mesh.vertices[i * 5 + 4],
          _number(color['r']),
          _number(color['g']),
          _number(color['b']),
          opacity,
        );
      }
      output.add(
        OurNotesGekisouOverlaySprite(
          id: 'gekisou-$name-$visualIndex',
          textureKey: sprite['texture'] as String,
          geometry: builder.build(),
          screenSpace: screen,
          sortingOrder: visual['sortingOrder'] as int,
        ),
      );
    }
    return output;
  }
}

final _quadTopology = TriangleTopology(Uint16List.fromList([0, 1, 2, 0, 2, 3]));
