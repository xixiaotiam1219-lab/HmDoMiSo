/** DoMiSo text parser. Timing matches the reference AHK 0.01 ms beat rounding. */
export class NoteEvent {
  pitch: number = 60;
  start: number = 0;
  end: number = 0;
  voice: number = 0;
  line: number = 0;
}
export class TouchGroup {
  time: number = 0;
  pitches: number[] = [];
}
export class ParsedNote {
  pitch: number = 0;
  beats: number = 1;
  arpeggio: boolean = false;
}
export class ScoreResult {
  events: NoteEvent[] = [];
  groups: TouchGroup[] = [];
  errors: string[] = [];
  warnings: string[] = [];
  duration: number = 0;
  voices: number = 1;
  bpms: number[] = [];
  low: number = 128;
  high: number = 0;
  unsupportedPitches: number[] = [];
}
const STEPS: number[] = [0, 2, 4, 5, 7, 9, 11];
export function keyIndex(pitch: number): number {
  for (let row = 0; row < 3; row++) {
    for (let col = 0; col < 7; col++) {
      if (72 - row * 12 + STEPS[col] === pitch) { return row * 7 + col; }
    }
  }
  return -1;
}
export function keyPitch(index: number): number { return 72 - Math.floor(index / 7) * 12 + STEPS[index % 7]; }
export function keyName(index: number): string {
  return ['高', '中', '低'][Math.floor(index / 7)] + ['do', 're', 'mi', 'fa', 'sol', 'la', 'ti'][index % 7];
}
export function noteLength(suffix: string, base: number = 1): number {
  let value = base;
  let last = 1;
  const parts = suffix.match(/\/+|-+|\.+/g) || [];
  for (const part of parts) {
    if (part[0] === '/') { const next = last / Math.pow(2, part.length); value += next - last; last = next; }
    else if (part[0] === '-') { value += part.length; last = 1; }
    else { value += last * (1 - 1 / Math.pow(2, part.length)); }
  }
  return value;
}
/** Transpose written scale degrees to C, preserving octave numbers and source comments. */
export function scoreToCKey(text: string): string {
  const lines = text.split(/\r?\n/);
  let body = 0;
  for (let i = 0; i < lines.length; i++) { if (lines[i].indexOf('======') >= 0) { body = i + 1; break; } }
  for (let i = body; i < lines.length; i++) {
    lines[i] = lines[i].replace(/(^|\s)1=[A-G](\d{1,2})?#?(?=\s|$)/g,
      (match: string, prefix: string, octave: string) => prefix + '1=C' + (octave || ''));
  }
  return lines.join('\n');
}
export class ScoreParser {
  private result: ScoreResult = new ScoreResult();
  private cursor: number = 0;
  private beatMs: number = 750;
  private bpm: number = 80;
  private base: number = 60;
  private voice: number = 0;
  private line: number = 0;
  private previousStart: number = -1;
  private arpeggioDelay: number = 0;
  private emit(notes: ParsedNote[], beats: number, arpeggio: boolean = false): void {
    if (arpeggio && this.previousStart < 0) { this.error('琶音前需要有起始音符或组'); return; }
    // The reference offsets each ~ onset by 40 ms, shortening its own written duration.
    const delay = arpeggio ? this.arpeggioDelay + 40 : 0;
    const start = arpeggio ? this.previousStart + 40 : this.cursor;
    const ms = beats * this.beatMs - delay;
    if (!Number.isFinite(ms) || ms < 1) {
      this.error(arpeggio ? '琶音时值不足以容纳累计40毫秒起音间隔' : '时值必须至少为1毫秒'); return;
    }
    if (this.result.events.length + notes.length > 100000) { throw new Error('曲谱超过十万音符上限'); }
    for (const note of notes) {
      if (note.pitch === 0) { continue; }
      const event = new NoteEvent();
      event.pitch = note.pitch; event.start = start; event.end = start + ms;
      event.voice = this.voice; event.line = this.line;
      this.result.events.push(event);
      this.result.low = Math.min(this.result.low, event.pitch); this.result.high = Math.max(this.result.high, event.pitch);
      if (keyIndex(event.pitch) < 0 && this.result.unsupportedPitches.indexOf(event.pitch) < 0) {
        this.result.unsupportedPitches.push(event.pitch);
      }
    }
    // A completed chord is a fresh anchor; a tuplet anchors at its final member.
    this.previousStart = start; this.arpeggioDelay = delay;
    this.cursor = start + ms; this.result.duration = Math.max(this.result.duration, this.cursor);
    if (this.result.bpms.indexOf(this.bpm) < 0) { this.result.bpms.push(this.bpm); }
  }
  private error(message: string): void { if (this.result.errors.length < 100) { this.result.errors.push(`第${this.line}行：${message}`); } }
  private note(token: string): ParsedNote | undefined {
    const m = /^(~?)(-*|\+*)([0-7])([#bB]?)([\/.-]*)$/.exec(token);
    if (!m) { return undefined; }
    const n = new ParsedNote(); n.beats = noteLength(m[5]); n.arpeggio = m[1] === '~';
    if (m[3] === '0') { if (m[2] || m[4]) { this.error('休止不能带八度或半音'); } return n; }
    n.pitch = this.base + STEPS[Number(m[3]) - 1] + (m[2][0] === '+' ? 12 : -12) * m[2].length;
    n.pitch += m[4] === '#' ? 1 : m[4] ? -1 : 0;
    return n;
  }
  parse(text: string): ScoreResult {
    this.result = new ScoreResult(); this.cursor = 0; this.beatMs = 750; this.bpm = 80; this.base = 60; this.voice = 0;
    this.previousStart = -1; this.arpeggioDelay = 0; this.line = 0;
    if (text.length > 2000000) { this.result.errors.push('曲谱超过2MB上限'); return this.result; }
    const lines = text.replace(/^\uFEFF/, '').split(/\r?\n/);
    let split = -1;
    for (let i = 0; i < lines.length; i++) { if (lines[i].indexOf('======') >= 0) { split = i; break; } }
    const labels = ['右手', '左手', '旋律', '伴奏', '主旋律', '低音', '重复', 'melody', 'bass', 'right', 'left', 'repeat'];
    let lyricLines = 0;
    for (let i = split + 1; i < lines.length; i++) {
      this.line = i + 1;
      const trimmed = lines[i].trim();
      if (/^[-_=]{3,}$/.test(trimmed)) { continue; }
      // Only whole Chinese text lines are lyrics; mixed or malformed music still reports errors.
      if (trimmed && /^[\u3400-\u9FFF\s\u3000-\u303F\uFF00-\uFF65，。！？、：；“”‘’…·—,.!?;:()]+$/.test(trimmed)) {
        if (labels.indexOf(trimmed.toLowerCase()) < 0) { lyricLines++; }
        continue;
      }
      // Keep closing-bracket length suffixes intact while accepting compact formatting.
      const rawTokens = lines[i].replace(/_/g, ' ').replace(/([({|])/g, ' $1 ')
        .replace(/([)}][\/.-]*)/g, ' $1 ').trim().split(/\s+/).filter((t: string) => t.length > 0)
        .map((t: string) => /^bpm\d+$/i.test(t) ? t.replace(/^bpm/i, 'bpm=') : t);
      const tokens: string[] = [];
      for (const token of rawTokens) {
        if (/^[\/.-]+$/.test(token) && tokens.length > 0 &&
          /^(~?(-*|\+*)[0-7][#bB]?[\/.-]*|[)}][\/.-]*)$/.test(tokens[tokens.length - 1])) {
          tokens[tokens.length - 1] += token;
        } else { tokens.push(token); }
      }
      for (const prefix of ['bpm=', '1=', 'rollback=']) {
        const commands = tokens.filter((t: string) => t.toLowerCase().startsWith(prefix));
        if (commands.length > 1) { this.error(`一行只能有一个${prefix}命令`); }
        if (!commands.length) { continue; }
        const value = commands[0].split('=')[1];
        if (prefix === 'bpm=') {
          if (!/^\d+$/.test(value) || Number(value) < 31 || Number(value) > 599) { this.error('BPM应为31至599整数'); }
          else { this.bpm = Number(value); this.beatMs = Math.round(6000000 / this.bpm) / 100; }
        } else if (prefix === '1=') {
          const k = /^([A-G])(\d{1,2})?(#)?$/.exec(value);
          if (!k) { this.error('调号格式应为1=C或1=F5#'); }
          else { this.base = Number(k[2] || '5') * 12 + STEPS['CDEFGAB'.indexOf(k[1])] + (k[3] ? 1 : 0); }
        } else {
          if (!/^\d+(\.\d*)?$/.test(value)) { this.error('rollback应为非负拍数'); }
          else {
            this.cursor = Math.max(0, this.cursor - Number(value) * this.beatMs); this.voice++;
            this.previousStart = -1; this.arpeggioDelay = 0;
          }
        }
      }
      let group = ''; let members: ParsedNote[] = [];
      for (const token of tokens) {
        if (/^(bpm|1|rollback)=/i.test(token) || labels.indexOf(token.toLowerCase()) >= 0) { continue; }
        if (token === '|') { if (group) { this.error('组内不能有小节线'); } continue; }
        if (token === '(' || token === '{') {
          if (group) { this.error('不支持嵌套组'); } else { group = token; members = []; } continue;
        }
        const close = /^([)}])([\/.-]*)$/.exec(token);
        if (close) {
          if (group !== (close[1] === ')' ? '(' : '{') || !members.length) { this.error('括号不匹配或空组'); continue; }
          if (group === '(') {
            if (members.some((n: ParsedNote) => n.pitch === 0)) { this.error('和弦内不能使用休止'); }
            this.emit(members, noteLength(close[2], Math.max(...members.map((n: ParsedNote) => n.beats))));
          } else {
            const total = members.reduce((sum: number, n: ParsedNote) => sum + n.beats, 0);
            for (const n of members) { this.emit([n], noteLength(close[2]) * n.beats / total); }
          }
          group = ''; members = []; continue;
        }
        const note = this.note(token);
        if (!note) { this.error(`无法识别 ${token}；请检查音符或指令写法`); }
        else if (group) { members.push(note); } else { this.emit([note], note.beats, note.arpeggio); }
      }
      if (group) { this.error('组必须在同一行闭合'); }
    }
    this.result.voices = this.voice + 1;
    if (this.result.unsupportedPitches.length && this.result.errors.length < 100) {
      this.result.errors.push(`当前调号有${this.result.unsupportedPitches.length}种音高不在21键自然音范围内，请转为C调或调整音域`);
    }
    if (lyricLines) { this.result.warnings.push(`已忽略${lyricLines}行歌词或文字说明`); }
    if (!this.result.events.length) { this.error('未找到发声音符'); }
    this.result.events.sort((a: NoteEvent, b: NoteEvent) => a.start - b.start || a.pitch - b.pitch);
    const active = new Map<number, number>(); let overlaps = 0;
    for (const e of this.result.events) {
      if ((active.get(e.pitch) || -1) > e.start + 0.001) { overlaps++; }
      active.set(e.pitch, Math.max(active.get(e.pitch) || 0, e.end));
      let last = this.result.groups[this.result.groups.length - 1];
      if (!last || Math.abs(last.time - e.start) > 0.001) { last = new TouchGroup(); last.time = e.start; this.result.groups.push(last); }
      if (last.pitches.indexOf(e.pitch) < 0) { last.pitches.push(e.pitch); }
    }
    if (overlaps) { this.result.warnings.push(`${overlaps}个同音重叠，游戏按起音重触发`); }
    if (this.result.groups.some((g: TouchGroup) => g.pitches.length > 10)) { this.error('同时起音超过10指'); }
    return this.result;
  }
}
