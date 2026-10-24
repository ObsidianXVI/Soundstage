import 'package:flutter/material.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

/// "Style: name" with a Detach button, shown above the stroke and effect
/// stacks while the node takes them from a style.
class StyleBanner extends StatelessWidget {
  const StyleBanner({
    required this.name,
    required this.onDetach,
    this.bannerKey,
    super.key,
  });

  final String name;
  final VoidCallback onDetach;
  final Key? bannerKey;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Padding(
      key: bannerKey,
      padding: const EdgeInsets.only(bottom: SsSpace.s2),
      child: Row(
        children: [
          SsIcon(SsIcons.link, size: 14, color: t.colors.textSecondary),
          const SizedBox(width: SsSpace.s1),
          Expanded(
            child: Text(
              'Style: $name',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.text.small.copyWith(color: t.colors.textSecondary),
            ),
          ),
          SsButton(
            label: 'Detach',
            variant: SsButtonVariant.ghost,
            onPressed: onDetach,
          ),
        ],
      ),
    );
  }
}
