import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

import 'chart_intro_source.dart';
import 'chart_intro_timeline.dart';

final class OurNotesIntroScene {
  OurNotesIntroScene(this.source) {
    for (final node in source.local.where((v) => v.type == 'Transform')) {
      initial[node.key] = {
        for (final field in [
          'm_LocalPosition',
          'm_LocalRotation',
          'm_LocalScale',
        ])
          field: Map.of(node.data[field] as Map),
      };
      active[source.graph.gameObject(node).key] =
          source.graph.gameObject(node).data['m_IsActive'] == true;
    }
    sprites = source.local.where((v) => v.type == 'SpriteRenderer').toList();
    skins = source.local.where((v) => v.type == 'SkinnedMeshRenderer').toList();
    for (final renderer in skins) {
      final mesh = source.graph.reference(
        renderer,
        renderer.data['m_Mesh'] as Map,
      )!;
      skinMeshes[renderer.key] = AuthoredSkinnedMesh(
        Map<String, Object?>.from(mesh.data),
      );
    }
  }
  final OurNotesIntroSource source;
  final initial = <String, Map>{};
  final active = <String, bool>{};
  final spriteColors = <String, Float32List>{};
  final materialColors = <String, Float32List>{};
  final skinMeshes = <String, AuthoredSkinnedMesh>{};
  late final List<NativeEffectObject> sprites, skins;
  final _shapeCache = <String, NativeSpriteGeometry>{};

  void apply(List<OurNotesIntroTimelineValue> values) {
    for (final entry in initial.entries) {
      final target = source.graph.objects[entry.key]!;
      for (final field in entry.value.keys)
        target.data[field] = Map.of(entry.value[field] as Map);
      final go = source.graph.gameObject(target);
      active[go.key] = go.data['m_IsActive'] == true;
    }
    spriteColors.clear();
    materialColors.clear();
    final colorAttributes = [
      for (final channel in ['r', 'g', 'b', 'a'])
        nativeEffectPathHash('m_Color.$channel'),
    ];
    final tintAttributes = [
      for (var channel = 0; channel < 4; channel++)
        (nativeEffectPathHash('_TintColor') & 0x0fffffff) |
            ((channel + 4) << 28),
    ];
    for (final value in values.where((v) => v.target == 'LiveGameLaneEffect')) {
      final target = source.paths[value.path];
      if (target == null) continue;
      if (value.type == 4 && [1, 2, 3].contains(value.attribute)) {
        final field = {
          1: 'm_LocalPosition',
          2: 'm_LocalRotation',
          3: 'm_LocalScale',
        }[value.attribute]!;
        final row = target.data[field] as Map;
        for (var i = 0; i < value.values.length; i++)
          row[['x', 'y', 'z', 'w'][i]] = value.values[i];
      } else if (value.type == 1 && value.attribute == 2086281974) {
        active[source.graph.gameObject(target).key] = value.values.single >= .5;
      } else if (value.type == 212 &&
          colorAttributes.contains(value.attribute)) {
        final renderer = source.graph
            .selectedComponents(
              source.graph.gameObject(target),
              type: 'SpriteRenderer',
            )
            .single;
        final raw = renderer.data['m_Color'] as Map;
        final color = spriteColors.putIfAbsent(
          target.key,
          () => Float32List.fromList([
            for (final c in ['r', 'g', 'b', 'a']) (raw[c] as num).toDouble(),
          ]),
        );
        color[colorAttributes.indexOf(value.attribute)] = value.values.single;
      } else if (value.type == 137 &&
          tintAttributes.contains(value.attribute)) {
        final color = materialColors.putIfAbsent(
          target.key,
          () => Float32List.fromList([1, 1, 1, 1]),
        );
        color[tintAttributes.indexOf(value.attribute)] = value.values.single;
      } else {
        throw UnsupportedError(
          'intro_scene_binding:${value.type}:${value.attribute}',
        );
      }
    }
  }

  bool isActive(NativeEffectObject transform) {
    NativeEffectObject? node = transform;
    while (node != null) {
      if (!(active[source.graph.gameObject(node).key] ??
          source.graph.gameObject(node).data['m_IsActive'] == true))
        return false;
      node = source.graph.reference(node, node.data['m_Father'] as Map);
    }
    return true;
  }

