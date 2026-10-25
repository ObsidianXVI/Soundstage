import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/core.dart';

/// The Tokens tab (architecture §8; m3.md T3.1): the story's variable
/// collections, their modes and breakpoint modes, the variables of one
/// collection with their values in one mode, and the named styles.
///
/// - A collection picker with add, rename and delete; a mode picker with
///   add, rename, make default and delete. Deleting what is in use replaces
///   every use by its value first (one undo step).
/// - Breakpoints: which mode each breakpoint uses (responsive tokens).
/// - Variables grouped by their slash name, renamed inline, with a value
///   editor for the shown mode, or an alias chip.
/// - Text, paint and effect styles: rename and delete. Styles are created
///   from the inspector.
///
/// Every change is a [TokenEdit] through [editorControllerProvider].
class TokensPanel extends ConsumerStatefulWidget {
  const TokensPanel({super.key});

  @override
  ConsumerState<TokensPanel> createState() => _TokensPanelState();
}

const double _valueWidth = 104;

IconData variableTypeIcon(ir.VariableType t) => switch (t) {
  ir.VariableType.color => SsIcons.droplet,
  ir.VariableType.number => SsIcons.ruler,
  ir.VariableType.string => SsIcons.type,
  ir.VariableType.boolean => SsIcons.circleCheck,
  ir.VariableType.fontFamily => SsIcons.caseSensitive,
};

String variableTypeLabel(ir.VariableType t) => switch (t) {
  ir.VariableType.color => 'Colour',
  ir.VariableType.number => 'Number',
  ir.VariableType.string => 'String',
  ir.VariableType.boolean => 'Boolean',
  ir.VariableType.fontFamily => 'Font family',
};

/// The last segment of a slash-grouped name (`color/brand/primary` →
/// `primary`).
String variableLeafName(String name) {
  final i = name.lastIndexOf('/');
  return i < 0 ? name : name.substring(i + 1);
}

String _groupOf(String name) {
  final i = name.lastIndexOf('/');
  return i < 0 ? '' : name.substring(0, i);
}

ir.IrValue _defaultValue(ir.VariableType t, ir.StageDocument doc) =>
    switch (t) {
      ir.VariableType.color => const ir.IrValue.color(
        ir.StageColor(r: 0, g: 0, b: 0),
      ),
      ir.VariableType.number => const ir.IrValue.number(0),
      ir.VariableType.string => const ir.IrValue.string(''),
      ir.VariableType.boolean => const ir.IrValue.boolean(false),
      ir.VariableType.fontFamily => ir.IrValue.string(
        doc.fonts.keys.isEmpty ? '' : doc.fonts.keys.first,
      ),
    };

String _uniqueName(String base, Iterable<String> taken) {
  final set = taken.toSet();
  if (!set.contains(base)) return base;
  for (var i = 2; ; i++) {
    final n = '$base $i';
    if (!set.contains(n)) return n;
  }
}

class _TokensPanelState extends ConsumerState<TokensPanel> {
  String? _collectionId;
  String? _modeId;
  String? _renamingId;

  EditorController get _ctl => ref.read(editorControllerProvider.notifier);
  ir.StageDocument get _doc => ref.read(editorControllerProvider).document;

  void _run(String label, ir.EditResult Function(ir.StageDocument d) edit) =>
      _ctl.execute(TokenEdit(label, edit));

  ir.IdGenerator get _ids => ir.IdGenerator.forDocument(_doc);

  // ---- Collections ----------------------------------------------------------

  void _addCollection() {
    final ids = _ids;
    final id = ids.next(), mode = ids.next();
    final name = _uniqueName('Collection', [
      for (final c in _doc.tokens.collections) c.name,
    ]);
    _run(
      'Add collection',
      (d) => ir.addCollection(
        d,
        ir.VariableCollection(
          id: id,
          name: name,
          modes: [ir.TokenMode(id: mode, name: 'Default')],
          defaultModeId: mode,
        ),
      ),
    );
    setState(() {
      _collectionId = id;
      _modeId = mode;
    });
  }

