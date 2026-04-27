import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:snapshot/lobby/lobby_entry_screen.dart';
import 'package:snapshot/services/testing/in_memory_lobby_repository.dart';

void main() {
  testWidgets('Create lobby button takes the host into the waiting room', (tester) async {
    final repo = InMemoryLobbyRepository(currentUid: 'host-1')
      ..registerProfile('host-1', displayName: 'Alice');

    await tester.pumpWidget(MaterialApp(
      home: LobbyEntryScreen(repo: repo, displayName: 'Alice'),
    ));

    await tester.tap(find.text('Create lobby'));
    await tester.pumpAndSettle();

    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);

    addTearDown(repo.dispose);
  });

  testWidgets('Join button takes a player into the join screen', (tester) async {
    final repo = InMemoryLobbyRepository(currentUid: 'host-1')
      ..registerProfile('host-1', displayName: 'Alice')
      ..registerProfile('joiner-1', displayName: 'Bob');
    final created = await repo.createLobby();
    repo.currentUid = 'joiner-1';

    await tester.pumpWidget(MaterialApp(
      home: LobbyEntryScreen(repo: repo, displayName: 'Bob'),
    ));

    await tester.tap(find.text('Join a lobby'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), created.code);
    await tester.tap(find.widgetWithText(FilledButton, 'Join'));
    await tester.pumpAndSettle();

    // Joiner waiting room — code visible but no QR.
    expect(find.text(created.code), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);

    addTearDown(repo.dispose);
  });
}
