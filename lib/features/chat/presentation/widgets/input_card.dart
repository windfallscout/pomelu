import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/secret_vault.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/ui/ui.dart';
import '../../../../core/utils/l10n_ext.dart';
import '../../../../hermes/requests/server_request.dart';
import 'request_frame.dart';

/// A sudo password or a named secret. Masked, never suggested, corrected or
/// autofilled; skipping sends an empty value, which the agent reads as
/// declined. Saved secrets from [SecretVault] can be applied without leaving
/// encrypted storage in plaintext.
class InputCard extends ConsumerStatefulWidget {
  const InputCard({required this.request, required this.onSend, super.key});

  final InputRequest request;
  final bool Function(String value) onSend;

  @override
  ConsumerState<InputCard> createState() => _InputCardState();
}

class _InputCardState extends ConsumerState<InputCard>
    with RequestAnswerGate<InputCard> {
  final TextEditingController _value = TextEditingController();
  bool _hidden = true;

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  void _send(String value) => answerOnce(() => widget.onSend(value));

  Future<void> _applySaved(String name) async {
    final secret = await ref.read(secretVaultProvider).read(name);
    if (!mounted || secret == null || secret.isEmpty) return;
    _value.value = TextEditingValue(
      text: secret,
      selection: TextSelection.collapsed(offset: secret.length),
    );
    setState(() {});
  }

  Future<void> _pickSaved(BuildContext button, List<String> names) async {
    final picked = await showAppMenu<String>(
      button,
      items: [
        for (final name in names)
          AppMenuItem(value: name, label: name, icon: CupertinoIcons.lock),
      ],
    );
    if (picked == null || !mounted) return;
    await _applySaved(picked);
  }

  String? _matchingSecret(List<String> savedNames) {
    final subject = widget.request.subject.trim();
    if (subject.isEmpty) return null;
    final lower = subject.toLowerCase();
    for (final name in savedNames) {
      if (name.toLowerCase() == lower) return name;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final request = widget.request;
    final savedNames = ref.watch(secretNamesProvider).value ?? const <String>[];
    final matched = _matchingSecret(savedNames);

    return RequestCard(
      title: switch (request.kind) {
        InputKind.sudo => l10n.chatInputSudoTitle,
        InputKind.secret =>
          request.prompt.isNotEmpty
              ? request.prompt
              : l10n.chatInputSecretTitle,
      },
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (request.subject.isNotEmpty) ...[
            SelectableText(
              request.subject,
              style: context.textScale.mono(
                color: context.colors.textSecondary,
              ),
            ),
            SizedBox(height: context.spacing.sm),
          ],
          TextField(
            controller: _value,
            enabled: !busy,
            obscureText: _hidden,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.send,
            onChanged: (_) => setState(() {}),
            onSubmitted: (value) {
              if (value.isNotEmpty) _send(value);
            },
            style: Theme.of(context).textTheme.bodyMedium,
            decoration: InputDecoration(
              hintText: l10n.chatInputHint,
              suffixIcon: AppIconButton.plain(
                icon: _hidden ? CupertinoIcons.eye : CupertinoIcons.eye_slash,
                tooltip: _hidden ? l10n.chatInputShow : l10n.chatInputHide,
                onPressed: () => setState(() => _hidden = !_hidden),
              ),
            ),
          ),
        ],
      ),
      actions: [
        if (matched != null)
          OutlinedButton(
            onPressed: busy ? null : () => unawaited(_applySaved(matched)),
            child: Text(l10n.chatInputUseMatched(matched)),
          )
        else if (savedNames.isNotEmpty)
          Builder(
            builder: (buttonContext) => OutlinedButton(
              onPressed: busy
                  ? null
                  : () => unawaited(_pickSaved(buttonContext, savedNames)),
              child: Text(l10n.chatInputUseSaved),
            ),
          ),
        TextButton(
          onPressed: busy ? null : () => _send(''),
          child: Text(l10n.chatRequestSkip),
        ),
        FilledButton(
          onPressed: busy || _value.text.isEmpty
              ? null
              : () => _send(_value.text),
          child: Text(l10n.chatRequestSend),
        ),
      ],
    );
  }
}
