import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../section_registry.dart';
import 'audio_section.dart';
import 'clock_commands.dart' show sceneFrames;
import 'clock_dialogs.dart';
import 'clock_fields.dart';

// The Behaviour section (m2.md "Lyrics lane"): sets up Lyrics and TextReveal
// on a text node and removes them. In the file format a behaviour belongs to
// a frame and acts on the text inside it (Lyrics: the frame's first text
// child is the line template; TextReveal: every text inside the frame), so:
//
// - a selected frame shows and edits its own behaviour;
// - a selected text node shows the behaviour of the frame that drives it, and
//   adding one wraps the text in a new frame that carries it.

/// The Behaviour section: Lyrics and TextReveal setup for a text node (or a
/// frame).
final InspectorSectionSpec behaviorSection = InspectorSectionSpec(
  id: 'behavior',
  title: 'Behaviour',
  appliesTo: (info) =>
      info.isSingle &&
      info.roots == 0 &&
      info.innerNodes == 0 &&
      (info.kinds.contains(ir.NodeKind.text) ||
          info.kinds.contains(ir.NodeKind.frame)),
  builder: (context, info) => BehaviorSectionBody(nodeId: info.ids.single),
);

/// The frame whose Lyrics or TextReveal drives text node [textId], else
/// null: the nearest ancestor frame with TextReveal (it reveals every text
/// inside), or the parent frame when it has Lyrics (it drives its direct
/// text children).
ir.FrameNode? drivingFrame(ir.StageDocument doc, String textId) {
  final index = ir.DocumentIndex.of(doc);
  final loc = index.locate(textId);
  if (loc == null) return null;
  for (final id in loc.ancestorIds.reversed) {
    final n = index.node(id);
    if (n is! ir.FrameNode) continue;
    final b = n.behavior;
    if (b is ir.TextRevealBehavior) return n;
    if (b is ir.LyricsBehavior && id == loc.parentId) return n;
  }
  return null;
}

/// The default clock for a new TextReveal in [scene]: a timeline clock,
/// else an audio clock, else the scene's own scroll clock.
ir.Clock? defaultRevealClock(ir.Scene scene) {
  for (final test in <bool Function(ir.Clock)>[
    (c) => c is ir.TimelineClock,
    (c) => c is ir.AudioClock,
    (c) => c is ir.SceneScrollClock && c.sceneId == scene.id,
    (c) => c is ir.SceneScrollClock,
  ]) {
    for (final c in scene.clocks) {
      if (test(c)) return c;
    }
  }
  return null;
}

/// The range of [clock]'s values a reveal covers by default: the clock's
/// whole span (scroll 0–1, timeline 0–duration, audio 0–track length,
/// pointer −1…1), else 0–1.
ir.ClockRange naturalRevealRange(ir.StageDocument doc, ir.Clock clock) {
  final r = ir.clockTimeRange(doc, clock);
  return r == null
      ? const ir.ClockRange()
      : ir.ClockRange(start: r.start, end: r.end);
}

String _behaviorName(ir.Behavior b) => switch (b) {
  ir.LyricsBehavior() => 'Lyrics',
  ir.TextRevealBehavior() => 'Text reveal',
  ir.CarouselBehavior() => 'Carousel',
  ir.LightboxBehavior() => 'Lightbox',
  ir.MarqueeBehavior() => 'Marquee',
  ir.AudioControlsBehavior() => 'Audio controls',
};

class BehaviorSectionBody extends ConsumerWidget {
  const BehaviorSectionBody({required this.nodeId, super.key});

