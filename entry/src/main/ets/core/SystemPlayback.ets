import { common, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { avSession } from '@kit.AVSessionKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'DoMiSoSystem';
const BUNDLE: string = 'cn.xxtstudio.GenshinDoMiSo';
const CONTROL_NOTIFICATION: number = 701;

/** System controls represent the real lyre performance; no silent audio is played. */
export class SystemPlayback {
  private static instance: SystemPlayback = new SystemPlayback();
  static getInstance(): SystemPlayback { return SystemPlayback.instance; }
  onPlay: () => void = () => {};
  onPause: () => void = () => {};
  onStop: () => void = () => {};
  onProtectionLost: (reason: string) => void = () => {};
  onStatus: (status: string) => void = () => {};
  backgroundEnabled: boolean = true;
  controlsEnabled: boolean = true;
  isProtected: boolean = false;
  private context: common.UIAbilityContext | undefined = undefined;
  private session: avSession.AVSession | undefined = undefined;
  private taskId: number = -1;
  private taskNotificationId: number = -1;
  private taskMode: string = '';
  private connectionRetained: boolean = false;
  private performanceActive: boolean = false;
  private audioPreview: boolean = false;
  private taskQueue: Promise<void> = Promise.resolve();
  private stopping: boolean = false;
  private title: string = '';
  private duration: number = 0;
  private elapsed: number = 0;
  private paused: boolean = false;
  private lastPublished: number = 0;
  private launch: WantAgent | undefined = undefined;
  private pauseAgent: WantAgent | undefined = undefined;
  private resumeAgent: WantAgent | undefined = undefined;
  private stopAgent: WantAgent | undefined = undefined;
  private notificationsAllowed: boolean = false;
  private stateQueue: Promise<void> = Promise.resolve();
  private initialized: boolean = false;
  private generation: number = 0;

  initialize(context: common.UIAbilityContext): void {
    this.context=context;
    if (this.initialized) { return; }
    this.initialized=true;
    backgroundTaskManager.on('continuousTaskCancel',(info) => {
      if (this.stopping || !this.isProtected || (this.taskId>=0 && info.id!==this.taskId)) { return; }
      this.isProtected=false; this.taskId=-1; this.taskNotificationId=-1; this.connectionRetained=false;
      this.onProtectionLost('后台任务已被系统或用户结束');
      hilog.warn(0xD001,TAG,'continuous task cancelled %{public}d',info.reason);
    });
    backgroundTaskManager.on('continuousTaskSuspend',(info) => {
      if (this.stopping || this.taskId<0 || info.continuousTaskId!==this.taskId) { return; }
      this.isProtected=!info.suspendState;
      if (info.suspendState) { this.onProtectionLost('后台保护已暂停，请返回应用继续'); }
    });
  }
  dispatch(want: Want): void {
    const action=want.parameters?.domisoAction;
    if (action==='pause') { this.onPause(); }
    else if (action==='resume') { this.onPlay(); }
    else if (action==='stop') { this.onStop(); }
  }
  private async makeAgent(action: string,requestCode: number): Promise<WantAgent> {
    return wantAgent.getWantAgent({wants:[{bundleName:BUNDLE,abilityName:'EntryAbility',parameters:{domisoAction:action}}],
      actionType:wantAgent.OperationType.START_ABILITY,requestCode:requestCode});
  }
  private async authorizeNotifications(): Promise<void> {
    if (!this.context) { throw new Error('应用上下文未就绪'); }
    if (!await notificationManager.isNotificationEnabled()) { await notificationManager.requestEnableNotification(this.context); }
    this.notificationsAllowed=await notificationManager.isNotificationEnabled();
  }
  /** Align with the transfer controller: keep the actual HDC connection alive while enabled. */
  async retainConnection(): Promise<void> {
    this.connectionRetained=this.backgroundEnabled;
    if (!this.connectionRetained || !this.context) { return; }
    await this.authorizeNotifications();
    if (!this.notificationsAllowed) { this.connectionRetained=false; throw new Error('请允许通知，以启用后台演奏'); }
    if (!this.launch) { this.launch=await this.makeAgent('',700); }
    if (!this.pauseAgent) { this.pauseAgent=await this.makeAgent('pause',701); this.resumeAgent=await this.makeAgent('resume',702); this.stopAgent=await this.makeAgent('stop',703); }
    if (!this.performanceActive) {
      this.title='HmDoMiSo'; this.duration=0; this.elapsed=0;
      await this.requestTask('dataTransfer'); await this.publishNotification(true);
    }
  }
  async releaseConnection(): Promise<void> {
    this.connectionRetained=false;
    if (!this.performanceActive) { await this.finish(); }
  }
  private requestTask(mode: string): Promise<void> {
    const operation=this.taskQueue.then(async () => {
      if (!this.context || !this.launch) { throw new Error('后台任务上下文未就绪'); }
      if (this.isProtected && this.taskMode===mode) { return; }
      const task=this.taskId>=0?await backgroundTaskManager.updateBackgroundRunning(this.context,[mode]):
        await backgroundTaskManager.startBackgroundRunning(this.context,[mode],this.launch);
      this.taskId=task.continuousTaskId ?? -1; this.taskNotificationId=task.notificationId; this.taskMode=mode; this.isProtected=true;
      this.onStatus('后台保护已开启');
      hilog.info(0xD001,TAG,'task mode=%{public}s id=%{public}d notification=%{public}d',mode,this.taskId,this.taskNotificationId);
    });
    this.taskQueue=operation.catch(() => {}); return operation;
  }
  async begin(title: string,duration: number,audioPreview: boolean = false): Promise<void> {
    if (!this.context) { throw new Error('应用上下文未就绪'); }
    const generation=++this.generation;
    this.performanceActive=true; this.audioPreview=audioPreview; this.title=title; this.duration=duration; this.elapsed=0; this.paused=false;
    await this.authorizeNotifications();
    if (generation!==this.generation) { throw new Error('演奏已取消'); }
    this.launch=await this.makeAgent('',700);
    this.pauseAgent=await this.makeAgent('pause',701); this.resumeAgent=await this.makeAgent('resume',702); this.stopAgent=await this.makeAgent('stop',703);
    if (this.backgroundEnabled) {
      if (!this.notificationsAllowed) { throw new Error('请允许通知，以启用后台演奏'); }
      await this.requestTask(audioPreview?'audioPlayback':'dataTransfer');
      this.onStatus('后台保护已开启');
    }
    if (generation!==this.generation) { await this.finish(); throw new Error('演奏已取消'); }
    if (this.controlsEnabled || audioPreview) { await this.ensureSession(); }
    await this.publishNotification(true);
  }
  async applySettings(background: boolean,controls: boolean,connected: boolean): Promise<void> {
    this.backgroundEnabled=background; this.controlsEnabled=controls; this.connectionRetained=background && connected;
    if (!this.performanceActive) {
      if (this.connectionRetained) { await this.retainConnection(); }
      else { await this.finish(); }
      return;
    }
    if (background) {
      await this.authorizeNotifications();
      if (!this.notificationsAllowed) { throw new Error('请允许通知，以启用后台演奏'); }
      await this.requestTask(this.audioPreview?'audioPlayback':'dataTransfer');
    } else {
      await this.taskQueue;
      this.stopping=true;
      try {
        if (this.context && this.taskId>=0) { await backgroundTaskManager.stopBackgroundRunning(this.context,this.taskId); }
        this.isProtected=false; this.taskId=-1; this.taskNotificationId=-1; this.taskMode='';
        this.onStatus('后台保护未启用');
      } finally { this.stopping=false; }
    }
    if (controls || this.audioPreview) { await this.ensureSession(); }
    else if (this.session) { await this.session.deactivate(); }
    await this.publishNotification(true);
  }
  private async ensureSession(): Promise<void> {
    if (!this.context || !this.launch) { return; }
    if (!this.session) {
      this.session=await avSession.createAVSession(this.context,'DoMiSoPerformance','audio');
      this.session.on('play',() => { hilog.info(0xD001,TAG,'system play'); this.onPlay(); });
      this.session.on('pause',() => { hilog.info(0xD001,TAG,'system pause'); this.onPause(); });
      this.session.on('stop',() => { hilog.info(0xD001,TAG,'system stop'); this.onStop(); });
      await this.session.setLaunchAbility(this.launch);
    }
    await this.session.setAVMetadata({assetId:'domiso-current',title:this.title,artist:'HmDoMiSo',duration:this.duration});
    await this.session.activate();
    hilog.info(0xD001,TAG,'media session active %{public}s',this.session.sessionId);
  }
  update(elapsed: number,paused: boolean,speed: number): void {
    this.elapsed=elapsed; this.paused=paused;
    const generation=this.generation;
    this.stateQueue=this.stateQueue.then(async () => {
      if (generation!==this.generation) { return; }
      if (this.session) {
        await this.session.setAVPlaybackState({state:paused?avSession.PlaybackState.PLAYBACK_STATE_PAUSE:avSession.PlaybackState.PLAYBACK_STATE_PLAY,
          position:{elapsedTime:Math.max(0,elapsed),updateTime:Date.now()},speed:speed});
      }
      await this.publishNotification();
    }).catch((e: Error) => { hilog.warn(0xD001,TAG,'system state %{public}s',e.message); });
  }
  private async publishNotification(force: boolean = false): Promise<void> {
    if (!this.notificationsAllowed || !this.launch || !this.pauseAgent || !this.resumeAgent || !this.stopAgent) { return; }
    if (!force && Date.now()-this.lastPublished<2000) { return; }
    this.lastPublished=Date.now();
    if (this.taskNotificationId>=0 && this.taskMode==='dataTransfer') {
      const text=this.performanceActive?(this.paused?'演奏已暂停':`${Math.floor(this.elapsed/1000)} / ${Math.ceil(this.duration/1000)} 秒`):'演奏服务已连接';
      const progress=this.duration>0?Math.min(100,Math.floor(this.elapsed/this.duration*100)):0;
      try {
        await notificationManager.publish({id:this.taskNotificationId,updateOnly:true,isAlertOnce:true,wantAgent:this.launch,
          notificationSlotType:notificationManager.SlotType.LIVE_VIEW,
          content:{notificationContentType:notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
            systemLiveView:{typeCode:8,title:this.title,text:text,progress:{maxValue:100,currentValue:progress,isPercentage:false}}},
          template:{name:'downloadTemplate',data:{title:this.title,fileName:text,progressValue:progress}},
          actionButtons:[{title:this.paused?'继续':'暂停',wantAgent:this.paused?this.resumeAgent:this.pauseAgent},{title:'停止',wantAgent:this.stopAgent}]});
        await notificationManager.cancel(CONTROL_NOTIFICATION).catch(() => {});
        hilog.info(0xD001,TAG,'system live view id=%{public}d progress=%{public}d',this.taskNotificationId,progress);
        return;
      } catch (e) { hilog.warn(0xD001,TAG,'live view fallback %{public}s',(e as Error).message); }
    }
    if (!this.performanceActive) { return; }
    await notificationManager.publish({id:CONTROL_NOTIFICATION,isOngoing:true,isAlertOnce:true,tapDismissed:false,
      notificationSlotType:notificationManager.SlotType.SOCIAL_COMMUNICATION,wantAgent:this.launch,
      content:{notificationContentType:notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal:{title:this.title,text:this.paused?'演奏已暂停':`演奏中 · ${Math.floor(this.elapsed/1000)} / ${Math.ceil(this.duration/1000)} 秒`}},
      actionButtons:[{title:this.paused?'继续':'暂停',wantAgent:this.paused?this.resumeAgent:this.pauseAgent},{title:'停止',wantAgent:this.stopAgent}]});
  }
  async finish(): Promise<void> {
    this.generation++; this.performanceActive=false; this.stopping=true;
    try {
      await this.stateQueue;
      if (this.session) { await this.session.setAVPlaybackState({state:avSession.PlaybackState.PLAYBACK_STATE_STOP}); await this.session.deactivate(); }
      if (this.connectionRetained && this.backgroundEnabled) {
        this.title='HmDoMiSo'; this.duration=0; this.elapsed=0; this.paused=false;
        await this.requestTask('dataTransfer'); await this.publishNotification(true);
      } else {
        await this.taskQueue;
        if (this.context && this.taskId>=0) { await backgroundTaskManager.stopBackgroundRunning(this.context,this.taskId); }
        else if (this.context && this.isProtected) { await backgroundTaskManager.stopBackgroundRunning(this.context); }
        this.isProtected=false; this.taskId=-1; this.taskNotificationId=-1; this.taskMode='';
        this.onStatus('后台保护未启用');
      }
    } catch (e) { hilog.warn(0xD001,TAG,'finish %{public}s',(e as Error).message); }
    finally { this.stopping=false; await notificationManager.cancel(CONTROL_NOTIFICATION).catch(() => {}); }
  }
  async destroy(): Promise<void> {
    this.connectionRetained=false; await this.finish();
    if (this.session) { await this.session.destroy(); this.session=undefined; }
    if (this.initialized) { backgroundTaskManager.off('continuousTaskCancel'); backgroundTaskManager.off('continuousTaskSuspend'); this.initialized=false; }
  }
}


