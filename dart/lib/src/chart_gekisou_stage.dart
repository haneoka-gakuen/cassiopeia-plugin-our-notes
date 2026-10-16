import 'dart:math' as math;
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

import 'chart_gekisou.dart';
import 'chart_gekisou_stage_source.dart';

/// Effect option 119 is independent from render quality and lightweight mode.
enum OurNotesGekisouEffectMode { off, light, standard }

enum OurNotesGekisouStagePhase { fade, entrance, loop, exit }

final class OurNotesGekisouStageFrame {
  const OurNotesGekisouStageFrame({
    required this.rangeIndex,
    required this.phase,
    required this.effectSeconds,
    required this.clipName,
    required this.clipSeconds,
  });
  final int rangeIndex;
  final OurNotesGekisouStagePhase phase;
  final double effectSeconds, clipSeconds;
  final String clipName;
}

/// A seek projection of the formal range controller. Sampling never advances
/// its input clock. Completion has two consecutive source timers.
final class OurNotesGekisouStageClock {
  OurNotesGekisouStageClock(Map packet)
    : lifecycle = Map<String, Object?>.from(packet['lifecycle'] as Map),
      clips = {
        for (final row in packet['clips'] as List)
          (row as Map)['name'] as String: (row['duration'] as num).toDouble(),
      };
  final Map<String, Object?> lifecycle;
  final Map<String, double> clips;

  OurNotesGekisouStageFrame? sample(
    OurNotesGekisouPlan? plan,
    double mediaMs, {
    required OurNotesGekisouEffectMode mode,
    bool lightweight = false,
  }) {
    if (plan == null || mode == OurNotesGekisouEffectMode.off || lightweight) {
      return null;
    }
    final lead = (lifecycle['standbyLeadMs'] as num).toDouble();
    final completion =
        (lifecycle['lastNoteSlowJudgeMs'] as num).toDouble() +
        (lifecycle['completeDelayMs'] as num).toDouble();
    for (var index = plan.ranges.length - 1; index >= 0; index--) {
      final range = plan.ranges[index];
      final fade = range.startTimeMs - lead;
      if (mediaMs < fade) continue;
      final exit = range.endTimeMs + completion;
      final inLength = clips['gekisou_start_in']!;
      final loopLength = clips['gekisou_start_loop']!;
      final outLength = clips['gekisou_start_out']!;
      if (mediaMs >= exit + outLength * 1000) return null;
      final (phase, clip, seconds) = mediaMs < range.startTimeMs
          ? (
              OurNotesGekisouStagePhase.fade,
              'gekisou_start_startfade',
              math.min(
                (mediaMs - fade) / 1000,
                clips['gekisou_start_startfade']!,
              ),
            )
          : mediaMs < range.startTimeMs + inLength * 1000
          ? (
              OurNotesGekisouStagePhase.entrance,
              'gekisou_start_in',
              (mediaMs - range.startTimeMs) / 1000,
            )
          : mediaMs < exit
          ? (
              OurNotesGekisouStagePhase.loop,
              'gekisou_start_loop',
              ((mediaMs - range.startTimeMs) / 1000 - inLength) % loopLength,
            )
          : (
              OurNotesGekisouStagePhase.exit,
              'gekisou_start_out',
              (mediaMs - exit) / 1000,
            );
      return OurNotesGekisouStageFrame(
        rangeIndex: index,
        phase: phase,
        effectSeconds: (mediaMs - fade) / 1000,
        clipName: clip,
        clipSeconds: seconds,
      );
    }
    return null;
  }
}

/// Animator channels are applied to the source component graph. Sprite PPtrs
/// use the clip's mapping; parameter values survive state changes as Animator
/// bindings do, including emission and start-alpha changes during the out clip.
final class _StagePose {
  _StagePose(this.source) {
    for (final row in source.packet['clips'] as List) {
      final data = row as Map;
      clips[data['name'] as String] = NativeAuthoredAnimationClip(
        data['raw'] as Map,
      );
    }
  }
  final ChartGekisouStageSource source;
  final clips = <String, NativeAuthoredAnimationClip>{};
  final active = <String, bool>{};
  final spriteAlpha = <String, double>{};
  final groupAlpha = <String, double>{};
  final spritePointers = <String, Map>{};
  final particleValues = <int, Map<NativeEffectProperty, Float32List>>{};