  final String nodeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doc = ref.watch(editorControllerProvider.select((s) => s.document));
    final index = ir.DocumentIndex.of(doc);
    final node = index.node(nodeId);
    final loc = index.locate(nodeId);
    if (node == null || loc == null || loc.sceneIndex == null) {
      return const SizedBox.shrink();
    }
    final scene = doc.scenes[loc.sceneIndex!];
    final ir.FrameNode? frame = switch (node) {
      ir.FrameNode() => node,
      ir.TextNode() => drivingFrame(doc, nodeId),
      _ => null,
    };
    final behavior = frame?.behavior;
    final t = context.ss;
    final ctl = ref.read(editorControllerProvider.notifier);
    return Column(
      key: const ValueKey('behavior-body'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (behavior == null)
          _Setup(node: node, scene: scene, doc: doc)
        else ...[
          Row(
            children: [
              Expanded(
                child: Text(_behaviorName(behavior), style: t.text.bodyStrong),
              ),
              SsIconButton(
                icon: SsIcons.trash2,
                semanticLabel: 'Remove behaviour',
                size: 24,
                iconSize: 14,
                onPressed: () => ctl.execute(
                  SetBehavior(
                    frame!.id,
                    null,
                    label: 'Remove ${_behaviorName(behavior).toLowerCase()}',
                  ),
                ),
              ),
            ],
          ),
          if (node is ir.TextNode)
            Padding(
              padding: const EdgeInsets.only(bottom: SsSpace.s2),
              child: Text(
                'Set on the frame "${frame!.common.name.isEmpty ? frame.id : frame.common.name}" around this text.',
                style: t.text.caption.copyWith(color: t.colors.textSecondary),
              ),
            ),
          switch (behavior) {
            final ir.LyricsBehavior b => _LyricsFields(
              frameId: frame!.id,
              behavior: b,
              scene: scene,
              doc: doc,
            ),
            final ir.TextRevealBehavior b => _RevealFields(
              frameId: frame!.id,
              behavior: b,
              scene: scene,
              doc: doc,
            ),
            final ir.CarouselBehavior b => _CarouselFields(
              frameId: frame!.id,
              behavior: b,
            ),
            final ir.MarqueeBehavior b => _MarqueeFields(
              frameId: frame!.id,
              behavior: b,
            ),
            ir.LightboxBehavior() => Text(
              'In the published story, tapping an item in this frame shows '
              'it full screen.',
              style: t.text.caption.copyWith(color: t.colors.textSecondary),
            ),
            _ => Text(
              'This behaviour is edited in a later milestone. It can be '
              'removed here.',
              style: t.text.caption.copyWith(color: t.colors.textDisabled),
            ),
          },
        ],
      ],
    );
  }
}

// ---- Setup ---------------------------------------------------------------------

class _Setup extends ConsumerWidget {
  const _Setup({required this.node, required this.scene, required this.doc});

