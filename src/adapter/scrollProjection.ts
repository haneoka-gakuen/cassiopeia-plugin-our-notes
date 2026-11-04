import { interpolateNoteLine, isPairNoteOperateType, mirrorLane } from "@haneoka/cassiopeia";
import type { ChartDocument, ChartNote, SessionSnapshot } from "@haneoka/cassiopeia";
import type { NativeChartVisualProfiles, RenderNoteKind, RenderDirection, RenderNote, RenderHold, RenderPathPoint, RenderSimultaneousLine } from "../render/types.js";

/** Musical time remains the judgement clock, including while the visual clock stops or reverses. */
export class NativeScrollClock {
  readonly segments: { timeMs: number; value: number; scale: number }[] = [{ timeMs: 0, value: 0, scale: 1 }];
  current = 0;
  constructor(readonly id: string, changes: readonly { timeMs: number; scale: number }[]) {
    let previous = -1;
    for (const change of changes) {
      if (!Number.isFinite(change.timeMs) || change.timeMs < 0 || change.timeMs <= previous || !Number.isFinite(change.scale))
        throw new RangeError("Invalid scroll timeline");
      previous = change.timeMs;
      const last = this.segments[this.segments.length - 1]!;
      if (change.timeMs === 0) last.scale = change.scale;
      else this.segments.push({ timeMs: change.timeMs, value: last.value + (change.timeMs - last.timeMs) * last.scale, scale: change.scale });
    }
  }
  at(timeMs: number): number {
    if (timeMs < 0) return timeMs;
    let low = 0, high = this.segments.length;
    while (low < high) { const mid = (low + high) >>> 1; if (this.segments[mid]!.timeMs <= timeMs) low = mid + 1; else high = mid; }
    const segment = this.segments[Math.max(0, low - 1)]!;
    return segment.value + (timeMs - segment.timeMs) * segment.scale;
  }
}
interface PathSample { timeMs: number; pos: number; size: number; value: number; left: NativeScrollClock; right: NativeScrollClock; ratio: number }
interface ScrollLine { id: number; kind: "long" | "guide"; critical: boolean; minimumWidth: number; authored: ChartNote[]; points: PathSample[]; start: number; end: number; clocks: NativeScrollClock[]; minimumValue: number; maximumValue: number }
interface NotePartition { clock: NativeScrollClock; speed?: number; notes: { note: ChartNote; value: number }[] }
interface ProjectionPolicy {
  kind(note: ChartNote): RenderNoteKind;
  direction(note: ChartNote, mirror: boolean): RenderDirection;
  hiddenStart(note: ChartNote): boolean;
  guideAlpha(timeMs: number, endTimeMs: number): number;
  viewTime(speed: number, curve: number): number;
}
const lowerBound = <T>(items: readonly T[], target: number, value: (item: T) => number) => {
  let low = 0, high = items.length;
  while (low < high) { const mid = (low + high) >>> 1; if (value(items[mid]!) < target) low = mid + 1; else high = mid; }
  return low;
};

