import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fixtures.dart';

/// Encodes [value] to a JSON string and parses it back with [fromJson],
/// as a file save/load would.
T roundTrip<T>(Object value, T Function(Map<String, dynamic>) fromJson) =>
    fromJson(jsonDecode(jsonEncode(value)) as Map<String, dynamic>);

/// Registers one round-trip test per sample. [fromJson] is the union base's
/// parser for union variants, so the discriminator is exercised too.
void rt<T extends Object>(
  String group_,
  List<T> samples,
  T Function(Map<String, dynamic>) fromJson,
) {
  group(group_, () {
    for (var i = 0; i < samples.length; i++) {
      final sample = samples[i];
      test('#$i ${sample.runtimeType}', () {
        final back = roundTrip(sample, fromJson);
        expect(back, sample);
        expect(back.hashCode, sample.hashCode);
        // Re-encoding is stable byte for byte.
        expect(jsonEncode(back), jsonEncode(sample));
      });
    }
  });
}

void main() {
  group('values', () {
    rt('StageColor', const [
      red,
      blue,
      StageColor.transparent,
    ], StageColor.fromJson);
    rt('StageSize', const [
      StageSize(width: 1.5, height: 2),
    ], StageSize.fromJson);
    rt('StagePoint', const [
      StagePoint(),
      StagePoint(x: -1, y: 0.25),
    ], StagePoint.fromJson);
    rt('StageRect', const [
      StageRect(),
      StageRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
    ], StageRect.fromJson);
    rt('EdgeInsetsValue', [
      EdgeInsetsValue.zero,
      EdgeInsetsValue.all(8),
    ], EdgeInsetsValue.fromJson);
    rt('CornerRadius', const [
      CornerRadius.uniform(),
      CornerRadius.uniform(8),
      CornerRadius.perCorner(tl: 1, tr: 2, br: 3, bl: 4),
    ], CornerRadius.fromJson);
    rt('IrValue', allIrValues, IrValue.fromJson);
    rt('TokenRef', const [TokenRef(variableId: 'v')], TokenRef.fromJson);
  });

  group('paints, strokes, effects', () {
    rt('Paint', const [
      solid,
      gradient,
      image,
      Paint.solid(id: 'p', color: red),
    ], Paint.fromJson);
    rt('ColorStop', const [
      ColorStop(position: 0.5, color: red),
    ], ColorStop.fromJson);
    rt('GradientHandles', const [GradientHandles()], GradientHandles.fromJson);
    rt('ImageFilters', const [
      ImageFilters(),
      ImageFilters(exposure: 1),
    ], ImageFilters.fromJson);
    rt('StrokeWeight', const [
      StrokeWeight.uniform(3),
      StrokeWeight.perSide(left: 2),
    ], StrokeWeight.fromJson);
    rt('Stroke', const [Stroke(), stroke], Stroke.fromJson);
    rt('Effect', const [
      dropShadow,
      innerShadow,
      layerBlur,
      backgroundBlur,
    ], Effect.fromJson);
    rt('Appearance', const [Appearance(), appearance], Appearance.fromJson);
  });

  group('layout', () {
    rt('Gap', const [Gap.fixed(), Gap.fixed(-4), Gap.auto()], Gap.fromJson);
    rt('AutoLayout', const [AutoLayout(), autoLayout], AutoLayout.fromJson);
    rt('GridTrack', const [
      GridTrack.fixed(100),
      GridTrack.flex(),
      GridTrack.hug(),
    ], GridTrack.fromJson);
    rt('GridLayout', const [GridLayout(), gridLayout], GridLayout.fromJson);
    rt('MotionTransform', const [
      MotionTransform(),
      motionTransform,
    ], MotionTransform.fromJson);
    rt('Constraints', const [Constraints()], Constraints.fromJson);
    rt('GridPlacement', const [GridPlacement()], GridPlacement.fromJson);
    rt('LayoutChild', const [LayoutChild(), layoutChild], LayoutChild.fromJson);
    rt('NodeCommon', [
      const NodeCommon(id: 'n'),
      common('n2'),
    ], NodeCommon.fromJson);
  });

  group('text', () {
    rt('LineHeight', const [
      LineHeight.auto(),
      LineHeight.px(24),
      LineHeight.percent(120),
    ], LineHeight.fromJson);
    rt('LetterSpacing', const [
      LetterSpacing.px(1),
      LetterSpacing.percent(-2),
    ], LetterSpacing.fromJson);
    rt('TextDecoration', const [TextDecoration()], TextDecoration.fromJson);
    rt('TextStyle', const [TextStyle(), textStyle], TextStyle.fromJson);
    rt('TextStyleOverride', const [
      TextStyleOverride(),
      styleOverride,
    ], TextStyleOverride.fromJson);
    rt('ParagraphStyle', const [
      ParagraphStyle(),
      paragraphStyle,
    ], ParagraphStyle.fromJson);
    rt('SpanLink', const [
      SpanLink.url('https://a.b'),
      SpanLink.scene('s'),
    ], SpanLink.fromJson);
    rt('Span', const [Span(text: ''), span], Span.fromJson);
    rt('Paragraph', const [Paragraph(), paragraph], Paragraph.fromJson);
  });

  group('nodes', () {
    rt('ShapeGeometry', allShapeGeometries, ShapeGeometry.fromJson);
    rt('InstanceSource', const [
      InstanceSource.component('cmp'),
      InstanceSource.variant(variantSetId: 'vs', variantValues: {'a': 'b'}),
    ], InstanceSource.fromJson);
    rt('Node', <Node>[
      const FrameNode(common: NodeCommon(id: 'f')),
      fullFrame('f2', children: [fullText('t'), fullFrame('f3')]),
      const TextNode(common: NodeCommon(id: 't')),
      fullText('t2'),
      const ShapeNode(common: NodeCommon(id: 's')),
      for (final g in allShapeGeometries) fullShape('s2', g),
      const InstanceNode(
        common: NodeCommon(id: 'i'),
        source: InstanceSource.component('cmp'),
      ),
      fullInstance('i2'),
      const VideoNode(
        common: NodeCommon(id: 'v'),
        assetId: 'a',
      ),
      fullVideo('v2'),
      const EmbedNode(
        common: NodeCommon(id: 'e'),
        assetId: 'a',
      ),
      fullEmbed('e2'),
    ], Node.fromJson);
    rt('FrameNode (variant parser)', [fullFrame('f')], FrameNode.fromJson);
  });

  group('behaviours and interactions', () {
    rt('Behavior', allBehaviors, Behavior.fromJson);
    rt('ClockRange', const [ClockRange()], ClockRange.fromJson);
    rt('InteractionTrigger', allTriggers, InteractionTrigger.fromJson);
    rt('Action', allActions, Action.fromJson);
    rt('Interaction', const [
      interaction,
      Interaction(id: 'i', trigger: InteractionTrigger.sceneEnter()),
    ], Interaction.fromJson);
  });

  group('motion', () {
    rt('Clock', allClocks, Clock.fromJson);
    rt('Easing', allEasings, Easing.fromJson);
    rt('Keyframe', [
      const Keyframe(id: 'k', t: 0, value: IrValue.number(1)),
      trackWithAllEasings().keyframes[1],
    ], Keyframe.fromJson);
    rt('Track', [
      const Track(id: 't', target: 'n', property: 'opacity', clockId: 'c'),
      trackWithAllEasings(),
    ], Track.fromJson);
  });

  group('audio', () {
    rt('AudioScope', const [
      AudioScope.story(),
      AudioScope.scene('s'),
    ], AudioScope.fromJson);
    rt('LyricWord', const [LyricWord(start: 1, text: 'a')], LyricWord.fromJson);
    rt('LyricLine', lyrics.lines, LyricLine.fromJson);
    rt('LyricsDoc', const [LyricsDoc(), lyrics], LyricsDoc.fromJson);
    rt('AudioTrack', const [
      AudioTrack(id: 'a', assetId: 'b'),
      audioTrack,
    ], AudioTrack.fromJson);
  });

  group('assets and fonts', () {
    rt('AssetVariant', asset.variants, AssetVariant.fromJson);
    rt('AssetPlaceholder', [asset.placeholder!], AssetPlaceholder.fromJson);
    rt('Asset', const [
      Asset(id: 'a', kind: AssetKind.rive, uri: 'local://a'),
      asset,
    ], Asset.fromJson);
    rt('FontAxis', fontFamily.faces[1].axes, FontAxis.fromJson);
    rt('FontFace', fontFamily.faces, FontFace.fromJson);
    rt('FontFamily', const [
      FontFamily(id: 'f', name: 'F'),
      fontFamily,
    ], FontFamily.fromJson);
  });

  group('tokens', () {
    rt('TokenMode', const [TokenMode(id: 'm', name: 'M')], TokenMode.fromJson);
    rt('Variable', tokenSystem.collections.first.variables, Variable.fromJson);
    rt(
      'VariableCollection',
      tokenSystem.collections,
      VariableCollection.fromJson,
    );
    rt(
      'TextStyleDef',
      tokenSystem.textStyles.values.toList(),
      TextStyleDef.fromJson,
    );
    rt(
      'PaintStyleDef',
      tokenSystem.paintStyles.values.toList(),
      PaintStyleDef.fromJson,
    );
    rt(
      'EffectStyleDef',
      tokenSystem.effectStyles.values.toList(),
      EffectStyleDef.fromJson,
    );
    rt('TokenSystem', const [TokenSystem(), tokenSystem], TokenSystem.fromJson);
  });

  group('components', () {
    rt(
      'ComponentPropDef',
      buttonComponent('c').properties.values.toList(),
      ComponentPropDef.fromJson,
    );
    rt('ComponentDef', [buttonComponent('c')], ComponentDef.fromJson);
    rt('Variant', variantSet.variants, Variant.fromJson);
    rt('VariantSet', const [
      VariantSet(id: 'v', name: 'V'),
      variantSet,
    ], VariantSet.fromJson);
  });

  group('document', () {
    rt('Breakpoint', breakpoints, Breakpoint.fromJson);
    rt('SceneTransition', const [SceneTransition()], SceneTransition.fromJson);
    rt('Scene', compositeDocument().scenes, Scene.fromJson);
    rt('StageMeta', [
      const StageMeta(),
      compositeDocument().meta,
    ], StageMeta.fromJson);
    rt('StageDocument', [
      StageDocument.empty(ids: IdGenerator.seeded(1)),
      compositeDocument(),
    ], StageDocument.fromJson);
  });
}
