import { systemDateTime } from '@kit.BasicServicesKit';
import { CalibrationProfile } from './Calibration';
import { ScoreResult, TouchGroup, keyIndex } from './Score';
import { TouchBackend } from './TouchBackend';

export function monotonicMs(): number { return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP); }
export class Playback {
  state: string = '未播放';
  beforeCountdown: () => Promise<void> = () => Promise.resolve();
  elapsedMs: number = 0;
  durationMs: number = 0;
  onChange: (text: string) => void = () => {};
  private generation: number = 0;
  private paused: boolean = false;
  private speed: number = 1;
  private sourceAnchor: number = 0;
  private timeAnchor: number = 0;
  private position: number = 0;
  private active: boolean = false;
  private ready: boolean = false;
  private groups: TouchGroup[] = [];
  private nextGroup: number = 0;
  private timeline: number = 0;
  isActive(): boolean { return this.active; }
  isPaused(): boolean { return this.paused; }
  canSeek(): boolean { return this.active && this.ready; }
  setPaused(value: boolean): void { if (this.active && this.paused !== value) { this.pauseResume(); } }
  private update(text: string): void { this.state = text; this.onChange(text); }
  private current(): number { return this.paused ? this.position : this.sourceAnchor + Math.max(0, monotonicMs() - this.timeAnchor) * this.speed; }
  setSpeed(value: number): void {
    if (!Number.isFinite(value) || value < 0.5 || value > 1.5) { throw new Error('速度支持0.5至1.5倍'); }
    if (this.active && !this.paused && this.ready) {
      const now = monotonicMs(); const remaining = Math.max(0, this.timeAnchor - now);
      this.sourceAnchor = this.current(); this.timeAnchor = now + remaining;
    }
    this.speed = value;
  }
  pauseResume(): void {
    if (!this.active) { return; }
    if (this.paused) { this.paused = false; this.sourceAnchor = this.position; this.timeAnchor = monotonicMs(); this.update('演奏中'); }
    else { this.position = this.ready ? this.current() : 0; this.paused = true; this.update('已暂停'); }
  }
  seek(value: number): void {
    if (!this.canSeek() || !Number.isFinite(value)) { return; }
    const target = Math.max(0, Math.min(value, this.durationMs));
    let low = 0; let high = this.groups.length;
    while (low < high) {
      const middle = Math.floor((low + high) / 2);
      if (this.groups[middle].time < target) { low = middle + 1; } else { high = middle; }
    }
    this.nextGroup = low; this.position = target; this.elapsedMs = target;
    this.sourceAnchor = target; this.timeAnchor = monotonicMs(); this.timeline++;
    this.update(this.paused ? '已暂停' : '演奏中');
  }
  stop(): void { this.generation++; this.active = false; this.ready = false; this.paused = false; this.update('已停止'); }
  async play(score: ScoreResult, calibration: CalibrationProfile, backend: TouchBackend, delaySeconds: number = 5): Promise<void> {
    this.stop(); const generation = this.generation; this.active = true; this.elapsedMs = 0; this.durationMs = score.duration;
    this.groups = score.groups; this.nextGroup = 0;
    try {
      if (score.errors.length || !score.groups.length) { throw new Error('曲谱尚未通过检查'); }
      this.update('缓存和弦触摸矩阵…'); const cache = new Map<string, string>();
      for (const group of score.groups) {
        if (generation !== this.generation) { return; }
        const key = group.pitches.join(',');
        if (!cache.has(key)) {
          const points = group.pitches.map((pitch: number) => calibration.points[keyIndex(pitch)]);
          cache.set(key, await backend.matrix(group.pitches, points));
        }
      }
      await this.beforeCountdown(); if (generation !== this.generation) { return; }
      this.sourceAnchor = 0; this.position = 0; this.timeAnchor = monotonicMs() + delaySeconds * 1000; this.paused = false; this.ready = true;
      this.update(`${delaySeconds}秒后开始，请切入原神琴界面`);
      let nextReport = 0;
      while (generation === this.generation) {
        if (this.paused) { await new Promise<void>((resolve) => { setTimeout(resolve, 20); }); continue; }
        const now = monotonicMs();
        if (now < this.timeAnchor) { await new Promise<void>((resolve) => { setTimeout(resolve, 20); }); continue; }
        const current = this.current();
        const group = this.groups[this.nextGroup];
        if (group && group.time <= current) {
          const timeline = this.timeline;
          const matrix = cache.get(group.pitches.join(',')); if (!matrix) { throw new Error('和弦缓存丢失'); }
          this.nextGroup++;
          await backend.inject(matrix);
          if (generation !== this.generation) { return; }
          if (timeline !== this.timeline) { continue; }
        } else if (!group && current >= score.duration) { break; }
        if (now >= nextReport) {
          this.elapsedMs = Math.min(this.current(), score.duration); nextReport = now + 250;
          this.update(`演奏中 ${(this.elapsedMs / 1000).toFixed(1)}/${(score.duration / 1000).toFixed(1)}秒`);
        }
        if (!group || group.time > current) { await new Promise<void>((resolve) => { setTimeout(resolve, 10); }); }
      }
      if (generation === this.generation) { this.active = false; this.ready = false; this.elapsedMs = score.duration; this.update('演奏完成'); }
    } catch (e) { if (generation === this.generation) { this.stop(); this.update('演奏失败：' + (e as Error).message); } throw e as Error; }
  }
}
