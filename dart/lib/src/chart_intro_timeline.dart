import 'dart:math' as math;
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

import 'chart_intro_types.dart';

final class OurNotesIntroTimelineValue {
  const OurNotesIntroTimelineValue(
    this.target,
    this.path,
    this.type,
    this.attribute,
    this.values,
  );
  final String target;
  final int path, type, attribute;
  final Float32List values;
}

final class _Clip {
  _Clip(this.timing, this.animation);
  final Map timing;
  final NativeAuthoredAnimationClip animation;
  double get start => (timing['m_Start'] as num).toDouble();
  double get duration => (timing['m_Duration'] as num).toDouble();
  double? at(double seconds) {
    final clipIn = (timing['m_ClipIn'] as num).toDouble();
    final rate = (timing['m_TimeScale'] as num).toDouble();
    if (seconds >= start && seconds <= start + duration) {
      return math.min((seconds - start) * rate + clipIn, animation.duration);
    }
    if (seconds < start &&
        seconds >= start - (timing['m_PreExtrapolationTime'] as num) &&
        timing['m_PreExtrapolationMode'] == 1) {
      return clipIn;
    }
    final post = timing['m_PostExtrapolationTime'];
    final postTime = post is Map && post[r'$unityFloat'] == 'Infinity'
        ? double.infinity
        : (post as num).toDouble();
    if (seconds > start + duration &&
        seconds <= start + duration + postTime &&
        timing['m_PostExtrapolationMode'] == 1) {
      return math.min(duration * rate + clipIn, animation.duration);
    }
    return null;
  }
}

/// Compiled original Timeline clips retain their authored ordering and Hold extrapolation.
final class OurNotesIntroTimeline {
  OurNotesIntroTimeline(this.packet, Map band) {
    final records = packet['records'] as Map;
    for (final raw in band['tracks'] as List) {
      final track = raw as Map, name = track['name'] as String;
      final clips = <_Clip>[];
      for (final rawClip in track['clips'] as List) {
        final clip = rawClip as Map;
        final source = (records[clip['animation']] as Map)['record'] as Map;
        final parsed = _Clip(
          clip['timing'] as Map,
          NativeAuthoredAnimationClip(source['data'] as Map),
        );
        clips.add(parsed);
        durationSeconds = math.max(
          durationSeconds,
          parsed.start + parsed.duration,
        );
      }
      tracks.add((target: name, clips: clips));
      if (clips.isEmpty && track['markers'] is Map) {
        final owner = (track['key'] as String).split(':').first;
        for (final pointer in (track['markers'] as Map)['m_Objects'] as List) {
          final data = _resolve(records, pointer as Map, owner)['data'] as Map;
          if (data['m_Enabled'] != 1 && data['m_Enabled'] != true) continue;
          final asset = data['m_Asset'] as Map;
          final sf = (asset['reference'] as Map?)?['serializedFile'] ?? owner;
          final id = '$sf:${asset['m_PathID']}';
          signals.add((
            time: (data['m_Time'] as num).toDouble(),
            id: id,
            once: data['m_EmitOnce'] == true || data['m_EmitOnce'] == 1,
            retroactive:
                data['m_Retroactive'] == true || data['m_Retroactive'] == 1,
          ));
        }
      }
    }
    // The receiver owns the SignalAsset→persistent-call mapping.
    for (final raw in records.values) {
      final record = (raw as Map)['record'] as Map;
      final data = record['data'] as Map;
      final events = data['m_Events'];
      if (events is! Map || events['m_Signals'] is! List) continue;
      final assets = events['m_Signals'] as List;
      final handlers = events['m_Events'] as List;
      for (var i = 0; i < assets.length; i++) {
        final pointer = assets[i] as Map,
            owner = record['serializedFile'] as String;
        final sf = (pointer['reference'] as Map?)?['serializedFile'] ?? owner;
        final id = '$sf:${pointer['m_PathID']}';
        final calls =
            (((handlers[i] as Map)['m_PersistentCalls'] as Map)['m_Calls']
                    as List)
                .cast<Map>();
        if (calls.any(
          (call) =>
              call['m_CallState'] != 0 &&
              call['m_MethodName'] == 'NotifyPlayVoice' &&
              call['m_Mode'] == 1 &&
              call['m_TargetAssemblyTypeName'] ==
                  'Live.LivePlayableTimeline, SiriusAsset',
        )) {
          voiceSignals.add(id);
        }
      }
    }
    signals.sort((a, b) => a.time.compareTo(b.time));
  }
  final Map packet;
  final tracks = <({String target, List<_Clip> clips})>[];
  final signals = <({double time, String id, bool once, bool retroactive})>[];
  final voiceSignals = <String>{}, emitted = <String>{};
  double durationSeconds = 0;
  double _previous = -1;

  static Map _resolve(Map records, Map pointer, String owner) {
    final file = (pointer['reference'] as Map?)?['serializedFile'] ?? owner;
    return (records['$file:${pointer['m_PathID']}'] as Map)['record'] as Map;
  }

  List<OurNotesIntroTimelineValue> sample(double elapsed) {
    final time = elapsed.clamp(0, durationSeconds).toDouble();
    return [
      for (final track in tracks)
        for (final clip in track.clips)
          if (clip.at(time) case final seconds?)
            for (final value in clip.animation.sampleBindingsAt(seconds))
              OurNotesIntroTimelineValue(
                track.target,
                value.binding['path'] as int,
                value.binding['typeID'] as int,
                value.binding['attribute'] as int,
                value.values,
              ),
    ];
  }

  List<OurNotesIntroVoiceCue> advanceSignals(
    double elapsed, {
    bool bypass = false,
  }) {
    final result = <OurNotesIntroVoiceCue>[];
    if (elapsed < _previous) {
      _previous = -1;
      emitted.clear();
    }
    for (var index = 0; index < signals.length; index++) {
      final signal = signals[index], key = '$index:${signals[index].id}';
      final crossed = _previous < signal.time && elapsed >= signal.time;
      if (crossed && (!signal.once || !emitted.contains(key))) {
        emitted.add(key);
        if (!bypass && voiceSignals.contains(signal.id)) {
          result.add(
            OurNotesIntroVoiceCue(
              timeSeconds: signal.time,
              signalIdentity: signal.id,
              method: 'NotifyPlayVoice',
            ),
          );
        }
      }
    }
    _previous = elapsed;
    return result;
  }
}
