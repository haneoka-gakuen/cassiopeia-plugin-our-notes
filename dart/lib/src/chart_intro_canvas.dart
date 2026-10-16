import 'dart:math' as math;
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

import 'chart_intro_timeline.dart';
import 'chart_intro_types.dart';

final class OurNotesIntroCanvas {
  OurNotesIntroCanvas(this.packet, this.fonts) {
    owner = (packet['titleCanvasOwners'] as List).single as Map;
    file = owner['serializedFile'] as String;
    component = owner['data'] as Map;
    for (final e in (packet['uiRecords'] as Map).entries) {
      final record = (e.value as Map)['record'] as Map;
      records[record['pathId'] as String] = record;
    }
    rootGo = (component['m_GameObject'] as Map)['m_PathID'] as String;
    for (final record in records.values.where(
      (r) => r['type'] == 'RectTransform',
    )) {
      final data = record['data'] as Map;
      final go = (data['m_GameObject'] as Map)['m_PathID'] as String;
      transforms[go] = record;
    }
    root = transforms[rootGo]!['pathId'] as String;
    final animator = _data(_pointer(component['_animator'] as Map));
    final animatorRoot =
        transforms[_pointer(animator['m_GameObject'] as Map)]!['pathId'];
    scaler =
        records.values.singleWhere(
              (v) =>
                  (v['data']['m_Script'] as Map?)?['reference']?['name'] ==
                  'CanvasScaler',
            )['data']
            as Map;
    if (scaler['m_UiScaleMode'] != 1 || scaler['m_ScreenMatchMode'] != 1)
      throw const FormatException('intro_canvas_scaler');
    for (final transform in transforms.values) {
      var node = transform;
      final names = <String>[];
      while (node['pathId'] != animatorRoot && node['pathId'] != root) {
        final go =
            records[((node['data'] as Map)['m_GameObject']
                as Map)['m_PathID']]!;
        names.add((go['data'] as Map)['m_Name'] as String);
        node = records[((node['data'] as Map)['m_Father'] as Map)['m_PathID']]!;
      }
      if (node['pathId'] != animatorRoot) continue;
      paths[nativeEffectPathHash(names.reversed.join('/'))] =
          transform['pathId'] as String;
    }
  }
  final Map<String, Object?> packet;
  final SourceSdfFontBank? fonts;
  late final Map owner, component, scaler;
  late final String file, rootGo, root;
  final records = <String, Map>{}, transforms = <String, Map>{};
  final paths = <int, String>{};
  final missingGlyphs = <int>{};
  final _layoutCache = <String, SourceGlyphLayout>{};
  Map get resources => packet['uiResources'] as Map;
  static String _pointer(Map value) => value['m_PathID'] as String;
  Map _data(String id) => records[id]!['data'] as Map;
  String _componentText(Object? pointer) {
    final data = _data(_pointer(pointer as Map));
    return data.containsKey('_targetText')
        ? _pointer(data['_targetText'] as Map)
        : _pointer(pointer);
  }

  String _spriteKey(Map pointer) =>
      '${(pointer['reference'] as Map?)?['serializedFile'] ?? file}:${pointer['m_PathID']}';
  Map? _spriteOutput(String key) {
    final outputs =
        ((resources[key] as Map?)?['outputs'] as List?)?.cast<Map>() ??
        const <Map>[];
    return outputs
        .where(
          (v) =>
              v['type'] == 'Sprite' && (v['path'] as String).endsWith('.png'),
        )
        .firstOrNull;
  }

  Map<String, String> texturePaths() => {
    for (final entry in resources.entries)
      if (_spriteOutput(entry.key as String) case final output?)
        'intro-ui:${entry.key}': output['path'] as String,
  };
  String _localized(Object? value, String locale) {
    if (value is! List) return value?.toString() ?? '';
    final index = switch (locale) {
      'en' => 1,
      'zh-TW' || 'zh-Hant' => 2,
      'zh-CN' || 'zh-Hans' => 3,
      'ko' => 4,
      _ => 0,
    };
    return (value.elementAtOrNull(index) ?? value.firstOrNull)?.toString() ??
        '';
  }