  void apply(OurNotesGekisouStageFrame frame) {
    final clip = clips[frame.clipName]!;
    final raw =
        (source.packet['clips'] as List).cast<Map>().firstWhere(
              (row) => row['name'] == frame.clipName,
            )['raw']
            as Map;
    final pptr =
        (raw['m_ClipBindingConstant'] as Map)['pptrCurveMapping'] as List;
    for (final sample in clip.sampleBindingsAt(frame.clipSeconds)) {
      final b = sample.binding;
      final transform = source.pathNodes[b['path'] as int];
      if (transform == null) continue;
      final go = source.graph.gameObject(transform);
      final type = b['typeID'], attribute = b['attribute'];
      final values = sample.values;
      if (type == 1 && attribute == 2086281974) {
        active[go.key] = values.single > .5;
      } else if (type == 4 && attribute == 1) {
        transform.data['m_LocalPosition'] = {
          'x': values[0],
          'y': values[1],
          'z': values[2],
        };
      } else if (type == 4 && attribute == 4 && b['customType'] == 4) {
        transform.data['m_LocalRotation'] = _euler(values);
      } else if (type == 212 && attribute == 304273561) {
        spriteAlpha[go.key] = values.single;
      } else if (type == 212 && b['isPPtrCurve'] == 1) {
        spritePointers[go.key] = pptr[values.single.round()] as Map;
      } else if (type == 225 && attribute == 1574349066) {
        groupAlpha[go.key] = values.single;
      } else if (type == 198) {
        final property = switch (attribute) {
          2883525743 => NativeEffectProperty.emissionTimeScalar,
          2007035361 => NativeEffectProperty.startMaxA,
          _ => throw UnsupportedError('gekisou_particle_channel:$attribute'),
        };
        (particleValues[b['path'] as int] ??= {})[property] = values;
      } else if (type == 114 && attribute == 251136292) {
        // GekisouBgMaterialSetter owns the video mask cutoff; it never dims the song background.
        videoMaskVisible = values.single;
      } else {
        throw UnsupportedError(
          'gekisou_stage_animation_channel:$type:$attribute',
        );
      }
    }
  }

  double videoMaskVisible = 0;

  NativeEffectAnimationFrame get particles {
    final frame = NativeEffectAnimationFrame.empty();
    frame.channels.addAll(particleValues);
    return frame;
  }

  bool isActive(NativeEffectObject transform) {
    NativeEffectObject? node = transform;
    while (node != null) {
      final go = source.graph.gameObject(node);
      if (!(active[go.key] ?? go.data['m_IsActive'] == true)) return false;
      node = source.graph.reference(node, node.data['m_Father'] as Map);
    }
    return true;
  }

  double opacity(NativeEffectObject transform) {
    var alpha = 1.0;
    NativeEffectObject? node = transform;
    while (node != null) {
      alpha *= groupAlpha[source.graph.gameObject(node).key] ?? 1;
      node = source.graph.reference(node, node.data['m_Father'] as Map);
    }
    return alpha.clamp(0, 1);
  }

  // Unity uses Z-X-Y Euler order.
  static Map<String, double> _euler(Float32List values) {
    final x = values[0] * math.pi / 360;
    final y = values[1] * math.pi / 360;
    final z = values[2] * math.pi / 360;
    final sx = math.sin(x), cx = math.cos(x);
    final sy = math.sin(y), cy = math.cos(y);
    final sz = math.sin(z), cz = math.cos(z);
    return {
      'x': sx * cy * cz + cx * sy * sz,
      'y': cx * sy * cz - sx * cy * sz,
      'z': cx * cy * sz - sx * sy * cz,
      'w': cx * cy * cz + sx * sy * sz,
    };
  }
}

