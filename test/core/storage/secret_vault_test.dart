import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes/core/storage/key_value_store.dart';
import 'package:hermes/core/storage/secret_store.dart';
import 'package:hermes/core/storage/secret_vault.dart';
import 'package:hermes/features/settings/domain/preference_keys.dart';
import 'package:logger/logger.dart';

import '../../support/memory_stores.dart';

class _FakeFlutterSecureStorage extends Fake implements FlutterSecureStorage {
  final Map<String, String> data = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    data.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.unmodifiable(data);
}

void main() {
  group('SecretVault', () {
    late MemorySecretStore secrets;
    late SecretVault vault;

    setUp(() {
      secrets = MemorySecretStore();
      vault = SecretVault(secrets);
    });

    test('writes, reads, lists, overwrites, and deletes secrets', () async {
      await vault.write('  OPENAI_API_KEY  ', 'sk-test-123');
      await vault.write('anthropic_key', 'ant-456');

      expect(await vault.read('OPENAI_API_KEY'), 'sk-test-123');
      expect(await vault.read('  OPENAI_API_KEY '), 'sk-test-123');
      expect(await vault.contains('OPENAI_API_KEY'), isTrue);
      expect(await vault.contains('MISSING'), isFalse);
      expect(await vault.listNames(), ['anthropic_key', 'OPENAI_API_KEY']);

      await vault.write('OPENAI_API_KEY', 'sk-rotated-789');
      expect(await vault.read('OPENAI_API_KEY'), 'sk-rotated-789');
      expect(await vault.listNames(), ['anthropic_key', 'OPENAI_API_KEY']);

      await vault.delete('anthropic_key');
      expect(await vault.read('anthropic_key'), isNull);
      expect(await vault.listNames(), ['OPENAI_API_KEY']);
    });

    test('rejects empty names and empty values', () async {
      await expectLater(vault.write('', 'v'), throwsArgumentError);
      await expectLater(vault.write('   ', 'v'), throwsArgumentError);
      await expectLater(vault.write('KEY', ''), throwsArgumentError);
      expect(secrets.values, isEmpty);
    });

    test('isolates user secrets from internal gateway credentials', () async {
      await secrets.write(PreferenceKeys.gatewayToken, 'gw-token');
      await secrets.write(PreferenceKeys.gatewayPassword, 'gw-pass');

      await vault.write(PreferenceKeys.gatewayToken, 'user-secret');

      expect(await vault.listNames(), [PreferenceKeys.gatewayToken]);
      expect(await secrets.read(PreferenceKeys.gatewayToken), 'gw-token');
      expect(await secrets.read(PreferenceKeys.gatewayPassword), 'gw-pass');
      expect(await vault.read(PreferenceKeys.gatewayToken), 'user-secret');
      expect(await vault.read(PreferenceKeys.gatewayPassword), isNull);
    });

    test(
      'never persists plaintext to KeyValueStore and never logs secret values',
      () async {
        const secretValue = 'super-secret-api-key-999';
        final kv = MemoryKeyValueStore();
        final captured = <String>[];
        final previousLevel = Logger.level;
        Logger.level = Level.all;
        addTearDown(() => Logger.level = previousLevel);

        await runZoned(
          () async {
            final container = ProviderContainer(
              overrides: [
                secretStoreProvider.overrideWithValue(secrets),
                keyValueStoreProvider.overrideWithValue(kv),
              ],
            );
            addTearDown(container.dispose);

            await container
                .read(secretNamesProvider.notifier)
                .save('MY_API_KEY', secretValue);
            expect(await container.read(secretNamesProvider.future), [
              'MY_API_KEY',
            ]);
            expect(
              await container.read(secretVaultProvider).read('MY_API_KEY'),
              secretValue,
            );

            // No plaintext value or key name ever lands in KeyValueStore.
            expect(kv.values, isEmpty);
            // SecretStore holds the value only under the secret prefix.
            expect(secrets.values, {
              '${PreferenceKeys.userSecretPrefix}MY_API_KEY': secretValue,
            });

            // Simulate a keystore error whose exception text includes a secret.
            secrets.readError = StateError(
              'keystore failure with $secretValue',
            );
            expect(await vault.read('MY_API_KEY'), isNull);
            secrets.readError = null;

            await container
                .read(secretNamesProvider.notifier)
                .remove('MY_API_KEY');
            expect(await container.read(secretNamesProvider.future), isEmpty);
            expect(kv.values, isEmpty);
          },
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, line) => captured.add(line),
          ),
        );

        expect(captured.join('\n'), contains('secret unreadable (StateError)'));
        for (final line in captured) {
          expect(line, isNot(contains(secretValue)));
        }
      },
    );
  });

  group('SecureSecretStore', () {
    test(
      'delegates CRUD and configures backup-excluded platform options',
      () async {
        final fakeStorage = _FakeFlutterSecureStorage();
        final store = SecureSecretStore(fakeStorage);

        await store.write('secret.API_KEY', 'val-1');
        expect(await store.read('secret.API_KEY'), 'val-1');
        expect(await store.readAll(), {'secret.API_KEY': 'val-1'});
        await store.delete('secret.API_KEY');
        expect(await store.read('secret.API_KEY'), isNull);

        // Default instance uses non-synchronizable first-unlock-this-device iOS
        // Keychain and non-backup-migrated Android Keystore options.
        const defaultStorage = FlutterSecureStorage(
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.first_unlock_this_device,
          ),
        );
        expect(
          defaultStorage.iOptions.accessibility,
          KeychainAccessibility.first_unlock_this_device,
        );
        expect(defaultStorage.iOptions.synchronizable, isFalse);
        expect(defaultStorage.aOptions, AndroidOptions.defaultOptions);
        expect(defaultStorage.aOptions.toMap()['migrateWithBackup'], 'false');
      },
    );
  });
}
