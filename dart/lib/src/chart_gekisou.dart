/// MasterLiveMusic mission types, paired with the score's native fever ranges.
enum OurNotesGekisouMission { none, combo, luck, justCount }

final class OurNotesGekisouRange {
  const OurNotesGekisouRange({
    required this.startTimeMs,
    required this.endTimeMs,
    required this.mission,
  });

  final int startTimeMs;
  final int endTimeMs;
  final OurNotesGekisouMission mission;

  bool contains(int noteTimeMs) =>
      startTimeMs <= noteTimeMs && noteTimeMs <= endTimeMs;
}

/// Pure source policy. Media clocks, team skills and renderers remain callers.
final class OurNotesGekisouPlan {
  OurNotesGekisouPlan(Iterable<OurNotesGekisouRange> ranges)
    : ranges = List.unmodifiable(ranges);

  final List<OurNotesGekisouRange> ranges;
  static const laneLifetimeSeconds = 0.44999998807907104;

  // MasterLiveJudgementTiming rows containing the Just judgement.
  static const _justTypes = {1, 2, 5, 10, 12, 15};

  OurNotesGekisouRange? rangeAtNoteTime(int noteTimeMs) {
    for (final range in ranges) {
      if (range.contains(noteTimeMs)) return range;
    }
    return null;
  }

  int autoJudgement({
    required int judgementType,
    required int? currentRangeIndex,
    required bool feverActive,
  }) =>
      feverActive &&
          _missionAt(currentRangeIndex) == OurNotesGekisouMission.justCount &&
          _justTypes.contains(judgementType)
      ? 6
      : 5;

  OurNotesGekisouMission? _missionAt(int? index) =>
      index != null && index >= 0 && index < ranges.length
      ? ranges[index].mission
      : null;

  /// Playback range is independent from a note's inclusive setup-time mark.
  ({int? rangeIndex, bool active}) atPlaybackTimeUs(int observedTimeUs) {
    int? current;
    for (var index = 0; index < ranges.length; index++) {
      if (ranges[index].startTimeMs * 1000 > observedTimeUs) break;
      current = index;
    }
    return (
      rangeIndex: current,
      active:
          current != null && observedTimeUs < ranges[current].endTimeMs * 1000,
    );
  }

  int autoJudgementAtTime({
    required int judgementType,
    required int observedTimeUs,
  }) {
    final state = atPlaybackTimeUs(observedTimeUs);
    return autoJudgement(
      judgementType: judgementType,
      currentRangeIndex: state.rangeIndex,
      feverActive: state.active,
    );
  }

  bool isGekisouLaneAtTime({
    required int noteTimeMs,
    required int judgement,
    required int diffMs,
    required int observedTimeUs,
  }) => isGekisouLane(
    noteTimeMs: noteTimeMs,
    judgement: judgement,
    diffMs: diffMs,
    currentRangeIndex: atPlaybackTimeUs(observedTimeUs).rangeIndex,
  );

  bool isGekisouLane({
    required int noteTimeMs,
    required int judgement,
    required int diffMs,
    required int? currentRangeIndex,
  }) {
    if (rangeAtNoteTime(noteTimeMs) == null) return false;
    final mission = _missionAt(currentRangeIndex);
    return (mission == OurNotesGekisouMission.luck && diffMs == 0) ||
        (mission == OurNotesGekisouMission.justCount && judgement == 6);
  }
}
