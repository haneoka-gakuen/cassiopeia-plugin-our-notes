import 'package:cassiopeia_runtime/cassiopeia_runtime.dart';

import 'chart_gekisou.dart';
import 'chart_gekisou_presentation.dart';
import 'chart_lane_feedback.dart';
import 'haptic_feedback_profile.dart';

typedef OurNotesWatchSourceNote = ({
  int timeMs,
  int operateType,
  int judgementType,
  bool judged,
});
typedef OurNotesWatchSourceBinding = ({int sourceOrdinal, int id});

List<CassiopeiaWatchNote> createOurNotesWatchNotes({
  required List<OurNotesWatchSourceNote> enumeration,
  required Iterable<OurNotesWatchSourceBinding> bindings,
}) {
  final ids = <int, int>{}, ordinals = <int, int>{};
  for (final b in bindings) {
    if (b.sourceOrdinal < 0 ||
        b.sourceOrdinal >= enumeration.length ||
        b.id < 0 ||
        b.id > 0xffffffff)
      throw const FormatException('watch_source_binding');
    final old = ids[b.sourceOrdinal], other = ordinals[b.id];
    if ((old != null && old != b.id) ||
        (other != null && other != b.sourceOrdinal))
      throw const FormatException('watch_source_binding_conflict');
    ids[b.sourceOrdinal] = b.id;
    ordinals[b.id] = b.sourceOrdinal;
  }
  final rows = <({int ordinal, CassiopeiaWatchNote note})>[];
  for (final (i, n) in enumeration.indexed) {
    if (!n.judged) continue;
    final id = ids[i];
    if (id == null) throw FormatException('watch_source_id:$i');
    rows.add((
      ordinal: i,
      note: CassiopeiaWatchNote(
        id: id,
        timeMicros: n.timeMs * 1000,
        operateType: CassiopeiaOperation.fromCode(n.operateType),
        judgementType: CassiopeiaJudgementType.fromCode(n.judgementType),
      ),
    ));
  }
  rows.sort((a, b) {
    final t = a.note.timeMicros.compareTo(b.note.timeMicros);
    return t != 0 ? t : a.ordinal.compareTo(b.ordinal);
  });
  return List.unmodifiable(rows.map((r) => r.note));
}

/// The source's integer-millisecond observation; raw media time remains separate.
int ourNotesRuntimeObservationMicros(int mediaMicros) =>
    (mediaMicros / 1000).floor() * 1000;

CassiopeiaAutomaticPolicy ourNotesAutomaticPolicy(OurNotesGekisouPlan? plan) {
  if (plan == null) return CassiopeiaAutomaticPolicy();
  final rules = <CassiopeiaAutomaticRule>[];
  for (var i = 0; i < plan.ranges.length; i++) {
    final range = plan.ranges[i];
    final start = range.startTimeMs * 1000;
    final end =
        i + 1 < plan.ranges.length &&
            plan.ranges[i + 1].startTimeMs < range.endTimeMs
        ? plan.ranges[i + 1].startTimeMs * 1000
        : range.endTimeMs * 1000;
    if (end <= start) continue;
    final byResult = <int, List<CassiopeiaJudgementType>>{};
    for (final type in CassiopeiaJudgementType.values) {
      final result = plan.autoJudgementAtTime(
        judgementType: type.code,
        observedTimeUs: start,
      );
      if (result != 5) (byResult[result] ??= []).add(type);
    }
    for (final e in byResult.entries)
      rules.add(
        CassiopeiaAutomaticRule(
          startMicros: start,
          endMicros: end,
          judgementTypes: e.value,
          judgement: e.key,
        ),
      );
  }
  return CassiopeiaAutomaticPolicy(rules);
}

final class OurNotesWatchFeedback {
  const OurNotesWatchFeedback({
    required this.effectKind,
    required this.laneKind,
    required this.soundCue,
    required this.hapticRecipe,
  });
  final String? effectKind, soundCue;
  final ChartLaneFeedbackKind? laneKind;
  final int? hapticRecipe;
}

