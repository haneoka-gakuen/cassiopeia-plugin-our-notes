import 'package:cassiopeia_runtime/cassiopeia_runtime.dart';

import 'chart_gekisou.dart';
import 'chart_runtime.dart';

typedef OurNotesWatchObservation = ({
  CassiopeiaObservation value,
  bool terminal,
  int presentationMicros,
});

/// Owns Source watch observations and presentation for one loaded session.
/// The caller supplies real media samples and closes this owner at teardown.
final class OurNotesWatchPlayback {
  OurNotesWatchPlayback({
    required this.sourceKey,
    required CassiopeiaSessionPort runtime,
    required List<CassiopeiaWatchNote> notes,
    OurNotesGekisouPlan? plan,
  }) : _runtime = runtime,
       notesById = Map.unmodifiable({for (final note in notes) note.id: note}),
       presentation = OurNotesWatchPresentation(
         notes,
         plan: plan,
         sourceKey: sourceKey,
       ) {
    _runtime.configureAutomaticPolicy(ourNotesAutomaticPolicy(plan));
  }

  final String sourceKey;
  final CassiopeiaSessionPort _runtime;
  final Map<int, CassiopeiaWatchNote> notesById;
  final OurNotesWatchPresentation presentation;
  OurNotesWatchReplayClock? _replayClock;
  (double, double)? _replayClockKey;
  int? _epoch, _lastMediaMicros;
  bool _resetPending = true, _finished = false, _closed = false;
  int _observations = 0, _resets = 0, _ignoredBackwardObservations = 0;

  int? get lastMediaMicros => _lastMediaMicros;
  bool get finished => _finished;
  int get observationCount => _observations;
  int get resetCount => _resets;
  int get ignoredBackwardObservationCount => _ignoredBackwardObservations;
  bool get supportsWatchProjection =>
      _runtime is CassiopeiaWatchProjectionPort &&
      (_runtime as CassiopeiaWatchProjectionPort).supportsWatchProjection;
  Iterable<CassiopeiaJudgementView> get visualHistory =>
      presentation.visualProjection?.events ?? presentation.events;

  void setGekisouPlan(OurNotesGekisouPlan? plan) {
    _check();
    _runtime.configureAutomaticPolicy(ourNotesAutomaticPolicy(plan));
    presentation.setGekisouPlan(plan);
    _resetPending = true;
  }

  void resetOnNextObservation() {
    _check();
    _resetPending = true;
  }

  OurNotesWatchReplayClock _seekVisualClock(
    int sourceMicros,
    double durationMs,
    double playbackRate,
  ) {
    final targetMs = sourceMicros / 1000;
    final coverageMs = durationMs < targetMs ? targetMs : durationMs;
    final key = (playbackRate, coverageMs);
    if (key != _replayClockKey) {
      _replayClock = OurNotesWatchReplayClock(
        sourceKey: sourceKey,
        originSeconds: 0,
        stepSeconds: (1 / 60) * playbackRate,
        durationMs: coverageMs,
      );
      _replayClockKey = key;
    }
    return _replayClock!;
  }

  /// A media epoch change replays history. An older sample within one epoch
  /// retains the accepted state; force renders do not synthesize observations.
  OurNotesWatchObservation observe({
    required int mediaMicros,
    required double durationMs,
    required double playbackRate,
    required bool completed,
    int? epoch,
  }) {
    _check();
    final sourceMicros = ourNotesRuntimeObservationMicros(mediaMicros);
    final epochChanged = epoch != null && _epoch != epoch;
    if (epochChanged) _epoch = epoch;
    final reset = _resetPending || epochChanged;
    final CassiopeiaObservation observation;
    var terminal = false;
    if (reset) {
      _resetPending = false;
      _finished = false;
      ++_resets;
      observation = resetOurNotesWatch(
        runtime: _runtime,
        presentation: presentation,
        mediaMicros: sourceMicros,
        visualClock: _seekVisualClock(sourceMicros, durationMs, playbackRate),
      );
    } else if (completed && !_finished) {
      _finished = true;
      terminal = true;
      observation = _runtime.finish(sourceMicros);
      presentation.apply(observation);
    } else if (!_finished &&
        (_lastMediaMicros == null || sourceMicros > _lastMediaMicros!)) {
      ++_observations;
      observation = _runtime.observe(sourceMicros);
      presentation.apply(observation);
    } else {
      if (_lastMediaMicros != null && sourceMicros < _lastMediaMicros!) {
        ++_ignoredBackwardObservations;
      }
      observation = CassiopeiaObservation(
        snapshot: _runtime.snapshot,
        events: const [],
        historical: false,
      );
    }
    if (reset ||
        _lastMediaMicros == null ||
        sourceMicros >= _lastMediaMicros!) {
      _lastMediaMicros = sourceMicros;
    }
    return (
      value: observation,
      terminal: terminal,
      presentationMicros: presentation.sampledVisualTimeMicros ?? mediaMicros,
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _replayClock = null;
    _replayClockKey = null;
    _runtime.close();
  }

  void _check() {
    if (_closed) throw StateError('our_notes_watch_closed');
  }
}