final class _SubEmitter {
  _SubEmitter(this.system, this.parent, this.parentSystem, this.started);
  final AuthoredParticleSystem system, parentSystem;
  final NativeAuthoredParticle parent;
  final double started;
  Float32List? lastMatrix;
}

/// Owns source stage state, reference reconstruction and pure draw generation.
/// The host supplies media time and projection; no audio, IO or renderer lives here.
final class OurNotesGekisouStage {
  OurNotesGekisouStage(
    this.packet, {
    required this.sourceSha256,
    NativeAuthoredRandom? random,
  }) : random = random ?? NativeAuthoredRandom(1),
       clock = OurNotesGekisouStageClock(packet),
       _assets = ChartGekisouStageSource(packet, sourceSha256: sourceSha256);
  final Map<String, Object?> packet;
  final String sourceSha256;
  final NativeAuthoredRandom random;
  OurNotesGekisouEffectMode get defaultMode =>
      OurNotesGekisouEffectMode.values[int.parse(
        (((packet['defaults'] as Map)['rows'] as List).first
                as Map)['_valueString']
            as String,
      )];
  final OurNotesGekisouStageClock clock;
  final ChartGekisouStageSource _assets;
  Float32List uiClip(double width, double height) {
    final camera = (packet['cameraProfiles'] as Map)['27'] as Map;
    return orthographicClip(
      width,
      height,
      (camera['orthographicSize'] as num).toDouble(),
      (camera['near'] as num).toDouble(),
      (camera['far'] as num).toDouble(),
    );
  }

  Map<String, Map> get textureManifest => _assets.textureManifest;
  Map<String, String> texturePaths(String server) => {
    for (final entry in textureManifest.entries)
      entry.key: _texturePath(entry.value['path'] as String, server),
  };
  static String _texturePath(String path, String server) {
    if (path.startsWith('assets/'))
      return '/assets/$server/${path.substring(7)}';
    if (path.startsWith('runtime/'))
      return '/runtime/$server/${path.substring(8)}';
    throw FormatException('gekisou_stage_texture_path:$path');
  }

  static Float32List orthographicClip(
    double width,
    double height,
    double size,
    double near,
    double far,
  ) => Float32List.fromList([
    1 / (size * width / height),
    0,
    0,
    0,
    0,
    1 / size,
    0,
    0,
    0,
    0,
    1 / (far - near),
    0,
    0,
    0,
    -near / (far - near),
    1,
  ]);

  ChartGekisouStageSource? _source;
  _StagePose? _pose;
  final _systems = <AuthoredParticleSystem>[];
  final _subEmitters = <_SubEmitter>[];
  final _subTargets = <String>{};
  final _matrices = <String, Float32List>{};
  OurNotesGekisouStageFrame? _frame;
  int? _range;
  OurNotesGekisouEffectMode? _mode;
  double _seconds = 0;
  int rebuilds = 0, simulationFrames = 0;
  double get videoMaskVisible => _pose?.videoMaskVisible ?? 0;
  OurNotesGekisouStageFrame? get frame => _frame;
  int get aliveParticles => [
    ..._systems,
    ..._subEmitters.map((value) => value.system),
  ].fold(0, (total, system) => total + system.alive);

  Map<String, Object?> get diagnostic => {
    'range': _range,
    'mode': _mode?.name,
    'phase': _frame?.phase.name,
    'clip': _frame?.clipName,
    'clipSeconds': _frame?.clipSeconds,
    'effectSeconds': _seconds,
    'systems': _systems.length,
    'subEmitters': _subEmitters.length,
    'aliveParticles': aliveParticles,
    'rebuilds': rebuilds,
    'simulationFrames': simulationFrames,
    'videoMaskVisible': videoMaskVisible,
  };

  void clear() {
    _source = null;
    _pose = null;
    _frame = null;
    _range = null;
    _mode = null;
    _systems.clear();
    _subEmitters.clear();
    _matrices.clear();
    _subTargets.clear();
    _seconds = 0;
  }