  Future<void> _renameCollection(ir.VariableCollection c) async {
    final name = await showSsPrompt(
      context,
      title: 'Rename collection',
      initialValue: c.name,
    );
    if (name == null || !mounted) return;
    _run(
      'Rename collection',
      (d) => ir.updateCollection(d, c.id, (c) => c.copyWith(name: name)),
    );
  }

  Future<void> _deleteCollection(ir.VariableCollection c) async {
    final uses = c.variables.fold<int>(
      0,
      (n, v) => n + ir.variableUseCount(_doc, v.id),
    );
    final ok = await showSsConfirm(
      context,
      title: 'Delete collection',
      message: uses == 0
          ? '"${c.name}" and its ${c.variables.length} variables will be '
                'deleted.'
          : '"${c.name}" is used by $uses properties. They keep their '
                'current values.',
      confirmLabel: 'Delete',
      danger: true,
    );
    if (!ok || !mounted) return;
    _run('Delete collection', (d) => ir.removeCollection(d, c.id));
    setState(() => _collectionId = null);
  }

  // ---- Modes ----------------------------------------------------------------

  Future<void> _addMode(ir.VariableCollection c) async {
    final name = await showSsPrompt(
      context,
      title: 'Add mode',
      initialValue: _uniqueName('Mode', [for (final m in c.modes) m.name]),
      confirmLabel: 'Add',
    );
    if (name == null || !mounted) return;
    final id = _ids.next();
    _run(
      'Add mode',
      (d) => ir.addMode(d, c.id, ir.TokenMode(id: id, name: name)),
    );
    setState(() => _modeId = id);
  }

  Future<void> _renameMode(ir.VariableCollection c, ir.TokenMode m) async {
    final name = await showSsPrompt(
      context,
      title: 'Rename mode',
      initialValue: m.name,
    );
    if (name == null || !mounted) return;
    _run(
      'Rename mode',
      (d) => ir.updateCollection(
        d,
        c.id,
        (c) => c.copyWith(
          modes: [
            for (final x in c.modes) x.id == m.id ? x.copyWith(name: name) : x,
          ],
        ),
      ),
    );
  }

  Future<void> _deleteMode(ir.VariableCollection c, ir.TokenMode m) async {
    final ok = await showSsConfirm(
      context,
      title: 'Delete mode',
      message:
          'The values of "${m.name}" will be deleted. Frames and breakpoints '
          'using it fall back to the default mode.',
      confirmLabel: 'Delete',
      danger: true,
    );
    if (!ok || !mounted) return;
    _run('Delete mode', (d) => ir.removeMode(d, c.id, m.id));
    setState(() => _modeId = null);
  }

  void _openModeMenu(
    BuildContext anchor,
    ir.VariableCollection c,
    ir.TokenMode m,
  ) {
    final box = anchor.findRenderObject()! as RenderBox;
    showSsMenu(
      context,
      anchor: box.localToGlobal(Offset.zero) & box.size,
      placement: SsPlacement.belowEnd,
      entries: [
        SsMenuItem(
          label: 'Add mode…',
          icon: SsIcons.plus,
          onSelected: () => _addMode(c),
        ),
        SsMenuItem(
          label: 'Rename mode…',
          icon: SsIcons.pencil,
          onSelected: () => _renameMode(c, m),
        ),
        SsMenuItem(
          label: 'Make default',
          icon: SsIcons.check,
          enabled: c.defaultModeId != m.id,
          onSelected: () => _run(
            'Make default mode',
            (d) => ir.updateCollection(
              d,
              c.id,
              (c) => c.copyWith(defaultModeId: m.id),
            ),
          ),
        ),
        const SsMenuDivider(),
        SsMenuItem(
          label: 'Delete mode',
          icon: SsIcons.trash2,
          danger: true,
          enabled: c.modes.length > 1,
          onSelected: () => _deleteMode(c, m),
        ),
      ],
    );
  }

