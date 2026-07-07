import 'package:flutter_test/flutter_test.dart';
import 'package:envelope_app/main.dart';

void main() {
  testWidgets('renders Envelope shell', (tester) async {
    await tester.pumpWidget(const EnvelopeApp(autoRefresh: false));
    await tester.pumpAndSettle();

    expect(find.text('Envelope'), findsOneWidget);
    expect(find.text('本地消息'), findsOneWidget);
  });

  testWidgets('message input has no placeholder text', (tester) async {
    await tester.pumpWidget(const EnvelopeApp(autoRefresh: false));
    await tester.pumpAndSettle();

    expect(find.text('输入要发送的端到端加密消息'), findsNothing);
    expect(find.text('你好，来自Envelope Android。'), findsNothing);
  });
}
