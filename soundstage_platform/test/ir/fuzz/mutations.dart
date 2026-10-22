import 'dart:math';

import 'package:soundstage_platform/ir/ir.dart';

/// Rebuilds [n] bottom-up, applying [f] to every node (children first).
Node mapNode(Node n, Node Function(Node) f) {
  if (n is FrameNode) {
    return f(n.copyWith(children: [for (final c in n.children) mapNode(c, f)]));
  }
  return f(n);
}

/// [doc] with [f] applied to every node of every scene, the overlay and
/// every component.
StageDocument mapDocumentNodes(StageDocument doc, Node Function(Node) f) {
  FrameNode frame(FrameNode n) => mapNode(n, f) as FrameNode;
  return doc.copyWith(
    scenes: [for (final s in doc.scenes) s.copyWith(root: frame(s.root))],
    overlay: doc.overlay == null ? null : frame(doc.overlay!),
    components: {
      for (final e in doc.components.entries)
        e.key: e.value.copyWith(root: frame(e.value.root)),
    },
  );
}

/// All nodes in the scenes and overlay.
List<Node> sceneNodes(StageDocument doc) {
  final out = <Node>[];
  void walk(Node n) {
    out.add(n);
    if (n is FrameNode) n.children.forEach(walk);
  }

  for (final s in doc.scenes) {
    walk(s.root);
  }
  if (doc.overlay != null) walk(doc.overlay!);
  return out;
}

/// A way of introducing one dangling reference (or duplicate id).
typedef Mutation = ({
  String name,
  StageDocument? Function(StageDocument, Random) apply,
});

/// Applies [change] to the first node (in tree order) of type [T] that
/// [where] accepts; null when there is none.
StageDocument? changeFirst<T extends Node>(
  StageDocument doc,
  Node Function(T) change, {
  bool Function(T)? where,
}) {
  var done = false;
  final out = doc.copyWith(
    scenes: [
      for (final s in doc.scenes)
        s.copyWith(
          root:
              mapNode(s.root, (n) {
                    if (!done && n is T && (where?.call(n) ?? true)) {
                      done = true;
                      return change(n);
                    }
                    return n;
                  })
                  as FrameNode,
        ),
    ],
  );
  return done ? out : null;
}

NodeCommon _withInteraction(NodeCommon c, Action a) => c.copyWith(
  interactions: [
    ...c.interactions,
    Interaction(
      id: 'zInt',
      trigger: const InteractionTrigger.tap(),
      actions: [a],
    ),
  ],
);