  void _openCollectionMenu(BuildContext anchor, ir.VariableCollection c) {
    final box = anchor.findRenderObject()! as RenderBox;
    showSsMenu(
      context,
      anchor: box.localToGlobal(Offset.zero) & box.size,
      placement: SsPlacement.belowEnd,
      entries: [
        SsMenuItem(
          label: 'Rename collection…',
          icon: SsIcons.pencil,
          onSelected: () => _renameCollection(c),
        ),
        SsMenuItem(
          label: 'Add mode…',
          icon: SsIcons.plus,
          onSelected: () => _addMode(c),
        ),
        const SsMenuDivider(),
        SsMenuItem(
          label: 'Delete collection',
          icon: SsIcons.trash2,
          danger: true,
          onSelected: () => _deleteCollection(c),
        ),
      ],
    );
  }

  // ---- Variables ------------------------------------------------------------

  void _openAddVariableMenu(BuildContext anchor, ir.VariableCollection c) {
    final box = anchor.findRenderObject()! as RenderBox;
    showSsMenu(
      context,
      anchor: box.localToGlobal(Offset.zero) & box.size,
      placement: SsPlacement.belowEnd,
      entries: [
        for (final t in ir.VariableType.values)
          SsMenuItem(
            label: variableTypeLabel(t),
            icon: variableTypeIcon(t),
            onSelected: () => _addVariable(c, t),
          ),
      ],
    );
  }

  void _addVariable(ir.VariableCollection c, ir.VariableType t) {
    final id = _ids.next();
    final value = _defaultValue(t, _doc);
    final name = _uniqueName(variableTypeLabel(t).toLowerCase(), [
      for (final v in c.variables) v.name,
    ]);
    _run(
      'Add variable',
      (d) => ir.addVariable(
        d,
        c.id,
        ir.Variable(
          id: id,
          name: name,
          type: t,
          valuesByMode: {for (final m in c.modes) m.id: value},
        ),
      ),
    );
    setState(() => _renamingId = id);
  }

  Future<void> _deleteVariable(ir.Variable v) async {
    final uses = ir.variableUseCount(_doc, v.id);
    if (uses > 0) {
      final ok = await showSsConfirm(
        context,
        title: 'Delete variable',
        message:
            '"${v.name}" is used by $uses '
            '${uses == 1 ? 'property' : 'properties'}. They keep their '
            'current values.',
        confirmLabel: 'Delete',
        danger: true,
      );
      if (!ok || !mounted) return;
    }
    _run('Delete variable', (d) => ir.removeVariable(d, v.id));
  }

  void _duplicateVariable(ir.VariableCollection c, ir.Variable v) {
    final id = _ids.next();
    final name = _uniqueName('${v.name} copy', [
      for (final x in c.variables) x.name,
    ]);
    _run(
      'Duplicate variable',
      (d) => ir.addVariable(d, c.id, v.copyWith(id: id, name: name)),
    );
  }

  void _openAliasMenu(Offset at, ir.Variable v, String modeId) {
    final targets = [
      for (final c in _doc.tokens.collections)
        for (final x in c.variables)
          if (x.id != v.id && x.type == v.type) (c, x),
    ];
    showSsContextMenu(
      context,
      position: at,
      entries: [
        if (targets.isEmpty)
          const SsMenuItem(label: 'No variables of this type', enabled: false),
        for (final (c, x) in targets)
          SsMenuItem(
            label: '${c.name} / ${x.name}',
            icon: variableTypeIcon(x.type),
            onSelected: () => _run(
              'Set alias',
              (d) => ir.setVariableValue(
                d,
                v.id,
                modeId,
                ir.IrValue.tokenRef(ir.TokenRef(variableId: x.id)),
              ),
            ),
          ),
      ],
    );
  }

