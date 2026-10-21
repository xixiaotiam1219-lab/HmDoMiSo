import { floatingBall } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** One system floating ball; its entire surface is the play/pause control. */
export class PlaybackBall {
  onToggle: () => void = () => {};
  onVisibility: (shown: boolean) => void = () => {};
  onError: (message: string) => void = () => {};
  private controller: floatingBall.FloatingBallController | undefined = undefined;
  private visible: boolean = false;
  private active: boolean = false;
  private paused: boolean = false;
  private preparing: boolean = false;
  private title: string = 'HmDoMiSo';
  private queue: Promise<void> = Promise.resolve();
  private published: string = '';
  private params(): floatingBall.FloatingBallParams {
    return {template: floatingBall.FloatingBallTemplate.NORMAL,
      title: this.preparing ? '准备中' : this.active && !this.paused ? '暂停' : '播放',
      content: this.title.slice(0, 18), backgroundColor: '#167E6C'};
  }
  private signature(): string { return this.title + '/' + this.active + '/' + this.paused + '/' + this.preparing; }
  setPlayback(active: boolean, paused: boolean, preparing: boolean, title: string): void {
    this.active = active; this.paused = paused; this.preparing = preparing; this.title = title || 'HmDoMiSo';
    if (!this.visible || this.published === this.signature()) { return; }
    this.queue = this.queue.then(async () => {
      if (!this.visible || !this.controller || this.published === this.signature()) { return; }
      await this.controller.updateFloatingBall(this.params()); this.published = this.signature();
    }).catch((e: Error) => { this.onError('悬浮球更新失败：' + e.message); });
  }
  async show(context: common.UIAbilityContext): Promise<void> {
    await this.queue;
    if (this.visible) { return; }
    if (!canIUse('SystemCapability.Window.SessionManager') || !floatingBall.isFloatingBallEnabled()) {
      throw new Error('当前设备暂不支持系统悬浮球');
    }
    if (!this.controller) {
      this.controller = await floatingBall.create({context: context});
      this.controller.on('click', () => {
        hilog.info(0xD001, 'DoMiSoBall', 'toggle active=%{public}s paused=%{public}s', String(this.active), String(this.paused));
        if (!this.preparing) { this.onToggle(); }
      });
      this.controller.on('stateChange', (state: floatingBall.FloatingBallState) => {
        this.visible = state === floatingBall.FloatingBallState.STARTED;
        this.onVisibility(this.visible);
        hilog.info(0xD001, 'DoMiSoBall', 'state %{public}d', state);
      });
    }
    await this.controller.startFloatingBall(this.params());
    this.visible = true; this.published = this.signature(); this.onVisibility(true);
    await this.controller.setFloatingBallVisibilityInApp(true);
  }
  async hide(): Promise<void> {
    await this.queue;
    if (this.controller && this.visible) { await this.controller.stopFloatingBall(); }
    this.visible = false; this.published = ''; this.onVisibility(false);
  }
  async destroy(): Promise<void> {
    await this.hide().catch(() => {});
    this.controller?.off('click'); this.controller?.off('stateChange'); this.controller = undefined;
  }
}