  void observe({
    required OurNotesGekisouPlan? plan,
    required int mediaUs,
    required OurNotesGekisouEffectMode mode,
    bool lightweight = false,
    bool reset = false,
  }) {
    final next = clock.sample(
      plan,
      mediaUs / 1000,
      mode: mode,
      lightweight: lightweight,
    );
    if (next == null) {
      if (_source != null) clear();
      return;
    }
    final rebuild =
        reset ||
        _range != next.rangeIndex ||
        _mode != mode ||
        next.effectSeconds < _seconds;
    if (rebuild) {
      clear();
      rebuilds++;
      _range = next.rangeIndex;
      _mode = mode;
      final source = ChartGekisouStageSource(
        packet,
        sourceSha256: sourceSha256,
        light: mode == OurNotesGekisouEffectMode.light,
        random: random,
      );
      _source = source;
      _pose = _StagePose(source);
      for (final object in source.systems) {
        final sub = object.data['SubModule'] as Map;
        if (sub['enabled'] == true) {
          for (final entry in sub['subEmitters'] as List) {
            final row = entry as Map;
            if (row['type'] != 0 ||
                row['properties'] != 0 ||
                row['emitProbability'] != 1) {
              throw UnsupportedError(
                'gekisou_subemitter_binding:${object.key}',
              );
            }
            _subTargets.add(
              source.graph.reference(object, row['emitter'] as Map)!.key,
            );
          }
        }
      }
      for (final object in source.systems) {
        if (_subTargets.contains(object.key) ||
            (object.data['EmissionModule'] as Map)['enabled'] != true)
          continue;
        late final AuthoredParticleSystem system;
        system = _newSystem(
          source,
          object,
          onBirth: (particle, matrix) => _spawnChildren(system, particle),
        );
        _systems.add(system);
      }
      // Reference reconstruction uses the actual authored 60 Hz simulation
      // cadence. Live observations preserve their supplied delta.
      const step = 1 / 60;
      while (_seconds + step < next.effectSeconds) {
        final at = _seconds + step;
        final time =
            plan!.ranges[next.rangeIndex].startTimeMs -
            (clock.lifecycle['standbyLeadMs'] as num) +
            at * 1000;
        final sampled = clock.sample(plan, time.toDouble(), mode: mode)!;
        _step(sampled, step);
      }
    }
    _step(next, math.max(0, next.effectSeconds - _seconds));
  }

  AuthoredParticleSystem _newSystem(
    ChartGekisouStageSource source,
    NativeEffectObject object, {
    void Function(NativeAuthoredParticle, Float32List)? onBirth,
  }) {
    final g = packet['globalSettings'] as Map;
    final gravity = g['gravity'] as Map;
    final result = AuthoredParticleSystem(
      source,
      {'metadataUrl': object.path},
      projectGravity: Float64List.fromList([
        for (final axis in ['x', 'y', 'z']) (gravity[axis] as num).toDouble(),
      ]),
      onBirth: onBirth,
      // Formal MobileAddHdrColor consumes position/color/UV.xy only.
      customDataUnusedByMaterial: true,
    );
    result.sourceWidthBound = true;
    return result;
  }

  void _spawnChildren(
    AuthoredParticleSystem parent,
    NativeAuthoredParticle particle,
  ) {
    final source = _source!;
    final module = parent.object.data['SubModule'] as Map;
    if (module['enabled'] != true) return;
    for (final entry in module['subEmitters'] as List) {
      final target = source.graph.reference(
        parent.object,
        (entry as Map)['emitter'] as Map,
      )!;
      final system = _newSystem(source, target);
      _subEmitters.add(
        _SubEmitter(system, particle, parent, particle.birthSeconds),
      );
    }
  }