/// Formal LiveHapticType groups use five consecutive judgements, Bad to Just.
int? ourNotesHapticRecipe(int operateType, int judgement) {
  if (judgement < 2 || judgement > 6) return null;
  final firstType = switch (operateType) {
    40 || 41 || 42 || 102 => 6,
    60 || 61 || 62 || 63 || 104 || 105 => 11,
    21 || 120 => 16,
    _ => 1,
  };
  final recipe =
      OurNotesHapticFeedbackProfile.recipeByType[firstType + judgement - 2];
  return recipe != OurNotesHapticFeedbackProfile.noneRecipeId ? recipe : null;
}

/// Source event order: note judgements, then a newly active long line.
final class OurNotesWatchHapticCues {
  bool _held = false;

  Iterable<int> observe(
    Iterable<int> noteRecipes, {
    required bool held,
    required bool live,
  }) {
    final beginLong = held && !_held;
    _held = held;
    if (!live) return const [];
    return [
      ...noteRecipes,
      if (beginLong) OurNotesHapticFeedbackProfile.recipeByType[22],
    ];
  }
}

OurNotesWatchFeedback ourNotesWatchFeedback({
  required int noteTimeMs,
  required int operateType,
  required int direction,
  required int judgement,
  required int differenceMicros,
  required int judgedAtMicros,
  required bool mirror,
  OurNotesGekisouPlan? plan,
}) {
  if (judgement != 5 && judgement != 6)
    return const OurNotesWatchFeedback(
      effectKind: null,
      laneKind: null,
      soundCue: null,
      hapticRecipe: null,
    );
  final geki =
      plan?.isGekisouLaneAtTime(
        noteTimeMs: noteTimeMs,
        judgement: judgement,
        diffMs: differenceMicros ~/ 1000,
        observedTimeUs: judgedAtMicros,
      ) ??
      false;
  final ordinaryLane = chartLaneFeedbackKind(operateType, direction);
  final d = mirror
      ? (direction == 1
            ? 2
            : direction == 2
            ? 1
            : direction)
      : direction;
  final effect = switch (operateType) {
    1 || 101 => geki ? 'Excellent' : 'Normal',
    20 || 22 => 'Slide',
    21 || 60 || 61 || 62 || 63 || 104 || 105 => 'Connect',
    40 || 41 || 42 || 102 =>
      d == 1
          ? 'Left'
          : d == 2
          ? 'Right'
          : 'Flick',
    _ => null,
  };
  final sound = switch (operateType) {
    40 || 41 || 42 || 102 => direction == 0 ? 'flick' : 'flickDirection',
    21 || 60 || 61 || 62 || 63 || 104 || 105 => 'trace',
    _ => judgement == 6 ? 'just' : 'perfect',
  };
  return OurNotesWatchFeedback(
    effectKind: effect,
    laneKind: geki && ordinaryLane != null
        ? ChartLaneFeedbackKind.gekisou
        : ordinaryLane,
    soundCue: sound,
    hapticRecipe: ourNotesHapticRecipe(operateType, judgement),
  );
}

/// Presentation counters consume authoritative events; they never judge or score.
final class OurNotesWatchPresentation {
  OurNotesWatchPresentation(
    Iterable<CassiopeiaWatchNote> notes, {
    OurNotesGekisouPlan? plan,
    this.sourceKey,
  }) : _notes = {for (final n in notes) n.id: n} {
    setGekisouPlan(plan);
  }
  final String? sourceKey;
  final Map<int, CassiopeiaWatchNote> _notes;
  CassiopeiaWatchVisualProjection? _visual;
  int? _visualSampledMicros;
  CassiopeiaWatchVisualProjection? get visualProjection => _visual;
  int get visualCombo => _visual?.combo ?? snapshot.combo;
  bool get visualAllPerfect => _visual?.allPerfect ?? snapshot.allPerfect;
  bool get visualFullCombo => _visual?.fullCombo ?? snapshot.fullCombo;
  bool get visualPerfectCombo => _visual?.perfectCombo ?? snapshot.perfectCombo;
  CassiopeiaJudgementView? get visualLastEvent =>
      _visual == null ? lastEvent : _visual!.lastEvent;
  int? get sampledVisualTimeMicros =>
      _visual != null && snapshot.timeMicros <= _visual!.timeMicros
      ? _visualSampledMicros
      : null;

