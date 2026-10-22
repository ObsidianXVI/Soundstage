import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/runtime/runtime.dart';

Duration _ms(int v) => Duration(milliseconds: v);

void main() {
  group('WheelClassifier', () {
    test('isolated whole notches are notches', () {
      final c = WheelClassifier();
      expect(c.classify(100, _ms(0)), WheelKind.notch);
      expect(c.classify(100, _ms(300)), WheelKind.notch);
      expect(c.classify(-120, _ms(700)), WheelKind.notch);
    });

    test('small and fractional deltas are precise', () {
      final c = WheelClassifier();
      expect(c.classify(12, _ms(0)), WheelKind.precise);
      expect(c.classify(100.5, _ms(500)), WheelKind.precise);
      expect(c.classify(39, _ms(1000)), WheelKind.precise);
    });

    test('a dense trackpad stream stays precise, even a big first delta', () {
      final c = WheelClassifier();
      expect(c.classify(8, _ms(0)), WheelKind.precise);
      // Big integer delta right after: latched as precise.
      expect(c.classify(90, _ms(16)), WheelKind.precise);
      expect(c.classify(60, _ms(120)), WheelKind.precise);
      // Quiet for longer than the latch: a notch again.
      expect(c.classify(100, _ms(400)), WheelKind.notch);
    });

    test('a free-spinning wheel repeats its notch size', () {
      final c = WheelClassifier();
      expect(c.classify(100, _ms(0)), WheelKind.notch);
      expect(c.classify(100, _ms(12)), WheelKind.notch);
      expect(c.classify(100, _ms(24)), WheelKind.notch);
      // Dense but a different size: not a wheel.
      expect(c.classify(70, _ms(30)), WheelKind.precise);
    });
  });

  group('StageScrollController wheel', () {
    late StageScrollController controller;
    var now = Duration.zero;

    Future<void> pump(WidgetTester tester, {StageWheelSmoothing? s}) async {
      now = Duration.zero;
      controller = StageScrollController(
        smoothing: s ?? const StageWheelSmoothing(),
        clock: () => now,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomScrollView(
            controller: controller,
            slivers: [
              const SliverToBoxAdapter(
                child: SizedBox(height: 5000, width: 100),
              ),
            ],
          ),
        ),
      );
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    Future<void> wheel(WidgetTester tester, double dy) async {
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(const Offset(50, 50)));
      await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
    }

    StageScrollPosition position() =>
        controller.position as StageScrollPosition;

    testWidgets('a notch eases to its target and lands exactly', (
      tester,
    ) async {
      await pump(tester);
      await wheel(tester, 100);
      // Not jumped.
      expect(controller.offset, 0);
      expect(position().isWheelAnimating, isTrue);
      var prev = 0.0;
      final samples = <double>[];
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 8));
        samples.add(controller.offset);
        expect(controller.offset, greaterThanOrEqualTo(prev));
        expect(controller.offset, lessThanOrEqualTo(100));
        prev = controller.offset;
      }
      // About 91% done after 120 ms (15 frames of 8 ms).
      expect(samples[14], inInclusiveRange(80, 99));
      expect(samples[0], lessThan(20));
      expect(controller.offset, 100);
      expect(position().isWheelAnimating, isFalse);
    });

    testWidgets('notches accumulate into one target', (tester) async {
      await pump(tester);
      await wheel(tester, 100);
      await tester.pump(const Duration(milliseconds: 16));
      now += _ms(100);
      await wheel(tester, 100);
      now += _ms(100);
      await wheel(tester, 100);
      expect(position().wheelTarget, 300);
      await tester.pump(const Duration(milliseconds: 16));
      await settle(tester);
      expect(controller.offset, 300);
    });

    testWidgets('the target is clamped to the extent', (tester) async {
      await pump(tester);
      await wheel(tester, -100);
      expect(position().isWheelAnimating, isFalse);
      expect(controller.offset, 0);
      controller.jumpTo(controller.position.maxScrollExtent - 30);
      await wheel(tester, 100);
      await settle(tester);
      await settle(tester);
      expect(controller.offset, controller.position.maxScrollExtent);
    });

    testWidgets('precise deltas are applied at once, untouched', (
      tester,
    ) async {
      await pump(tester);
      await wheel(tester, 7);
      expect(controller.offset, 7);
      now += _ms(8);
      await wheel(tester, 90.5);
      expect(controller.offset, 97.5);
      expect(position().isWheelAnimating, isFalse);
    });

    testWidgets('a precise delta cancels a notch in flight', (tester) async {
      await pump(tester);
      await wheel(tester, 100);
      await tester.pump(const Duration(milliseconds: 16));
      final mid = controller.offset;
      now += _ms(300);
      await wheel(tester, 5);
      expect(position().isWheelAnimating, isFalse);
      expect(controller.offset, mid + 5);
      await settle(tester);
      expect(controller.offset, mid + 5);
    });

    testWidgets('keyboard and jumpTo take over from the wheel', (tester) async {
      await pump(tester);
      await wheel(tester, 100);
      await tester.pump(const Duration(milliseconds: 16));
      controller.jumpTo(500);
      expect(position().isWheelAnimating, isFalse);
      await settle(tester);
      expect(controller.offset, 500);
      // An animateTo (what PgDn/Space do) also takes over.
      now += _ms(500);
      await wheel(tester, 100);
      await tester.pump(const Duration(milliseconds: 16));
      unawaited(
        controller.animateTo(
          900,
          duration: const Duration(milliseconds: 200),
          curve: Curves.linear,
        ),
      );
      await tester.pump();
      expect(position().isWheelAnimating, isFalse);
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.offset, 900);
    });

    testWidgets('smoothing null is the stock behaviour', (tester) async {
      await pump(tester);
      controller.smoothing = null;
      await wheel(tester, 100);
      expect(controller.offset, 100);
    });

    testWidgets('frame rate does not change the trajectory', (tester) async {
      Future<double> at120ms(int frameMs) async {
        await pump(tester);
        await wheel(tester, 100);
        for (var t = 0; t < 120; t += frameMs) {
          await tester.pump(Duration(milliseconds: frameMs));
        }
        final v = controller.offset;
        await tester.pumpWidget(const SizedBox());
        return v;
      }

      final a = await at120ms(8);
      final b = await at120ms(30);
      // The first frame after a notch only starts the clock, so a slower
      // frame rate lags by one frame; the curve itself is the same.
      expect(a, closeTo(b, 12));
      expect(b, inInclusiveRange(70, 95));
    });
  });
}
