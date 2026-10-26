import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

void main() {
  test('frame URIs follow the numbered pattern', () {
    const a = Asset(
      id: 'seq',
      kind: AssetKind.imageSequence,
      uri: 'https://cdn.example/s/frame_{0001}.webp',
      frameCount: 120,
    );
    expect(sequenceFrameUri(a, 0), 'https://cdn.example/s/frame_0001.webp');
    expect(sequenceFrameUri(a, 119), 'https://cdn.example/s/frame_0120.webp');
    expect(frameUriFromPattern('local://abc_{0}', 12), 'local://abc_12');
    expect(frameUriFromPattern('f{007}.png', 3), 'f010.png');
    expect(frameUriFromPattern('plain.png', 3), 'plain.png');
    expect(isFramePattern(a.uri), isTrue);
    expect(isFramePattern('local://abc'), isFalse);
  });
  test('a sequence without a pattern or frames is flagged', () {
    StageDocument withAsset(Asset a) =>
        StageDocument.empty(ids: IdGenerator()).copyWith(assets: {a.id: a});
    bool flagged(Asset a) => validateDocument(
      withAsset(a),
    ).any((d) => d.kind == IrDiagnosticKind.invalidValue);
    expect(
      flagged(
        const Asset(id: 's', kind: AssetKind.imageSequence, uri: 'local://s'),
      ),
      isTrue,
    );
    expect(
      flagged(
        const Asset(
          id: 's',
          kind: AssetKind.imageSequence,
          uri: 'local://s_{0001}',
          frameCount: 3,
        ),
      ),
      isFalse,
    );
  });
}
