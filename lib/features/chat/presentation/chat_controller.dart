import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/misc.dart' show KeepAliveLink;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/config/app_config.dart';
import '../../../core/platform/app_shortcuts.dart';
import '../../../core/platform/app_visibility.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/failure_text.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../hermes/api/hermes_api.dart';
import '../../../hermes/client/connection_state.dart';
import '../../../hermes/client/hermes_client.dart';
import '../../../hermes/events/event_payloads.dart';
import '../../../hermes/events/gateway_event.dart';
import '../../../hermes/events/turn_payloads.dart';
import '../../../hermes/hermes_constants.dart';
import '../../../hermes/hermes_failure.dart';
import '../../../hermes/models/local_attachment.dart';
import '../../../hermes/models/model_options.dart';
import '../../../hermes/models/session_message.dart';
import '../../../hermes/models/session_resume.dart';
import '../../../hermes/models/session_summary.dart';
import '../../connection/presentation/connection_providers.dart';
import '../data/attachments.dart';
import '../data/chat_store.dart';
import '../domain/chat_message.dart';
import '../domain/chat_reducer.dart';
import '../domain/chat_state.dart';
import '../domain/chat_target.dart';
import '../domain/new_id.dart';
import '../domain/outbox.dart';
import '../domain/slash_command.dart';
import '../domain/transcript.dart';

import 'review_prompt.dart';

part 'chat_controller.g.dart';
part 'controller/chat_commands.dart';
part 'controller/chat_conversations.dart';
part 'controller/chat_edits.dart';
part 'controller/chat_opening.dart';
part 'controller/chat_outbox.dart';
part 'controller/chat_session.dart';
part 'controller/chat_stop.dart';

class _Run {
  _Run(this.ref, this.api, this.client, this.store);

  final Ref ref;
  final HermesApi api;
  final HermesClient client;
  final ChatStore store;

  bool get live => ref.mounted;

  StreamSubscription<GatewayEvent>? events;

  /// Live events that came in while the transcript loaded.
  List<GatewayEvent>? held;

  /// Counts binds: a later bind wins over an earlier one still in flight.
  int generation = 0;
  String watched = '';

  /// `message_count` of the Bot Chat when it was last read; 0 is unknown.
  int seenCount = 0;
  Future<void>? opening;
  Future<void>? reopening;

  /// The app let go of the session while away (see `_release`); it
  /// resumes when the app is back on screen.
  bool released = false;
  Future<void>? releasing;

  /// The socket came back while an open or a resume was on the old one:
  /// that attempt may still fail, so one more runs after it.
  bool openAgain = false;
  bool reopenAgain = false;
  Future<void>? loadingEarlier;
  Future<void>? startingOver;
  DateTime? earlierFailedAt;
  bool draining = false;
  bool drainAgain = false;
  String? delivering;
  bool staging = false;
  bool deleting = false;
  int modelSwitchSeq = 0;
  int effortSeq = 0;
  Future<void>? settingModel;
  Timer? stopGuard;
  Timer? follow;

  void dispose() {
    stopGuard?.cancel();
    follow?.cancel();
    unawaited(events?.cancel());
    if (watched.isNotEmpty) client.unwatchSession(watched);
  }
}

