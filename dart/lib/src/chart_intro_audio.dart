import 'chart_intro_playback.dart';

final class OurNotesIntroSound {
  const OurNotesIntroSound({
    required this.path,
    required this.gain,
    this.loopStartSeconds,
    this.loopEndSeconds,
  });
  final String path;
  final double gain;
  final double? loopStartSeconds, loopEndSeconds;
}

/// Canonical MasterLiveSe and live-category option data shared with the web host.
final class OurNotesIntroAudio {
  OurNotesIntroAudio(Map<String, Object?> options) {
    final defaults = (options['defaults'] as List).cast<Map>();
    String option(int type) {
      final values = {
        for (final row in defaults)
          if (row['optionItemType'] == type) row['valueString'] as String,
      };
      if (values.length != 1) {
        throw FormatException('intro_option_default:$type');
      }
      return values.single;
    }

    final mute = option(416), volume = double.parse(option(412));
    if ((mute != 'TRUE' && mute != 'FALSE') ||
        !volume.isFinite ||
        volume < 0 ||
        volume > 100) {
      throw const FormatException('intro_audio_category');
    }
    final rows = (options['liveSe'] as List).cast<Map>().where(
      (row) => row['liveSeType'] == 9,
    );
    if (rows.length != 1) {
      throw const FormatException('intro_cheer_binding');
    }
    final source = rows.single['sound'] as Map?;
    if (source == null || source['missing'] == true) return;
    final path = source['playableUrl'];
    if (path is! String || path.isEmpty || source['category'] != 1) {
      throw const FormatException('intro_cheer_source');
    }
    final loop = source['loopInfo'] as Map?;
    double? start, end;
    if (loop?['isLoop'] == true) {
      final rate = source['sampleRate'] as num,
          first = loop!['loopStartSample'] as num,
          last = loop['loopEndSample'] as num;
      if (!rate.isFinite ||
          rate <= 0 ||
          !first.isFinite ||
          first < 0 ||
          !last.isFinite ||
          last <= first) {
        throw const FormatException('intro_cheer_loop');
      }
      start = first / rate;
      end = last / rate;
    }
    _cheer = OurNotesIntroSound(
      path: path,
      gain: mute == 'TRUE' ? 0 : volume / 100,
      loopStartSeconds: start,
      loopEndSeconds: end,
    );
  }

  OurNotesIntroSound? _cheer;
  OurNotesIntroSound? get cheer => _cheer;
  // These two timings preserve the existing web intro-host contract.
  static const cheerStartSeconds = 1.0;
  static const cheerFadeDuration = Duration(seconds: 1);
  bool _cheerStarted = false, _complete = false;
  bool get cheerActive => _cheerStarted && !_complete && _cheer != null;

  Set<OurNotesIntroAudioCue> sample(OurNotesIntroPlayback playback) {
    if (_complete) return const {};
    if (playback.phase == OurNotesIntroPlaybackPhase.complete) {
      _complete = true;
      return _cheerStarted ? const {OurNotesIntroAudioCue.fadeCheer} : const {};
    }
    if (!_cheerStarted &&
        playback.phase == OurNotesIntroPlaybackPhase.playing &&
        playback.elapsedSeconds >= cheerStartSeconds) {
      _cheerStarted = true;
      return cheer == null ? const {} : const {OurNotesIntroAudioCue.cheer};
    }
    return const {};
  }

  void bypass() {
    _cheerStarted = true;
    _complete = true;
  }
}

enum OurNotesIntroAudioCue { cheer, fadeCheer }
