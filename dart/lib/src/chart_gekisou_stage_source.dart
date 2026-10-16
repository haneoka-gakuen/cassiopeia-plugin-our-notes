import 'package:haneoka_render_profile/core.dart';

/// Source packet to the common authored-particle graph. Hosts verify the packet
/// hash and provide texture bytes; this adapter owns numeric resources only.
final class ChartGekisouStageSource implements AuthoredParticleSource {
  ChartGekisouStageSource(
    this.packet, {
    required this.sourceSha256,
    bool light = false,
    NativeAuthoredRandom? random,
  }) : _random = random ?? NativeAuthoredRandom(1) {
    if (packet['schema'] != 'ournotes-gekisou-effect-profile-v1' ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sourceSha256)) {
      throw const FormatException('chart_gekisou_stage_source');
    }
    profile = (packet['profiles'] as Map)[light ? 'light' : 'standard'] as Map;
    owner = profile['owner'] as String;
    final records = <String, Map>{};
    void add(String file, String id, String type, Map data) {
      final key = '$file:$id';
      final existing = records[key];
      if (existing != null) {
        if (existing['type'] != type || !_sameValue(existing['data'], data)) {
          throw StateError('chart_gekisou_source_conflict:$key');
        }
        return;
      }
      records[key] = {
        'record': 'object',
        'serializedFile': file,
        'pathId': id,
        'type': type,
        'data': data,
      };
    }

    for (final raw in profile['nodes'] as List) {
      final node = raw as Map;
      add(
        owner,
        node['id'] as String,
        'GameObject',
        node['rawGameObject'] as Map,
      );
      add(
        owner,
        node['transformId'] as String,
        'Transform',
        node['rawTransform'] as Map,
      );
    }
    for (final raw in profile['systems'] as List) {
      final system = raw as Map;
      add(
        owner,
        system['id'] as String,
        'ParticleSystem',
        system['raw'] as Map,
      );
    }
    for (final raw in profile['components'] as List) {
      final component = raw as Map;
      if (component['type'] == 'AssetBundle') continue;
      add(
        component['serializedFile'] as String,
        component['pathId'] as String,
        component['type'] as String,
        component['data'] as Map,
      );
    }
    for (final raw in packet['resources'] as List) {
      final resource = raw as Map, key = resource['key'] as String;
      final separator = key.lastIndexOf(':');
      add(
        key.substring(0, separator),
        key.substring(separator + 1),
        resource['type'] as String,
        resource['raw'] as Map,
      );
    }

    Object? copy(Object? value, String file) {
      if (value is List) return [for (final child in value) copy(child, file)];
      if (value is! Map) return value;
      final result = <String, Object?>{
        for (final entry in value.entries)
          entry.key as String: copy(entry.value, file),
      };
      if (result['m_PathID'] is! String ||
          result['m_FileID'] == 0 ||
          result['m_PathID'] == '0') {
        return result;
      }
      final reference = result['reference'] as Map?;
      if (reference?['status'] == 'resolved') return result;
      final id = result['m_PathID'] as String;
      final builtin =
          reference?['externalPath'] == 'Library/unity default resources' &&
          id == '10210';
      final candidates = builtin
          ? <String>['$file:$id']
          : records.keys.where((key) => key.endsWith(':$id')).toList();
      if (candidates.length != 1 || !records.containsKey(candidates.single))
        return result;
      final selected = records[candidates.single]!;
      result['reference'] = <String, Object?>{
        ...?reference?.cast<String, Object?>(),
        'status': 'resolved',
        'serializedFile': selected['serializedFile'],
        'pathId': id,
        'type': selected['type'],
        'name': (selected['data'] as Map)['m_Name'],
      };
      pointerAliases.add({
        'owner': file,
        'pathId': id,
        'target': candidates.single,
        'basis': builtin
            ? 'formal-apk-builtin-resource'
            : 'unique-identity-in-exported-source-closure',
      });
      return result;
    }