export function prepareNativeScrollGeometry(chart: ChartDocument, scroll: NonNullable<NativeChartVisualProfiles["scroll"]>) {
  const clocks = new Map<string, NativeScrollClock>(), noteClocks = new Map<number, NativeScrollClock>(), lines: ScrollLine[] = [];
    const offsetMs = scroll.offsetMs ?? 0;
    if (!Number.isFinite(offsetMs)) throw new RangeError("Invalid scroll offset");
    if (!Array.isArray(scroll.groups) || !Array.isArray(scroll.notes) || !scroll.groups.length) throw new TypeError("Invalid scroll profiles");
    for (const group of scroll.groups) {
      if (!group.id || clocks.has(group.id)) throw new TypeError("Duplicate scroll group");
      clocks.set(group.id, new NativeScrollClock(group.id, group.changes));
    }
    const byId = new Map(chart.notes.map(note => [note.id, note]));
    for (const entry of scroll.notes) {
      const clock = clocks.get(entry.groupId);
      if (!byId.has(entry.nativeNoteId) || !clock || noteClocks.has(entry.nativeNoteId)) throw new TypeError("Invalid scroll note");
      noteClocks.set(entry.nativeNoteId, clock);
    }
    if (noteClocks.size !== chart.notes.length) throw new TypeError("Missing scroll note");
    for (const line of chart.lines) {
      const authored = line.noteIds.map(id => byId.get(id)!).filter(note => note.indexInLine !== null).sort((a, b) => a.timeMs - b.timeMs || (a.indexInLine ?? 0) - (b.indexInLine ?? 0));
      if (authored.length < 2) continue;
      const points: PathSample[] = [];
      for (let index = 0; index < authored.length - 1; index++) {
        const head = authored[index]!, tail = authored[index + 1]!, left = noteClocks.get(head.id)!, right = noteClocks.get(tail.id)!;
        const times = new Set<number>([head.timeMs, tail.timeMs]);
        const steps = Math.max(1, Math.ceil((tail.timeMs - head.timeMs) / 45));
        for (let step = 1; step < steps; step++) times.add(head.timeMs + (tail.timeMs - head.timeMs) * step / steps);
        for (const clock of [left, right]) for (const segment of clock.segments) if (segment.timeMs + offsetMs > head.timeMs && segment.timeMs + offsetMs < tail.timeMs) times.add(segment.timeMs + offsetMs);
        for (const timeMs of [...times].sort((a, b) => a - b)) {
          if (index > 0 && timeMs === head.timeMs) continue;
          const ratio = tail.timeMs === head.timeMs ? 1 : (timeMs - head.timeMs) / (tail.timeMs - head.timeMs), shape = interpolateNoteLine(head, tail, timeMs);
          points.push({ timeMs, pos: shape.pos, size: shape.size, left, right, ratio, value: left.at(timeMs - offsetMs) * (1 - ratio) + right.at(timeMs - offsetMs) * ratio });
        }
      }
      const usedClocks = new Set<NativeScrollClock>();
      let minimumValue = Infinity, maximumValue = -Infinity;
      for (const point of points) {
        usedClocks.add(point.left); usedClocks.add(point.right);
        minimumValue = Math.min(minimumValue, point.value); maximumValue = Math.max(maximumValue, point.value);
      }
      lines.push({ id: line.id, kind: line.kind, critical: line.critical, minimumWidth: authored.reduce((size, note) => Math.min(size, note.size), Infinity), authored, points, start: authored[0]!.timeMs, end: authored[authored.length - 1]!.timeMs, clocks: [...usedClocks], minimumValue, maximumValue });
    }
  return { clocks, noteClocks, lines };
}

