import 'dart:math' as math;
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

import 'chart_intro_canvas.dart';
import 'chart_intro_scene.dart';
import 'chart_intro_source.dart';
import 'chart_intro_timeline.dart';
import 'chart_intro_types.dart';

export 'chart_intro_types.dart';

/// Pre-music presentation of the original Director. The application supplies
/// one intro clock, current UI locale, resource IO and the actual render camera.
final class OurNotesIntroProjector {
  OurNotesIntroProjector(
    this.packet, {
    required int bandId,
    required SourceSdfFontBank fontBank,
    NativeAuthoredRandom? random,
  }) : source = OurNotesIntroSource(packet, bandId: bandId, random: random) {
    if (packet['schema'] != 'our-notes-intro-source-v1')
      throw const FormatException('intro_source_schema');
    timeline = OurNotesIntroTimeline(packet, source.band);
    scene = OurNotesIntroScene(source);
    canvas = OurNotesIntroCanvas(packet, fontBank);
    final lane = source.graph.objects.values.singleWhere(
      (v) =>
          v.type == 'MonoBehaviour' &&
          v.data.containsKey('_tapAreaFadeInDuration'),
    );
    tapFadeDuration = (lane.data['_tapAreaFadeInDuration'] as num).toDouble();
    tapFadeEase = lane.data['_tapAreaFadeInEase'] as int;
    if (tapFadeEase != 2)
      throw UnsupportedError('intro_tap_fade_ease:$tapFadeEase');
    _newSystems();
    _values = timeline.sample(0);
    scene.apply(_values);
    _laneVisible = _sourceLaneVisible(_values);
  }
  final Map<String, Object?> packet;
  final OurNotesIntroSource source;
  late final OurNotesIntroTimeline timeline;
  late final OurNotesIntroScene scene;
  late final OurNotesIntroCanvas canvas;
  late final double tapFadeDuration;
  late final int tapFadeEase;
  final _systems = <AuthoredParticleSystem>[];
  double _evaluated = 0, _requested = 0;
  bool _laneVisible = true;
  double? _laneShownAt;
  List<OurNotesIntroTimelineValue> _values = const [];
  double get durationSeconds => timeline.durationSeconds;
  bool supports({required String server, required String sourceId}) =>
      packet['server'] == server && packet['sourceId'] == sourceId;
  Map<String, Map> get fontMetadataPaths => {
    for (final e in (packet['fontMetadata'] as Map).entries)
      e.key as String: Map.from(e.value as Map),
  };
  Map<String, String> independentTexturePaths(
    String server, {
    Map<String, Object?> canonicalSong = const {},
    int? difficulty,
    String locale = 'ja',
  }) {
    final needed = canvas.requiredFontTextureKeys(
      canonicalSong,
      difficulty ?? 0,
      locale,
    );
    return {
      for (final e in fontMetadataPaths.entries)
        for (final (page, path) in (e.value['atlases'] as List).indexed)
          if (needed.contains('intro:font:${e.key}:$page'))
            'intro:font:${e.key}:$page': 'asset:$path',
    };
  }

  Map<String, String> straightTexturePaths(String server) => {
    for (final e in (packet['textures'] as Map).entries)
      e.key as String: _path(server, (e.value as Map)['path'] as String),
  };
  Map<String, String> texturePaths(
    String server, {
    Map<String, Object?> canonicalSong = const {},
    int? difficulty,
    String locale = 'ja',
  }) => {
    for (final e in (packet['textures'] as Map).entries)
      e.key as String: _path(server, (e.value as Map)['path'] as String),
    for (final e in canvas.texturePaths().entries)
      e.key: _path(server, e.value),
    if (canonicalSong['jacketUrl'] is String)
      'intro:jacket': canonicalSong['jacketUrl'] as String,
    ...independentTexturePaths(
      server,
      canonicalSong: canonicalSong,
      difficulty: difficulty,
      locale: locale,
    ),
  };
  static String _path(String server, String path) => path.startsWith('assets/')
      ? '/assets/$server/${path.substring(7)}'
      : path.startsWith('runtime/')
      ? '/runtime/$server/${path.substring(8)}'
      : path;

  void _newSystems() {
    _systems.clear();
    for (final object in source.local.where(
      (v) => v.type == 'ParticleSystem',
    )) {
      final system = AuthoredParticleSystem(source, {
        'metadataUrl': object.path,
      }, noise: AuthoredParticleNoise(object.data['NoiseModule'] as Map));
      system.sourceWidthBound = true;
      _systems.add(system);
    }
  }

  bool _sourceLaneVisible(List<OurNotesIntroTimelineValue> values) {
    var result = true;
    for (final value in values.where(
      (v) =>
          v.target == 'LiveGameViewTrack' &&
          v.type == 1 &&
          v.path == nativeEffectPathHash('LiveGameLane') &&
          v.attribute == 2086281974,
    ))
      result = value.values.single >= .5;
    return result;
  }