  void _step(OurNotesGekisouStageFrame next, double delta) {
    final source = _source!, pose = _pose!;
    pose.apply(next);
    final particleFrame = pose.particles;
    for (final system in _systems) {
      final matrix = source.graph.worldMatrix(system.transform);
      _matrices[system.object.key] = matrix;
      final path = _pathHash(source, system.transform);
      system.simulateFrame(
        next.effectSeconds,
        frameDelta: delta,
        pathHash: path,
        nativeWidth: 1,
        activeAt: (_) => pose.isActive(system.transform),
        frameAt: (_) => particleFrame,
        matrixAt: (_) => matrix,
      );
    }
    for (var index = 0; index < _subEmitters.length;) {
      final sub = _subEmitters[index], system = sub.system;
      final parentMatrix = _matrices[sub.parentSystem.object.key]!;
      final matrix = source.graph.worldMatrix(system.transform);
      final world = sub.parentSystem.object.data['moveWithTransform'] == 1;
      final center = world
          ? sub.parent.position
          : AuthoredParticleSystem.point(parentMatrix, sub.parent.position);
      // Birth emitters follow the actual parent particle, without inheriting
      // its color/size/velocity (the source properties flags are zero).
      for (var axis = 0; axis < 3; axis++) {
        matrix[12 + axis] += center[axis] - parentMatrix[12 + axis];
      }
      if (!sub.parent.alive && sub.lastMatrix != null) {
        matrix.setAll(0, sub.lastMatrix!);
      }
      sub.lastMatrix = Float32List.fromList(matrix);
      _matrices['sub:$index'] = matrix;
      system.simulateFrame(
        next.effectSeconds,
        frameDelta: delta,
        activeAge: next.effectSeconds - sub.started,
        pathHash: _pathHash(source, system.transform),
        nativeWidth: 1,
        activeAt: (_) => pose.isActive(system.transform),
        frameAt: (_) => particleFrame,
        matrixAt: (_) => matrix,
      );
      if (!sub.parent.alive && system.alive == 0) {
        _subEmitters.removeAt(index);
      } else {
        index++;
      }
    }
    _seconds = next.effectSeconds;
    _frame = next;
    simulationFrames++;
  }

  static int _pathHash(
    ChartGekisouStageSource source,
    NativeEffectObject node,
  ) => source.pathNodes.entries
      .firstWhere((entry) => entry.value.key == node.key)
      .key;

