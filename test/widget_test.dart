import 'package:flutter_test/flutter_test.dart';

import 'package:alice_chat/app/app.dart';

void main() {
  testWidgets('App smoke test - app launches', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const AliceChatApp());

    // Verify that the app bar title is shown.
    expect(find.text('通讯录'), findsOneWidget);
  });

  testWidgets('ContactsScreen shows alice contact', (WidgetTester tester) async {
    await tester.pumpWidget(const AliceChatApp());
    await tester.pumpAndSettle();

    // Verify alice appears in contacts list.
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('点击进入真实聊天'), findsOneWidget);
  });

  testWidgets('Tapping alice navigates to chat screen', (WidgetTester tester) async {
    await tester.pumpWidget(const AliceChatApp());
    await tester.pumpAndSettle();

    // Tap the alice ListTile.
    await tester.tap(find.text('alice'));
    await tester.pumpAndSettle();

    // Verify chat screen app bar shows alice.
    expect(find.text('alice'), findsWidgets);
  });
}