  void applyVisualProjection(
    CassiopeiaWatchVisualProjection value, {
    required String sourceKey,
    int? sampledTimeMicros,
  }) {
    if (this.sourceKey == null ||
        this.sourceKey != sourceKey ||
        value.timeMicros != snapshot.timeMicros)
      throw const FormatException('watch_visual_source');
    _visual = value;
    _visualSampledMicros = sampledTimeMicros;
  }

  final _events = <int, CassiopeiaJudgementEvent>{};
  final _observed = <int, int>{};
  CassiopeiaSessionSnapshot? _snapshot;
  CassiopeiaSessionSnapshot get snapshot =>
      _snapshot ?? (throw StateError('watch_presentation_empty'));
  CassiopeiaJudgementEvent? lastEvent;
  int justCount = 0, perfectCount = 0;
  late OurNotesGekisouPresentation gekisou;
  Map<int, int> get observedByNote => Map.unmodifiable(_observed);
  List<CassiopeiaJudgementEvent> get events =>
      List.unmodifiable(_events.values);
  int get judgement => lastEvent?.judgement ?? 5;
  int get latestJudgementMicros => lastEvent?.judgedAtMicros ?? 0;

  void setGekisouPlan(OurNotesGekisouPlan? plan) {
    _visual = null;
    _visualSampledMicros = null;
    gekisou = OurNotesGekisouPresentation(plan?.ranges ?? const []);
    for (final e in _events.values) {
      _recordTask(e);
    }
  }

  void _recordTask(CassiopeiaJudgementEvent e) {
    final note = _notes[e.noteId];
    if (note == null)
      throw FormatException('watch_event_source_id:${e.noteId}');
    gekisou.record(
      OurNotesGekisouPresentationJudgement(
        noteId: e.noteId,
        noteTimeMs: note.timeMicros ~/ 1000,
        judgedAtMs: e.judgedAtMicros / 1000,
        judgement: e.judgement,
      ),
    );
  }

  void apply(CassiopeiaObservation observation) {
    _snapshot = observation.snapshot;
    if (observation.historical || observation.events.isNotEmpty) {
      _visual = null;
      _visualSampledMicros = null;
    }
    if (observation.historical) {
      _events.clear();
      justCount = perfectCount = 0;
      lastEvent = null;
      gekisou.reset();
      _observed.removeWhere((id, t) => t > snapshot.timeMicros);
    }
    for (final e in observation.events) {
      final old = _events[e.noteId];
      if (old?.judgement == 6) justCount--;
      if (old?.judgement == 5) perfectCount--;
      _events[e.noteId] = e;
      if (e.judgement == 6) justCount++;
      if (e.judgement == 5) perfectCount++;
      if (!observation.historical) _observed[e.noteId] = e.judgedAtMicros;
      lastEvent = e;
      _recordTask(e);
    }
  }
}

/// Authored long-note presence controls the existing loop sound.
bool ourNotesWatchHoldActive(
  int mediaMicros,
  Iterable<
    ({
      String family,
      bool complete,
      int pointCount,
      int startMicros,
      int endMicros,
    })
  >
  spans,
) => spans.any(
  (s) =>
      s.family == 'line' &&
      s.complete &&
      s.pointCount > 1 &&
      s.startMicros < mediaMicros &&
      mediaMicros < s.endMicros,
);

/// Interactive strict-prior history is enabled only after its journal is implemented.
CassiopeiaScoringComboPolicy ourNotesScoringComboPolicy(CassiopeiaMode mode) =>
    mode == CassiopeiaMode.watch
    ? CassiopeiaScoringComboPolicy.strictPriorNoteTime
    : CassiopeiaScoringComboPolicy.sequential;