/** Projection of source-independent authored clocks through the existing Our Notes visual DTO. */
export class NativeScrollProjection {
  private readonly offsetMs: number;
  private readonly clocks: Map<string, NativeScrollClock>;
  private readonly noteClocks: Map<number, NativeScrollClock>;
  private readonly speeds: Map<number, number>;
  private readonly lineSpeeds: Map<number, number>;
  private readonly partitions: NotePartition[] = [];
  private readonly lines: ScrollLine[];
  private readonly pairs: [ChartNote, ChartNote][] = [];
  private readonly notePool: RenderNote[] = [];
  private readonly holdPool: (RenderHold & { points: RenderPathPoint[]; pool: RenderPathPoint[] })[] = [];
  private readonly pairPool: RenderSimultaneousLine[] = [];
  private readonly viewTimes = new Map<number, number>();
  private readonly path: RenderPathPoint[] = [];
  private readonly pathPool: RenderPathPoint[] = [];
  private readonly run: RenderPathPoint[] = [];
  constructor(private readonly chart: ChartDocument, profiles: NativeChartVisualProfiles, private readonly policy: ProjectionPolicy) {
    this.offsetMs = profiles.scroll?.offsetMs ?? 0;
    const prepared = prepareNativeScrollGeometry(chart, profiles.scroll!);
    this.clocks = prepared.clocks; this.noteClocks = prepared.noteClocks; this.lines = prepared.lines;
    this.speeds = new Map(profiles.notes.map(entry => [entry.nativeNoteId, entry.noteSpeed]));
    this.lineSpeeds = new Map(profiles.lines.map(entry => [entry.nativeLineId, entry.noteSpeed]));
    const partitions = new Map<NativeScrollClock, Map<number | undefined, NotePartition>>(), pairs = new Map<number, ChartNote[]>();
    for (const note of chart.notes) {
      if (!note.visible || policy.hiddenStart(note)) continue;
      const clock = this.noteClocks.get(note.id)!, speed = this.speeds.get(note.id);
      let speeds = partitions.get(clock); if (!speeds) partitions.set(clock, speeds = new Map());
      let partition = speeds.get(speed); if (!partition) { partition = { clock, speed, notes: [] }; speeds.set(speed, partition); this.partitions.push(partition); }
      partition.notes.push({ note, value: clock.at(note.timeMs - this.offsetMs) });
      if (isPairNoteOperateType(note.operateType)) { const group = pairs.get(note.tick) ?? []; group.push(note); pairs.set(note.tick, group); }
    }
    for (const partition of this.partitions) partition.notes.sort((a, b) => a.value - b.value || a.note.id - b.note.id);
    for (const group of pairs.values()) {
      group.sort((a, b) => a.id - b.id);
      for (let index = 1; index < group.length; index++) if (group[index - 1]!.pos + group[index - 1]!.size / 2 !== group[index]!.pos + group[index]!.size / 2) this.pairs.push([group[index - 1]!, group[index]!]);
    }

  }
  project(timeMs: number, snapshot: SessionSnapshot, settings: { noteSpeed: number; curve: number; mirror: boolean; noteSize: number; pairs: boolean; guideAlpha: number; longAlpha: number }, output: { notes: RenderNote[]; holds: RenderHold[]; simultaneousLines: RenderSimultaneousLine[] }): void {
    for (const clock of this.clocks.values()) clock.current = clock.at(timeMs - this.offsetMs);
    const viewTimes = this.viewTimes; viewTimes.clear();
    const view = (speed?: number) => { const key = speed ?? settings.noteSpeed; let value = viewTimes.get(key); if (value === undefined) { value = this.policy.viewTime(key, settings.curve) * 1000; viewTimes.set(key, value); } return value; };
    output.notes.length = output.holds.length = output.simultaneousLines.length = 0;
    for (const partition of this.partitions) {
      const duration = view(partition.speed), current = partition.clock.current;
      const first = lowerBound(partition.notes, current - duration * .16, item => item.value), last = lowerBound(partition.notes, current + duration * 1.1, item => item.value);
      for (let index = first; index < last; index++) {
        const { note, value } = partition.notes[index]!;
        if (snapshot.noteState.isProcessed(note.id)) continue;
        const approach = (value - current) / duration, next = this.notePool[output.notes.length] ??= { id: note.id, kind: "tap", lane: 0, width: 0, approach: 0 };
        next.id = note.id; next.kind = this.policy.kind(note); next.lane = settings.mirror ? mirrorLane(note.pos, note.size) : note.pos;
        next.width = note.size; next.approach = approach; next.direction = this.policy.direction(note, settings.mirror); next.critical = note.critical; next.scale = settings.noteSize; next.alpha = approach < 0 ? Math.max(0, 1 + approach / .16) : 1;
        output.notes.push(next);
      }
    }
    output.notes.sort((a, b) => Number(a.id) - Number(b.id));
    if (settings.pairs) for (const [first, second] of this.pairs) {
      if (snapshot.noteState.isProcessed(first.id) || snapshot.noteState.isProcessed(second.id)) continue;
      const a = first.pos + first.size / 2 < second.pos + second.size / 2 ? first : second, b = a === first ? second : first;
      const left = this.noteClocks.get(a.id)!, right = this.noteClocks.get(b.id)!;
      const leftApproach = (left.at(a.timeMs - this.offsetMs) - left.current) / view(this.speeds.get(a.id)), rightApproach = (right.at(b.timeMs - this.offsetMs) - right.current) / view(this.speeds.get(b.id));
      if (leftApproach < 0 || leftApproach > 1.1 || rightApproach < 0 || rightApproach > 1.1) continue;
      const next = this.pairPool[output.simultaneousLines.length] ??= { id: "", leftCenter: 0, rightCenter: 0, approach: 0 };
      next.id = `${a.id}:${b.id}`; next.leftCenter = settings.mirror ? 24 - (b.pos + b.size / 2) : a.pos + a.size / 2; next.rightCenter = settings.mirror ? 24 - (a.pos + a.size / 2) : b.pos + b.size / 2;
      next.approach = leftApproach; next.leftApproach = settings.mirror ? rightApproach : leftApproach; next.rightApproach = settings.mirror ? leftApproach : rightApproach;
      output.simultaneousLines.push(next);
    }
    for (const line of this.lines) {
      if (timeMs >= line.end) continue;
      const duration = view(this.lineSpeeds.get(line.id)), start = Math.max(timeMs, line.start), path = this.path;
      if (timeMs < line.start) {
        let minimumClock = Infinity, maximumClock = -Infinity;
        for (const clock of line.clocks) {
          minimumClock = Math.min(minimumClock, clock.current); maximumClock = Math.max(maximumClock, clock.current);
        }
        if (line.minimumValue - maximumClock > duration * 1.1 || line.maximumValue - minimumClock < -duration * .16) continue;
      }
      path.length = 0;
      const append = (lane: number, width: number, approach: number, lineProgress: number) => {
        const point = this.pathPool[path.length] ??= { lane: 0, width: 0, approach: 0 };
        point.lane = lane; point.width = width; point.approach = approach; point.lineProgress = lineProgress; path.push(point);
      };
      if (start > line.start) {
        const index = Math.min(line.authored.length - 2, Math.max(0, lowerBound(line.authored, start, note => note.timeMs) - 1)), head = line.authored[index]!, tail = line.authored[index + 1]!, shape = interpolateNoteLine(head, tail, start);
        append(settings.mirror ? mirrorLane(shape.pos, shape.size) : shape.pos, shape.size, 0, (start - line.start) / (line.end - line.start));
      }
      for (let index = lowerBound(line.points, start, point => point.timeMs); index < line.points.length; index++) {
        const point = line.points[index]!, approach = (point.value - point.left.current * (1 - point.ratio) - point.right.current * point.ratio) / duration;
        append(settings.mirror ? mirrorLane(point.pos, point.size) : point.pos, point.size, approach, (point.timeMs - line.start) / (line.end - line.start));
      }
      const run = this.run; run.length = 0;
      let direction = 0, part = 0;
      const emit = () => {
        if (run.length < 2) return;
        const next = this.holdPool[output.holds.length] ??= { id: "", kind: "slide", points: [], pool: [] };
        next.id = `scroll:${line.id}:${part++}`; next.kind = line.kind === "guide" ? "guide" : "slide"; next.minimumWidth = line.minimumWidth;
        next.critical = line.critical; next.active = line.kind !== "guide" && timeMs >= line.start && snapshot.lineState.isActive(line.id);
        next.alpha = line.kind === "guide" ? settings.guideAlpha * this.policy.guideAlpha(timeMs, line.end) : settings.longAlpha;
        next.points.length = 0;
        for (let index = 0; index < run.length; index++) {
          const point = run[direction < 0 ? run.length - index - 1 : index]!;
          const target = next.pool[index] ??= { lane: 0, width: 0, approach: 0 }; Object.assign(target, point); next.points.push(target);
        }
        output.holds.push(next);
      };
      for (let index = 1; index < path.length; index++) {
        const a = path[index - 1]!, b = path[index]!, change = b.approach - a.approach, sign = Math.sign(change);
        if (!sign || Math.max(a.approach, b.approach) < -.16 || Math.min(a.approach, b.approach) > 1.1) { emit(); run.length = 0; direction = 0; continue; }
        if (direction && direction !== sign) { emit(); run.length = 0; }
        direction = sign;
        const clip = (point: RenderPathPoint, other: RenderPathPoint) => {
          const approach = Math.max(-.16, Math.min(1.1, point.approach)); if (approach === point.approach) return point;
          const ratio = (approach - point.approach) / (other.approach - point.approach);
          return { lane: point.lane + (other.lane - point.lane) * ratio, width: point.width + (other.width - point.width) * ratio, approach, lineProgress: point.lineProgress! + (other.lineProgress! - point.lineProgress!) * ratio };
        };
        if (!run.length) run.push(clip(a, b)); run.push(clip(b, a));
      }
      emit();
    }
  }
}
