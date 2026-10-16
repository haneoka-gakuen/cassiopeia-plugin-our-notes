enum OurNotesIntroPlaybackPhase { idle, playing, paused, complete }

/// Independent pre-music timeline driven by the host's monotonic timestamp.
final class OurNotesIntroPlayback {
  OurNotesIntroPlayback(this.durationSeconds) {
    if (!durationSeconds.isFinite || durationSeconds <= 0) {
      throw ArgumentError.value(durationSeconds, 'durationSeconds');
    }
  }

  final double durationSeconds;
  static const _fixedDelta = 1 / 60;
  var _phase = OurNotesIntroPlaybackPhase.idle;
  var _elapsed = 0.0;
  var _anchorMicros = 0;
  var _rate = 1.0;
  var _pendingRealtime = 0.0;

  OurNotesIntroPlaybackPhase get phase => _phase;
  double get elapsedSeconds => _elapsed;
  double get playbackRate => _rate;

  bool start(int nowMicros) {
    if (_phase == OurNotesIntroPlaybackPhase.complete) return false;
    if (_phase != OurNotesIntroPlaybackPhase.playing) {
      _anchorMicros = nowMicros;
      _phase = OurNotesIntroPlaybackPhase.playing;
    }
    return true;
  }

  void pause(int nowMicros) {
    sample(nowMicros);
    if (_phase == OurNotesIntroPlaybackPhase.playing) {
      _phase = OurNotesIntroPlaybackPhase.paused;
    }
  }

  void setRate(double rate, int nowMicros) {
    if (!rate.isFinite || rate <= 0) throw ArgumentError.value(rate, 'rate');
    sample(nowMicros);
    _rate = rate;
  }

  double sample(int nowMicros) {
    if (_phase != OurNotesIntroPlaybackPhase.playing) return _elapsed;
    if (nowMicros < _anchorMicros) {
      throw StateError('intro_host_clock_moved_backwards');
    }
    _pendingRealtime += (nowMicros - _anchorMicros) / 1000000;
    _anchorMicros = nowMicros;
    while (_pendingRealtime >= _fixedDelta && _elapsed < durationSeconds) {
      _pendingRealtime -= _fixedDelta;
      final next = _elapsed + _fixedDelta * _rate;
      _elapsed = next < durationSeconds ? next : durationSeconds;
    }
    if (_elapsed >= durationSeconds) {
      _phase = OurNotesIntroPlaybackPhase.complete;
    }
    return _elapsed;
  }

  void bypass() {
    _elapsed = durationSeconds;
    _pendingRealtime = 0;
    _phase = OurNotesIntroPlaybackPhase.complete;
  }
}