  void _openVariableMenu(
    Offset at,
    ir.VariableCollection c,
    ir.Variable v,
    String modeId,
  ) {
    final aliased = v.valuesByMode[modeId] is ir.TokenRefValue;
    showSsContextMenu(
      context,
      position: at,
      entries: [
        SsMenuItem(
          label: 'Rename',
          icon: SsIcons.pencil,
          shortcut: 'F2',
          onSelected: () => setState(() => _renamingId = v.id),
        ),
        SsMenuItem(
          label: 'Duplicate',
          icon: SsIcons.copy,
          onSelected: () => _duplicateVariable(c, v),
        ),
        if (aliased)
          SsMenuItem(
            label: 'Remove alias',
            icon: SsIcons.unlink,
            onSelected: () => _run(
              'Remove alias',
              (d) => ir.setVariableValue(
                d,
                v.id,
                modeId,
                ir.concreteVariableValue(d, v.id, modeId) ??
                    _defaultValue(v.type, d),
              ),
            ),
          )
        else
          SsMenuItem(
            label: 'Set alias…',
            icon: SsIcons.link,
            onSelected: () => _openAliasMenu(at, v, modeId),
          ),
        const SsMenuDivider(),
        SsMenuItem(
          label: 'Delete',
          icon: SsIcons.trash2,
          danger: true,
          onSelected: () => _deleteVariable(v),
        ),
      ],
    );
  }

  // ---- Styles ---------------------------------------------------------------

  Future<void> _deleteStyle(ir.StyleKind kind, String id, String name) async {
    final uses = ir.styleUseCount(_doc, kind, id);
    if (uses > 0) {
      final ok = await showSsConfirm(
        context,
        title: 'Delete style',
        message:
            '"$name" is used by $uses ${uses == 1 ? 'layer' : 'layers'}. '
            'They keep its values as their own.',
        confirmLabel: 'Delete',
        danger: true,
      );
      if (!ok || !mounted) return;
    }
    _run('Delete style', (d) => ir.removeStyle(d, kind, id));
  }

  void _renameStyle(ir.StyleKind kind, String id, String name) {
    _run('Rename style', (d) {
      final t = d.tokens;
      return switch (kind) {
        ir.StyleKind.text => ir.setTextStyle(
          d,
          id,
          t.textStyles[id]!.copyWith(name: name),
        ),
        ir.StyleKind.paint => ir.setPaintStyle(
          d,
          id,
          t.paintStyles[id]!.copyWith(name: name),
        ),
        ir.StyleKind.effect => ir.setEffectStyle(
          d,
          id,
          t.effectStyles[id]!.copyWith(name: name),
        ),
      };
    });
  }

