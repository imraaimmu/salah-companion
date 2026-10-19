import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/src/screens/summary_page.dart';
import 'package:salah_core/salah_core.dart';

import 'helpers.dart';

void main() {
  testWidgets('completed: one line and one Done button', (tester) async {
    final h = Harness();
    await h.pumpScreen(
      tester,
      const SummaryPage(status: SessionStatus(ended: EndReason.completed)),
    );
    expect(find.text("Fajr completed · 2 rak'ahs"), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
    await tester.tap(find.byKey(const Key('summary-done')));
    await tester.pumpAndSettle();
    expect(find.text('stub-home'), findsOneWidget);
  });

  testWidgets('returns home by itself after 30 s', (tester) async {
    final h = Harness();
    await h.pumpScreen(
      tester,
      const SummaryPage(status: SessionStatus(ended: EndReason.completed)),
    );
    await tester.pump(const Duration(seconds: 29));
    expect(find.byType(SummaryPage), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byType(SummaryPage), findsNothing);
    expect(find.text('stub-home'), findsOneWidget);
  });

  test('gentle messages for other endings', () {
    String t(SessionStatus s) => SummaryPage.messageFor(s).$1;
    expect(
      t(const SessionStatus(ended: EndReason.cameraLost)),
      'Prayer tracking stopped',
    );
    expect(t(const SessionStatus(ended: EndReason.timeout)), 'Session ended');
    expect(t(const SessionStatus(ended: EndReason.cancelled)), 'Session ended');
    expect(
      t(
        const SessionStatus(
          ended: EndReason.cancelled,
          interruption: Interruption.cameraUnavailable,
        ),
      ),
      'Camera unavailable',
    );
    expect(
      SummaryPage.messageFor(
        const SessionStatus(
          ended: EndReason.cancelled,
          interruption: Interruption.phoneCall,
        ),
      ).$2,
      'A call came in.',
    );
  });

  testWidgets('summary is a TalkBack header and survives large text', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final h = Harness();
    await h.pumpScreen(
      tester,
      const SummaryPage(status: SessionStatus(ended: EndReason.timeout)),
      textScale: 2.5,
      textDirection: TextDirection.rtl,
    );
    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('Session ended'), findsOneWidget);
    expect(find.bySemanticsLabel('Done'), findsOneWidget);
    handle.dispose();
  });
}
