import 'package:flutter/material.dart';

import '../design_system.dart';

/// `/demo/design-system`: every token and component in every state.
/// Hover, press and keyboard focus are live: interact with each control.
class DesignSystemGallery extends StatefulWidget {
  const DesignSystemGallery({super.key});

  @override
  State<DesignSystemGallery> createState() => _DesignSystemGalleryState();
}

class _DesignSystemGalleryState extends State<DesignSystemGallery> {
  bool _dark = true;

  @override
  Widget build(BuildContext context) {
    final theme = _dark ? SsThemeData.dark() : SsThemeData.light();
    return SsScope(
      theme: theme,
      child: Builder(
        builder: (context) => ColoredBox(
          color: theme.colors.surface0,
          child: _GalleryBody(
            dark: _dark,
            onTheme: (v) => setState(() => _dark = v),
          ),
        ),
      ),
    );
  }
}

class _GalleryBody extends StatefulWidget {
  const _GalleryBody({required this.dark, required this.onTheme});

  final bool dark;
  final ValueChanged<bool> onTheme;

  @override
  State<_GalleryBody> createState() => _GalleryBodyState();
}

class _GalleryBodyState extends State<_GalleryBody> {
  bool _toggle = true;
  bool? _check = true;
  String _seg = 'b';
  String _segIcon = 'desktop';
  String _drop = 'two';
  String _tab = 'layers';
  double? _num = 120;
  double? _mixedNum;
  double _angle = 45;
  Color _color = const Color(0xCC2F6FED);
  bool _panelOpen = true;
  SsAlign3 _ah = SsAlign3.start;
  SsAlign3 _av = SsAlign3.center;
  bool _space = false;
  SsHConstraint _ch = SsHConstraint.left;
  SsVConstraint _cv = SsVConstraint.top;
  String _treeName = 'Hero title';
  bool _treeVisible = true;
  bool _treeLocked = false;
  bool _treeOpen = true;
  String _selected = 'row2';
  Color _fieldColor = const Color(0xFFF2C94C);

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Scrollbar(
      child: ListView(
        primary: true,
        padding: const EdgeInsets.symmetric(
          horizontal: SsSpace.s4,
          vertical: SsSpace.s6,
        ),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: SsSpace.s6,
                    runSpacing: SsSpace.s3,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('Design system', style: t.text.heading),
                      SsToggle(
                        value: !widget.dark,
                        onChanged: (v) => widget.onTheme(!v),
                        label: 'Light theme',
                      ),
                    ],
                  ),
                  const SizedBox(height: SsSpace.s2),
                  Text(
                    'Editor chrome tokens and components. Hover, press and '
                    'keyboard focus are live on every control.',
                    style: t.text.body.copyWith(color: t.colors.textSecondary),
                  ),
                  ..._sections(context),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _sections(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    return [
      _Section('Colour roles', [
        Wrap(
          spacing: SsSpace.s3,
          runSpacing: SsSpace.s3,
          children: [
            for (final (name, color) in <(String, Color)>[
              ('surface0', c.surface0),
              ('surface1', c.surface1),
              ('surface2', c.surface2),
              ('surface3', c.surface3),
              ('borderSubtle', c.borderSubtle),
              ('border', c.border),
              ('borderStrong', c.borderStrong),
              ('textPrimary', c.textPrimary),
              ('textSecondary', c.textSecondary),
              ('textDisabled', c.textDisabled),
              ('accent', c.accent),
              ('accentText', c.accentText),
              ('selection', c.selection),
              ('danger', c.danger),
              ('warning', c.warning),
              ('success', c.success),
              ('focusRing', c.focusRing),
            ])
              _Chip(name: name, color: color),
          ],
        ),
      ]),
      _Section('Type scale', [
        for (final (name, style) in <(String, TextStyle)>[
          ('heading 20/28', t.text.heading),
          ('title 16/24', t.text.title),
          ('large 14/20', t.text.large),
          ('bodyStrong 13/20', t.text.bodyStrong),
          ('body 13/20', t.text.body),
          ('small 12/16', t.text.small),
          ('numeric 12/16  0123456789', t.text.numeric),
          ('caption 11/16', t.text.caption),
          ('OVERLINE 11/16', t.text.overline),
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text('$name   The quick brown fox', style: style),
          ),
      ]),
      _Section('Spacing, radii, elevation, motion', [
        Wrap(
          spacing: SsSpace.s4,
          runSpacing: SsSpace.s3,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            for (final s in <double>[4, 8, 12, 16, 20, 24, 32, 40, 48])
              Column(
                children: [
                  Container(width: s, height: s, color: c.accent),
                  const SizedBox(height: 4),
                  Text('${s.round()}', style: t.text.caption),
                ],
              ),
          ],
        ),
        const SizedBox(height: SsSpace.s4),
        Wrap(
          spacing: SsSpace.s4,
          runSpacing: SsSpace.s3,
          children: [
            for (final r in <double>[2, 4, 6, 8, 12])
              Container(
                width: 56,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.surface2,
                  border: Border.all(color: c.borderStrong),
                  borderRadius: BorderRadius.circular(r),
                ),
                child: Text('r${r.round()}', style: t.text.caption),
              ),
            for (final (n, e) in [
              ('e1', SsElevation.e1),
              ('e2', SsElevation.e2),
              ('e3', SsElevation.e3),
            ])
              Container(
                width: 72,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.surface3,
                  borderRadius: SsRadius.brMd,
                  boxShadow: e,
                ),
                child: Text(n, style: t.text.caption),
              ),
          ],
        ),
        const SizedBox(height: SsSpace.s3),
        Text(
          'Motion: instant 60 ms, fast 100 ms, base 160 ms, slow 240 ms; '
          'easeOut (0.2, 0, 0, 1); tooltip delay 500 ms.',
          style: t.text.small.copyWith(color: c.textSecondary),
        ),
      ]),
      _Section('Icons (Lucide, ISC)', [
        Wrap(
          spacing: SsSpace.s2,
          runSpacing: SsSpace.s2,
          children: [
            for (final i in <IconData>[
              SsIcons.mousePointer2,
              SsIcons.frame,
              SsIcons.type,
              SsIcons.square,
              SsIcons.circle,
              SsIcons.hand,
              SsIcons.image,
              SsIcons.layers,
              SsIcons.clapperboard,
              SsIcons.eye,
              SsIcons.eyeOff,
              SsIcons.lock,
              SsIcons.lockOpen,
              SsIcons.search,
              SsIcons.settings,
              SsIcons.undo2,
              SsIcons.redo2,
              SsIcons.play,
              SsIcons.pause,
              SsIcons.pipette,
              SsIcons.copy,
              SsIcons.trash2,
              SsIcons.pencil,
              SsIcons.music,
              SsIcons.link,
              SsIcons.monitor,
              SsIcons.tablet,
              SsIcons.smartphone,
              SsIcons.panelLeft,
              SsIcons.panelRight,
              SsIcons.panelBottom,
              SsIcons.keyboard,
              SsIcons.info,
              SsIcons.triangleAlert,
            ])
              SizedBox(
                width: 32,
                height: 32,
                child: Center(child: SsIcon(i, size: 18)),
              ),
          ],
        ),
      ]),
      _Section('Buttons', [
        Wrap(
          spacing: SsSpace.s3,
          runSpacing: SsSpace.s3,
          children: [
            for (final v in SsButtonVariant.values)
              SsButton(label: v.name, variant: v, onPressed: () {}),
            for (final v in SsButtonVariant.values)
              SsButton(label: '${v.name} disabled', variant: v),
            SsButton(
              label: 'With icon',
              icon: SsIcons.plus,
              variant: SsButtonVariant.primary,
              onPressed: () {},
            ),
          ],
        ),
        const SizedBox(height: SsSpace.s4),
        Wrap(
          spacing: SsSpace.s2,
          children: [
            SsIconButton(
              icon: SsIcons.mousePointer2,
              semanticLabel: 'Move',
              shortcut: 'V',
              onPressed: () {},
            ),
            SsIconButton(
              icon: SsIcons.type,
              semanticLabel: 'Text (selected)',
              selected: true,
              onPressed: () {},
            ),
            const SsIconButton(
              icon: SsIcons.trash2,
              semanticLabel: 'Delete (disabled)',
            ),
          ],
        ),
      ]),
      _Section('Toggle, checkbox', [
        Wrap(
          spacing: SsSpace.s6,
          runSpacing: SsSpace.s3,
          children: [
            SsToggle(
              value: _toggle,
              onChanged: (v) => setState(() => _toggle = v),
              label: 'Toggle',
            ),
            const SsToggle(value: true, onChanged: null, label: 'On, disabled'),
            const SsToggle(
              value: false,
              onChanged: null,
              label: 'Off, disabled',
            ),
            SsCheckbox(
              value: _check,
              onChanged: (v) => setState(() => _check = v),
              label: 'Checkbox',
            ),
            SsCheckbox(value: null, onChanged: (_) {}, label: 'Mixed'),
            SsCheckbox(value: false, onChanged: (_) {}, label: 'Unchecked'),
            const SsCheckbox(value: true, onChanged: null, label: 'Disabled'),
          ],
        ),
      ]),
      _Section('Segmented control', [
        Wrap(
          spacing: SsSpace.s6,
          runSpacing: SsSpace.s3,
          children: [
            SsSegmented<String>(
              semanticLabel: 'Demo segments',
              selected: _seg,
              onChanged: (v) => setState(() => _seg = v),
              segments: const [
                SsSegment(value: 'a', label: 'Both'),
                SsSegment(value: 'b', label: 'This breakpoint'),
                SsSegment(value: 'c', label: 'Disabled', enabled: false),
              ],
            ),
            SsSegmented<String>(
              semanticLabel: 'Breakpoint',
              selected: _segIcon,
              onChanged: (v) => setState(() => _segIcon = v),
              segments: const [
                SsSegment(
                  value: 'desktop',
                  icon: SsIcons.monitor,
                  semanticLabel: 'Desktop',
                ),
                SsSegment(
                  value: 'tablet',
                  icon: SsIcons.tablet,
                  semanticLabel: 'Tablet',
                ),
                SsSegment(
                  value: 'mobile',
                  icon: SsIcons.smartphone,
                  semanticLabel: 'Mobile',
                ),
              ],
            ),
            const SsSegmented<String>(
              semanticLabel: 'Disabled segments',
              selected: 'a',
              onChanged: null,
              segments: [
                SsSegment(value: 'a', label: 'Off'),
                SsSegment(value: 'b', label: 'Disabled'),
              ],
            ),
          ],
        ),
      ]),
      const _Section('Text field', [
        Wrap(
          spacing: SsSpace.s4,
          runSpacing: SsSpace.s3,
          children: [
            SizedBox(
              width: 200,
              child: SsTextField(
                placeholder: 'Placeholder',
                semanticLabel: 'Empty',
              ),
            ),
            SizedBox(
              width: 200,
              child: SsTextField(
                initialValue: 'Filled value',
                semanticLabel: 'Filled',
                prefix: SsIcon(SsIcons.search, size: 14),
              ),
            ),
            SizedBox(
              width: 200,
              child: SsTextField(
                initialValue: 'bad value',
                errorText: 'Something is wrong',
                semanticLabel: 'Error',
              ),
            ),
            SizedBox(
              width: 200,
              child: SsTextField(
                initialValue: 'Disabled',
                enabled: false,
                semanticLabel: 'Disabled',
              ),
            ),
          ],
        ),
      ]),
      _Section('Number field', [
        Text(
          'Drag the label to scrub (Shift x10, Alt x0.1). Arrow keys step. '
          'Type 120/2, +8, *2. Enter or blur commits, Esc cancels.',
          style: t.text.small.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: SsSpace.s3),
        Wrap(
          spacing: SsSpace.s4,
          runSpacing: SsSpace.s3,
          children: [
            SsNumberField(
              width: 110,
              label: 'X',
              value: _num,
              unit: 'px',
              onChanged: (v) => setState(() => _num = v),
            ),
            SsNumberField(
              width: 110,
              label: 'W',
              value: _mixedNum,
              mixed: _mixedNum == null,
              min: 0,
              onChanged: (v) => setState(() => _mixedNum = v),
            ),
            SsNumberField(
              width: 110,
              label: 'R',
              value: _angle,
              unit: '°',
              min: -360,
              max: 360,
              onChanged: (v) => setState(() => _angle = v),
            ),
            const SsNumberField(
              width: 110,
              label: 'Y',
              value: 40,
              onChanged: null,
            ),
            SsNumberField(
              width: 110,
              value: 0.5,
              step: 0.1,
              min: 0,
              max: 1,
              semanticLabel: 'Opacity, no label',
              onChanged: (_) {},
            ),
          ],
        ),
      ]),
      _Section('Dropdown, menu, context menu', [
        Wrap(
          spacing: SsSpace.s4,
          runSpacing: SsSpace.s3,
          children: [
            SsDropdown<String>(
              width: 160,
              semanticLabel: 'Choice',
              value: _drop,
              onChanged: (v) => setState(() => _drop = v),
              items: const [
                SsDropdownItem(value: 'one', label: 'One'),
                SsDropdownItem(value: 'two', label: 'Two'),
                SsDropdownItem(value: 'three', label: 'Three'),
              ],
            ),
            const SsDropdown<String>(
              width: 160,
              mixed: true,
              value: null,
              onChanged: _noop,
              items: [SsDropdownItem(value: 'a', label: 'A')],
            ),
            const SsDropdown<String>(
              width: 160,
              value: 'a',
              onChanged: null,
              items: [SsDropdownItem(value: 'a', label: 'Disabled')],
            ),
            Builder(
              builder: (ctx) => SsButton(
                label: 'Open menu',
                onPressed: () => showSsMenu(
                  ctx,
                  anchor: ssGlobalRect(ctx),
                  entries: _menuEntries(ctx),
                ),
              ),
            ),
            SsContextMenuRegion(
              entries: () => _menuEntries(context),
              child: Container(
                width: 200,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border.all(color: c.border),
                  borderRadius: SsRadius.brMd,
                ),
                child: Text('Right-click me', style: t.text.small),
              ),
            ),
          ],
        ),
      ]),
      _Section('Tabs, panel, tooltip', [
        SizedBox(
          height: 120,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: c.surface1,
              border: Border.all(color: c.borderSubtle),
              borderRadius: SsRadius.brMd,
            ),
            child: Column(
              children: [
                SsTabs(
                  selectedId: _tab,
                  onChanged: (v) => setState(() => _tab = v),
                  tabs: const [
                    SsTab(id: 'scenes', label: 'Scenes'),
                    SsTab(id: 'layers', label: 'Layers'),
                    SsTab(id: 'assets', label: 'Assets'),
                  ],
                ),
                Expanded(
                  child: Center(child: Text('Tab: $_tab', style: t.text.body)),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: SsSpace.s4),
        DecoratedBox(
          decoration: BoxDecoration(
            color: c.surface1,
            border: Border.all(color: c.borderSubtle),
            borderRadius: SsRadius.brMd,
          ),
          child: Column(
            children: [
              SsPanel(
                title: 'Collapsible panel',
                expanded: _panelOpen,
                onExpandedChanged: (v) => setState(() => _panelOpen = v),
                actions: [
                  SsIconButton(
                    icon: SsIcons.plus,
                    semanticLabel: 'Add',
                    size: 24,
                    iconSize: 14,
                    onPressed: () {},
                  ),
                ],
                child: Text('Panel content', style: t.text.body),
              ),
              SsPanel(
                title: 'Collapsed initially',
                initiallyExpanded: false,
                divider: false,
                child: Text('Hidden until opened', style: t.text.body),
              ),
            ],
          ),
        ),
        const SizedBox(height: SsSpace.s4),
        SsTooltip(
          message: 'Tooltip text',
          shortcut: 'Ctrl+K',
          child: SsButton(label: 'Hover or focus me', onPressed: () {}),
        ),
      ]),
      _Section('Tree row', [
        Container(
          width: 320,
          padding: const EdgeInsets.all(SsSpace.s2),
          decoration: BoxDecoration(
            color: c.surface1,
            border: Border.all(color: c.borderSubtle),
            borderRadius: SsRadius.brMd,
          ),
          child: Column(
            children: [
              SsTreeRow(
                label: 'Scene 1',
                icon: SsIcons.clapperboard,
                hasChildren: true,
                expanded: _treeOpen,
                selected: _selected == 'row1',
                onTap: () => setState(() => _selected = 'row1'),
                onExpandedChanged: (v) => setState(() => _treeOpen = v),
                onRename: (_) {},
              ),
              if (_treeOpen) ...[
                SsTreeRow(
                  label: _treeName,
                  depth: 1,
                  icon: SsIcons.type,
                  selected: _selected == 'row2',
                  visible: _treeVisible,
                  locked: _treeLocked,
                  onTap: () => setState(() => _selected = 'row2'),
                  onRename: (v) => setState(() => _treeName = v),
                  onVisibleChanged: (v) => setState(() => _treeVisible = v),
                  onLockedChanged: (v) => setState(() => _treeLocked = v),
                ),
                SsTreeRow(
                  label: 'Background image',
                  depth: 1,
                  icon: SsIcons.image,
                  selected: _selected == 'row3',
                  visible: false,
                  onTap: () => setState(() => _selected = 'row3'),
                  onVisibleChanged: (_) {},
                  onLockedChanged: (_) {},
                ),
                SsTreeRow(
                  label: 'Locked frame',
                  depth: 1,
                  icon: SsIcons.frame,
                  locked: true,
                  onTap: () {},
                  onVisibleChanged: (_) {},
                  onLockedChanged: (_) {},
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: SsSpace.s2),
        Text(
          'Double-click or F2 renames. Left/Right collapses and expands.',
          style: t.text.small.copyWith(color: c.textSecondary),
        ),
      ]),
      _Section('Colour', [
        Wrap(
          spacing: SsSpace.s4,
          runSpacing: SsSpace.s4,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: [
            Wrap(
              spacing: SsSpace.s2,
              children: [
                SsColorSwatch(
                  color: const Color(0xFFE5484D),
                  onTap: () => setState(() => _color = const Color(0xFFE5484D)),
                ),
                SsColorSwatch(
                  color: const Color(0x802F6FED),
                  selected: true,
                  onTap: () {},
                ),
                const SsColorSwatch(color: Color(0xFF3FBF7F)),
                const SsColorSwatch(color: Color(0x00000000), mixed: true),
              ],
            ),
            SizedBox(
              width: 140,
              child: SsColorField(
                color: _fieldColor,
                onChanged: (v) => setState(() => _fieldColor = v),
              ),
            ),
            const SizedBox(
              width: 140,
              child: SsColorField(
                color: Color(0xFF000000),
                mixed: true,
                onChanged: _noopColor,
              ),
            ),
            Container(
              padding: const EdgeInsets.all(SsSpace.s3),
              decoration: BoxDecoration(
                color: c.surface3,
                borderRadius: SsRadius.brLg,
                border: Border.all(color: c.border),
              ),
              child: SsColorPicker(
                width: 260,
                color: _color,
                onChanged: (v) => setState(() => _color = v),
              ),
            ),
          ],
        ),
      ]),
      _Section('Alignment matrix, constraints', [
        Wrap(
          spacing: SsSpace.s8,
          runSpacing: SsSpace.s4,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: [
            SsAlignmentMatrix(
              horizontal: _ah,
              vertical: _av,
              spaceBetween: _space,
              onSpaceBetweenChanged: (v) => setState(() => _space = v),
              onChanged: (h, v) => setState(() {
                _ah = h;
                _av = v;
              }),
            ),
            const SsAlignmentMatrix(
              horizontal: null,
              vertical: null,
              onChanged: null,
            ),
            SizedBox(
              width: 260,
              child: SsConstraintsWidget(
                horizontal: _ch,
                vertical: _cv,
                onChanged: (h, v) => setState(() {
                  _ch = h;
                  _cv = v;
                }),
              ),
            ),
            const SizedBox(
              width: 260,
              child: SsConstraintsWidget(
                horizontal: null,
                vertical: null,
                onChanged: null,
              ),
            ),
          ],
        ),
      ]),
      _Section('Dialog, toast', [
        Wrap(
          spacing: SsSpace.s3,
          runSpacing: SsSpace.s3,
          children: [
            Builder(
              builder: (ctx) => SsButton(
                label: 'Show dialog',
                onPressed: () => showSsConfirm(
                  ctx,
                  title: 'Delete scene?',
                  message: 'The scene and its layers will be removed.',
                  confirmLabel: 'Delete',
                  danger: true,
                ),
              ),
            ),
            for (final k in SsToastKind.values)
              Builder(
                builder: (ctx) => SsButton(
                  label: 'Toast: ${k.name}',
                  onPressed: () => SsToast.show(
                    ctx,
                    'This is a ${k.name} toast.',
                    kind: k,
                    actionLabel: k == SsToastKind.danger ? 'Undo' : null,
                  ),
                ),
              ),
          ],
        ),
      ]),
      const SizedBox(height: SsSpace.s10),
    ];
  }

  List<SsMenuEntry> _menuEntries(BuildContext context) => [
    const SsMenuLabel('Arrange'),
    SsMenuItem(
      label: 'Bring forward',
      shortcut: 'Ctrl+]',
      icon: SsIcons.arrowUp,
      onSelected: () {},
    ),
    SsMenuItem(
      label: 'Send backward',
      shortcut: 'Ctrl+[',
      icon: SsIcons.arrowDown,
      onSelected: () {},
    ),
    const SsMenuDivider(),
    SsMenuItem(label: 'Snap to grid', checked: true, onSelected: () {}),
    const SsMenuItem(label: 'Disabled item'),
    const SsMenuDivider(),
    SsMenuItem(
      label: 'Delete',
      danger: true,
      icon: SsIcons.trash2,
      onSelected: () {},
    ),
  ];
}

void _noop(String _) {}
void _noopColor(Color _) {}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Padding(
      padding: const EdgeInsets.only(top: SsSpace.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: t.text.title),
          const SizedBox(height: SsSpace.s2),
          Container(height: 1, color: t.colors.borderSubtle),
          const SizedBox(height: SsSpace.s4),
          ...children,
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.name, required this.color});

  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return SizedBox(
      width: 112,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 36,
            decoration: BoxDecoration(
              color: color,
              borderRadius: SsRadius.brMd,
              border: Border.all(color: t.colors.border),
            ),
          ),
          const SizedBox(height: 4),
          Text(name, style: t.text.caption),
        ],
      ),
    );
  }
}
