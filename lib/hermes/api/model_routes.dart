part of 'hermes_api.dart';

/// Models to pick from (for a session or a bot), and a live session's model
/// and reasoning effort.
mixin _ModelRoutes {
  HermesClient get _client;

  /// Models and providers to pick from, for a live session or a bot.
  Future<ModelOptions> modelOptions({
    String? runtimeId,
    String? profile,
  }) async => parseObject(
    await _client.call(HermesMethods.modelOptions, {
      if (runtimeId != null && runtimeId.isNotEmpty) 'session_id': runtimeId,
      'profile': ?profile,
    }, HermesTimeouts.rpcStartup),
    ModelOptions.fromJson,
    what: 'model options',
  );

  /// Switches the live session's model (and optional [provider]). Uses the
  /// canonical revision-fenced `session.mutate` RPC when the gateway provides
  /// CAS fences, falling back to `config.set` / `slash.exec` on older gateways.
  Future<ModelSwitchResult> switchModel({
    required String runtimeId,
    required String model,
    String? provider,
    String? confirm,
  }) async {
    final named = provider != null && provider.isNotEmpty;
    if (!_isPlainModelId(model)) {
      throw ProtocolFailure('not a usable model or provider id: "$model"');
    }
    if (named && (provider.startsWith('-') || provider.trim().isEmpty)) {
      throw ProtocolFailure('not a usable model or provider id: "$provider"');
    }

    final resume = await _client.call(HermesMethods.sessionResume, {
      'session_id': runtimeId,
      'omit_messages': true,
    }, HermesTimeouts.rpcStartup);
    final resolvedId = const LooseString().fromJson(resume['session_id']);
    final targetId = resolvedId.isNotEmpty ? resolvedId : runtimeId;
    final revision = const LooseIntOrNull().fromJson(resume['revision']);
    final generation = const LooseIntOrNull().fromJson(
      resume['execution_generation'],
    );
    if (revision != null && generation != null) {
      final mutated = await _mutateModel(
        runtimeId: targetId,
        model: model,
        provider: named ? provider : null,
        confirm: confirm,
        revision: revision,
        generation: generation,
      );
      if (mutated != null) return mutated;
    }

    if (named && !_isPlainModelId(provider)) {
      throw ProtocolFailure('not a usable model or provider id: "$provider"');
    }
    return _legacySwitchModel(
      runtimeId: targetId,
      model: model,
      provider: named ? provider : null,
      confirm: confirm != null,
    );
  }

  static bool _isPlainModelId(String id) =>
      !id.startsWith('-') && RegExp(r'^[\w.:/@+-]+$').hasMatch(id);

  /// Sends `session.mutate` (`operation: 'model'`), retrying on stale CAS
  /// fences; returns null if the gateway does not implement `session.mutate`.
  Future<ModelSwitchResult?> _mutateModel({
    required String runtimeId,
    required String model,
    String? provider,
    String? confirm,
    required int revision,
    required int generation,
  }) async {
    var expectedRevision = revision;
    var expectedGeneration = generation;
    for (var attempt = 0; attempt < HermesLimits.metaWriteAttempts; attempt++) {
      try {
        final res = await _client.call(HermesMethods.sessionMutate, {
          'session_id': runtimeId,
          'request_id': const Uuid().v4(),
          'expected_revision': expectedRevision,
          'expected_generation': expectedGeneration,
          'operation': 'model',
          'payload': {
            'model': model,
            'provider': ?provider,
            'confirm': ?confirm,
          },
        }, HermesTimeouts.slashExec);
        return _parseMutateModelResult(res, model: model, provider: provider);
      } on ServerFailure catch (e) {
        if (e.rpcCode == HermesProtocol.errMethodNotFound) return null;
        final data = e.data;
        final reason = data is Map ? data['reason']?.toString() : null;
        if (reason != HermesProtocol.reasonRevisionConflict &&
            reason != HermesProtocol.reasonStaleGeneration) {
          rethrow;
        }
        if (attempt + 1 >= HermesLimits.metaWriteAttempts) rethrow;
        final nextRev = data is Map
            ? const LooseIntOrNull().fromJson(data['revision'])
            : null;
        final nextGen = data is Map
            ? const LooseIntOrNull().fromJson(data['execution_generation'])
            : null;
        if (nextRev != null && nextGen != null) {
          expectedRevision = nextRev;
          expectedGeneration = nextGen;
        } else {
          final fresh = await _client.call(HermesMethods.sessionResume, {
            'session_id': runtimeId,
            'omit_messages': true,
          }, HermesTimeouts.rpcStartup);
          final r = const LooseIntOrNull().fromJson(fresh['revision']);
          final g = const LooseIntOrNull().fromJson(
            fresh['execution_generation'],
          );
          if (r == null || g == null) rethrow;
          expectedRevision = r;
          expectedGeneration = g;
        }
      }
    }
    return null;
  }

  ModelSwitchResult _parseMutateModelResult(
    Map<String, dynamic> res, {
    required String model,
    String? provider,
  }) {
    final status = const LooseString().fromJson(res['status']);
    if (status == 'confirmation_required' || res['confirm_required'] == true) {
      final msg = const LooseString().fromJson(res['confirm_message']);
      final token = const LooseString().fromJson(res['confirm']);
      return ModelSwitchConfirmRequired(
        message: msg.isNotEmpty ? msg : 'Confirmation required to switch model',
        token: token.isNotEmpty ? token : null,
        targetModel: const LooseString().fromJson(res['target_model']),
        targetProvider: const LooseString().fromJson(res['target_provider']),
      );
    }
    if (status == 'refused') {
      final reason = const LooseString().fromJson(res['reason']);
      throw ServerFailure(
        reason.isNotEmpty ? reason : 'model switch refused',
        data: res,
      );
    }
    if (status == 'cancelled') {
      throw const CancelledFailure();
    }
    final switched = const LooseString().fromJson(res['model']);
    final switchedProvider = const LooseString().fromJson(res['provider']);
    return ModelSwitched(
      model: switched.isNotEmpty ? switched : model,
      provider: switchedProvider.isNotEmpty
          ? switchedProvider
          : (provider ?? ''),
      deferred: status == 'deferred',
    );
  }

  Future<ModelSwitchResult> _legacySwitchModel({
    required String runtimeId,
    required String model,
    String? provider,
    required bool confirm,
  }) async {
    final command = provider != null
        ? 'model $model --provider $provider'
        : 'model $model';
    try {
      final res = await _client.call(HermesMethods.configSet, {
        'session_id': runtimeId,
        'key': 'model',
        'value': command,
        if (confirm) 'confirm_expensive_model': true,
      }, HermesTimeouts.slashExec);
      if (res['confirm_required'] == true) {
        final msg = const LooseString().fromJson(res['confirm_message']);
        final warn = const LooseString().fromJson(res['warning']);
        final text = msg.isNotEmpty ? msg : warn;
        return ModelSwitchConfirmRequired(
          message: text.isNotEmpty
              ? text
              : 'Confirmation required to switch model',
          token: 'confirm',
          targetModel: model,
          targetProvider: provider ?? '',
        );
      }
      final switched = const LooseString().fromJson(res['value']);
      return ModelSwitched(
        model: switched.isNotEmpty ? switched : model,
        provider: provider ?? '',
        deferred: res['deferred'] == true,
      );
    } on ServerFailure catch (e) {
      final data = e.data;
      final reason = data is Map ? data['reason']?.toString() : null;
      if (reason == HermesProtocol.reasonUseSessionMutationModel ||
          (e.rpcCode != HermesProtocol.errMethodNotFound &&
              e.rpcCode != HermesProtocol.errInvalidParams)) {
        rethrow;
      }
    }
    final res = await _client.call(HermesMethods.slashExec, {
      'session_id': runtimeId,
      'command': command,
    }, HermesTimeouts.slashExec);
    final warning = const LooseString().fromJson(res['warning']);
    if (warning.startsWith('live session sync failed:')) {
      throw ServerFailure(warning);
    }
    return ModelSwitched(model: model, provider: provider ?? '');
  }

  /// Sets the reasoning effort for this session only.
  Future<void> setReasoningEffort({
    required String runtimeId,
    required String effort,
  }) => _client.call(HermesMethods.configSet, {
    'session_id': runtimeId,
    'key': 'reasoning',
    'value': effort,
    'scope': 'session',
  });
}