/// An explicitly declared source clock for seek visuals. It never observes the
/// live runtime or adds entries to the real observation history.
final class OurNotesWatchReplayClock {
  OurNotesWatchReplayClock({
    required this.sourceKey,
    required this.originSeconds,
    required this.stepSeconds,
    required double durationMs,
    this.inputOffsetMicros = 0,
  }) {
    if (sourceKey.isEmpty ||
        !originSeconds.isFinite ||
        !stepSeconds.isFinite ||
        stepSeconds <= 0 ||
        !durationMs.isFinite)
      throw const FormatException('watch_replay_clock');
    final ticks = <int>[];
    var seconds = originSeconds;
    while ((seconds * 1000).truncate() <= durationMs + 1000) {
      final next = seconds + stepSeconds;
      if (next <= seconds)
        throw const FormatException('watch_replay_clock_step');
      seconds = next;
      ticks.add((seconds * 1000).truncate() * 1000);
    }
    tickTimesMicros = List.unmodifiable(ticks);
  }
  final String sourceKey;
  final double originSeconds, stepSeconds;
  final int inputOffsetMicros;
  late final List<int> tickTimesMicros;
  int? sampledAt(int targetMicros) {
    var low = 0, high = tickTimesMicros.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (tickTimesMicros[middle] <= targetMicros) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low == 0 ? null : tickTimesMicros[low - 1];
  }

  Map<int, int> observations(
    Iterable<CassiopeiaWatchNote> notes,
    int targetMicros, {
    required bool strict,
  }) {
    if (tickTimesMicros.isEmpty || tickTimesMicros.last <= targetMicros)
      throw const FormatException('watch_replay_clock_coverage');
    final values = <int, int>{};
    for (final note in notes) {
      final eligible = note.timeMicros + inputOffsetMicros;
      var low = 0, high = tickTimesMicros.length;
      while (low < high) {
        final middle = (low + high) >> 1, tick = tickTimesMicros[middle];
        if (strict ? tick <= eligible : tick < eligible) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      if (low < tickTimesMicros.length && tickTimesMicros[low] <= targetMicros)
        values[note.id] = tickTimesMicros[low];
    }
    return Map.unmodifiable(values);
  }
}

/// Historical output is returned for presentation only; device feedback stays
/// on live observations. Mission counts and score consume only business data.
CassiopeiaObservation resetOurNotesWatch({
  required CassiopeiaSessionPort runtime,
  required OurNotesWatchPresentation presentation,
  required int mediaMicros,
  OurNotesWatchReplayClock? visualClock,
}) {
  CassiopeiaWatchVisualProjection? visual;
  final observed = <int, int>{
    for (final entry in presentation.observedByNote.entries)
      if (entry.value <= mediaMicros) entry.key: entry.value,
  };
  if (visualClock != null) {
    if (presentation.sourceKey != visualClock.sourceKey)
      throw const FormatException('watch_visual_source');
    final projection = runtime is CassiopeiaWatchProjectionPort
        ? runtime as CassiopeiaWatchProjectionPort
        : null;
    if (projection == null || !projection.supportsWatchProjection)
      throw UnsupportedError('cassiopeia_watch_projection_unsupported');
    final notes = presentation._notes.values;
    visual = projection.projectWatchObserved(
      mediaMicros,
      observedByNote: visualClock.observations(
        notes,
        mediaMicros,
        strict: false,
      ),
    );
    for (final entry
        in visualClock.observations(notes, mediaMicros, strict: true).entries)
      observed.putIfAbsent(entry.key, () => entry.value);
  }
  final result = runtime.reset(mediaMicros, observedByNote: observed);
  presentation.apply(result);
  if (visual != null)
    presentation.applyVisualProjection(
      visual,
      sourceKey: visualClock!.sourceKey,
      sampledTimeMicros: visualClock.sampledAt(mediaMicros),
    );
  return result;
}
