import { worker } from '@kit.ArkTS';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ScoreResult } from './Score';

interface RenderMessage { type: string; progress?: number; text?: string; }
class PreviewSession {
  cancelled: boolean = false;
  path: string = '';
  thread: worker.ThreadWorker | undefined = undefined;
  player: media.AVPlayer | undefined = undefined;
  file: fs.File | undefined = undefined;
  cleanup: Promise<void> | undefined = undefined;
  renderDone: () => void = () => {};
  playDone: () => void = () => {};
  seekDone: () => void = () => {};
}

/** Worker prepares a temporary WAV; native AVPlayer owns decoding, mixing and timing. */
export class PreviewController {
  cacheDir: string = '';
  elapsedMs: number = 0;
  durationMs: number = 0;
  onChange: (text: string) => void = () => {};
  private session: PreviewSession | undefined = undefined;
  private active: boolean = false;
  private paused: boolean = false;
  private speed: number = 1;
  private controlQueue: Promise<void> = Promise.resolve();
  isActive(): boolean { return this.active; }
  isPaused(): boolean { return this.paused; }
  canSeek(): boolean {
    const state = this.session?.player?.state;
    return state === 'prepared' || state === 'playing' || state === 'paused';
  }
  async seek(value: number): Promise<void> {
    await this.controlQueue;
    const session = this.session;
    const player = session?.player;
    if (!session || !player || !this.canSeek() || !Number.isFinite(value)) { return; }
    const target = Math.max(0, Math.min(value, this.durationMs));
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => { player.off('seekDone'); reject(new Error('进度调整超时')); }, 3000);
      session.seekDone = () => { clearTimeout(timer); player.off('seekDone'); resolve(); };
      player.on('seekDone', () => { this.elapsedMs = Math.min(player.currentTime, this.durationMs); session.seekDone(); });
      try { player.seek(target, media.SeekMode.SEEK_CLOSEST); }
      catch (e) { clearTimeout(timer); player.off('seekDone'); reject(e as Error); }
    });
  }
  setSpeed(value: number): void {
    if (!Number.isFinite(value) || value < 0.5 || value > 1.5) { return; }
    this.speed = value;
    const player = this.session?.player;
    if (player && (player.state === 'playing' || player.state === 'paused' || player.state === 'prepared')) {
      try { player.setPlaybackRate(value); } catch (e) { this.onChange('速度调节失败：' + (e as Error).message); }
    }
  }
  async setPaused(value: boolean): Promise<void> {
    if (!this.active) { return; }
    this.paused = value;
    const session = this.session;
    const operation = this.controlQueue.then(async () => {
      if (!session || session.cancelled) { return; }
      const player = session.player;
      if (player?.state === 'playing' && value) { await player.pause(); }
      else if ((player?.state === 'paused' || player?.state === 'prepared') && !value) { await player.play(); }
      if (!session.cancelled) { this.onChange(value ? '已暂停' : '试听中'); }
    });
    this.controlQueue = operation.catch(() => {});
    await operation;
  }
  private async render(session: PreviewSession, score: ScoreResult): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      session.renderDone = resolve;
      const thread = new worker.ThreadWorker('entry/ets/workers/PreviewWorker.ets', {name: 'HmDoMiSoRender'});
      session.thread = thread;
      thread.onmessage = (event) => {
        if (session.cancelled) { return; }
        const message = event.data as RenderMessage;
        if (message.type === 'progress') { this.onChange('准备琴音 ' + (message.progress ?? 0) + '%'); }
        else if (message.type === 'ready') { resolve(); }
        else if (message.type === 'error') { reject(new Error(message.text || '琴音生成失败')); }
      };
      thread.onerror = (error) => { reject(new Error('琴音生成异常：' + error.message)); };
      thread.postMessage({type: 'render', score: JSON.stringify(score), path: session.path});
    });
    session.thread?.terminate(); session.thread = undefined;
  }
  async play(score: ScoreResult): Promise<void> {
    await this.stop();
    if (!this.cacheDir) { throw new Error('试听缓存目录未就绪'); }
    const session = new PreviewSession();
    session.path = this.cacheDir + '/preview_' + Date.now() + '.wav';
    this.session = session; this.active = true; this.paused = false;
    this.elapsedMs = 0; this.durationMs = score.duration;
    try {
      this.onChange('准备琴音');
      const started = Date.now();
      await this.render(session, score);
      if (session.cancelled) { return; }
      hilog.info(0xD001, 'DoMiSoPreview', 'rendered %{public}d notes, %{public}d ms audio in %{public}d ms', score.events.length, score.duration, Date.now() - started);
      session.file = fs.openSync(session.path, fs.OpenMode.READ_ONLY);
      const player = await media.createAVPlayer();
      if (session.cancelled) { await player.release(); return; }
      session.player = player;
      let completed = false;
      await new Promise<void>((resolve, reject) => {
        session.playDone = resolve;
        player.on('stateChange', (state: media.AVPlayerState) => {
          if (session.cancelled) { return; }
          if (state === 'initialized') {
            player.audioRendererInfo = {content: audio.ContentType.CONTENT_TYPE_MUSIC, usage: audio.StreamUsage.STREAM_USAGE_MUSIC, rendererFlags: 0};
            player.prepare().catch(reject);
          } else if (state === 'prepared') {
            player.setPlaybackRate(this.speed);
            if (!this.paused) { player.play().catch(reject); }
            else { this.onChange('已暂停'); }
          } else if (state === 'playing' || state === 'paused') {
            this.paused = state === 'paused'; this.onChange(this.paused ? '已暂停' : '试听中');
            hilog.info(0xD001, 'DoMiSoPreview', 'native state %{public}s', state);
          } else if (state === 'completed') { completed = true; resolve(); }
        });
        player.on('timeUpdate', (time: number) => {
          if (session.cancelled) { return; }
          this.elapsedMs = Math.min(time, this.durationMs); this.onChange(this.paused ? '已暂停' : '试听中');
        });
        player.on('error', (error) => { reject(new Error('系统试听失败：' + error.message)); });
        player.on('audioInterrupt', (event: audio.InterruptEvent) => {
          if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE) { this.setPaused(true).catch(reject); }
          else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) { this.stop().catch(reject); }
        });
        player.fdSrc = {fd: session.file!.fd, offset: 0, length: fs.statSync(session.file!.fd).size};
      });
      if (completed && !session.cancelled) { this.elapsedMs = this.durationMs; this.onChange('试听完成'); }
    } catch (e) { if (!session.cancelled) { throw e as Error; } }
    finally {
      await this.release(session);
      if (this.session === session) { this.session = undefined; this.active = false; this.paused = false; }
    }
  }
  private release(session: PreviewSession): Promise<void> {
    if (!session.cleanup) {
      session.cleanup = (async () => {
        session.thread?.terminate(); session.thread = undefined;
        if (session.player) { await session.player.release().catch(() => {}); session.player = undefined; }
        if (session.file) { fs.closeSync(session.file); session.file = undefined; }
        if (fs.accessSync(session.path)) { fs.unlinkSync(session.path); }
      })();
    }
    return session.cleanup;
  }
  async stop(): Promise<void> {
    const session = this.session;
    if (!session) { return; }
    this.session = undefined; this.active = false; this.paused = false;
    session.cancelled = true; session.renderDone(); session.playDone(); session.seekDone();
    await this.release(session); this.onChange('已停止');
  }
}