  // ---- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final tokens = ref.watch(
      editorControllerProvider.select((s) => s.document.tokens),
    );
    final breakpoints = ref.watch(
      editorControllerProvider.select((s) => s.document.breakpoints),
    );
    final cols = tokens.collections;
    final col = cols.isEmpty
        ? null
        : cols.firstWhere(
            (c) => c.id == _collectionId,
            orElse: () => cols.first,
          );
    final mode = col?.modes.firstWhere(
      (m) => m.id == _modeId,
      orElse: () => col.modes.firstWhere(
        (m) => m.id == col.defaultModeId,
        orElse: () => col.modes.first,
      ),
    );

    Widget overline(String text, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.only(
        left: SsSpace.s3,
        right: SsSpace.s1,
        top: SsSpace.s3,
        bottom: SsSpace.s1,
      ),
      child: SizedBox(
        height: 24,
        child: Row(
          children: [
            Expanded(child: Text(text, style: t.text.overline)),
            ?trailing,
          ],
        ),
      ),
    );

    final children = <Widget>[
      // Collection header.
      Padding(
        padding: const EdgeInsets.fromLTRB(
          SsSpace.s3,
          SsSpace.s2,
          SsSpace.s1,
          0,
        ),
        child: Row(
          children: [
            Expanded(
              child: col == null
                  ? Text('No collections', style: t.text.caption)
                  : SsDropdown<String>(
                      key: const ValueKey<String>('tokens-collection'),
                      semanticLabel: 'Collection',
                      value: col.id,
                      onChanged: (id) => setState(() {
                        _collectionId = id;
                        _modeId = null;
                      }),
                      items: [
                        for (final c in cols)
                          SsDropdownItem(value: c.id, label: c.name),
                      ],
                    ),
            ),
            SsIconButton(
              key: const ValueKey<String>('tokens-add-collection'),
              icon: SsIcons.plus,
              semanticLabel: 'Add collection',
              tooltip: 'Add collection',
              size: 24,
              iconSize: 14,
              onPressed: _addCollection,
            ),
            if (col != null)
              Builder(
                builder: (b) => SsIconButton(
                  key: const ValueKey<String>('tokens-collection-menu'),
                  icon: SsIcons.ellipsis,
                  semanticLabel: 'Collection options',
                  size: 24,
                  iconSize: 14,
                  onPressed: () => _openCollectionMenu(b, col),
                ),
              ),
          ],
        ),
      ),
    ];

    if (col == null) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SsSpace.s3,
            vertical: SsSpace.s6,
          ),
          child: Column(
            children: [
              SsIcon(SsIcons.hexagon, size: 24, color: t.colors.textDisabled),
              const SizedBox(height: SsSpace.s3),
              Text('No tokens yet', style: t.text.bodyStrong),
              const SizedBox(height: SsSpace.s2),
              Text(
                'Collections hold colours, sizes and fonts you reuse, '
                'with modes such as light and dark.',
                style: t.text.caption,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: SsSpace.s3),
              SsButton(label: 'New collection', onPressed: _addCollection),
            ],
          ),
        ),
      );
    } else {
      final m = mode!;
      // Mode picker.
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(
            SsSpace.s3,
            SsSpace.s2,
            SsSpace.s1,
            0,
          ),
          child: Row(
            children: [
              SizedBox(width: 48, child: Text('Mode', style: t.text.caption)),
              Expanded(
                child: SsDropdown<String>(
                  key: const ValueKey<String>('tokens-mode'),
                  semanticLabel: 'Mode',
                  value: m.id,
                  onChanged: (id) => setState(() => _modeId = id),
                  items: [
                    for (final x in col.modes)
                      SsDropdownItem(
                        value: x.id,
                        label: x.id == col.defaultModeId
                            ? '${x.name} (default)'
                            : x.name,
                      ),
                  ],
                ),
              ),
              Builder(
                builder: (b) => SsIconButton(
                  key: const ValueKey<String>('tokens-mode-menu'),
                  icon: SsIcons.ellipsis,
                  semanticLabel: 'Mode options',
                  size: 24,
                  iconSize: 14,
                  onPressed: () => _openModeMenu(b, col, m),
                ),
              ),
            ],
          ),
        ),
      );

      // Breakpoint modes.
      if (col.modes.length > 1) {
        children.add(overline('BREAKPOINTS'));
        for (final bp in breakpoints) {
          children.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SsSpace.s3,
                0,
                SsSpace.s1,
                SsSpace.s1,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      bp.name,
                      style: t.text.body,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  SizedBox(
                    width: 132,
                    child: SsDropdown<String>(
                      key: ValueKey<String>('tokens-bp-mode-${bp.id}'),
                      semanticLabel: '${bp.name} mode',
                      value: col.breakpointModes[bp.id] ?? '',
                      onChanged: (v) => _run(
                        'Set breakpoint mode',
                        (d) => ir.updateCollection(
                          d,
                          col.id,
                          (c) => c.copyWith(
                            breakpointModes: {
                              for (final e in c.breakpointModes.entries)
                                if (e.key != bp.id) e.key: e.value,
                              if (v.isNotEmpty) bp.id: v,
                            },
                          ),
                        ),
                      ),
                      items: [
                        const SsDropdownItem(value: '', label: 'Auto'),
                        for (final x in col.modes)
                          SsDropdownItem(value: x.id, label: x.name),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }
      }

      // Variables.
      children.add(
        overline(
          'VARIABLES',
          trailing: Builder(
            builder: (b) => SsIconButton(
              key: const ValueKey<String>('tokens-add-variable'),
              icon: SsIcons.plus,
              semanticLabel: 'Add variable',
              tooltip: 'Add variable',
              size: 24,
              iconSize: 14,
              onPressed: () => _openAddVariableMenu(b, col),
            ),
          ),
        ),
      );
      if (col.variables.isEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SsSpace.s3,
              vertical: SsSpace.s2,
            ),
            child: Text('No variables', style: t.text.caption),
          ),
        );
      }
      final groups = <String, List<ir.Variable>>{};
      for (final v in col.variables) {
        (groups[_groupOf(v.name)] ??= []).add(v);
      }
      final names = groups.keys.toList()..sort();
      for (final g in names) {
        if (g.isNotEmpty) {
          children.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SsSpace.s3,
                SsSpace.s2,
                SsSpace.s3,
                SsSpace.s1,
              ),
              child: Text(
                g.replaceAll('/', ' › '),
                style: t.text.caption.copyWith(color: t.colors.textSecondary),
              ),
            ),
          );
        }
        for (final v in groups[g]!) {
          children.add(_variableRow(col, v, m.id));
        }
      }
    }

    // Styles.
    void styleList(
      String title,
      ir.StyleKind kind,
      Map<String, String> names,
      IconData icon,
    ) {
      if (names.isEmpty) return;
      children.add(overline(title));
      for (final MapEntry(key: id, value: name) in names.entries) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: SsSpace.s2),
            child: SsTreeRow(
              key: ValueKey<String>('style-$id'),
              label: name,
              icon: icon,
              showToggles: false,
              startRenaming: _renamingId == id,
              onRenameEnd: () {
                if (_renamingId != null) setState(() => _renamingId = null);
              },
              onRename: (n) => _renameStyle(kind, id, n),
              onSecondaryTapDown: (d) => showSsContextMenu(
                context,
                position: d.globalPosition,
                entries: [
                  SsMenuItem(
                    label: 'Rename',
                    icon: SsIcons.pencil,
                    onSelected: () => setState(() => _renamingId = id),
                  ),
                  SsMenuItem(
                    label: 'Delete',
                    icon: SsIcons.trash2,
                    danger: true,
                    onSelected: () => _deleteStyle(kind, id, name),
                  ),
                ],
              ),
            ),
          ),
        );
      }
    }

    styleList('TEXT STYLES', ir.StyleKind.text, {
      for (final e in tokens.textStyles.entries) e.key: e.value.name,
    }, SsIcons.type);
    styleList('PAINT STYLES', ir.StyleKind.paint, {
      for (final e in tokens.paintStyles.entries) e.key: e.value.name,
    }, SsIcons.droplet);
    styleList('EFFECT STYLES', ir.StyleKind.effect, {
      for (final e in tokens.effectStyles.entries) e.key: e.value.name,
    }, SsIcons.sun);

    return ListView(
      padding: const EdgeInsets.only(bottom: SsSpace.s4),
      children: children,
    );
  }

  Widget _variableRow(ir.VariableCollection c, ir.Variable v, String modeId) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: SsSpace.s2),
        child: SsTreeRow(
          key: ValueKey<String>('variable-${v.id}'),
          label: variableLeafName(v.name),
          icon: variableTypeIcon(v.type),
          showToggles: false,
          startRenaming: _renamingId == v.id,
          onRenameEnd: () {
            if (_renamingId != null) setState(() => _renamingId = null);
          },
          // The inline editor edits the leaf; a typed slash regroups.
          onRename: (leaf) {
            final g = _groupOf(v.name);
            final name = g.isEmpty || leaf.contains('/') ? leaf : '$g/$leaf';
            _run(
              'Rename variable',
              (d) => ir.updateVariable(d, v.id, (v) => v.copyWith(name: name)),
            );
          },
          onSecondaryTapDown: (d) =>
              _openVariableMenu(d.globalPosition, c, v, modeId),
          trailing: SizedBox(
            width: _valueWidth,
            child: VariableValueEditor(
              key: ValueKey<String>('variable-value-${v.id}-$modeId'),
              variable: v,
              modeId: modeId,
            ),
          ),
        ),
      );
}