    final rows = <String, Map>{};
    for (final entry in records.entries) {
      final row = entry.value;
      rows['geki/${entry.key}'] = {
        'sha256': sourceSha256,
        'normalization': 'pptr-decimal64-v1',
        'record': {
          ...row,
          'data': copy(row['data'], row['serializedFile'] as String),
        },
        'derivedFromPacket': sourceSha256,
      };
    }
    graph = NativeAuthoredEffectGraph({
      'schema': 'haneoka-native-fx-shared-render-data-v1',
      'objects': rows,
    });
    final settings = packet['globalSettings'] as Map;
    final activeColorSpace = settings['activeColorSpace'];
    if (activeColorSpace != null && activeColorSpace != 0) {
      throw UnsupportedError('gekisou_stage_color_space:$activeColorSpace');
    }
    final orderBases = settings['sortingOrderBases'] as Map?;
    if (orderBases != null) {
      for (final component in graph.objects.values) {
        if (component.type != 'MonoBehaviour') continue;
        final script =
            (component.data['m_Script'] as Map?)?['reference'] as Map?;
        final pointerField = switch (script?['name']) {
          'LiveParticleOrderInLayerSetter' => '_particleSystemRenderer',
          'LiveRendererOrderInLayerSetter' => '_renderer',
          'LiveCanvasOrderInLayerSetter' => '_canvas',
          _ => null,
        };
        if (pointerField == null) continue;
        final base = orderBases[component.data['_orderInLayer'].toString()];
        if (base is! int)
          throw FormatException(
            'gekisou_sorting_order_source:${component.key}',
          );
        final target = graph.reference(
          component,
          component.data[pointerField] as Map,
        )!;
        target.data['m_SortingOrder'] =
            base + (component.data['_offset'] as int);
      }
    }
    systems = List.unmodifiable([
      for (final raw in profile['systems'] as List)
        graph.objects['$owner:${(raw as Map)['id']}']!,
    ]);
    sprites = List.unmodifiable(
      graph.objects.values.where(
        (object) =>
            object.serializedFile == owner && object.type == 'SpriteRenderer',
      ),
    );
    final transforms = <String, NativeEffectObject>{
      for (final raw in profile['nodes'] as List)
        (raw as Map)['id'] as String:
            graph.objects['$owner:${raw['transformId']}']!,
    };
    pathNodes = Map.unmodifiable({
      for (final entry in (profile['pathNodes'] as Map).entries)
        int.parse(entry.key as String): transforms[entry.value as String]!,
    });
    for (final raw in packet['resources'] as List) {
      final resource = raw as Map;
      if (resource['type'] != 'Texture2D') continue;
      final key = resource['key'] as String, texture = 'geki:$key';
      final outputs = (resource['outputs'] as List).cast<Map>().where(
        (output) => output['type'] == 'Texture2D',
      );
      if (outputs.length != 1)
        throw StateError('chart_gekisou_texture_output:$key');
      textureManifest[texture] = Map.unmodifiable(outputs.single);
      textureIdentityKeys[key] = texture;
      final data = graph.objects[key]!.data;
      _textureSizes[texture] = (
        data['m_Width'] as int,
        data['m_Height'] as int,
      );
    }
    for (final system in systems) {
      for (final renderer in graph.selectedComponents(
        graph.gameObject(system),
        type: 'ParticleSystemRenderer',
      )) {
        for (final pointer in renderer.data['m_Materials'] as List) {
          final material = graph.reference(renderer, pointer as Map);
          if (material == null) continue;
          final typed = NativeMobileHdrMaterial(material);
          final texture = graph.reference(material, typed.texturePointer)!;
          final textureKey = textureIdentityKeys[texture.key];
          if (textureKey == null)
            throw StateError('chart_gekisou_material_texture:${material.key}');
          materialTextureKeys[material.key] = textureKey;
        }
      }
    }
  }

  final Map packet;
  final String sourceSha256;
  final NativeAuthoredRandom _random;
  late final Map profile;
  late final String owner;
  @override
  late final NativeAuthoredEffectGraph graph;
  late final List<NativeEffectObject> systems, sprites;
  late final Map<int, NativeEffectObject> pathNodes;
  @override
  final materialTextureKeys = <String, String>{};
  final textureManifest = <String, Map>{};
  final textureIdentityKeys = <String, String>{};
  final pointerAliases = <Map<String, String>>[];
  final _textureSizes = <String, (int, int)>{};

  static bool _sameValue(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every(
            (key) => b.containsKey(key) && _sameValue(a[key], b[key]),
          );
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_sameValue(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  (int, int) textureSize(String key) => _textureSizes[key]!;

  @override
  NativeEffectObject component(String path) =>
      graph.paths[path] ??
      graph.objects[path] ??
      (throw StateError('chart_gekisou_component:$path'));

  @override
  NativeAuthoredRandom randomFor(NativeEffectObject system) =>
      system.data['autoRandomSeed'] == true
      ? _random
      : NativeAuthoredRandom(system.data['randomSeed'] as int);
}
