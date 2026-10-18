import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/main.dart';
import 'package:flutter/material.dart';

void main() {
  testWidgets('home shows one Start Fajr button and two small icons', (
    tester,
  ) async {
    await tester.pumpWidget(const SalahCompanionApp());

    expect(find.byKey(const Key('start-fajr')), findsOneWidget);
    expect(find.text('Start Fajr'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.byTooltip('Practice'), findsOneWidget);
    expect(find.byKey(const Key('todays-surahs')), findsOneWidget);
  });

  testWidgets('tapping Start Fajr does not crash before tracking exists', (
    tester,
  ) async {
    await tester.pumpWidget(const SalahCompanionApp());
    await tester.tap(find.byKey(const Key('start-fajr')));
    await tester.pump();
    expect(find.text('Prayer tracking is not built yet.'), findsOneWidget);
  });
}
