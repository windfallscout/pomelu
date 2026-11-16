import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes/core/storage/key_value_store.dart';
import 'package:hermes/core/storage/secret_store.dart';
import 'package:hermes/core/storage/secret_vault.dart';
import 'package:hermes/features/settings/domain/preference_keys.dart';
import 'package:hermes/features/settings/presentation/widgets/settings_secrets_section.dart';

import '../../support/app_host.dart';
import '../../support/memory_stores.dart';

void main() {
  late MemorySecretStore secrets;
  late MemoryKeyValueStore kv;

  setUp(() {
    secrets = MemorySecretStore();
    kv = MemoryKeyValueStore();
  });

  Future<void> pumpSection(
    WidgetTester tester, {
    Size size = const Size(360, 800),
    double textScale = 1,
  }) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SizedBox());
    await pumpApp(
      tester,
      const SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: SettingsSecretsSection(),
        ),
      ),
      textScale: textScale,
      overrides: [
        secretStoreProvider.overrideWithValue(secrets),
        keyValueStoreProvider.overrideWithValue(kv),
      ],
    );
    await tester.pumpAndSettle();
  }

  testWidgets('empty state shows placeholder and Add secret button', (
    tester,
  ) async {
    await pumpSection(tester);
    expect(find.text('Secrets'), findsOneWidget);
    expect(find.text('No saved secrets'), findsOneWidget);
    expect(find.text('Add secret'), findsOneWidget);
  });

  testWidgets('error state reports when secret store cannot open', (
    tester,
  ) async {
    secrets.readError = StateError('locked');
    await pumpSection(tester);
    expect(find.text('Could not open the secret store'), findsOneWidget);
  });

  testWidgets('add, view-mask/reveal, and delete secret without plaintext', (
    tester,
  ) async {
    const secretName = 'OPENAI_API_KEY';
    const secretValue = 'sk-secret-value-xyz';

    await pumpSection(tester);

    // Open Add secret sheet.
    await tester.tap(find.text('Add secret'));
    await tester.pumpAndSettle();
    expect(find.text('New secret'), findsOneWidget);

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    // Secret value input is masked by default and has suggestions disabled.
    final valueField = tester.widget<TextField>(fields.at(1));
    expect(valueField.obscureText, isTrue);
    expect(valueField.enableSuggestions, isFalse);

    await tester.enterText(fields.at(0), secretName);
    await tester.enterText(fields.at(1), secretValue);
    await tester.pump();

    await tester.tap(find.byIcon(CupertinoIcons.checkmark));
    await tester.pumpAndSettle();

    // Stored encrypted in SecretStore, never in KeyValueStore.
    expect(
      secrets.values['${PreferenceKeys.userSecretPrefix}$secretName'],
      secretValue,
    );
    expect(kv.values, isEmpty);

    // UI shows the name and masked placeholder; plaintext is NOT in the tree.
    expect(find.text(secretName), findsOneWidget);
    expect(find.text(maskedSecretPlaceholder), findsOneWidget);
    expect(find.textContaining(secretValue), findsNothing);

    // Reveal on demand, then mask again.
    await tester.tap(find.byTooltip('Show secret'));
    await tester.pumpAndSettle();
    expect(find.text(secretValue), findsOneWidget);

    await tester.tap(find.byTooltip('Hide secret'));
    await tester.pumpAndSettle();
    expect(find.text(maskedSecretPlaceholder), findsOneWidget);
    expect(find.textContaining(secretValue), findsNothing);

    // Delete with confirmation: Cancel keeps it, Delete removes it.
    await tester.tap(find.byTooltip('Delete $secretName'));
    await tester.pumpAndSettle();
    expect(find.text('Delete $secretName?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text(secretName), findsOneWidget);

    await tester.tap(find.byTooltip('Delete $secretName'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text(secretName), findsNothing);
    expect(find.text('No saved secrets'), findsOneWidget);
    expect(secrets.values, isEmpty);
  });

  testWidgets('lays out cleanly at 360dp, 840dp, and 2.0x text scale', (
    tester,
  ) async {
    await SecretVault(secrets).write('GITHUB_TOKEN', 'ghp_123456');
    for (final (size, scale) in [
      (const Size(360, 800), 1.0),
      (const Size(840, 900), 1.0),
      (const Size(360, 800), 2.0),
    ]) {
      await pumpSection(tester, size: size, textScale: scale);
      expect(tester.takeException(), isNull);
      expect(find.text('GITHUB_TOKEN'), findsOneWidget);
      expect(find.text(maskedSecretPlaceholder), findsOneWidget);
    }
  });
}
