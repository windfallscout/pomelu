import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/secret_vault.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/ui/ui.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/l10n_ext.dart';
import 'settings_section.dart';

/// User-managed secrets (API keys, passwords) stored encrypted on-device in
/// [SecretVault]. Listed by name with masked values; individual entries can be
/// revealed on demand, added, or deleted.
class SettingsSecretsSection extends ConsumerWidget {
  const SettingsSecretsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final spacing = context.spacing;
    final colors = context.colors;
    final secretsAsync = ref.watch(secretNamesProvider);
    final names = secretsAsync.value;

    final List<Widget> rows;
    if (names != null) {
      rows = [
        if (names.isEmpty)
          SettingsInset(
            child: Text(
              l10n.settingsSecretsEmpty,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: colors.textSecondary),
            ),
          )
        else
          for (final name in names) _SecretRow(key: ValueKey(name), name: name),
        FormButtonRow(
          label: l10n.settingsSecretsAdd,
          onPressed: () => unawaited(_addSecret(context, ref, names)),
        ),
      ];
    } else if (secretsAsync.hasError) {
      rows = [
        SettingsInset(
          child: SettingsStatus(
            kind: StatusKind.warn,
            label: l10n.settingsSecretsLoadFailed,
          ),
        ),
      ];
    } else {
      rows = [
        Padding(
          padding: EdgeInsets.all(spacing.lg),
          child: ShimmerLine(height: spacing.md),
        ),
      ];
    }

    return FormSection(
      header: l10n.settingsSecretsSection,
      footer: l10n.settingsSecretsFooter,
      children: rows,
    );
  }

  Future<void> _addSecret(
    BuildContext context,
    WidgetRef ref,
    List<String> existingNames,
  ) async {
    final snacks = AppSnacks.of(context);
    final l10n = context.l10n;
    final entry = await AppSheet.show<({String name, String value})>(
      context,
      builder: (_) => _AddSecretSheet(existingNames: existingNames),
    );
    if (entry == null) return;
    try {
      await ref
          .read(secretNamesProvider.notifier)
          .save(entry.name, entry.value);
    } on Object catch (e) {
      log.w('secret save failed (${e.runtimeType})');
      snacks.show(l10n.settingsSecretsSaveFailed);
    }
  }
}

class _SecretRow extends ConsumerStatefulWidget {
  const _SecretRow({required this.name, super.key});

  final String name;

  @override
  ConsumerState<_SecretRow> createState() => _SecretRowState();
}

class _SecretRowState extends ConsumerState<_SecretRow> {
  String? _revealedValue;
  bool _loading = false;

  @override
  void didUpdateWidget(_SecretRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name != widget.name) _revealedValue = null;
  }

  @override
  void dispose() {
    _revealedValue = null;
    super.dispose();
  }

  Future<void> _toggleReveal() async {
    if (_revealedValue != null) {
      setState(() => _revealedValue = null);
      return;
    }
    final snacks = AppSnacks.of(context);
    final failed = context.l10n.settingsSecretsLoadFailed;
    setState(() => _loading = true);
    final value = await ref.read(secretVaultProvider).read(widget.name);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _revealedValue = value;
    });
    if (value == null) snacks.show(failed);
  }

  Future<void> _confirmDelete() async {
    final l10n = context.l10n;
    final snacks = AppSnacks.of(context);
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.settingsSecretDeleteTitle(widget.name),
      body: l10n.settingsSecretDeleteBody,
      confirmLabel: l10n.settingsSecretDeleteAction,
    );
    if (!confirmed || !mounted) return;
    setState(() => _loading = true);
    try {
      await ref.read(secretNamesProvider.notifier).remove(widget.name);
    } on Object catch (e) {
      log.w('secret delete failed (${e.runtimeType})');
      if (mounted) setState(() => _loading = false);
      snacks.show(l10n.settingsSecretsDeleteFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final spacing = context.spacing;
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final revealed = _revealedValue;

    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: spacing.minTouch),
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          start: spacing.lg,
          end: spacing.xs,
          top: spacing.sm,
          bottom: spacing.sm,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.name, style: text.bodyLarge),
                  SizedBox(height: spacing.xxs),
                  if (revealed != null)
                    Text(
                      revealed,
                      style: context.textScale.mono(color: colors.textPrimary),
                    )
                  else
                    Semantics(
                      label: l10n.settingsSecretMasked,
                      child: ExcludeSemantics(
                        child: Text(
                          maskedSecretPlaceholder,
                          style: context.textScale.mono(
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(width: spacing.xs),
            AppIconButton.plain(
              icon: revealed != null
                  ? CupertinoIcons.eye_slash
                  : CupertinoIcons.eye,
              tooltip: revealed != null
                  ? l10n.settingsSecretHide
                  : l10n.settingsSecretShow,
              busy: _loading,
              onPressed: _loading ? null : () => unawaited(_toggleReveal()),
            ),
            AppIconButton.plain(
              icon: CupertinoIcons.trash,
              color: colors.danger,
              tooltip: l10n.settingsSecretDelete(widget.name),
              onPressed: _loading ? null : () => unawaited(_confirmDelete()),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddSecretSheet extends StatefulWidget {
  const _AddSecretSheet({required this.existingNames});

  final List<String> existingNames;

  @override
  State<_AddSecretSheet> createState() => _AddSecretSheetState();
}

class _AddSecretSheetState extends State<_AddSecretSheet> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _value = TextEditingController();
  bool _hidden = true;

  bool get _canSubmit => _name.text.trim().isNotEmpty && _value.text.isNotEmpty;

  bool get _replacesExisting =>
      widget.existingNames.contains(_name.text.trim());

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_canSubmit) return;
    Navigator.of(context).pop((name: _name.text.trim(), value: _value.text));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final spacing = context.spacing;

    return SingleChildScrollView(
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.lg,
        0,
        spacing.lg,
        spacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AppCloseButton(onPressed: () => Navigator.of(context).pop()),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    l10n.settingsSecretsAddTitle,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              AppIconButton(
                icon: CupertinoIcons.checkmark,
                tooltip: l10n.settingsSecretsSave,
                onPressed: _canSubmit ? _submit : null,
                disc: true,
              ),
            ],
          ),
          SizedBox(height: spacing.md),
          FormSection(
            footer: _replacesExisting
                ? l10n.settingsSecretReplacesExisting
                : null,
            children: [
              SettingsField(
                label: l10n.settingsSecretNameLabel,
                child: TextField(
                  controller: _name,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: l10n.settingsSecretNameHint,
                  ),
                ),
              ),
              SettingsField(
                label: l10n.settingsSecretValueLabel,
                child: TextField(
                  controller: _value,
                  obscureText: _hidden,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    hintText: l10n.settingsSecretValueHint,
                    suffixIcon: AppIconButton.plain(
                      icon: _hidden
                          ? CupertinoIcons.eye
                          : CupertinoIcons.eye_slash,
                      tooltip: _hidden
                          ? l10n.settingsSecretShow
                          : l10n.settingsSecretHide,
                      onPressed: () => setState(() => _hidden = !_hidden),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