/// Owns one open chat: its [ChatState] and what the user can do to it. With
/// no gateway configured it builds in an error state and every method does
/// nothing.
@riverpod
class ChatController extends _$ChatController
    with _Session, _Opening, _Outbox, _Stop, _Conversations, _Commands, _Edits {
  @override
  ChatState build(ChatTarget target) {
    final api = ref.watch(hermesApiProvider);
    final client = ref.watch(hermesClientProvider);
    final store = ref.watch(chatStoreProvider);
    // Work the user committed to shows first, even after Android killed us.
    final queue = Outbox.rehydrate(store.outbox(target.key));
    if (queue.isNotEmpty) unawaited(store.saveOutbox(target.key, queue));
    final base = ChatState(
      profile: target.profile,
      outbox: queue,
      hidden: store.hidden(target.key),
      messages: Outbox.project(const [], queue),
    );
    if (api == null || client == null) {
      _run = null;
      return base.copyWith(error: NetworkFailure.notConfigured);
    }
    final run = _run = _Run(ref, api, client, store);
    _holdWhileWorking(queue);
    final conn = client.states.listen((s) => _onConnection(run, s));
    final lifecycle = AppLifecycleListener(
      onHide: () => _release(run),
      onShow: () => unawaited(_comeBack(run)),
    );
    ref.onDispose(() {
      lifecycle.dispose();
      unawaited(conn.cancel());
      run.dispose();
    });
    unawaited(_open(run));
    return base.copyWith(loading: true, online: client.isConnected);
  }

  void _holdWhileWorking(List<OutboxEntry> queue) {
    KeepAliveLink? hold;
    void update(List<OutboxEntry> q) {
      if (Outbox.hasWork(q)) {
        hold ??= ref.keepAlive();
      } else {
        hold?.close();
        hold = null;
      }
    }

    update(queue);
    listenSelf((_, next) => update(next.outbox));
  }

  // Each answer says whether the question is settled; false means the socket
  // is down: the question stays open and the banner says so.

  bool answerClarify(String id, Map<String, String?> answers) =>
      _settled(_live?.client.requests.answerClarify(id, answers));

  bool cancelClarify(String id) =>
      _settled(_live?.client.requests.cancelClarify(id));

  bool answerApproval(String id, String choice) =>
      _settled(_live?.client.requests.answerApproval(id, choice));

  /// Empty means skipped.
  bool answerInput(String id, String value) =>
      _settled(_live?.client.requests.answerInput(id, value));

  bool _settled(bool? settled) {
    if (settled ?? false) return true;
    if (ref.mounted) {
      state = state.copyWith(error: NetworkFailure.notConnected);
    }
    return false;
  }

  Future<ModelOptions> modelOptions() async {
    final run = _live;
    if (run == null) throw NetworkFailure.notConfigured;
    return run.api.modelOptions(
      runtimeId: state.runtimeId,
      profile: target.profile,
    );
  }

  /// `session.info` confirms the switch.
  Future<void> switchModel(
    String model, {
    String? provider,
    Future<bool> Function(String message)? confirm,
  }) {
    final run = _live;
    if (run == null) return Future<void>.value();
    final seq = ++run.modelSwitchSeq;
    final prior = run.settingModel;
    final task = () async {
      if (prior != null) {
        try {
          await prior;
        } on Object catch (_) {}
      }
      if (!run.live || seq != run.modelSwitchSeq) return;
      await _runSetting(
        run,
        () => seq == run.modelSwitchSeq,
        'model switch',
        () async {
          var result = await _onSession<ModelSwitchResult>(
            run,
            (id) => run.api.switchModel(
              runtimeId: id,
              model: model,
              provider: provider,
            ),
          );
          if (!run.live || seq != run.modelSwitchSeq) return;
          if (result case final ModelSwitchConfirmRequired ask) {
            if (confirm == null) {
              state = state.copyWith(error: ServerFailure(ask.message));
              return;
            }
            final ok = await confirm(ask.message);
            if (!run.live || seq != run.modelSwitchSeq || !ok) return;
            result = await _onSession<ModelSwitchResult>(
              run,
              (id) => run.api.switchModel(
                runtimeId: id,
                model: model,
                provider: provider,
                confirm: ask.token ?? 'confirm',
              ),
            );
            if (!run.live || seq != run.modelSwitchSeq) return;
            if (result case final ModelSwitchConfirmRequired again) {
              state = state.copyWith(error: ServerFailure(again.message));
              return;
            }
          }
          if (result case final ModelSwitched switched) {
            state = state.copyWith(
              model: switched.model.isNotEmpty ? switched.model : model,
              provider: switched.provider.isNotEmpty
                  ? switched.provider
                  : (provider ?? state.provider),
              error: null,
            );
          }
        },
      );
    }();
    run.settingModel = task.whenComplete(() {
      if (identical(run.settingModel, task)) run.settingModel = null;
    });
    return run.settingModel!;
  }

  Future<void> setEffort(String effort) {
    final run = _live;
    if (run == null) return Future<void>.value();
    final seq = ++run.effortSeq;
    return _runSetting(
      run,
      () => seq == run.effortSeq,
      'reasoning effort change',
      () async {
        await _onSession(
          run,
          (id) => run.api.setReasoningEffort(runtimeId: id, effort: effort),
        );
        if (run.live && seq == run.effortSeq) {
          state = state.copyWith(effort: effort, error: null);
        }
      },
    );
  }

  Future<void> _runSetting(
    _Run run,
    bool Function() isCurrent,
    String what,
    Future<void> Function() body,
  ) async {
    state = state.copyWith(error: null);
    if (!await _ensureSession(run) || !isCurrent()) return;
    try {
      await body();
    } on CancelledFailure {
      return;
    } on HermesFailure catch (e) {
      if (run.live && isCurrent()) state = state.copyWith(error: e);
    } on Object catch (e, st) {
      log.w('$what failed', error: e, stackTrace: st);
      if (run.live && isCurrent()) {
        state = state.copyWith(
          error: ProtocolFailure('$what failed', cause: e),
        );
      }
    }
  }

  /// Speech to text through the gateway; empty when nothing was heard.
  Future<String> transcribe(LocalAttachment audio) async {
    final run = _live;
    if (run == null) throw NetworkFailure.notConfigured;
    return run.api.transcribe(
      bytes: await Attachments.read(audio),
      mimeType: audio.mimeType,
      profile: target.profile,
    );
  }

  void clearError() {
    if (ref.mounted) state = state.copyWith(error: null);
  }

  /// The Retry of a chat that never opened, or whose transcript could not be
  /// read. Joins the attempt running; without a gateway, builds again.
  Future<void> reopen() async {
    if (!ref.mounted) return;
    final run = _run;
    if (run == null) return ref.invalidateSelf();
    final opened = state.runtimeId.isNotEmpty;
    state = state.copyWith(error: null, loading: !opened);
    return opened ? _reopen(run) : _open(run);
  }
}