  List<NativeDraw> appendLayer({
    required int layer,
    required Float32List clipFromWorld,
    required double fieldOfViewRadians,
    required List<double> cameraPosition,
    required double cameraXDegrees,
    required Map<String, GeometryBuffer> meshes,
    required Map<String, NativeMaterial> materials,
  }) {
    final source = _source, pose = _pose;
    if (source == null || pose == null) return const [];
    final draws = <(int, int, NativeDraw)>[];
    void appendSystem(
      AuthoredParticleSystem system,
      Float32List matrix,
      int ordinal,
    ) {
      if (source.graph.gameObject(system.object).data['m_Layer'] != layer)
        return;
      final mesh = system.buildMesh(
        matrix: matrix,
        nativeWidth: 1,
        clipFromWorld: clipFromWorld,
        fieldOfViewRadians: fieldOfViewRadians,
        cameraPosition: cameraPosition,
        cameraXDegrees: cameraXDegrees,
      );
      if (mesh == null) return;
      final key = 'geki-stage:$_range:ps:$ordinal:${system.object.key}';
      meshes[key] = mesh;
      materials[key] = NativeMaterial(
        texture: system.texture,
        recipe: NativeMaterialRecipe.mobileHdr,
        textureAlpha: NativeTextureAlpha.straight,
        blend: NativeBlend.sourceAlphaAdditive,
      );
      draws.add((
        system.spec.sortingOrder,
        ordinal,
        NativeDraw(mesh: key, material: key),
      ));
    }

    for (final (index, system) in _systems.indexed) {
      appendSystem(system, _matrices[system.object.key]!, index);
    }
    for (final (index, sub) in _subEmitters.indexed) {
      if (sub.lastMatrix case final matrix?)
        appendSystem(sub.system, matrix, index + _systems.length);
    }
    for (final (ordinal, renderer) in source.sprites.indexed) {
      final go = source.graph.gameObject(renderer),
          transform = source.graph.transform(renderer);
      if (go.data['m_Layer'] != layer ||
          renderer.data['m_Enabled'] != true ||
          !pose.isActive(transform))
        continue;
      final sprite = source.graph.reference(
        renderer,
        pose.spritePointers[go.key] ?? renderer.data['m_Sprite'] as Map,
      );
      if (sprite == null) continue;
      final raw = renderer.data['m_Color'] as Map;
      final color = Float32List.fromList([
        (raw['r'] as num).toDouble(),
        (raw['g'] as num).toDouble(),
        (raw['b'] as num).toDouble(),
        (pose.spriteAlpha[go.key] ?? (raw['a'] as num).toDouble()) *
            pose.opacity(transform),
      ]);
      if (color[3] <= 0) continue;
      final textureObject = source.graph.reference(
        sprite,
        (sprite.data['m_RD'] as Map)['texture'] as Map,
      )!;
      final texture = source.textureIdentityKeys[textureObject.key]!;
      final shape = source.graph.spriteGeometry(
        sprite,
        textureSize: source.textureSize(texture),
      );
      final positions = Float32List.fromList(shape.positions);
      for (var vertex = 0; vertex < positions.length ~/ 3; vertex++) {
        if (renderer.data['m_FlipX'] == true) positions[vertex * 3] *= -1;
        if (renderer.data['m_FlipY'] == true) positions[vertex * 3 + 1] *= -1;
      }
      final material = source.graph.reference(
        renderer,
        (renderer.data['m_Materials'] as List).single as Map,
      )!;
      final shaderPointer = material.data['m_Shader'] as Map;
      final reference = shaderPointer['reference'] as Map?;
      final shaderName =
          reference?['name'] ??
          (source.graph.reference(material, shaderPointer)!.data['m_ParsedForm']
              as Map)['m_Name'];
      final NativeMaterialRecipe recipe;
      final NativeBlend blend;
      final Float32List tint;
      if (shaderName == 'Custom/Mobile/MobileAddHdrColor') {
        recipe = NativeMaterialRecipe.mobileHdr;
        blend = NativeBlend.sourceAlphaAdditive;
        tint = NativeMobileHdrMaterial(material).hdrVertexColor(color);
      } else if (shaderName ==
          'Universal Render Pipeline/2D/Sprite-Unlit-Default') {
        final properties = material.data['m_SavedProperties'] as Map;
        final colors = (properties['m_Colors'] as List).cast<List>();
        final base =
            colors.singleWhere((entry) => entry.first == '_Color').last as Map;
        recipe = NativeMaterialRecipe.textured;
        blend = NativeBlend.premultipliedAlpha;
        tint = Float32List.fromList([
          for (var channel = 0; channel < 4; channel++)
            color[channel] * (base[['r', 'g', 'b', 'a'][channel]] as num),
        ]);
      } else {
        throw UnsupportedError('gekisou_source_sprite_shader:$shaderName');
      }
      final key = 'geki-stage:$_range:sprite:${renderer.key}';
      meshes[key] = projectSprite(
        NativeSpriteGeometry(
          positions: positions,
          uv: shape.uv,
          indices: shape.indices,
        ),
        NativeAuthoredEffectGraph.multiply(
          clipFromWorld,
          source.graph.worldMatrix(transform),
        ),
        tint,
      );
      materials[key] = NativeMaterial(
        texture: texture,
        recipe: recipe,
        textureAlpha: NativeTextureAlpha.straight,
        blend: blend,
      );
      draws.add((
        renderer.data['m_SortingOrder'] as int,
        ordinal + _systems.length + _subEmitters.length,
        NativeDraw(mesh: key, material: key),
      ));
    }
    draws.sort((a, b) {
      final order = a.$1.compareTo(b.$1);
      return order == 0 ? a.$2.compareTo(b.$2) : order;
    });
    return [for (final draw in draws) draw.$3];
  }
}
