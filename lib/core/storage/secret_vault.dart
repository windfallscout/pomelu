import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/domain/preference_keys.dart';
import '../utils/app_logger.dart';
import 'secret_store.dart';

/// Fixed-length mask shown whenever a secret is hidden, so even its length is
/// not disclosed.
const String maskedSecretPlaceholder = '••••••••';

/// Runtime API for user-managed secrets (passwords, API keys, tokens) stored
/// in the OS-backed encrypted [SecretStore].
///
/// Entries are namespaced under [PreferenceKeys.userSecretPrefix] so they
/// never collide with internal gateway credentials, are never written to
/// [KeyValueStore] or plain files, and are never written to logs.
class SecretVault {
  const SecretVault(this._secrets);

  final SecretStore _secrets;

  static String _storageKey(String name) =>
      '${PreferenceKeys.userSecretPrefix}$name';

  /// Reads the secret stored under [name], or null if missing or unreadable.
  ///
  /// Never throws and never logs secret values or raw exception text.
  Future<String?> read(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    try {
      return await _secrets.read(_storageKey(trimmed));
    } on Object catch (e) {
      log.w('secret unreadable (${e.runtimeType})');
      return null;
    }
  }

  /// Whether a non-empty secret exists for [name].
  Future<bool> contains(String name) async {
    final value = await read(name);
    return value != null && value.isNotEmpty;
  }

  /// Stores [value] encrypted under [name], replacing any existing entry.
  ///
  /// Throws [ArgumentError] if [name] (after trimming) or [value] is empty.
  Future<void> write(String name, String value) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Secret name must not be empty');
    }
    if (value.isEmpty) {
      throw ArgumentError('Secret value must not be empty');
    }
    await _secrets.write(_storageKey(trimmed), value);
  }

  /// Deletes the secret stored under [name], if present.
  Future<void> delete(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _secrets.delete(_storageKey(trimmed));
  }

  /// Lists the names of all user-managed secrets, sorted alphabetically.
  ///
  /// Secret values returned by [SecretStore.readAll] are discarded
  /// immediately and are not retained or logged.
  Future<List<String>> listNames() async {
    final all = await _secrets.readAll();
    const prefix = PreferenceKeys.userSecretPrefix;
    final names =
        [
          for (final key in all.keys)
            if (key.startsWith(prefix) && key.length > prefix.length)
              key.substring(prefix.length),
        ]..sort((a, b) {
          final ci = a.toLowerCase().compareTo(b.toLowerCase());
          return ci != 0 ? ci : a.compareTo(b);
        });
    return List.unmodifiable(names);
  }
}

/// Runtime secret store backed by [secretStoreProvider].
final secretVaultProvider = Provider<SecretVault>(
  (ref) => SecretVault(ref.watch(secretStoreProvider)),
);

/// Sorted names of user-managed secrets in [SecretVault].
///
/// Only secret names are kept in provider state; values are fetched on demand
/// via [SecretVault.read].
final secretNamesProvider =
    AsyncNotifierProvider<SecretNamesNotifier, List<String>>(
      SecretNamesNotifier.new,
    );

/// Manages the reactive list of saved secret names.
class SecretNamesNotifier extends AsyncNotifier<List<String>> {
  @override
  Future<List<String>> build() => ref.watch(secretVaultProvider).listNames();

  /// Encrypts and stores [value] under [name], then refreshes the name list.
  Future<void> save(String name, String value) async {
    final vault = ref.read(secretVaultProvider);
    await vault.write(name, value);
    if (!ref.mounted) return;
    state = AsyncData(await vault.listNames());
  }

  /// Deletes the secret under [name], then refreshes the name list.
  Future<void> remove(String name) async {
    final vault = ref.read(secretVaultProvider);
    await vault.delete(name);
    if (!ref.mounted) return;
    state = AsyncData(await vault.listNames());
  }
}
