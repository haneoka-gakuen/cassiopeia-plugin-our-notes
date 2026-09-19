import { NoteOperateType, NoteSimulateJudgement } from "@haneoka/cassiopeia";
import type { JudgementEvent } from "@haneoka/cassiopeia";

export type HapticFamily = "normal" | "flick" | "trace" | "slideCombo" | "beginLong" | "inVain";
export interface HapticCue {
  family: HapticFamily;
  /** Original HapticFeedbackParameter integer, passed unchanged to the host. */
  feedbackType: number;
  timeMs: number;
  noteId?: number;
  judgement?: NoteSimulateJudgement;
}
export interface HapticPort {
  emit(cue: Readonly<HapticCue>): void;
  stop(): void;
}
export type HapticProfile = Readonly<Record<HapticFamily, readonly number[]>>;

// Our Notes 0.3.2, App.LiveLogic.HapticFeedbackParameter::.ctor at 0x4bc216c:
// 34 Int32 values are initialized to 1; the enabled byte at +152 is true.
// Indexing follows native judgement values: Miss=1, Bad=2, ... Excellent=6.
const feedback = Object.freeze([0, 0, 1, 1, 1, 1, 1]);
export const OUR_NOTES_HAPTIC_PROFILE: HapticProfile = Object.freeze({
  normal: feedback,
  flick: feedback,
  trace: feedback,
  slideCombo: feedback,
  beginLong: feedback,
  inVain: feedback,
});

/** Browsers intentionally do not synthesize arbitrary vibration durations. */
export const NO_HAPTICS: HapticPort = Object.freeze({ emit() {}, stop() {} });

export function hapticFamily(type: NoteOperateType): HapticFamily {
  switch (type) {
    case NoteOperateType.Flick:
    case NoteOperateType.SlideBeginFlick:
    case NoteOperateType.SlideEndFlick:
    case NoteOperateType.GuideBeginFlick:
      return "flick";
    case NoteOperateType.Trace:
    case NoteOperateType.SlideBeginTrace:
    case NoteOperateType.SlideEndTrace:
    case NoteOperateType.SlideConnectionTrace:
    case NoteOperateType.GuideBeginTrace:
    case NoteOperateType.GuideEndTrace:
      return "trace";
    case NoteOperateType.SlideConnection:
    case NoteOperateType.Combo:
      return "slideCombo";
    default:
      return "normal";
  }
}

/** No delayed work survives pause, seek, or destruction; hosts own device APIs. */
export class HapticFeedback {
  constructor(
    private port: HapticPort = NO_HAPTICS,
    private profile: HapticProfile = OUR_NOTES_HAPTIC_PROFILE,
    public enabled = true,
  ) {}

  judgement(event: JudgementEvent): void {
    if (!this.enabled || event.judgement <= NoteSimulateJudgement.Miss) return;
    const family = hapticFamily(event.note.operateType);
    const feedbackType = this.profile[family][event.judgement] ?? 0;
    if (feedbackType !== 0)
      this.port.emit({
        family,
        feedbackType,
        timeMs: event.judgedAtMs,
        noteId: event.note.id,
        judgement: event.judgement,
      });
  }

  cue(family: "beginLong" | "inVain", timeMs: number): void {
    const feedbackType = this.profile[family][NoteSimulateJudgement.Perfect] ?? 0;
    if (this.enabled && feedbackType) this.port.emit({ family, feedbackType, timeMs });
  }

  stop(): void {
    this.port.stop();
  }
}