  List<NativeDraw> draw(
    int layer,
    Float32List clip,
    Map<String, ProjectedMesh> meshes,
    Map<String, NativeMaterial> materials,
  ) {
    final output = <({int group, int order, int ordinal, NativeDraw draw})>[];
    for (final (ordinal, renderer) in [...sprites, ...skins].indexed) {
      if (renderer.data['m_Enabled'] != true) continue;
      final go = source.graph.gameObject(renderer),
          transform = source.graph.transform(renderer);
      if (go.data['m_Layer'] != layer || !isActive(transform)) continue;
      final material = source.graph.reference(
        renderer,
        (renderer.data['m_Materials'] as List).single as Map,
      )!;
      final shader =
          ((material.data['m_Shader'] as Map)['reference'] as Map)['name'];
      final isHdr = shader == 'Custom/Mobile/MobileAddHdrColor';
      final raw = renderer.data['m_Color'] as Map?;
      final sourceColor =
          spriteColors[transform.key] ??
          Float32List.fromList([
            for (final c in ['r', 'g', 'b', 'a'])
              raw == null ? 1 : (raw[c] as num).toDouble(),
          ]);
      final hdr = isHdr ? NativeMobileHdrMaterial(material) : null;
      final color =
          hdr?.hdrVertexColor(
            sourceColor,
            authoredTintOverride: materialColors[transform.key],
          ) ??
          sourceColor;
      if (color[3] <= 0) continue;
      NativeSpriteGeometry shape;
      String texture;
      Float32List localClip;
      if (renderer.type == 'SkinnedMeshRenderer') {
        shape = skinMeshes[renderer.key]!.pose([
          for (final pointer in renderer.data['m_Bones'] as List)
            source.graph.worldMatrix(
              source.graph.reference(renderer, pointer as Map)!,
            ),
        ]);
        texture = source.materialTextureKeys[material.key]!;
        localClip = clip;
      } else {
        final sprite = source.graph.reference(
          renderer,
          renderer.data['m_Sprite'] as Map,
        )!;
        final tex = source.graph.reference(
          sprite,
          (sprite.data['m_RD'] as Map)['texture'] as Map,
        )!;
        texture = tex.key;
        final width = tex.data['m_Width'] as int,
            height = tex.data['m_Height'] as int;
        final size = renderer.data['m_Size'] as Map;
        final shapeKey = '${sprite.key}:${renderer.data['m_DrawMode']}:$size';
        shape = _shapeCache.putIfAbsent(
          shapeKey,
          () => renderer.data['m_DrawMode'] == 1
              ? nativeAuthoredSlicedSprite(
                  sprite.data,
                  width: (size['x'] as num).toDouble(),
                  height: (size['y'] as num).toDouble(),
                  textureWidth: width,
                  textureHeight: height,
                )
              : source.graph.spriteGeometry(
                  sprite,
                  textureSize: (width, height),
                ),
        );
        if (renderer.data['m_FlipX'] == true ||
            renderer.data['m_FlipY'] == true) {
          final positions = Float32List.fromList(shape.positions);
          for (var i = 0; i < positions.length; i += 3) {
            if (renderer.data['m_FlipX'] == true) positions[i] *= -1;
            if (renderer.data['m_FlipY'] == true) positions[i + 1] *= -1;
          }
          shape = NativeSpriteGeometry(
            positions: positions,
            uv: shape.uv,
            indices: shape.indices,
          );
        }
        localClip = NativeAuthoredEffectGraph.multiply(
          clip,
          source.graph.worldMatrix(transform),
        );
      }
      if (hdr != null) {
        final uv = Float32List.fromList(shape.uv), t = hdr.textureTransform;
        for (var i = 0; i < uv.length; i += 2) {
          uv[i] = uv[i] * t[0] + t[2];
          uv[i + 1] = 1 - ((1 - uv[i + 1]) * t[1] + t[3]);
        }
        shape = NativeSpriteGeometry(
          positions: shape.positions,
          uv: uv,
          indices: shape.indices,
        );
      }
      final key = 'intro:${renderer.key}';
      meshes[key] = projectSprite(shape, localClip, color);
      materials[key] = NativeMaterial(
        texture: texture,
        recipe: isHdr
            ? NativeMaterialRecipe.mobileHdr
            : NativeMaterialRecipe.textured,
        textureAlpha: NativeTextureAlpha.straight,
        blend: isHdr
            ? NativeBlend.sourceAlphaAdditive
            : NativeBlend.premultipliedAlpha,
      );
      var group = 0;
      NativeEffectObject? ancestor = transform;
      while (ancestor != null) {
        final groups = source.graph.selectedComponents(
          source.graph.gameObject(ancestor),
          type: 'SortingGroup',
        );
        if (groups.isNotEmpty) {
          group = groups.single.data['m_SortingOrder'] as int;
          break;
        }
        ancestor = source.graph.reference(
          ancestor,
          ancestor.data['m_Father'] as Map,
        );
      }
      output.add((
        group: group,
        order: renderer.data['m_SortingOrder'] as int,
        ordinal: ordinal,
        draw: NativeDraw(mesh: key, material: key),
      ));
    }
    output.sort((a, b) {
      final group = a.group.compareTo(b.group);
      if (group != 0) return group;
      final order = a.order.compareTo(b.order);
      return order != 0 ? order : a.ordinal.compareTo(b.ordinal);
    });
    return [for (final row in output) row.draw];
  }
}
