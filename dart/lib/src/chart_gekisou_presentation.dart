import 'dart:typed_data';

import 'chart_gekisou.dart';

final class OurNotesGekisouPresentationJudgement {
  const OurNotesGekisouPresentationJudgement({
    required this.noteId,
    required this.noteTimeMs,
    required this.judgedAtMs,
    required this.judgement,
  });

  final int noteId;
  final int noteTimeMs;
  final double judgedAtMs;
  final int judgement;
}

/// LiveSettingCreator uses the maximum of every MasterLiveJudgementTiming row.
final class OurNotesGekisouPresentationTiming {
  const OurNotesGekisouPresentationTiming({
    required this.completeDelayMs,
    required this.lastNoteSlowJudgeDelayMs,
  });

  final int completeDelayMs;
  final int lastNoteSlowJudgeDelayMs;

  static const source = OurNotesGekisouPresentationTiming(
    completeDelayMs: 500,
    lastNoteSlowJudgeDelayMs: 251,
  );
}

enum OurNotesGekisouCountdownClip { number1, number2, number3, out }

final class OurNotesGekisouCountdownPresentation {
  const OurNotesGekisouCountdownPresentation({
    required this.rangeIndex,
    required this.mission,
    required this.count,
    required this.clip,
    required this.clipTimeSeconds,
    required this.visible,
  });

  final int? rangeIndex;
  final OurNotesGekisouMission? mission;
  final int? count;
  final OurNotesGekisouCountdownClip? clip;
  final double clipTimeSeconds;
  final bool visible;
}

final class OurNotesGekisouJustPresentation {
  const OurNotesGekisouJustPresentation({
    required this.rangeIndex,
    required this.visible,
    required this.count,
    required this.lastJudgedAtMs,
    required this.lastAddedCount,
  });

  final int? rangeIndex;
  final bool visible;
  final int count;
  final double? lastJudgedAtMs;
  final int lastAddedCount;
}

final class OurNotesGekisouPresentationFrame {
  const OurNotesGekisouPresentationFrame({
    required this.enabled,
    required this.observedTimeMs,
    required this.countdown,
    required this.just,
  });

  final bool enabled;
  final double observedTimeMs;
  final OurNotesGekisouCountdownPresentation countdown;
  final OurNotesGekisouJustPresentation just;
}

final class _JustEvent {
  const _JustEvent(this.noteId, this.judgedAtMs);

  final int noteId;
  final double judgedAtMs;
}

int _upperBound(List<_JustEvent> events, double timeMs) {
  var low = 0;
  var high = events.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (events[middle].judgedAtMs <= timeMs) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

/// Canonical membership and actual judgement time also rebuild seek prefixes.
final class OurNotesGekisouPresentation {
  OurNotesGekisouPresentation(
    Iterable<OurNotesGekisouRange> ranges, [
    this.timing = OurNotesGekisouPresentationTiming.source,
  ]) : ranges = List.unmodifiable(ranges) {
    _events = List.generate(this.ranges.length, (_) => []);
  }

  final List<OurNotesGekisouRange> ranges;
  final OurNotesGekisouPresentationTiming timing;
  late final List<List<_JustEvent>> _events;
  final _counted = <int, ({int range, _JustEvent event})>{};
  final _float32 = Float32List(1);

  void record(OurNotesGekisouPresentationJudgement result) {
    final old = _counted[result.noteId];
    if (old != null) {
      if (result.judgement == 6 &&
          old.event.judgedAtMs == result.judgedAtMs &&
          ranges[old.range].contains(result.noteTimeMs)) {
        return;
      }
      _events[old.range].remove(old.event);
      _counted.remove(result.noteId);
    }
    if (result.judgement != 6) return;
    final index = ranges.indexWhere(
      (range) => range.contains(result.noteTimeMs),
    );
    if (index < 0 ||
        ranges[index].mission != OurNotesGekisouMission.justCount) {
      return;
    }
    final event = _JustEvent(result.noteId, result.judgedAtMs);
    final events = _events[index];
    events.insert(_upperBound(events, result.judgedAtMs), event);
    _counted[result.noteId] = (range: index, event: event);
  }

  void reset([
    Iterable<OurNotesGekisouPresentationJudgement> results = const [],
  ]) {
    _counted.clear();
    for (final events in _events) {
      events.clear();
    }
    for (final result in results) {
      record(result);
    }
  }

  OurNotesGekisouPresentationFrame sample(
    double observedTimeMs, {
    bool enabled = true,
    int? completedRangeCount,
  }) {
    var index = -1;
    if (enabled) {
      for (var candidate = 0; candidate < ranges.length; candidate++) {
        if (ranges[candidate].startTimeMs > observedTimeMs) break;
        index = candidate;
      }
    }
    final range = index >= 0 ? ranges[index] : null;
    final events = index >= 0 ? _events[index] : null;
    final count = events == null ? 0 : _upperBound(events, observedTimeMs);
    final lastTime = count > 0 ? events![count - 1].judgedAtMs : null;
    var added = 0;
    for (
      var cursor = count - 1;
      cursor >= 0 && events![cursor].judgedAtMs == lastTime;
      cursor--
    ) {
      added++;
    }
    return OurNotesGekisouPresentationFrame(
      enabled: enabled,
      observedTimeMs: observedTimeMs,
      countdown: _countdown(observedTimeMs, enabled, completedRangeCount),
      just: OurNotesGekisouJustPresentation(
        rangeIndex: index >= 0 ? index : null,
        visible:
            range?.mission == OurNotesGekisouMission.justCount &&
            observedTimeMs < range!.endTimeMs,
        count: count,
        lastJudgedAtMs: lastTime,
        lastAddedCount: added,
      ),
    );
  }

  OurNotesGekisouCountdownPresentation _countdown(
    double timeMs,
    bool enabled,
    int? completedCount,
  ) {
    const hidden = OurNotesGekisouCountdownPresentation(
      rangeIndex: null,
      mission: null,
      count: null,
      clip: null,
      clipTimeSeconds: 0,
      visible: false,
    );
    if (!enabled) return hidden;
    final completeDelay =
        timing.lastNoteSlowJudgeDelayMs + timing.completeDelayMs;
    final index =
        completedCount ??
        ranges.indexWhere((range) => timeMs < range.endTimeMs + completeDelay);
    if (index < 0 || index >= ranges.length) return hidden;
    final range = ranges[index];
    _float32[0] = (range.startTimeMs - timeMs.truncate()).toDouble();
    _float32[0] = _float32[0] / 1000;
    final count = _float32[0].floor() + 1;
    if (count > 3) return hidden;
    if (count < 1) {
      return OurNotesGekisouCountdownPresentation(
        rangeIndex: index,
        mission: range.mission,
        count: null,
        clip: OurNotesGekisouCountdownClip.out,
        clipTimeSeconds: ((timeMs - range.startTimeMs) / 1000).clamp(
          0,
          double.infinity,
        ),
        visible: true,
      );
    }
    return OurNotesGekisouCountdownPresentation(
      rangeIndex: index,
      mission: range.mission,
      count: count,
      clip: OurNotesGekisouCountdownClip.values[count - 1],
      clipTimeSeconds: ((timeMs - (range.startTimeMs - count * 1000)) / 1000)
          .clamp(0, double.infinity),
      visible: true,
    );
  }
}