  final ir.Node node;
  final ir.Scene scene;
  final ir.StageDocument doc;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final ctl = ref.read(editorControllerProvider.notifier);
    final tracks = audioTracksOfScene(doc, scene.id);
    final clock = defaultRevealClock(scene);
    void add(ir.Behavior b) => ctl.execute(
      node is ir.TextNode
          ? WrapTextInBehavior(node.id, b)
          : SetBehavior(
              node.id,
              b,
              label: 'Add ${_behaviorName(b).toLowerCase()}',
            ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          node is ir.TextNode
              ? 'Make this text follow a song or reveal as a clock plays.'
              : 'Make the text inside this frame follow a song or reveal as '
                    'a clock plays.',
          style: t.text.caption.copyWith(color: t.colors.textSecondary),
        ),
        const SizedBox(height: SsSpace.s2),
        Wrap(
          spacing: SsSpace.s2,
          runSpacing: SsSpace.s1,
          children: [
            SsButton(
              label: 'Lyrics',
              icon: SsIcons.music,
              onPressed: tracks.isEmpty
                  ? null
                  : () =>
                        add(ir.Behavior.lyrics(audioTrackId: tracks.first.id)),
            ),
            SsButton(
              label: 'Text reveal',
              icon: SsIcons.type,
              onPressed: clock == null
                  ? null
                  : () => add(
                      ir.Behavior.textReveal(
                        clockId: clock.id,
                        range: naturalRevealRange(doc, clock),
                      ),
                    ),
            ),
          ],
        ),
        if (tracks.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: SsSpace.s1),
            child: Text(
              'Lyrics needs audio: add some in the scene settings.',
              style: t.text.caption.copyWith(color: t.colors.textDisabled),
            ),
          ),
        if (node is ir.FrameNode) ...[
          const SizedBox(height: SsSpace.s3),
          Text(
            'Or move its children as a whole:',
            style: t.text.caption.copyWith(color: t.colors.textSecondary),
          ),
          const SizedBox(height: SsSpace.s2),
          Wrap(
            spacing: SsSpace.s2,
            runSpacing: SsSpace.s1,
            children: [
              SsButton(
                label: 'Carousel',
                icon: SsIcons.moveHorizontal,
                onPressed: () => add(const ir.Behavior.carousel()),
              ),
              SsButton(
                label: 'Marquee',
                icon: SsIcons.arrowLeftRight,
                onPressed: () => add(const ir.Behavior.marquee()),
              ),
              SsButton(
                label: 'Lightbox',
                icon: SsIcons.maximize,
                onPressed: () => add(const ir.Behavior.lightbox()),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

// ---- Carousel and marquee --------------------------------------------------------

Widget _row(BuildContext context, String label, Widget control) => Padding(
  padding: const EdgeInsets.only(bottom: SsSpace.s2),
  child: Row(
    children: [
      SizedBox(
        width: 72,
        child: Text(
          label,
          style: context.ss.text.small.copyWith(
            color: context.ss.colors.textSecondary,
          ),
        ),
      ),
      Expanded(child: control),
    ],
  ),
);

class _CarouselFields extends ConsumerWidget {
  const _CarouselFields({required this.frameId, required this.behavior});

  final String frameId;
  final ir.CarouselBehavior behavior;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctl = ref.read(editorControllerProvider.notifier);
    final b = behavior;
    void set(ir.CarouselBehavior next, {String? coalesce}) =>
        ctl.execute(SetBehavior(frameId, next, label: 'Change carousel'));
    return Column(
      key: const ValueKey<String>('carousel-fields'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _row(
          context,
          'Direction',
          SsSegmented<ir.LayoutDirection>(
            semanticLabel: 'Carousel direction',
            expand: true,
            selected: b.axis,
            onChanged: (v) => set(b.copyWith(axis: v)),
            segments: const [
              SsSegment(value: ir.LayoutDirection.horizontal, label: 'Across'),
              SsSegment(value: ir.LayoutDirection.vertical, label: 'Down'),
            ],
          ),
        ),
        _row(
          context,
          'Swipe',
          SsSegmented<ir.CarouselPhysics>(
            semanticLabel: 'Carousel swipe',
            expand: true,
            selected: b.physics,
            onChanged: (v) => set(b.copyWith(physics: v)),
            segments: const [
              SsSegment(value: ir.CarouselPhysics.paged, label: 'One item'),
              SsSegment(value: ir.CarouselPhysics.free, label: 'Free'),
            ],
          ),
        ),
        _row(
          context,
          'Autoplay',
          SsNumberField(
            semanticLabel: 'Autoplay seconds (0 = off)',
            value: b.autoplay,
            unit: 's',
            min: 0,
            step: 0.5,
            onChangeStart: ctl.beginGesture,
            onChangeEnd: ctl.endGesture,
            onChanged: (v) => set(b.copyWith(autoplay: v)),
          ),
        ),
        _row(
          context,
          'Peek',
          SsNumberField(
            semanticLabel: 'Peek of the previous item',
            value: b.peek,
            unit: 'px',
            min: 0,
            onChangeStart: ctl.beginGesture,
            onChangeEnd: ctl.endGesture,
            onChanged: (v) => set(b.copyWith(peek: v)),
          ),
        ),
        SsToggle(
          label: 'Snap to items',
          value: b.snap,
          onChanged: (v) => set(b.copyWith(snap: v)),
        ),
        SsToggle(
          label: 'Loop',
          value: b.loop,
          onChanged: (v) => set(b.copyWith(loop: v)),
        ),
      ],
    );
  }
}

class _MarqueeFields extends ConsumerWidget {
  const _MarqueeFields({required this.frameId, required this.behavior});

  final String frameId;
  final ir.MarqueeBehavior behavior;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctl = ref.read(editorControllerProvider.notifier);
    final b = behavior;
    void set(ir.MarqueeBehavior next) =>
        ctl.execute(SetBehavior(frameId, next, label: 'Change marquee'));
    return Column(
      key: const ValueKey<String>('marquee-fields'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _row(
          context,
          'Speed',
          SsNumberField(
            semanticLabel: 'Marquee speed',
            value: b.speed,
            unit: 'px/s',
            min: 1,
            onChangeStart: ctl.beginGesture,
            onChangeEnd: ctl.endGesture,
            onChanged: (v) => set(b.copyWith(speed: v)),
          ),
        ),
        _row(
          context,
          'Towards',
          SsSegmented<ir.MarqueeDirection>(
            semanticLabel: 'Marquee direction',
            expand: true,
            selected: b.direction,
            onChanged: (v) => set(b.copyWith(direction: v)),
            segments: const [
              SsSegment(
                value: ir.MarqueeDirection.left,
                icon: SsIcons.arrowLeft,
                semanticLabel: 'Left',
              ),
              SsSegment(
                value: ir.MarqueeDirection.right,
                icon: SsIcons.arrowRight,
                semanticLabel: 'Right',
              ),
              SsSegment(
                value: ir.MarqueeDirection.up,
                icon: SsIcons.arrowUp,
                semanticLabel: 'Up',
              ),
              SsSegment(
                value: ir.MarqueeDirection.down,
                icon: SsIcons.arrowDown,
                semanticLabel: 'Down',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---- Lyrics ----------------------------------------------------------------------

class _LyricsFields extends ConsumerWidget {
  const _LyricsFields({
    required this.frameId,
    required this.behavior,
    required this.scene,
    required this.doc,
  });

  final String frameId;
  final ir.LyricsBehavior behavior;
  final ir.Scene scene;
  final ir.StageDocument doc;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final ctl = ref.read(editorControllerProvider.notifier);
    void set(ir.LyricsBehavior b) =>
        ctl.execute(SetBehavior(frameId, b, label: 'Change lyrics'));
    final tracks = audioTracksOfScene(doc, scene.id);
    // The chosen track may no longer play in this scene; keep it listed.
    final current = [
      for (final a in doc.audioTracks)
        if (a.id == behavior.audioTrackId) a,
    ];
    final choices = [
      ...tracks,
      for (final a in current)
        if (!tracks.any((x) => x.id == a.id)) a,
    ];
    final track = current.isEmpty ? null : current.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClockField(
          'Audio',
          SsDropdown<String>(
            semanticLabel: 'Lyrics audio track',
            value: choices.any((c) => c.id == behavior.audioTrackId)
                ? behavior.audioTrackId
                : null,
            hint: 'Pick a track',
            items: [
              for (final a in choices)
                SsDropdownItem(value: a.id, label: audioAssetName(doc, a)),
            ],
            onChanged: (id) => set(behavior.copyWith(audioTrackId: id)),
          ),
        ),
        if (track != null && (track.lyrics?.lines.isEmpty ?? true))
          Padding(
            padding: const EdgeInsets.only(bottom: SsSpace.s2),
            child: Text(
              'This track has no lyrics yet. Import an LRC file in its audio '
              'settings.',
              style: t.text.caption.copyWith(color: t.colors.warning),
            ),
          ),
        ClockField(
          'Scroll',
          SsSegmented<ir.LyricsScrollMode>(
            semanticLabel: 'Lyrics scroll',
            expand: true,
            selected: behavior.scrollMode,
            onChanged: (m) => set(behavior.copyWith(scrollMode: m)),
            segments: const [
              SsSegment(value: ir.LyricsScrollMode.none, label: 'None'),
              SsSegment(value: ir.LyricsScrollMode.center, label: 'Centre'),
              SsSegment(value: ir.LyricsScrollMode.top, label: 'Top'),
            ],
          ),
        ),
        const SizedBox(height: SsSpace.s1),
        _StyleFields(
          title: 'Active line',
          semanticPrefix: 'Active',
          style: behavior.activeStyle,
          onChanged: (s) => set(behavior.copyWith(activeStyle: s)),
        ),
        _StyleFields(
          title: 'Inactive lines',
          semanticPrefix: 'Inactive',
          style: behavior.inactiveStyle,
          onChanged: (s) => set(behavior.copyWith(inactiveStyle: s)),
        ),
      ],
    );
  }
}

/// Weight, size and colour of one lyric line style. An empty field inherits
/// the text node's own style; lines move between the two styles as they
/// become active.
class _StyleFields extends ConsumerWidget {
  const _StyleFields({
    required this.title,
    required this.semanticPrefix,
    required this.style,
    required this.onChanged,
  });

  final String title;
  final String semanticPrefix;
  final ir.TextStyleOverride style;
  final ValueChanged<ir.TextStyleOverride> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final ctl = ref.read(editorControllerProvider.notifier);
    final fills = style.fills;
    final solid =
        fills != null && fills.length == 1 && fills.first is ir.SolidPaint
        ? (fills.first as ir.SolidPaint).color
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: SsSpace.s1, bottom: SsSpace.s1),
          child: Text(title, style: t.text.overline),
        ),
        ClockField(
          'Weight',
          Row(
            children: [
              Expanded(
                child: SsNumberField(
                  semanticLabel: '$semanticPrefix weight',
                  label: 'W',
                  value: style.fontWeight?.toDouble(),
                  min: 100,
                  max: 900,
                  step: 100,
                  fractionDigits: 0,
                  onChangeStart: ctl.beginGesture,
                  onChangeEnd: ctl.endGesture,
                  onChanged: (v) =>
                      onChanged(style.copyWith(fontWeight: v.round())),
                ),
              ),
              if (style.fontWeight != null)
                SsIconButton(
                  icon: SsIcons.x,
                  semanticLabel: 'Inherit $semanticPrefix weight',
                  size: 24,
                  iconSize: 12,
                  onPressed: () => onChanged(style.copyWith(fontWeight: null)),
                ),
            ],
          ),
        ),
        ClockField(
          'Size',
          Row(
            children: [
              Expanded(
                child: SsNumberField(
                  semanticLabel: '$semanticPrefix size',
                  label: 'S',
                  value: style.fontSize,
                  unit: 'px',
                  min: 1,
                  max: 1000,
                  step: 1,
                  onChangeStart: ctl.beginGesture,
                  onChangeEnd: ctl.endGesture,
                  onChanged: (v) => onChanged(style.copyWith(fontSize: v)),
                ),
              ),
              if (style.fontSize != null)
                SsIconButton(
                  icon: SsIcons.x,
                  semanticLabel: 'Inherit $semanticPrefix size',
                  size: 24,
                  iconSize: 12,
                  onPressed: () => onChanged(style.copyWith(fontSize: null)),
                ),
            ],
          ),
        ),
        ClockField(
          'Colour',
          Row(
            children: [
              Expanded(
                child: SsColorField(
                  semanticLabel: '$semanticPrefix colour',
                  color: solid == null
                      ? const Color(0xFFFFFFFF)
                      : Color.from(
                          alpha: solid.a,
                          red: solid.r,
                          green: solid.g,
                          blue: solid.b,
                        ),
                  mixed: solid == null,
                  placeholder: fills == null ? 'Inherit' : 'Mixed',
                  onChangeStart: ctl.beginGesture,
                  onChangeEnd: ctl.endGesture,
                  onChanged: (color) => onChanged(
                    style.copyWith(
                      fills: [
                        ir.Paint.solid(
                          id: fills != null && fills.isNotEmpty
                              ? fills.first.id
                              : ir.IdGenerator().next(),
                          color: ir.StageColor(
                            r: color.r,
                            g: color.g,
                            b: color.b,
                            a: color.a,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (fills != null)
                SsIconButton(
                  icon: SsIcons.x,
                  semanticLabel: 'Inherit $semanticPrefix colour',
                  size: 24,
                  iconSize: 12,
                  onPressed: () => onChanged(style.copyWith(fills: null)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---- Text reveal -----------------------------------------------------------------

class _RevealFields extends ConsumerWidget {
  const _RevealFields({
    required this.frameId,
    required this.behavior,
    required this.scene,
    required this.doc,
  });

  final String frameId;
  final ir.TextRevealBehavior behavior;
  final ir.Scene scene;
  final ir.StageDocument doc;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final ctl = ref.read(editorControllerProvider.notifier);
    void set(ir.TextRevealBehavior b) =>
        ctl.execute(SetBehavior(frameId, b, label: 'Change text reveal'));
    ir.Clock? clock;
    for (final c in scene.clocks) {
      if (c.id == behavior.clockId) clock = c;
    }
    final frameNames = {for (final f in sceneFrames(scene)) f.id: f.name};
    final seconds = clock is ir.TimelineClock || clock is ir.AudioClock;
    final span = clock == null ? null : ir.clockTimeRange(doc, clock);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClockField(
          'Clock',
          SsDropdown<String>(
            semanticLabel: 'Reveal clock',
            value: clock?.id,
            hint: 'Missing clock',
            items: [
              for (final c in scene.clocks)
                SsDropdownItem(value: c.id, label: clockLabel(c, frameNames)),
            ],
            onChanged: (id) {
              if (id == behavior.clockId) return;
              ir.Clock? next;
              for (final c in scene.clocks) {
                if (c.id == id) next = c;
              }
              // A range in seconds means nothing on a scroll clock: a clock
              // of another kind starts with its whole span.
              final sameKind =
                  clock != null &&
                  next != null &&
                  clock.runtimeType == next.runtimeType;
              set(
                behavior.copyWith(
                  clockId: id,
                  range: sameKind || next == null
                      ? behavior.range
                      : naturalRevealRange(doc, next),
                ),
              );
            },
          ),
        ),
        ClockField(
          'Unit',
          SsSegmented<ir.TextRevealUnit>(
            semanticLabel: 'Reveal unit',
            expand: true,
            selected: behavior.unit,
            onChanged: (u) => set(behavior.copyWith(unit: u)),
            segments: const [
              SsSegment(value: ir.TextRevealUnit.char, label: 'Letter'),
              SsSegment(value: ir.TextRevealUnit.word, label: 'Word'),
              SsSegment(value: ir.TextRevealUnit.line, label: 'Line'),
            ],
          ),
        ),
        ClockField(
          'Stagger',
          SsNumberField(
            semanticLabel: 'Reveal stagger',
            label: 'G',
            value: behavior.stagger,
            min: 0,
            max: 1,
            step: 0.01,
            onChangeStart: ctl.beginGesture,
            onChangeEnd: ctl.endGesture,
            onChanged: (v) => set(behavior.copyWith(stagger: v)),
          ),
        ),
        ClockField(
          'From',
          SsNumberField(
            semanticLabel: 'Reveal from',
            label: 'F',
            value: behavior.range.start,
            unit: seconds ? 's' : null,
            min: span?.start,
            max: span?.end,
            step: seconds ? 0.1 : 0.01,
            onChangeStart: ctl.beginGesture,
            onChangeEnd: ctl.endGesture,
            onChanged: (v) => set(
              behavior.copyWith(range: behavior.range.copyWith(start: v)),
            ),
          ),
        ),
        ClockField(
          'To',
          SsNumberField(
            semanticLabel: 'Reveal to',
            label: 'T',
            value: behavior.range.end,
            unit: seconds ? 's' : null,
            min: span?.start,
            max: span?.end,
            step: seconds ? 0.1 : 0.01,
            onChangeStart: ctl.beginGesture,
            onChangeEnd: ctl.endGesture,
            onChanged: (v) =>
                set(behavior.copyWith(range: behavior.range.copyWith(end: v))),
          ),
        ),
        Text(
          'The reveal runs while the clock is between From and To'
          '${seconds ? ' (seconds)' : ''}.',
          style: t.text.caption.copyWith(color: t.colors.textDisabled),
        ),
      ],
    );
  }
}