/// Each mutation breaks exactly one reference. `apply` returns null when the
/// document has nothing of the needed kind.
final List<Mutation> mutations = [
  (
    name: 'baseBreakpointId',
    apply: (d, r) => d.copyWith(baseBreakpointId: 'zzz'),
  ),
  (
    name: 'track clock',
    apply: (d, r) {
      for (final (si, s) in d.scenes.indexed) {
        if (s.tracks.isEmpty) continue;
        final scenes = [...d.scenes];
        scenes[si] = s.copyWith(
          tracks: [
            s.tracks.first.copyWith(clockId: 'zzz'),
            ...s.tracks.skip(1),
          ],
        );
        return d.copyWith(scenes: scenes);
      }
      return null;
    },
  ),
  (
    name: 'track target',
    apply: (d, r) {
      for (final (si, s) in d.scenes.indexed) {
        if (s.tracks.isEmpty) continue;
        final scenes = [...d.scenes];
        scenes[si] = s.copyWith(
          tracks: [
            s.tracks.first.copyWith(target: 'zzz'),
            ...s.tracks.skip(1),
          ],
        );
        return d.copyWith(scenes: scenes);
      }
      return null;
    },
  ),
  (
    name: 'track namespaced target',
    apply: (d, r) {
      for (final (si, s) in d.scenes.indexed) {
        for (final (ti, t) in s.tracks.indexed) {
          if (!t.target.contains('/')) continue;
          final scenes = [...d.scenes];
          final tracks = [...s.tracks];
          tracks[ti] = t.copyWith(target: '${t.target}/zzz');
          scenes[si] = s.copyWith(tracks: tracks);
          return d.copyWith(scenes: scenes);
        }
      }
      return null;
    },
  ),
  (
    name: 'track breakpoint',
    apply: (d, r) {
      final s = d.scenes.first;
      if (s.tracks.isEmpty) return null;
      return d.copyWith(
        scenes: [
          s.copyWith(
            tracks: [
              s.tracks.first.copyWith(breakpoints: ['zzz']),
              ...s.tracks.skip(1),
            ],
          ),
          ...d.scenes.skip(1),
        ],
      );
    },
  ),
  (
    name: 'instance component',
    apply: (d, r) => changeFirst<InstanceNode>(
      d,
      (n) => n.copyWith(source: const InstanceSource.component('zzz')),
      where: (n) => n.source is ComponentSource,
    ),
  ),
  (
    name: 'instance variant set',
    apply: (d, r) => changeFirst<InstanceNode>(
      d,
      (n) =>
          n.copyWith(source: const InstanceSource.variant(variantSetId: 'zzz')),
    ),
  ),
  (
    name: 'instance swap',
    apply: (d, r) => changeFirst<InstanceNode>(
      d,
      (n) => n.copyWith(
        propValues: {...n.propValues, 'pSwap': const IrValue.string('zzz')},
      ),
    ),
  ),
  (
    name: 'video asset',
    apply: (d, r) =>
        changeFirst<VideoNode>(d, (n) => n.copyWith(assetId: 'zzz')),
  ),
  (
    name: 'embed clock binding',
    apply: (d, r) => changeFirst<EmbedNode>(
      d,
      (n) => n.copyWith(inputBindings: {'progress': 'zzz'}),
    ),
  ),
  (
    name: 'image paint asset',
    apply: (d, r) => changeFirst<ShapeNode>(
      d,
      (n) => n.copyWith(
        appearance: n.appearance.copyWith(
          fills: [const Paint.image(id: 'zImg', assetId: 'zzz')],
        ),
      ),
    ),
  ),
  (
    name: 'text style id',
    apply: (d, r) =>
        changeFirst<TextNode>(d, (n) => n.copyWith(textStyleId: 'zzz')),
  ),
  (
    name: 'text font',
    apply: (d, r) => changeFirst<TextNode>(
      d,
      (n) => n.copyWith(style: n.style.copyWith(fontFamilyId: 'zzz')),
    ),
  ),
  (
    name: 'span scene link',
    apply: (d, r) => changeFirst<TextNode>(
      d,
      (n) => n.copyWith(
        content: [
          const Paragraph(
            spans: [Span(text: 'x', link: SpanLink.scene('zzz'))],
          ),
        ],
      ),
    ),
  ),
  (
    name: 'fill style',
    apply: (d, r) => changeFirst<FrameNode>(
      d,
      (n) => n.copyWith(appearance: n.appearance.copyWith(fillStyleId: 'zzz')),
    ),
  ),
  (
    name: 'effect style',
    apply: (d, r) => changeFirst<ShapeNode>(
      d,
      (n) =>
          n.copyWith(appearance: n.appearance.copyWith(effectStyleId: 'zzz')),
    ),
  ),
  (
    name: 'binding variable',
    apply: (d, r) => changeFirst<ShapeNode>(
      d,
      (n) => n.copyWith(
        common: n.common.copyWith(
          bindings: {'opacity': const TokenRef(variableId: 'zzz')},
        ),
      ),
    ),
  ),
  (
    name: 'breakpoint override key',
    apply: (d, r) => changeFirst<ShapeNode>(
      d,
      (n) => n.copyWith(
        common: n.common.copyWith(
          breakpointOverrides: {
            'zzz': {'x': const IrValue.number(1)},
          },
        ),
      ),
    ),
  ),
  (
    name: 'action scene',
    apply: (d, r) => changeFirst<ShapeNode>(
      d,
      (n) => n.copyWith(
        common: _withInteraction(
          n.common,
          const Action.scrollToScene(sceneId: 'zzz'),
        ),
      ),
    ),
  ),
  (
    name: 'action clock',
    apply: (d, r) => changeFirst<ShapeNode>(
      d,
      (n) => n.copyWith(
        common: _withInteraction(
          n.common,
          const Action.playTimeline(clockId: 'zzz'),
        ),
      ),
    ),
  ),
  (
    name: 'action audio',
    apply: (d, r) => changeFirst<ShapeNode>(
      d,
      (n) => n.copyWith(
        common: _withInteraction(
          n.common,
          const Action.playAudio(audioTrackId: 'zzz'),
        ),
      ),
    ),
  ),
  (
    name: 'action variable',
    apply: (d, r) => changeFirst<ShapeNode>(
      d,
      (n) => n.copyWith(
        common: _withInteraction(
          n.common,
          const Action.setVariable(variableId: 'zzz', value: IrValue.number(1)),
        ),
      ),
    ),
  ),
  (
    name: 'action lightbox',
    apply: (d, r) => changeFirst<ShapeNode>(
      d,
      (n) => n.copyWith(
        common: _withInteraction(
          n.common,
          const Action.openLightbox(nodeId: 'zzz'),
        ),
      ),
    ),
  ),
  (
    name: 'text reveal clock',
    apply: (d, r) => changeFirst<FrameNode>(
      d,
      (n) => n.copyWith(behavior: const Behavior.textReveal(clockId: 'zzz')),
    ),
  ),
  (
    name: 'lyrics audio',
    apply: (d, r) => changeFirst<FrameNode>(
      d,
      (n) => n.copyWith(behavior: const Behavior.lyrics(audioTrackId: 'zzz')),
    ),
  ),
  (
    name: 'duplicate node id',
    apply: (d, r) {
      final f = changeFirst<FrameNode>(
        d,
        (n) => n.copyWith(
          children: [n.children.first, n.children.first, ...n.children.skip(1)],
        ),
        where: (n) => n.children.isNotEmpty,
      );
      return f;
    },
  ),
  (
    name: 'duplicate id across scenes',
    apply: (d, r) {
      if (d.scenes.length < 2) return null;
      final other = d.scenes[1];
      final root = d.scenes[0].root;
      return d.copyWith(
        scenes: [
          d.scenes[0],
          other.copyWith(
            root: other.root.copyWith(
              common: other.root.common.copyWith(id: root.id),
            ),
          ),
          ...d.scenes.skip(2),
        ],
      );
    },
  ),
  (
    name: 'audio track asset',
    apply: (d, r) => d.copyWith(
      audioTracks: [
        d.audioTracks.first.copyWith(assetId: 'zzz'),
        ...d.audioTracks.skip(1),
      ],
    ),
  ),
  (
    name: 'audio scope scene',
    apply: (d, r) => d.copyWith(
      audioTracks: [
        d.audioTracks.first.copyWith(scope: const AudioScope.scene('zzz')),
        ...d.audioTracks.skip(1),
      ],
    ),
  ),
  (
    name: 'default font',
    apply: (d, r) => d.copyWith(
      defaultTextStyle: d.defaultTextStyle.copyWith(fontFamilyId: 'zzz'),
    ),
  ),
  (
    name: 'font face asset',
    apply: (d, r) => d.copyWith(
      fonts: {
        ...d.fonts,
        'fA': d.fonts['fA']!.copyWith(faces: [const FontFace(assetId: 'zzz')]),
      },
    ),
  ),
  (
    name: 'cover asset',
    apply: (d, r) => d.copyWith(meta: d.meta.copyWith(coverAssetId: 'zzz')),
  ),
  (
    name: 'variable alias',
    apply: (d, r) => d.copyWith(
      tokens: d.tokens.copyWith(
        collections: [
          d.tokens.collections.first.copyWith(
            variables: [
              ...d.tokens.collections.first.variables,
              const Variable(
                id: 'vBad',
                name: 'bad',
                type: VariableType.color,
                valuesByMode: {
                  'light': IrValue.tokenRef(TokenRef(variableId: 'zzz')),
                },
              ),
            ],
          ),
          ...d.tokens.collections.skip(1),
        ],
      ),
    ),
  ),
  (
    name: 'alias cycle',
    apply: (d, r) => d.copyWith(
      tokens: d.tokens.copyWith(
        collections: [
          d.tokens.collections.first.copyWith(
            variables: [
              ...d.tokens.collections.first.variables,
              const Variable(
                id: 'vCycA',
                name: 'a',
                type: VariableType.number,
                valuesByMode: {
                  'light': IrValue.tokenRef(TokenRef(variableId: 'vCycB')),
                },
              ),
              const Variable(
                id: 'vCycB',
                name: 'b',
                type: VariableType.number,
                valuesByMode: {
                  'light': IrValue.tokenRef(TokenRef(variableId: 'vCycA')),
                },
              ),
            ],
          ),
          ...d.tokens.collections.skip(1),
        ],
      ),
    ),
  ),
  (
    name: 'text style binding variable',
    apply: (d, r) => d.copyWith(
      tokens: d.tokens.copyWith(
        textStyles: {
          ...d.tokens.textStyles,
          'tsB': const TextStyleDef(
            name: 'B',
            bindings: {'fontSize': TokenRef(variableId: 'zzz')},
          ),
        },
      ),
    ),
  ),
  (
    name: 'variant component',
    apply: (d, r) => d.copyWith(
      variantSets: {
        'vsMain': d.variantSets['vsMain']!.copyWith(
          variants: [
            const Variant(componentId: 'zzz', values: {'size': 'small'}),
          ],
        ),
      },
    ),
  ),
  (
    name: 'component key mismatch',
    apply: (d, r) {
      final first = d.components.entries.first;
      return d.copyWith(
        components: {
          'zzz': first.value,
          ...Map.of(d.components)..remove(first.key),
        },
      );
    },
  ),
  (
    name: 'component cycle',
    apply: (d, r) {
      // The first component contains an instance of itself.
      final first = d.components.values.first;
      return d.copyWith(
        components: {
          ...d.components,
          first.id: first.copyWith(
            root: first.root.copyWith(
              children: [
                ...first.root.children,
                InstanceNode(
                  common: const NodeCommon(id: 'zSelf'),
                  source: InstanceSource.component(first.id),
                ),
              ],
            ),
          ),
        },
      );
    },
  ),
  (
    name: 'scroll clock scene',
    apply: (d, r) {
      final s = d.scenes.first;
      return d.copyWith(
        scenes: [
          s.copyWith(
            clocks: [
              ...s.clocks,
              const Clock.sceneScroll(id: 'zClock', sceneId: 'zzz'),
            ],
          ),
          ...d.scenes.skip(1),
        ],
      );
    },
  ),
  (
    name: 'mode override',
    apply: (d, r) => changeFirst<FrameNode>(
      d,
      (n) => n.copyWith(modeOverrides: {'colMode': 'zzz'}),
    ),
  ),
];