  void _step(double seconds, double delta) {
    final values = timeline.sample(seconds);
    scene.apply(values);
    final visible = _sourceLaneVisible(values);
    if (visible && !_laneVisible) _laneShownAt = seconds;
    if (!visible) _laneShownAt = null;
    _laneVisible = visible;
    final particleFrame = NativeEffectAnimationFrame.empty();
    for (final system in _systems) {
      final matrix = source.graph.worldMatrix(system.transform);
      system.simulateFrame(
        seconds,
        frameDelta: delta,
        pathHash: nativeEffectPathHash(
          source.graph.relativePath(system.transform, source.root),
        ),
        nativeWidth: 1,
        activeAt: (_) => scene.isActive(system.transform),
        frameAt: (_) => particleFrame,
        matrixAt: (_) => matrix,
      );
    }
    _values = values;
    _evaluated = seconds;
  }

  OurNotesIntroFrame sample(
    double elapsedSeconds,
    OurNotesIntroViewport viewport, {
    required Map<String, Object?> canonicalSong,
    required int difficulty,
    required String locale,
    required String liveMode,
    bool isLightweightMode = false,
    bool bypass = false,
  }) {
    final seconds = (bypass ? durationSeconds : elapsedSeconds)
        .clamp(0, durationSeconds)
        .toDouble();
    if (seconds < _requested) {
      _evaluated = 0;
      _laneVisible = true;
      _laneShownAt = null;
      _newSystems();
      _values = timeline.sample(0);
      scene.apply(_values);
      _laneVisible = _sourceLaneVisible(_values);
    }
    _requested = seconds;
    if (bypass) {
      _values = timeline.sample(durationSeconds);
      scene.apply(_values);
      _laneVisible = _sourceLaneVisible(_values);
      _laneShownAt = null;
      _evaluated = durationSeconds;
    } else {
      const tick = 1 / 60;
      while (_evaluated + tick <= seconds) _step(_evaluated + tick, tick);
      if (seconds >= durationSeconds && _evaluated < durationSeconds)
        _step(durationSeconds, 0);
    }
    final meshes = <String, ProjectedMesh>{},
        materials = <String, NativeMaterial>{};
    final clip = Float32List.fromList(viewport.worldToClip);
    final gameDraws = scene.draw(25, clip, meshes, materials),
        effectDraws = scene.draw(29, clip, meshes, materials);
    if (!bypass) {
      final particleDraws = <({int order, int ordinal, NativeDraw draw})>[];
      for (final (ordinal, system) in _systems.indexed) {
        final mesh = system.buildMesh(
          matrix: source.graph.worldMatrix(system.transform),
          nativeWidth: 1,
          clipFromWorld: clip,
          fieldOfViewRadians: viewport.fieldOfViewRadians,
          cameraPosition: viewport.cameraPosition,
          cameraXDegrees: viewport.cameraXDegrees,
        );
        if (mesh == null) continue;
        final key = 'intro:particle:${system.object.key}';
        meshes[key] = mesh;
        materials[key] = NativeMaterial(
          texture: system.texture,
          recipe: NativeMaterialRecipe.mobileHdr,
          textureAlpha: NativeTextureAlpha.straight,
          blend: NativeBlend.sourceAlphaAdditive,
        );
        particleDraws.add((
          order: system.spec.sortingOrder,
          ordinal: ordinal,
          draw: NativeDraw(mesh: key, material: key),
        ));
      }
      particleDraws.sort((a, b) {
        final order = a.order.compareTo(b.order);
        return order == 0 ? a.ordinal.compareTo(b.ordinal) : order;
      });
      effectDraws.addAll(particleDraws.map((v) => v.draw));
    }
    final draws = canvas.draw(
      viewport: viewport,
      song: canonicalSong,
      difficulty: difficulty,
      locale: locale,
      liveMode: liveMode,
        isLightweightMode: isLightweightMode,
      timeline: _values,
      meshes: meshes,
      materials: materials,
    );
    final backgroundScale = <double>[1, 1, 1];
    for (final value in _values.where(
      (v) =>
          v.target == 'LightWeightBackgroundStageTrack' &&
          v.type == 4 &&
          v.path == 0 &&
          v.attribute == 3,
    ))
      for (var axis = 0; axis < 3; axis++)
        backgroundScale[axis] = value.values[axis];
    final tapTime = _laneShownAt == null
        ? 1.0
        : ((_evaluated - _laneShownAt!) / tapFadeDuration).clamp(0, 1);
    return OurNotesIntroFrame(
      elapsedSeconds: seconds,
      durationSeconds: durationSeconds,
      complete: seconds >= durationSeconds,
      gameLaneVisible: _laneVisible,
      tapAlpha: !_laneVisible ? 0 : 1 - math.cos(tapTime * math.pi / 2),
      backgroundScale: backgroundScale,
      meshes: meshes,
      materials: materials,
      gameDraws: gameDraws,
      effectDraws: effectDraws,
      draws: draws,
      voiceCues: timeline.advanceSignals(_evaluated, bypass: bypass),
    );
  }

  Map<String, Object?> get diagnostic => {
    'elapsedSeconds': _evaluated,
    'durationSeconds': durationSeconds,
    'systems': _systems.length,
    'aliveParticles': _systems.fold<int>(0, (sum, s) => sum + s.alive),
    'missingGlyphs': canvas.missingGlyphs.toList(),
  };
}
