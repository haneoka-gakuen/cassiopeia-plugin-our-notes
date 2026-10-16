import 'package:haneoka_render_profile/core.dart';

/// Identity-preserving view of one original band prefab and its shared resources.
final class OurNotesIntroSource implements AuthoredParticleSource {
  OurNotesIntroSource(
    this.packet, {
    required int bandId,
    NativeAuthoredRandom? random,
  }) : random = random ?? NativeAuthoredRandom(1) {
    final bands = packet['bands'] as Map;
    band = (bands['$bandId'] ?? bands['0']) as Map;
    owner = band['serializedFile'] as String;
    final input = packet['records'] as Map;
    Object? copy(Object? value, String file) {
      if (value is List) return [for (final row in value) copy(row, file)];
      if (value is! Map) return value;
      final row = <String, Object?>{
        for (final e in value.entries) e.key as String: copy(e.value, file),
      };
      if (row['m_PathID'] is String &&
          row['m_PathID'] != '0' &&
          row['m_FileID'] != 0 &&
          (row['reference'] as Map?)?['status'] != 'resolved') {
        final candidates =
            (packet['externalPreloads'] as Map)['$file:${row['m_PathID']}']
                as List?;
        if (candidates?.length == 1) {
          final target =
              (input['${candidates!.single}:${row['m_PathID']}']
                      as Map?)?['record']
                  as Map?;
          if (target != null)
            row['reference'] = {
              'status': 'resolved',
              'serializedFile': target['serializedFile'],
              'pathId': target['pathId'],
              'type': target['type'],
              'name': (target['data'] as Map)['m_Name'],
            };
        }
      }
      return row;
    }

    final rows = <String, Map>{};
    for (final e in input.entries) {
      final wrapper = Map<String, Object?>.from(e.value as Map);
      final raw = wrapper['record'] as Map;
      final record = copy(raw, raw['serializedFile'] as String) as Map;
      final shader = record['nativeShader'];
      if (shader is Map && record['type'] == 'Material') {
        ((record['data'] as Map)['m_Shader'] as Map)['reference'] = {
          'status': 'resolved',
          ...shader,
        };
      }
      rows[e.key as String] = {...wrapper, 'record': record};
    }
    graph = NativeAuthoredEffectGraph({
      'schema': 'haneoka-native-fx-shared-render-data-v1',
      'objects': rows,
    });
    final materials = <String, NativeEffectObject>{};
    for (final renderer in local.where(
      (object) => object.data['m_Materials'] is List,
    )) {
      for (final pointer in renderer.data['m_Materials'] as List) {
        final material = graph.reference(renderer, pointer as Map)!;
        materials[material.key] = material;
      }
    }
    for (final object in materials.values) {
      final envs =
          ((object.data['m_SavedProperties'] as Map)['m_TexEnvs'] as List)
              .cast<List>();
      final main = envs.where((v) => v[0] == '_MainTex').firstOrNull;
      if (main == null) continue;
      final p = (main[1] as Map)['m_Texture'] as Map;
      if (p['m_PathID'] == '0') continue;
      final texture = graph.reference(object, p)!;
      materialTextureKeys[object.key] = texture.key;
    }
    final animators = local.where((v) => v.type == 'Animator').toList();
    animator = animators.single;
    root = graph.transform(animator);
    for (final transform in graph.descendants(root)) {
      paths[nativeEffectPathHash(graph.relativePath(transform, root))] =
          transform;
    }
  }
  final Map<String, Object?> packet;
  final NativeAuthoredRandom random;
  late final Map band;
  late final String owner;
  late final NativeEffectObject animator, root;
  @override
  late final NativeAuthoredEffectGraph graph;
  @override
  final materialTextureKeys = <String, String>{};
  final paths = <int, NativeEffectObject>{};
  Iterable<NativeEffectObject> get local =>
      graph.objects.values.where((v) => v.serializedFile == owner);
  @override
  NativeEffectObject component(String path) => graph.paths[path]!;
  @override
  NativeAuthoredRandom randomFor(NativeEffectObject system) => random;
}