/// Edits variable [variable]'s value in mode [modeId]: a colour field,
/// number field, text field, switch or font picker by type, or an alias
/// chip (tap: remove the alias).
class VariableValueEditor extends ConsumerWidget {
  const VariableValueEditor({
    required this.variable,
    required this.modeId,
    super.key,
  });

  final ir.Variable variable;
  final String modeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final ctl = ref.read(editorControllerProvider.notifier);
    final v = variable;
    final value = v.valuesByMode[modeId];
    void set(ir.IrValue x, {String? coalesce}) => ctl.execute(
      TokenEdit(
        'Change ${variableLeafName(v.name)}',
        (d) => ir.setVariableValue(d, v.id, modeId, x),
        coalesceKey: coalesce,
      ),
    );

    if (value is ir.TokenRefValue) {
      final doc = ref.watch(editorControllerProvider.select((s) => s.document));
      final target = doc.tokens.collections
          .expand((c) => c.variables)
          .where((x) => x.id == value.value.variableId)
          .firstOrNull;
      return SsTooltip(
        message: 'Alias. Tap to remove.',
        child: SsInteractive(
          semanticLabel: 'Alias of ${target?.name ?? 'missing variable'}',
          onTap: () => set(
            ir.concreteVariableValue(doc, v.id, modeId) ??
                _defaultValue(v.type, doc),
          ),
          builder: (context, states) => Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: SsSpace.s2),
            decoration: BoxDecoration(
              color: t.colors.surface3,
              borderRadius: BorderRadius.circular(SsRadius.sm),
            ),
            alignment: Alignment.centerLeft,
            child: Text(
              target == null ? 'Missing' : variableLeafName(target.name),
              style: t.text.caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      );
    }

    switch (v.type) {
      case ir.VariableType.color:
        final c = value is ir.ColorValue
            ? value.value
            : const ir.StageColor(r: 0, g: 0, b: 0);
        return SsColorField(
          semanticLabel: '${v.name} colour',
          color: Color.from(alpha: c.a, red: c.r, green: c.g, blue: c.b),
          onChangeStart: ctl.beginGesture,
          onChangeEnd: ctl.endGesture,
          onChanged: (x) => set(
            ir.IrValue.color(ir.StageColor(r: x.r, g: x.g, b: x.b, a: x.a)),
            coalesce: 'variable:${v.id}:$modeId',
          ),
        );
      case ir.VariableType.number:
        return SsNumberField(
          semanticLabel: '${v.name} value',
          value: value is ir.NumberValue ? value.value : 0,
          onChangeStart: ctl.beginGesture,
          onChangeEnd: ctl.endGesture,
          onChanged: (x) =>
              set(ir.IrValue.number(x), coalesce: 'variable:${v.id}:$modeId'),
        );
      case ir.VariableType.string:
        return SsTextField(
          semanticLabel: '${v.name} value',
          dense: true,
          initialValue: value is ir.StringValue ? value.value : '',
          releaseFocusOnSubmit: true,
          onSubmitted: (x) => set(ir.IrValue.string(x)),
        );
      case ir.VariableType.boolean:
        return Align(
          alignment: Alignment.centerLeft,
          child: SsToggle(
            semanticLabel: '${v.name} value',
            value: value is ir.BoolValue && value.value,
            onChanged: (x) => set(ir.IrValue.boolean(x)),
          ),
        );
      case ir.VariableType.fontFamily:
        final fonts = ref.watch(
          editorControllerProvider.select((s) => s.document.fonts),
        );
        final id = value is ir.StringValue ? value.value : '';
        return SsDropdown<String>(
          semanticLabel: '${v.name} font',
          value: fonts.containsKey(id) ? id : '',
          onChanged: (x) => set(ir.IrValue.string(x)),
          items: [
            const SsDropdownItem(value: '', label: 'System sans'),
            for (final f in fonts.values)
              SsDropdownItem(value: f.id, label: f.name),
          ],
        );
    }
  }
}