  List<NativeDraw> draw({
    required OurNotesIntroViewport viewport,
    required Map<String, Object?> song,
    required int difficulty,
    required String locale,
    required String liveMode,
    bool isLightweightMode = false,
    required List<OurNotesIntroTimelineValue> timeline,
    required Map<String, ProjectedMesh> meshes,
    required Map<String, NativeMaterial> materials,
  }) {
    final scale = math.min(
          viewport.width / (scaler['m_ReferenceResolution']['x'] as num),
          viewport.height / (scaler['m_ReferenceResolution']['y'] as num),
        ),
        width = viewport.width / scale,
        height = viewport.height / scale;
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
      0,
      0,
      0,
      0,
      0,
      1,
    ]);
    final groups = <String, double>{};
    for (final value in timeline.where(
      (v) =>
          v.target == 'UILiveStartCanvasTrack' &&
          v.type == 225 &&
          v.attribute == 1574349066,
    )) {
      if (paths[value.path] case final target?)
        groups[target] = value.values.single;
    }
    final overrides = <String, bool>{};
    for (final raw in component['_normalModeOnlyObjects'] as List)
      overrides[_pointer(raw as Map)] = !isLightweightMode;
    for (final raw in component['_simpleModeOnlyObjects'] as List)
      overrides[_pointer(raw as Map)] = isLightweightMode;
    for (final raw in component['_battleLiveGameObjects'] as List)
      overrides[_pointer(raw as Map)] = liveMode == 'gekisou';
    final textValues = _boundText(song, difficulty, locale);
    final imageSprites = <String, Map>{};
    final selectedDifficulty =
        (component['_difficultyPairs'] as List).cast<Map>().singleWhere(
              (v) => v['Difficulty'] == difficulty,
            )['Icon']
            as Map;
    for (final pointer in component['_difficultyImages'] as List)
      imageSprites[_pointer(pointer as Map)] = selectedDifficulty;
    final missions =
        (song['gekisou'] as Map?)?['missionTypes'] as List? ?? const [];
    for (var i = 0; i < (component['_gekisouIcons'] as List).length; i++) {
      final iconId = _pointer((component['_gekisouIcons'] as List)[i] as Map),
          textId = _componentText((component['_gekisouTexts'] as List)[i]);
      final mission = missions.elementAtOrNull(i);
      final selected = (component['_gekisouMissionIconPairs'] as List)
          .cast<Map>()
          .where((v) => v['MissionType'] == mission)
          .firstOrNull;
      if (selected != null) imageSprites[iconId] = selected['Icon'] as Map;
      overrides[_pointer(_data(iconId)['m_GameObject'] as Map)] =
          liveMode == 'gekisou' && selected != null;
      overrides[_pointer(_data(textId)['m_GameObject'] as Map)] =
          liveMode == 'gekisou' && selected != null;
      if (selected != null)
        textValues[textId] = switch (mission) {
          1 => 'COMBO',
          2 => 'LUCK',
          3 => 'JUST',
          _ => '',
        };
    }
    final fittedSizes = <String, List<double>>{};
    final preferredWidths = <String, double>{};
    for (final role in [
      '_lyricistTextSizeFitter',
      '_compositterTextSizeFitter',
    ]) {
      final fitter = _data(_pointer(component[role] as Map));
      final textId = _pointer(fitter['_text'] as Map), raw = _data(textId);
      final measured = _measureText(
        textId,
        raw,
        textValues[textId] ?? raw['m_text'] as String,
        locale,
        double.maxFinite,
        double.maxFinite,
        autoSize: false,
      );
      final maximum = (fitter['_widthMax'] as num).toDouble();
      final target = _pointer(fitter['_rectTransform'] as Map);
      fittedSizes[target] = [
        maximum > 0 ? math.min(maximum, measured.width) : measured.width,
        measured.height,
      ];
      preferredWidths[role] = measured.width;
    }
    final nodes = <NativeCanvasNode>[];
    for (final transform in transforms.values) {
      final data = transform['data'] as Map,
          goId = _pointer(data['m_GameObject'] as Map),
          go = _data(goId),
          id = transform['pathId'] as String;
      final components = (go['m_Component'] as List)
          .cast<Map>()
          .map((v) => records[_pointer(v['component'] as Map)])
          .whereType<Map>();
      final group = components
          .where((v) => v['type'] == 'CanvasGroup')
          .firstOrNull;
      final rawGroup = group?['data'] as Map?;
      List<double> vec(String key, [int count = 2]) => [
        for (final axis in ['x', 'y', 'z', 'w'].take(count))
          (data[key][axis] as num).toDouble(),
      ];
      nodes.add(
        NativeCanvasNode(
          id: id,
          parent: id == root ? null : _pointer(data['m_Father'] as Map),
          active: overrides[goId] ?? go['m_IsActive'] == true,
          anchorMin: id == root ? const [0, 0] : vec('m_AnchorMin'),
          anchorMax: id == root ? const [1, 1] : vec('m_AnchorMax'),
          pivot: vec('m_Pivot'),
          size: id == root
              ? const [0, 0]
              : fittedSizes[id] ?? vec('m_SizeDelta'),
          position: Float32List.fromList([
            ...vec('m_AnchoredPosition'),
            (data['m_LocalPosition']['z'] as num).toDouble(),
          ]),
          localPositionOverride: null,
          rotationQuaternion: Float32List.fromList(vec('m_LocalRotation', 4)),
          scale: Float32List.fromList(
            id == root ? const [1, 1, 1] : vec('m_LocalScale', 3),
          ),
          opacity:
              groups[id] ?? (rawGroup?['m_Alpha'] as num?)?.toDouble() ?? 1,
          ignoreParentGroups: rawGroup?['m_IgnoreParentGroups'] == true,
        ),
      );
    }
    final beforeGroups = placeNativeCanvas(
      nodes: nodes,
      canvasWidth: width,
      canvasHeight: height,
      canvasPivot: const [.5, .5],
      canvasWorld: Float32List.fromList([
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
      ]),
    );
    final areaId = _pointer(component['_lyricisAndCompositterArea'] as Map);
    final expanded =
        preferredWidths.values.reduce((a, b) => a + b) >
        beforeGroups[areaId]!.width;
    for (final role in ['_compositterText', '_compositterText2']) {
      overrides[_pointer(
        _data(_pointer(component[role] as Map))['m_GameObject'] as Map,
      )] = role == '_compositterText2'
          ? expanded
          : !expanded;
    }
    overrides[_pointer(component['_expandBaseLabel'] as Map)] = expanded;
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i],
          goId = _pointer(_data(node.id)['m_GameObject'] as Map);
      final active = overrides[goId];
      if (active == null || active == node.active) continue;
      nodes[i] = NativeCanvasNode(
        id: node.id,
        parent: node.parent,
        active: active,
        anchorMin: node.anchorMin,
        anchorMax: node.anchorMax,
        pivot: node.pivot,
        size: node.size,
        position: node.position,
        localPositionOverride: node.localPositionOverride,
        rotationQuaternion: node.rotationQuaternion,
        scale: node.scale,
        opacity: node.opacity,
        ignoreParentGroups: node.ignoreParentGroups,
      );
    }
    final actualGroups = <String, NativeCanvasLayoutGroup>{};
    final actualElements = <String, NativeCanvasLayoutMetrics>{};
    for (final record in records.values) {
      final raw = record['data'] as Map;
      final script = (raw['m_Script'] as Map?)?['reference']?['name'];
      if (script == 'HorizontalLayoutGroup' ||
          script == 'VerticalLayoutGroup') {
        final id =
            transforms[_pointer(raw['m_GameObject'] as Map)]!['pathId']
                as String;
        actualGroups[id] = NativeCanvasLayoutGroup.fromRaw(raw);
      } else if (script == 'Image') {
        final id =
            transforms[_pointer(raw['m_GameObject'] as Map)]!['pathId']
                as String;
        final spriteKey = _spriteKey(
          imageSprites[record['pathId']] ?? raw['m_Sprite'] as Map,
        );
        final sprite =
            (resources[spriteKey] as Map?)?['record']?['data'] as Map?;
        if (sprite == null) continue;
        final ppu =
            (sprite['m_PixelsToUnits'] as num) /
            (scaler['m_ReferencePixelsPerUnit'] as num);
        final rect = sprite['m_Rect'] as Map,
            border = sprite['m_Border'] as Map;
        final sliced = raw['m_Type'] == 1;
        final minimum = [
          sliced ? ((border['x'] as num) + (border['z'] as num)) / ppu : 0.0,
          sliced ? ((border['y'] as num) + (border['w'] as num)) / ppu : 0.0,
        ];
        actualElements[id] = NativeCanvasLayoutMetrics(
          minimum: minimum,
          preferred: sliced
              ? minimum
              : [(rect['width'] as num) / ppu, (rect['height'] as num) / ppu],
          flexible: const [-1, -1],
        );
      } else if (script == 'TextMeshProUGUI' && fonts != null) {
        final id =
            transforms[_pointer(raw['m_GameObject'] as Map)]!['pathId']
                as String;
        final measured = _measureText(
          record['pathId'] as String,
          raw,
          textValues[record['pathId']] ?? raw['m_text'] as String,
          locale,
          double.maxFinite,
          double.maxFinite,
          autoSize: false,
        );
        actualElements[id] = NativeCanvasLayoutMetrics(
          minimum: const [0, 0],
          preferred: [measured.width, measured.height],
          flexible: const [-1, -1],
        );
      }
    }
    final placements = layoutNativeCanvas(
      groups: actualGroups,
      elements: actualElements,
      nodes: nodes,
      canvasWidth: width,
      canvasHeight: height,
      canvasPivot: const [.5, .5],
      canvasWorld: Float32List.fromList([
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
      ]),
    );
    final result = <NativeDraw>[];
    void walk(String transformId) {
      final transform = records[transformId]!,
          data = transform['data'] as Map,
          go = _data(_pointer(data['m_GameObject'] as Map));
      final placement = placements[transformId]!;
      if (!placement.active || placement.opacity <= 0) return;
      final pivot = data['m_Pivot'] as Map,
          localClip = NativeAuthoredEffectGraph.multiply(
            clip,
            placement.matrix,
          );
      for (final item in go['m_Component'] as List) {
        final id = _pointer((item as Map)['component'] as Map),
            record = records[id]!,
            raw = record['data'] as Map;
        if (raw['m_Enabled'] == 0) continue;
        final script = (raw['m_Script'] as Map?)?['reference'] as Map?;
        if (script?['name'] == 'Image') {
          final pointer = imageSprites[id] ?? raw['m_Sprite'] as Map;
          final spriteKey = _spriteKey(pointer),
              resource = resources[spriteKey] as Map?,
              output = _spriteOutput(spriteKey);
          if (resource == null || output == null) continue;
          final jacket = (component['_jacketImages'] as List).cast<Map>().any(
            (v) => _pointer(v) == id,
          );
          final sprite = (resource['record'] as Map)['data'] as Map;
          final rgba = raw['m_Color'] as Map;
          final color = Float32List.fromList([
            for (final channel in ['r', 'g', 'b'])
              (rgba[channel] as num).toDouble(),
            (rgba['a'] as num).toDouble() * placement.opacity,
          ]);
          var iw = placement.width, ih = placement.height;
          if (raw['m_PreserveAspect'] == 1 || raw['m_PreserveAspect'] == true) {
            final fit = math.min(
              iw / (output['width'] as int),
              ih / (output['height'] as int),
            );
            iw = (output['width'] as int) * fit;
            ih = (output['height'] as int) * fit;
          }
          final x =
                  -placement.width * (pivot['x'] as num) +
                  (placement.width - iw) / 2,
              y =
                  -placement.height * (pivot['y'] as num) +
                  (placement.height - ih) / 2;
          NativeSpriteGeometry shape;
          if (raw['m_Type'] == 1 && !jacket) {
            final rect = sprite['m_Rect'] as Map;
            final adjusted = {
              ...sprite,
              'm_PixelsToUnits':
                  (sprite['m_PixelsToUnits'] as num) /
                  (scaler['m_ReferencePixelsPerUnit'] as num) *
                  ((raw['m_PixelsPerUnitMultiplier'] as num?) ?? 1),
              'm_Pivot': {'x': 0, 'y': 0},
              'm_RD': {
                ...(sprite['m_RD'] as Map),
                'textureRect': {
                  'x': 0,
                  'y': 0,
                  'width': rect['width'],
                  'height': rect['height'],
                },
                'textureRectOffset': {'x': 0, 'y': 0},
              },
            };
            final sliced = nativeAuthoredSlicedSprite(
              adjusted,
              width: iw,
              height: ih,
              textureWidth: output['width'] as int,
              textureHeight: output['height'] as int,
              fillCenter: raw['m_FillCenter'] != 0,
            );
            final positions = Float32List.fromList(sliced.positions);
            for (var i = 0; i < positions.length; i += 3) {
              positions[i] += x;
              positions[i + 1] += y;
            }
            shape = NativeSpriteGeometry(
              positions: positions,
              uv: sliced.uv,
              indices: sliced.indices,
            );
          } else {
            shape = NativeSpriteGeometry(
              positions: Float32List.fromList([
                x,
                y,
                0,
                x + iw,
                y,
                0,
                x,
                y + ih,
                0,
                x + iw,
                y + ih,
                0,
              ]),
              uv: Float32List.fromList([0, 1, 1, 1, 0, 0, 1, 0]),
              indices: Uint16List.fromList([0, 1, 2, 2, 1, 3]),
            );
          }
          final key = 'intro-ui:$id';
          final gradientComponent = (go['m_Component'] as List)
              .cast<Map>()
              .map((v) => records[_pointer(v['component'] as Map)])
              .whereType<Map>()
              .where(
                (v) =>
                    (v['data']['m_Script'] as Map?)?['reference']?['name'] ==
                    'UIGradientImage',
              )
              .firstOrNull;
          meshes[key] = gradientComponent == null
              ? projectSprite(shape, localClip, color)
              : projectNativeCanvasGradient(
                  shape: shape,
                  clip: localClip,
                  source: gradientComponent['data'] as Map,
                  imageColor: [
                    for (final c in ['r', 'g', 'b', 'a'])
                      (rgba[c] as num).toDouble(),
                  ],
                  inheritedOpacity: placement.opacity,
                );
          materials[key] = NativeMaterial(
            texture: jacket && song['jacketUrl'] != null
                ? 'intro:jacket'
                : 'intro-ui:$spriteKey',
            textureAlpha: NativeTextureAlpha.premultiplied,
          );
          result.add(NativeDraw(mesh: key, material: key));
        } else if (script?['name'] == 'TextMeshProUGUI' && fonts != null) {
          result.addAll(
            _drawText(
              id,
              raw,
              textValues[id] ?? raw['m_text'] as String,
              locale,
              placement,
              pivot,
              localClip,
              viewport,
              meshes,
              materials,
            ),
          );
        }
      }
      for (final child in data['m_Children'] as List)
        walk(_pointer(child as Map));
    }

    walk(root);
    return result;
  }

  Map<String, String> _boundText(
    Map<String, Object?> song,
    int difficulty,
    String locale,
  ) {
    final textValues = <String, String>{};
    void assign(String name, String value) =>
        textValues[_componentText(component[name])] = value;
    assign('_musicTitleText', _localized(song['musicTitle'], locale));
    assign('_singerText', _localized(song['bandName'], locale));
    for (final pair in [
      ('_lyricistText', 'lyricist'),
      ('_compositterText', 'composer'),
      ('_compositterText2', 'composer'),
      ('_arrangerText', 'arranger'),
    ]) {
      final id = _componentText(component[pair.$1]),
          raw = _data(id)['m_text'] as String;
      final prefix = raw.contains(':') ? '${raw.split(':').first}: ' : '';
      textValues[id] = '$prefix${_localized(song[pair.$2], locale)}';
    }
    final chart = (song['difficulty'] as List? ?? const [])
        .cast<Map>()
        .where((v) => v['difficulty'] == difficulty)
        .firstOrNull;
    for (final pointer in component['_musicLevelTexts'] as List)
      textValues[_componentText(pointer)] =
          '${chart?['displayLevel'] ?? chart?['playLevel'] ?? ''}';
    for (final pointer in component['_highScoreTexts'] as List)
      textValues[_componentText(pointer)] = '0';
    final missions =
        (song['gekisou'] as Map?)?['missionTypes'] as List? ?? const [];
    for (var i = 0; i < (component['_gekisouTexts'] as List).length; i++) {
      textValues[_componentText(
        (component['_gekisouTexts'] as List)[i],
      )] = switch (missions.elementAtOrNull(i)) {
        1 => 'COMBO',
        2 => 'LUCK',
        3 => 'JUST',
        _ => '',
      };
    }
    return textValues;
  }

  SourceSdfFontBank _fontChain(Map raw, String locale) {
    final sourceFont = (raw['m_fontAsset']['reference']['name'] as String),
        numeric = sourceFont == 'VibeMOPro-Medium SDF';
    final localeId = switch (locale) {
      'zh-CN' || 'zh-TW' || 'zh-Hant' || 'zh-Hans' => 'chinese',
      'ko' => 'korean',
      _ => 'dialogue',
    };
    final order = [if (numeric) 'numeric' else localeId, 'dialogue', 'symbols'];
    final selected = SourceSdfFontBank([
      for (final fid in order.toSet())
        if (fonts!.fonts.where((f) => f.id == fid).firstOrNull case final font?)
          font,
    ]);
    return selected;
  }

  Set<String> requiredFontTextureKeys(
    Map<String, Object?> song,
    int difficulty,
    String locale,
  ) {
    if (fonts == null) return const {};
    final texts = _boundText(song, difficulty, locale), result = <String>{};
    for (final record in records.values) {
      final raw = record['data'] as Map;
      if ((raw['m_Script'] as Map?)?['reference']?['name'] != 'TextMeshProUGUI')
        continue;
      final chain = _fontChain(raw, locale),
          text = _inputText(
            raw,
            texts[record['pathId']] ?? raw['m_text'] as String,
          );
      for (final code in text.runes) {
        final glyph = chain.select(code);
        if (glyph != null)
          result.add('intro:font:${glyph.font.id}:${glyph.glyph.atlasPage}');
      }
    }
    return result;
  }

  ({Map<String, double> floats, Map<String, Map> colors}) _fontMaterial(
    Map raw,
    SourceFontData font,
  ) {
    final resource =
        resources[_spriteKey(raw['m_sharedMaterial'] as Map)] as Map;
    final original = resource['record']['data']['m_SavedProperties'] as Map;
    final floats = {
      for (final row in (original['m_Floats'] as List).cast<List>())
        row[0] as String: (row[1] as num).toDouble(),
    };
    final colors = {
      for (final row in (original['m_Colors'] as List).cast<List>())
        row[0] as String: row[1] as Map,
    };
    final numeric =
        raw['m_fontAsset']['reference']['name'] == 'VibeMOPro-Medium SDF';
    if (font.id != (numeric ? 'numeric' : 'dialogue')) {
      final target =
          (packet['fontMetadata'] as Map)[font.id]['defaultMaterial']['floats']
              as Map;
      for (final field in [
        '_GradientScale',
        '_TextureWidth',
        '_TextureHeight',
        '_WeightNormal',
        '_WeightBold',
      ])
        floats[field] = (target[field] as num).toDouble();
      final gradient = floats['_GradientScale']!,
          weight =
              math.max(floats['_WeightNormal']!, floats['_WeightBold']!) / 4,
          extent = math.max(
            1.0,
            weight +
                floats['_FaceDilate']! +
                floats['_OutlineWidth']! +
                floats['_OutlineSoftness']!,
          );
      floats['_ScaleRatioA'] = (gradient - 1) / (gradient * extent);
    }
    return (floats: floats, colors: colors);
  }

  double _lineSpacing(Map raw, String locale) {
    final go = _data(_pointer(raw['m_GameObject'] as Map));
    for (final pointer in go['m_Component'] as List) {
      final c = _data(_pointer((pointer as Map)['component'] as Map));
      if ((c['m_Script'] as Map?)?['reference']?['name'] == 'LocalizeText' &&
          (c['_localizeEnabled'] == 1 || c['_localizeEnabled'] == true) &&
          (c['m_Enabled'] == 1 || c['m_Enabled'] == true)) {
        final mode = switch (locale) {
          'zh-Hant' => 'zh-TW',
          'zh-Hans' => 'zh-CN',
          _ => locale,
        };
        return (((packet['localeTypography'] as Map)['lineSpacing']
                    as Map)[mode]
                as num)
            .toDouble();
      }
    }
    return (raw['m_lineSpacing'] as num).toDouble();
  }

  final _inputCache = <(String, bool), String>{};
  String _inputText(Map raw, String text) {
    final controls =
        raw['m_parseCtrlCharacters'] == 1 ||
        raw['m_parseCtrlCharacters'] == true;
    return _inputCache.putIfAbsent((
      text,
      controls,
    ), () => decodeSourceTmpInput(text, parseControls: controls));
  }

  SourceGlyphLayout _measureText(
    String id,
    Map raw,
    String text,
    String locale,
    double width,
    double height, {
    bool autoSize = true,
  }) {
    text = _inputText(raw, text);
    final selected = _fontChain(raw, locale);
    final bold = ((raw['m_fontStyle'] as int) & 1) != 0;
    SourceGlyphLayout layout(double size) => layoutSourceGlyphRuns(
      fonts: selected,
      runs: [
        SourceGlyphRun(
          text: text,
          fontSize: size,
          color: const [1, 1, 1, 1],
          bold: bold,
          typingIndices: List.generate(text.runes.length, (i) => i),
        ),
      ],
      letterTestText: text,
      characterSpacing: (raw['m_characterSpacing'] as num).toDouble(),
      lineSpacing: _lineSpacing(raw, locale),
      maxWidth: width,
      actualBreakBeforeIndices: const {},
      actualRenderedGlyphCount: text.runes.length,
      kerning: raw['m_enableKerning'] == 1 || raw['m_enableKerning'] == true,
      paddingResolver: (font, bold) {
        final material = _fontMaterial(raw, font).floats;
        final padding = computeSourceSdfPadding(
          SourceSdfPaddingParameters(
            scaleRatioA: material['_ScaleRatioA']!,
            faceDilate: material['_FaceDilate']!,
            outlineWidth: material['_OutlineWidth']!,
            outlineSoftness: material['_OutlineSoftness']!,
            gradientScale: material['_GradientScale']!,
            style: bold ? font.boldWeight : font.normalWeight,
            extraPadding:
                raw['m_enableExtraPadding'] == 1 ||
                raw['m_enableExtraPadding'] == true,
            underlay: null,
          ),
        );
        return SourceGlyphPadding(
          padding.materialPadding,
          padding.stylePadding,
        );
      },
    );
    final size = (raw['m_fontSize'] as num).toDouble();
    final signature = '$id/$text/$locale/$width/$height/$size/$bold/$autoSize';
    final measured = _layoutCache.putIfAbsent(
      signature,
      () => measureSourceGlyphAutoSize(
        compile: layout,
        size: size,
        autoSize:
            autoSize &&
            (raw['m_enableAutoSizing'] == 1 ||
                raw['m_enableAutoSizing'] == true),
        minimum: (raw['m_fontSizeMin'] as num).toDouble(),
        maximum: (raw['m_fontSizeMax'] as num).toDouble(),
        width: width,
        height: height,
      ),
    );
    return measured;
  }

  List<NativeDraw> _drawText(
    String id,
    Map raw,
    String text,
    String locale,
    NativeCanvasPlacement placement,
    Map pivot,
    Float32List clip,
    OurNotesIntroViewport viewport,
    Map<String, ProjectedMesh> meshes,
    Map<String, NativeMaterial> materials,
  ) {
    final measured = _measureText(
      id,
      raw,
      text,
      locale,
      placement.width,
      placement.height,
    );
    final size = (raw['m_fontSize'] as num).toDouble();
    missingGlyphs.addAll(measured.missingGlyphs);
    final horizontal = raw['m_HorizontalAlignment'] as int,
        vertical = raw['m_VerticalAlignment'] as int;
    final offsetX = horizontal == 2
        ? (placement.width - measured.width) / 2
        : horizontal == 4
        ? placement.width - measured.width
        : 0.0;
    final offsetY = vertical == 512
        ? (placement.height - measured.height) / 2
        : vertical == 1024
        ? placement.height - measured.height
        : 0.0;
    final output = <NativeDraw>[];
    final batches = <String, List<SourceGlyphQuad>>{};
    for (final quad in measured.quads)
      (batches['${quad.fontId}:${quad.atlasPage}'] ??= []).add(quad);
    for (final entry in batches.entries) {
      final first = entry.value.first,
          font = fonts!.fonts.singleWhere((v) => v.id == first.fontId),
          vertices = <double>[],
          uv = <double>[],
          indices = <int>[];
      for (final q in entry.value) {
        final base = vertices.length ~/ 3,
            x = q.rect[0] + offsetX - placement.width * (pivot['x'] as num),
            top =
                placement.height * (1 - (pivot['y'] as num)) -
                q.rect[1] -
                offsetY,
            w = q.rect[2],
            h = q.rect[3],
            u = q.uvTopLeft[0],
            v = q.uvTopLeft[1],
            uw = q.uvTopLeft[2],
            vh = q.uvTopLeft[3];
        vertices.addAll([
          x,
          top - h,
          0,
          x + w,
          top - h,
          0,
          x,
          top,
          0,
          x + w,
          top,
          0,
        ]);
        uv.addAll([u, v + vh, u + uw, v + vh, u, v, u + uw, v]);
        indices.addAll([
          base,
          base + 1,
          base + 2,
          base + 2,
          base + 1,
          base + 3,
        ]);
      }
      final rgba = raw['m_fontColor'] as Map,
          key = 'intro-ui:$id:font:${entry.key}',
          color = Float32List.fromList([
            for (final c in ['r', 'g', 'b']) (rgba[c] as num).toDouble(),
            (rgba['a'] as num).toDouble() * placement.opacity,
          ]);
      meshes[key] = projectSprite(
        NativeSpriteGeometry(
          positions: Float32List.fromList(vertices),
          uv: Float32List.fromList(uv),
          indices: Uint16List.fromList(indices),
        ),
        clip,
        color,
      );
      final pixels =
          math.min(
            viewport.width / (scaler['m_ReferenceResolution']['x'] as num),
            viewport.height / (scaler['m_ReferenceResolution']['y'] as num),
          ) *
          viewport.pixelRatio;
      final material = _fontMaterial(raw, font), f = material.floats;
      final weight = first.bold ? f['_WeightBold']! : f['_WeightNormal']!,
          boundary =
              .5 - (weight * .25 + f['_FaceDilate']!) * f['_ScaleRatioA']! * .5;
      final pixelWidth =
          1 /
          (2 *
              f['_GradientScale']! *
              (first.glyphScale ?? size / font.size) *
              pixels *
              (1 + (f['_Sharpness'] ?? 0)));
      final face = material.colors['_FaceColor']!;
      materials[key] = NativeMaterial(
        texture: 'intro:font:${entry.key}',
        recipe: NativeMaterialRecipe.sdfText,
        textureAlpha: NativeTextureAlpha.independent,
        uniformFloats: Float32List.fromList([
          for (final c in ['r', 'g', 'b', 'a']) (face[c] as num).toDouble(),
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          boundary,
          0,
          0,
          pixelWidth,
          0,
          0,
          boundary,
          0,
          0,
          0,
          f['_ScaleX']!,
          f['_ScaleY']!,
        ]),
      );
      output.add(NativeDraw(mesh: key, material: key));
    }
    return output;
  }
}
