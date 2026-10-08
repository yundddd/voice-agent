// Widget-level check of the push-to-talk hold plumbing: the exact
// Listener+FAB shape from main.dart, driven through synthetic pointers.
// (Device-state questions — mode/worker/phase — the app's debug trace answers.)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class HoldProbe {
  final List<String> log = [];
  int pointers = 0;

  void down() {
    log.add('down');
    pointers++;
    if (pointers == 1) log.add('mic-on');
  }

  void up() {
    if (pointers == 0) return;
    pointers--;
    if (pointers == 0) log.add('send');
  }

  void cancel() {
    pointers = 0;
    log.add('cancel');
  }
}

Widget harness(Widget child) => MaterialApp(
  home: Scaffold(
    body: Column(
      children: [
        const Expanded(child: SizedBox.shrink()),
        child,
        const SizedBox(height: 8),
        const Text('hint'),
      ],
    ),
  ),
);

Widget fab(HoldProbe probe, {VoidCallback? onTap, Widget? parentAbove}) {
  final button = Listener(
    onPointerDown: (_) => probe.down(),
    onPointerUp: (_) => probe.up(),
    onPointerCancel: (_) => probe.cancel(),
    child: FloatingActionButton.large(
      onPressed: onTap ?? () {},
      backgroundColor: Colors.blue,
      foregroundColor: Colors.white,
      shape: const CircleBorder(),
      child: const Icon(Icons.mic, size: 40),
    ),
  );
  return parentAbove ?? button;
}

void main() {
  testWidgets('press and hold, release off-button: mic on, then send', (
    tester,
  ) async {
    final probe = HoldProbe();
    await tester.pumpWidget(harness(fab(probe)));
    final center = tester.getCenter(find.byType(FloatingActionButton));

    final g = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 700)); // a real hold
    await g.moveBy(const Offset(0, -40)); // thumb slides off the button
    await tester.pump(const Duration(milliseconds: 100));
    await g.up();
    await tester.pump();

    expect(probe.log, ['down', 'mic-on', 'send']);
  });

  testWidgets('second resting finger does not stop the first hold', (
    tester,
  ) async {
    final probe = HoldProbe();
    await tester.pumpWidget(harness(fab(probe)));
    final center = tester.getCenter(find.byType(FloatingActionButton));

    final g1 = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 400));
    final g2 = await tester.startGesture(center + const Offset(10, 0));
    await tester.pump(const Duration(milliseconds: 400));
    await g2.up(); // lift the resting finger first
    await tester.pump();
    // both pointer downs are observed; only the last release sends
    expect(probe.log, ['down', 'mic-on', 'down']); // still listening

    await g1.up();
    await tester.pump();
    expect(probe.log, ['down', 'mic-on', 'down', 'send']);
  });

  testWidgets('works inside a scrollable, with finger drag mid-hold', (
    tester,
  ) async {
    final probe = HoldProbe();
    await tester.pumpWidget(
      harness(
        fab(
          probe,
          parentAbove: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 160), // push into scroll range
              fab(probe),
              const SizedBox(height: 160),
            ],
          ),
        ),
      ),
    );
    final center = tester.getCenter(find.byType(FloatingActionButton));
    final g = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 300));
    await g.moveBy(const Offset(0, -30));
    await tester.pump(const Duration(milliseconds: 300));
    await g.up();
    await tester.pump();
    expect(probe.log, ['down', 'mic-on', 'send']);
  });

  testWidgets('quick tap behaves like a brief hold (opens, then sends)', (
    tester,
  ) async {
    final probe = HoldProbe();
    await tester.pumpWidget(harness(fab(probe)));
    await tester.tap(find.byType(FloatingActionButton), warnIfMissed: false);
    await tester.pump();
    expect(probe.log, ['down', 'mic-on', 'send']);
  });
}
