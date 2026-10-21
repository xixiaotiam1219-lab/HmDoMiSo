import { fileIo as fs } from '@kit.CoreFileKit';
import { NoteEvent, ScoreResult } from './Score';

const RATE: number = 22050;
const TABLE_SIZE: number = 4096;
const BLOCK: number = 4096;
const RELEASE: number = Math.round(RATE * 0.08);
const DECAY: number = Math.exp(-1.6 / RATE);

class RenderVoice {
  start: number = 0;
  end: number = 0;
  phase: number = 0;
  increment: number = 0;
  envelope: number = 1;
  gain: number = 0.1;
}

/** Offline PCM renderer. No ArkTS work runs on an audio callback deadline. */
export class SynthPreview {
  private table: Float32Array = new Float32Array(TABLE_SIZE);
  constructor() {
    for (let i = 0; i < TABLE_SIZE; i++) {
      const phase = i * 2 * Math.PI / TABLE_SIZE;
      this.table[i] = Math.sin(phase) * 0.7 + Math.sin(phase * 2) * 0.2 +
        Math.sin(phase * 3) * 0.07 + Math.sin(phase * 4) * 0.03;
    }
  }
  private voice(event: NoteEvent): RenderVoice {
    const voice = new RenderVoice();
    voice.start = Math.round(event.start * RATE / 1000);
    voice.end = Math.round(event.end * RATE / 1000);
    voice.increment = 440 * Math.pow(2, (event.pitch - 69) / 12) / RATE * TABLE_SIZE;
    voice.gain = event.voice === 0 ? 0.15 : 0.1;
    return voice;
  }
  async render(score: ScoreResult, path: string, progress: (value: number) => void): Promise<void> {
    if (!Number.isFinite(score.duration) || score.duration <= 0 || score.duration > 1800000) {
      throw new Error('试听曲谱时长需在 0 到 30 分钟之间');
    }
    const frames = Math.ceil((score.duration + 100) * RATE / 1000);
    const header = new ArrayBuffer(44);
    const view = new DataView(header);
    view.setUint32(0, 0x52494646); view.setUint32(4, frames * 2 + 36, true);
    view.setUint32(8, 0x57415645); view.setUint32(12, 0x666d7420);
    view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
    view.setUint32(24, RATE, true); view.setUint32(28, RATE * 2, true);
    view.setUint16(32, 2, true); view.setUint16(34, 16, true);
    view.setUint32(36, 0x64617461); view.setUint32(40, frames * 2, true);
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, header);
      const mix = new Float32Array(BLOCK);
      const pcm = new Int16Array(BLOCK);
      let voices: RenderVoice[] = [];
      let next = 0;
      let reported = 0;
      for (let offset = 0; offset < frames; offset += BLOCK) {
        const count = Math.min(BLOCK, frames - offset);
        mix.fill(0);
        while (next < score.events.length && score.events[next].start * RATE / 1000 < offset + count) {
          voices.push(this.voice(score.events[next++]));
        }
        for (const voice of voices) {
          const begin = Math.max(offset, voice.start);
          const end = Math.min(offset + count, voice.end + RELEASE, voice.start + RATE * 8);
          for (let frame = begin; frame < end; frame++) {
            const attack = Math.min(1, (frame - voice.start) / 90);
            const release = frame < voice.end ? 1 : Math.max(0, 1 - (frame - voice.end) / RELEASE);
            mix[frame - offset] += this.table[Math.floor(voice.phase)] * voice.envelope * attack * release * voice.gain;
            voice.phase += voice.increment;
            if (voice.phase >= TABLE_SIZE) { voice.phase -= TABLE_SIZE; }
            voice.envelope *= DECAY;
          }
        }
        voices = voices.filter((voice: RenderVoice) => voice.end + RELEASE > offset + count && voice.start + RATE * 8 > offset + count);
        for (let i = 0; i < count; i++) { pcm[i] = Math.round(Math.tanh(mix[i]) * 30000); }
        const buffer = count === BLOCK ? pcm.buffer : pcm.buffer.slice(0, count * 2);
        if (fs.writeSync(file.fd, buffer) !== count * 2) { throw new Error('试听缓存写入不完整'); }
        if (Date.now() - reported >= 200) {
          reported = Date.now(); progress(Math.round((offset + count) / frames * 100));
          await new Promise<void>((resolve) => { setTimeout(resolve, 0); });
        }
      }
      progress(100);
    } finally { fs.closeSync(file); }
  }
}
