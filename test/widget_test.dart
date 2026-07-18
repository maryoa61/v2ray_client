import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flaming_cherubim/main.dart';

void main() {
  testWidgets('App initialization smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const V2RayApp());
    expect(find.byType(MaterialApp), findsOneWidget);

    // Replace with an empty widget to trigger V2RayApp's dispose() within
    // the test body (instead of letting the test framework's automatic
    // teardown trigger it). dispose() fires an un-awaited disconnect()
    // call that schedules a 10s internal Timer (via .timeout()). Pump
    // past that duration here so the Timer resolves and is cancelled
    // before the test ends, avoiding a "pending timer" assertion.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 11));
  });
}
