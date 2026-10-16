import 'package:haneoka_render_profile/core.dart';

final class OurNotesIntroViewport {
  const OurNotesIntroViewport({
    required this.width,
    required this.height,
    required this.worldToClip,
    required this.fieldOfViewRadians,
    required this.cameraPosition,
    required this.cameraXDegrees,
    this.pixelRatio = 1,
  });
  final double width, height, pixelRatio, fieldOfViewRadians, cameraXDegrees;
  final List<double> cameraPosition;
  final List<double> worldToClip;
}

final class OurNotesIntroVoiceCue {
  const OurNotesIntroVoiceCue({
    required this.timeSeconds,
    required this.signalIdentity,
    required this.method,
  });
  final double timeSeconds;
  final String signalIdentity, method;
}

final class OurNotesIntroFrame {
  const OurNotesIntroFrame({
    required this.elapsedSeconds,
    required this.durationSeconds,
    required this.complete,
    required this.gameLaneVisible,
    required this.tapAlpha,
    required this.backgroundScale,
    required this.meshes,
    required this.materials,
    required this.gameDraws,
    required this.effectDraws,
    required this.draws,
    required this.voiceCues,
  });
  final double elapsedSeconds, durationSeconds, tapAlpha;
  final bool complete, gameLaneVisible;
  final List<double> backgroundScale;
  final Map<String, ProjectedMesh> meshes;
  final Map<String, NativeMaterial> materials;
  final List<NativeDraw> gameDraws, effectDraws, draws;
  final List<OurNotesIntroVoiceCue> voiceCues;
}
