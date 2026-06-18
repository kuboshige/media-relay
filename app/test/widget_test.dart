// Basic smoke test for media-relay app.

import 'package:flutter_test/flutter_test.dart';

import 'package:media_relay/main.dart';

void main() {
  testWidgets('App builds without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const MediaRelayApp());
    expect(find.text('media-relay'), findsWidgets);
  });
}
