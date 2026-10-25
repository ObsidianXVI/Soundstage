import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fixtures.dart';

Map<String, dynamic> encodeDecode(Object v) =>
    jsonDecode(jsonEncode(v)) as Map<String, dynamic>;

void main() {
  group('StageDocument.empty', () {
    final doc = StageDocument.empty(ids: IdGenerator.seeded(7));

    test('has primary desktop and mobile peers and a tablet under desktop', () {
      expect(doc.breakpoints.map((b) => b.name), [
        'Desktop',
        'Mobile',
        'Tablet',
      ]);
      expect(doc.breakpoints.map((b) => b.minWidth), [1024, 0, 600]);
      expect(doc.breakpoints.map((b) => b.designSize), const [
        StageSize(width: 1440, height: 900),
        StageSize(width: 390, height: 844),
        StageSize(width: 834, height: 1112),
      ]);
      expect(doc.primaryBreakpoints.map((b) => b.name), ['Desktop', 'Mobile']);
      expect(doc.breakpoints[0].inheritsFrom, isNull);
      expect(doc.breakpoints[1].inheritsFrom, isNull);
      expect(doc.breakpoints[2].inheritsFrom, doc.breakpoints[0].id);
      expect(validateDocument(doc), isEmpty);
      expect(doc.schemaVersion, kStageSchemaVersion);
      expect(doc.scenes, isEmpty);
      expect(doc.tokens, const TokenSystem());
    });

    test('uses unique generated ids', () {
      final ids = [doc.id, ...doc.breakpoints.map((b) => b.id)];
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids.every(isGeneratedId), isTrue);
    });

    test('is deterministic for a seeded generator', () {
      expect(StageDocument.empty(ids: IdGenerator.seeded(7)), doc);
    });

    test('loads through the migrating parser', () {
      expect(StageDocument.fromJsonMigrating(encodeDecode(doc)), doc);
    });
  });

  test('Scene.blankPinned sizes its root to the breakpoint viewport', () {
    final ids = IdGenerator.seeded(3);
    final doc = StageDocument.empty(ids: ids);
    final mobile = doc.breakpoints.firstWhere((b) => b.name == 'Mobile');
    final scene = Scene.blankPinned(
      ids: ids,
      breakpoint: mobile,
      name: 'Intro',
    );
    expect(scene.kind, SceneKind.pinned);
    expect(scene.scrollLength, 1);
    expect(scene.root.common.width, 390);
    expect(scene.root.common.height, 844);
    expect(scene.root.clipContent, isTrue);
    // B7: a new scene root is white, not see-through onto the dark canvas.
    expect(scene.root.appearance.fills, hasLength(1));
    expect(
      (scene.root.appearance.fills.single as SolidPaint).color,
      StageColor.white,
    );
    expect(scene.clocks.single, isA<SceneScrollClock>());
    expect((scene.clocks.single as SceneScrollClock).sceneId, scene.id);
    final withScene = doc.copyWith(scenes: [scene]);
    expect(StageDocument.fromJson(encodeDecode(withScene)), withScene);
  });

  test('the composite document round-trips exactly', () {
    final doc = compositeDocument();
    final json = jsonEncode(doc);
    final back = StageDocument.fromJson(
      jsonDecode(json) as Map<String, dynamic>,
    );
    expect(back, doc);
    expect(jsonEncode(back), json);
    // Sanity: the fixture really is large and nested.
    expect(doc.scenes, hasLength(3));
    expect(json.length, greaterThan(20000));
  });

  group('minimal JSON', () {
    test('a minimal document parses and defaults apply', () {
      final doc = StageDocument.fromJson({
        'schemaVersion': 1,
        'id': 'd',
        'breakpoints': [
          {
            'id': 'bp',
            'name': 'Desktop',
            'minWidth': 0,
            'designSize': {'width': 1440, 'height': 900},
          },
        ],
        'scenes': [
          {
            'id': 's',
            'root': {
              'type': 'frame',
              'common': {'id': 'root'},
              'children': [
                {
                  'type': 'text',
                  'common': {'id': 't'},
                  'content': [
                    {
                      'spans': [
                        {'text': 'Hi'},
                      ],
                    },
                  ],
                },
                {
                  'type': 'shape',
                  'common': {'id': 'r'},
                },
              ],
            },
          },
        ],
      });

      expect(doc.meta, const StageMeta());
      expect(doc.assets, isEmpty);
      final scene = doc.scenes.single;
      expect(scene.kind, SceneKind.flow);
      expect(scene.transitionIn.kind, SceneTransitionKind.none);
      final root = scene.root;
      expect(root.common.visible, isTrue);
      expect(root.common.opacity, 1);
      expect(root.common.blendMode, isNull);
      expect(root.effectiveBlendMode, BlendMode.passThrough);
      expect(root.common.layoutChild.positioning, Positioning.auto);
      expect(root.common.layoutChild.horizontalSizing, Sizing.fixed);
      expect(root.common.layoutChild.verticalSizing, Sizing.fixed);
      expect(
        root.common.layoutChild.constraints.horizontal,
        HorizontalConstraint.left,
      );
      expect(
        root.common.layoutChild.constraints.vertical,
        VerticalConstraint.top,
      );
      expect(root.common.motion, const MotionTransform());
      expect(root.appearance.fills, isEmpty);
      expect(root.appearance.cornerRadius, const CornerRadius.uniform(0));
      expect(root.autoLayout, isNull);

      final text = root.children[0] as TextNode;
      expect(text.effectiveBlendMode, BlendMode.normal);
      expect(text.style, const TextStyleOverride());
      final d = doc.defaultTextStyle;
      expect(d.fontSize, 16);
      expect(d.fontWeight, 400);
      expect(d.lineHeight, const LineHeight.auto());
      expect(d.fills, kDefaultTextFills);
      expect(text.autoResize, TextAutoResize.widthAndHeight);
      expect(text.content.single.spans.single.style, const TextStyleOverride());

      final shape = root.children[1] as ShapeNode;
      expect(shape.geometry, const ShapeGeometry.rectangle());
    });

    test('defaulted union fields parse from their minimal form', () {
      expect(AutoLayout.fromJson(const {}).gap, const Gap.fixed(0));
      expect(
        Keyframe.fromJson(const {
          't': 0,
          'id': 'k',
          'value': {'type': 'number', 'value': 2},
        }).easing,
        const Easing.linear(),
      );
      expect(Stroke.fromJson(const {}).weight, const StrokeWeight.uniform(1));
    });

    test('defaults are written back out, so files stay explicit', () {
      final json = encodeDecode(const FrameNode(common: NodeCommon(id: 'f')));
      expect(json['type'], 'frame');
      expect((json['common'] as Map)['opacity'], 1.0);
      expect((json['common'] as Map).containsKey('blendMode'), isFalse);
    });
  });

  group('errors', () {
    test('an unknown node type is a clear error', () {
      expect(
        () => Node.fromJson(const {
          'type': 'hologram',
          'common': {'id': 'x'},
        }),
        throwsA(
          isA<CheckedFromJsonException>().having(
            (e) => e.message,
            'message',
            contains('Invalid union type "hologram"'),
          ),
        ),
      );
    });

    test('unknown variant types fail for every union', () {
      final parsers = <String, Object Function(Map<String, dynamic>)>{
        'IrValue': IrValue.fromJson,
        'Paint': Paint.fromJson,
        'Effect': Effect.fromJson,
        'Easing': Easing.fromJson,
        'Clock': Clock.fromJson,
        'Behavior': Behavior.fromJson,
        'Action': Action.fromJson,
        'InteractionTrigger': InteractionTrigger.fromJson,
        'GridTrack': GridTrack.fromJson,
        'Gap': Gap.fromJson,
        'LineHeight': LineHeight.fromJson,
        'LetterSpacing': LetterSpacing.fromJson,
        'CornerRadius': CornerRadius.fromJson,
        'StrokeWeight': StrokeWeight.fromJson,
        'ShapeGeometry': ShapeGeometry.fromJson,
        'InstanceSource': InstanceSource.fromJson,
        'SpanLink': SpanLink.fromJson,
        'AudioScope': AudioScope.fromJson,
      };
      parsers.forEach((name, parse) {
        expect(
          () => parse(const {'type': 'nope'}),
          throwsA(isA<CheckedFromJsonException>()),
          reason: name,
        );
      });
    });

    test('an unknown type deep in a document fails the whole load', () {
      final json = encodeDecode(compositeDocument());
      final root = ((json['scenes'] as List).first as Map)['root'] as Map;
      ((root['children'] as List).first as Map)['type'] = 'blob';
      expect(
        () => StageDocument.fromJson(json),
        throwsA(isA<CheckedFromJsonException>()),
      );
    });

    test('an unknown enum value is rejected', () {
      expect(
        () => Paint.fromJson(const {
          'type': 'solid',
          'id': 'p',
          'color': {'r': 0, 'g': 0, 'b': 0},
          'blendMode': 'sparkle',
        }),
        throwsArgumentError,
      );
    });
  });

  test('ComponentDef.root serialises as a typed frame node', () {
    final json = encodeDecode(buttonComponent('c'));
    expect((json['root'] as Map)['type'], 'frame');
  });
}
