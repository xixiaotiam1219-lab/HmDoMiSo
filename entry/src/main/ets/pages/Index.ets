import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { display } from '@kit.ArkUI';
import { HdsTabs, HdsTabsController, HdsBarStyle, DividerMode, hdsMaterial } from '@kit.UIDesignKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HdcClient } from '../core/HdcClient';
import { TouchBackend } from '../core/TouchBackend';
import { Playback } from '../core/Playback';
import { SystemPlayback } from '../core/SystemPlayback';
import { PreviewController } from '../core/PreviewController';
import { ImportedScore, readScoreFile } from '../core/TextScoreImport';
import { PlaybackBall } from '../core/PlaybackBall';
import { StartDelayDialog } from '../components/StartDelayDialog';
import { SpeedDialog } from '../components/SpeedDialog';
import { LicenseDialog } from '../components/LicenseDialog';
import { ScoreParser, ScoreResult, keyName } from '../core/Score';
import { CalibrationProfile, PixelPoint, ImageFit, resetCalibration, recalculate, validateCalibration } from '../core/Calibration';

class LibraryEntry { id: string = ''; title: string = ''; text: string = ''; }
@Entry
@Component
struct Index {
  @State tab: number = 1;
  @StorageLink('safeTop') safeTop: number = 0;
  @StorageLink('safeBottom') safeBottom: number = 0;
  @StorageLink('externalScoreRequest') @Watch('receiveExternalScore') externalScoreRequest: string = '';
  @State ballShown: boolean = false;
  @State ballEnabled: boolean = false;
  private ballRestoreTimer: number = -1;
  private disposing: boolean = false;
  @State ballBusy: boolean = false;
  private ball: PlaybackBall = new PlaybackBall();
  @State editing: boolean = false;
  @State miniExpanded: boolean = true;
  @State previewMode: boolean = false;
  @State paused: boolean = false;
  @State preparing: boolean = false;
  @State elapsed: number = 0;
  @State duration: number = 0;
  @State noteCount: number = 0;
  @State tempo: string = '88';
  @State checked: boolean = false;
  @State backgroundEnabled: boolean = true;
  @State mediaEnabled: boolean = true;
  @State backgroundStatus: string = '按需开启';
  @State connectionReady: boolean = false;
  @State backendReady: boolean = false;
  @State calibrated: boolean = false;
  @State playbackState: string = '未播放';
  @State backendState: string = '触摸后端未连接';
  @State speed: number = 1;
  @State startDelay: number = 5;
  @State playing: boolean = false;
  @State showPlayer: boolean = false;
  @State seeking: boolean = false;
  @State seekValue: number = 0;
  @State seekReady: boolean = false;
  private resumeAfterSeek: boolean = false;
  @State host: string = '127.0.0.1';
  @State port: string = '';
  @State connection: string = '未连接';
  @State busy: boolean = false;
  @State title: string = '未命名曲谱';
  @State activeTitle: string = '';
  @State playbackDuration: number = 0;
  private activePreview: boolean = false;
  private stopQueue: Promise<void> = Promise.resolve();
  @State scoreText: string = '';
  @State report: string = '输入曲谱后点击转换与检查';
  @State library: LibraryEntry[] = [];
  @State @Watch('showNotice') notice: string = '';
  @State zoom: number = 1;
  @State selected: number = 0;
  @State rowAdjust: boolean = false;
  @State fullScreenshot: boolean = false;
  @State imageLabel: string = '尚未导入完整横屏截图';
  @State canvasWidth: number = 320;
  @State canvasHeight: number = 230;
  private hdc: HdcClient = new HdcClient();
  private backend: TouchBackend = new TouchBackend();
  private player: Playback = new Playback();
  private preview: PreviewController = new PreviewController();
  private system: SystemPlayback = SystemPlayback.getInstance();
  private runVersion: number = 0;
  private tabsController: HdsTabsController = new HdsTabsController();
  private miniRestoreTimer: number = -1;
  private orientationTimer: number = -1;
  @State windowWidth: number = 360;
  private speedDialog: CustomDialogController = new CustomDialogController({
    builder: SpeedDialog({initial:this.speed,onApply:(value: number) => { this.speed=value; this.player.setSpeed(value); this.preview.setSpeed(value); this.system.update(this.elapsed,this.paused,value); this.notice='速度已设为 '+value.toFixed(2)+'×'; }}),
    alignment:DialogAlignment.Center,customStyle:true,autoCancel:true
  });
  private delayDialog: CustomDialogController = new CustomDialogController({
    builder:StartDelayDialog({initial:this.startDelay,onApply:(value: number) => {
      this.startDelay=value;
      try { this.persistSettings(); this.notice='起播延迟已设为 '+value+' 秒'; }
      catch (e) { this.notice='延迟设置保存失败'; }
    }}),alignment:DialogAlignment.Center,customStyle:true,autoCancel:true
  });
  @State licenseHeading: string = '开源许可';
  @State licenseContent: string = '';
  private licenseDialog: CustomDialogController = new CustomDialogController({builder:LicenseDialog({heading:this.licenseHeading,content:this.licenseContent}),customStyle:true,alignment:DialogAlignment.Center});
  private lastToast: string = '';
  private lastToastAt: number = 0;
  private parsed: ScoreResult = new ScoreResult();
  private calibration: CalibrationProfile = new CalibrationProfile();
  private screenshot: image.PixelMap | undefined = undefined;
  private canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private dragTarget: number = -2;
  private dragStart: PixelPoint = new PixelPoint();
  private dragCorners: PixelPoint[] = [];
  private dragAdjustments: PixelPoint[] = [];
  private filesDir: string = '';
  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.filesDir=context.filesDir; this.preview.cacheDir=context.cacheDir;
    this.hdc.onStatus=(s: string) => { this.connection=s; this.connectionReady=this.hdc.ready; if (!this.hdc.ready) { this.system.releaseConnection().catch(() => {}); } };
    this.backend.onStatus=(s: string) => { this.backendState=s; this.backendReady=this.backend.ready; };
    this.system.initialize(context);
    this.ball.onToggle=() => { if (this.playing) { this.setPaused(!this.paused); } else { this.play(); } };
    this.ball.onVisibility=(shown: boolean) => {
      this.ballShown=shown;
      if (!shown && this.ballEnabled && !this.disposing && !this.ballBusy) {
        this.ballEnabled=false;
        try { this.persistSettings(); } catch (e) { this.notice='悬浮球设置保存失败'; }
      }
    };
    this.ball.onError=(message: string) => { this.notice=message; };
    this.player.onChange=(s: string) => { this.updatePlayback(s,false); };
    this.preview.onChange=(s: string) => { this.updatePlayback(s,true); };
    this.system.onPlay=() => { if (this.playing) { this.setPaused(false); } else { this.play(); } };
    this.system.onPause=() => { this.setPaused(true); };
    this.system.onStop=() => { this.stopPlayback(); };
    this.system.onProtectionLost=(reason: string) => { this.setPaused(true); this.notice=reason; this.backgroundStatus='已暂停'; };
    this.system.onStatus=(status: string) => { this.backgroundStatus=status; };
    this.player.beforeCountdown=() => this.openGame();
    this.load(); this.check(); this.restoreScreenshot(); this.receiveExternalScore(); this.scheduleBallRestore();
    display.on('change',() => {
      clearTimeout(this.orientationTimer);
      // Launching the game causes several normal rotation/display events. Only
      // protect a prepared performance, after the game has matched calibration.
      if (!this.playing || this.activePreview || !this.player.canSeek() || this.player.isPaused()) { return; }
      this.orientationTimer=setTimeout(() => {
        if (!this.playing || this.activePreview || !this.player.canSeek() || this.player.isPaused()) { return; }
        const screen=display.getDefaultDisplaySync();
        if (screen.width!==this.calibration.width || screen.height!==this.calibration.height) {
          this.setPaused(true,false); this.notice='屏幕方向已改变，演奏已暂停';
        }
      },400);
    });
  }
  onPageShow(): void { this.scheduleBallRestore(); }
  aboutToDisappear(): void { this.disposing=true; clearTimeout(this.ballRestoreTimer); this.ball.destroy(); this.stopPlayback(); this.backend.close().catch(() => {}); this.hdc.close().catch(() => {}); this.system.releaseConnection().catch(() => {}); display.off('change'); clearTimeout(this.orientationTimer); clearTimeout(this.miniRestoreTimer); this.speedDialog.close(); this.delayDialog.close(); this.licenseDialog.close(); this.screenshot?.release(); }
  private load(): void {
    try {
      const connectionPath=this.filesDir+'/connection.json';
      if (fs.accessSync(connectionPath)) { const saved=JSON.parse(fs.readTextSync(connectionPath)) as SavedConnection; this.host=saved.host; this.port=saved.port; }
      const settingsPath=this.filesDir+'/settings.json';
      if (fs.accessSync(settingsPath)) { const settings=JSON.parse(fs.readTextSync(settingsPath)) as PlaybackSettings; this.backgroundEnabled=settings.background; this.mediaEnabled=settings.media; this.ballEnabled=settings.floatingBall ?? false; const delay=settings.startDelay ?? 5; this.startDelay=Number.isFinite(delay)?Math.max(0,Math.min(30,Math.round(delay))):5; }
      const path=this.filesDir+'/library.json';
      if (fs.accessSync(path)) { this.library=JSON.parse(fs.readTextSync(path)) as LibraryEntry[]; if (this.library.length) { this.title=this.library[0].title; this.scoreText=this.library[0].text; } }
      const config=this.filesDir+'/calibration.json';
      if (fs.accessSync(config)) { this.calibration=JSON.parse(fs.readTextSync(config)) as CalibrationProfile; this.fullScreenshot=this.calibration.fullScreenshotConfirmed; this.calibrated=true; this.imageLabel=`已保存 ${this.calibration.width}×${this.calibration.height} 像素`; }
    } catch (e) { this.notice='读取保存数据失败：'+(e as Error).message; }
  }
  private write(name: string, value: string): void {
    const temporary=this.filesDir+'/'+name+'.tmp'; const destination=this.filesDir+'/'+name;
    const f=fs.openSync(temporary,fs.OpenMode.CREATE|fs.OpenMode.WRITE_ONLY|fs.OpenMode.TRUNC);
    try { fs.writeSync(f.fd,value); } finally { fs.closeSync(f); }
    fs.renameSync(temporary,destination);
  }
  private async connect(): Promise<void> {
    if (this.busy) { return; }
    if ((this.playing || this.preparing) && !this.activePreview) { await this.stopPlayback(); }
    this.busy=true;
    try { await this.hdc.connect(this.host.trim(),Number(this.port),this.filesDir); const saved: SavedConnection={host:this.host,port:this.port}; this.write('connection.json',JSON.stringify(saved)); this.notice='已连接'; await this.prepareBackend(); }
    catch (e) { const error=e as Error; this.notice=error.message; hilog.error(0xD001,'DoMiSo','%{public}s',error.stack || error.message); }
    finally { this.busy=false; }
  }
  private check(): void {
    this.checked=false; this.duration=0; this.noteCount=0; this.tempo='—'; this.parsed=new ScoreResult();
    try {
      this.parsed=new ScoreParser().parse(this.scoreText); this.checked=this.parsed.errors.length===0; this.noteCount=this.parsed.events.length; this.duration=this.parsed.duration; this.tempo=this.parsed.bpms.join('/') || '—';
      this.report=`${this.parsed.events.length}个音符 · ${this.parsed.groups.length}组起音 · ${this.parsed.voices}声部\n`+
        `${(this.parsed.duration/1000).toFixed(3)}秒 · BPM ${this.parsed.bpms.join('/')} · MIDI ${this.parsed.low}–${this.parsed.high}\n`+
        (this.parsed.errors.length ? this.parsed.errors.join('\n') : '校验通过')+
        (this.parsed.warnings.length ? '\n'+this.parsed.warnings.join('\n') : '');
    } catch (e) { this.report=(e as Error).message; }
    if (!this.playing && !this.preparing) { this.playbackDuration=this.duration; this.elapsed=0; }
    this.syncBall();
  }
  private async importText(): Promise<void> {
    try {
      const ctx=this.getUIContext().getHostContext() as common.UIAbilityContext;
      const paths=await new picker.DocumentViewPicker(ctx).select({maxSelectNumber:1,fileSuffixFilters:['文本曲谱|.txt']});
      if (!paths.length) { return; }
      const imported=await readScoreFile(paths[0]);
      await this.stopPlayback(false); this.scoreText=imported.text; this.title=imported.title; this.check(); this.notice='曲谱已导入';
    } catch (e) { this.notice='导入失败：'+(e as Error).message; }
  }
  private async receiveExternalScore(): Promise<void> {
    if (!this.externalScoreRequest || !this.filesDir) { return; }
    const request=JSON.parse(this.externalScoreRequest) as ImportedScore; this.externalScoreRequest='';
    if (request.error) { this.notice=request.error; return; }
    await this.stopPlayback(false);
    this.scoreText=request.text; this.title=request.title; this.editing=true; this.check();
    this.tab=1; this.tabsController.changeIndex(0); this.preserveMiniBar();
    this.notice=this.checked?'TXT曲谱已打开，检查通过':'TXT已打开，请检查曲谱格式';
  }
  private syncBall(): void {
    this.ball.setPlayback(this.playing,this.paused,this.preparing,(this.playing || this.preparing)?this.activeTitle:this.title);
  }
  private async toggleBall(): Promise<void> {
    if (this.ballBusy) { return; } this.ballBusy=true;
    try {
      if (this.ballShown) { await this.ball.hide(); this.ballEnabled=false; this.persistSettings(); this.notice='悬浮球已关闭'; }
      else {
        this.syncBall();
        await this.ball.show(this.getUIContext().getHostContext() as common.UIAbilityContext);
        this.ballEnabled=true; this.persistSettings(); this.notice='悬浮球已显示，点击可播放或暂停';
      }
    } catch (e) { this.notice='悬浮球开启失败：'+(e as Error).message; }
    finally { this.ballBusy=false; }
  }
  private scheduleBallRestore(): void {
    clearTimeout(this.ballRestoreTimer);
    if (!this.filesDir || !this.ballEnabled || this.disposing) { return; }
    this.ballRestoreTimer=setTimeout(() => { this.restoreBall(); },300);
  }
  private async restoreBall(): Promise<void> {
    if (!this.ballEnabled || this.ballShown || this.ballBusy || this.disposing) { return; }
    this.ballBusy=true;
    try { this.syncBall(); await this.ball.show(this.getUIContext().getHostContext() as common.UIAbilityContext); }
    catch (e) { this.notice='悬浮球恢复失败，请在设置中重新开启'; }
    finally { this.ballBusy=false; }
  }
  private persistSettings(): void {
    const settings: PlaybackSettings={background:this.backgroundEnabled,media:this.mediaEnabled,floatingBall:this.ballEnabled,startDelay:this.startDelay};
    this.write('settings.json',JSON.stringify(settings));
  }
  private async pasteScore(result: PasteButtonOnClickResult): Promise<void> {
    if (result!==PasteButtonOnClickResult.SUCCESS) { this.notice='未获得粘贴授权，请重新点击粘贴'; return; }
    try {
      // Read immediately within the temporary grant from the system PasteButton.
      const data=await pasteboard.getSystemPasteboard().getData();
      const text=data.getPrimaryText();
      if (!text || !text.trim()) { this.notice='剪贴板中没有可粘贴的文本曲谱'; return; }
      if (text.length>2000000 || new util.TextEncoder().encodeInto(text).byteLength>2000000) {
        this.notice='曲谱文本不能超过2MB'; return;
      }
      await this.stopPlayback(false);
      this.scoreText=text.replace(/^\uFEFF/,''); this.title='未命名曲谱'; this.editing=true;
      this.check(); this.notice=this.checked?'曲谱已粘贴，检查通过':'曲谱已粘贴，请检查曲谱格式';
    } catch (e) { this.notice='粘贴失败：'+(e as Error).message; }
  }
  private saveScore(): void {
    this.check(); if (!this.checked) { this.notice='请先修复曲谱错误'; return; }
    const item=new LibraryEntry(); item.id=Date.now().toString(); item.title=this.title.trim()||'未命名曲谱'; item.text=this.scoreText;
    const updated=[item,...this.library];
    try {
      this.write('library.json',JSON.stringify(updated)); this.library=updated;
      this.editing=false; this.getUIContext().getFocusController().clearFocus(); this.notice='已保存到本地曲库';
    }
    catch (e) { this.notice='保存失败：'+(e as Error).message; }
  }
  private async importScreenshot(): Promise<void> {
    try {
      const ctx=this.getUIContext().getHostContext() as common.UIAbilityContext;
      const chosen=await new photoAccessHelper.PhotoViewPicker().select({MIMEType:photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,maxSelectNumber:1});
      if (!chosen.photoUris.length) { return; }
      const file=await fs.open(chosen.photoUris[0],fs.OpenMode.READ_ONLY);
      try {
        if ((await fs.stat(file.fd)).size>30000000) { throw new Error('图片不能超过30MB'); }
        const source=image.createImageSource(file.fd); const info=await source.getImageInfo();
        const screen=display.getDefaultDisplaySync();
        if (info.size.width<=info.size.height || info.size.width!==Math.max(screen.width,screen.height) || info.size.height!==Math.min(screen.width,screen.height)) {
          source.release(); throw new Error('请导入本机完整横屏截图；裁剪、缩放或其他分辨率图片不能直接换算触摸坐标');
        }
        if (this.screenshot) { this.screenshot.release(); }
        this.screenshot=await source.createPixelMap(); source.release();
        this.calibration=resetCalibration(info.size.width,info.size.height); this.zoom=1; this.fullScreenshot=false;
        this.imageLabel=`原图 ${info.size.width}×${info.size.height} 像素 · 请将四角对齐外侧琴键中心`;
        fs.copyFileSync(file.fd,this.filesDir+'/calibration_image'); this.draw();
      } finally { await fs.close(file); }
    } catch (e) { const error=e as Error; this.notice=error.message; hilog.error(0xD001,'DoMiSo','%{public}s',error.stack || error.message); }
  }
  private fit(): ImageFit { return new ImageFit(this.calibration.width||2848,this.calibration.height||1320,this.canvasWidth,this.canvasHeight,this.zoom); }
  private draw(): void {
    const c=this.canvas; c.clearRect(0,0,this.canvasWidth,this.canvasHeight);
    if (!this.calibration.width) { return; }
    const fit=this.fit();
    if (this.screenshot) { c.drawImage(this.screenshot,fit.offsetX,fit.offsetY,this.calibration.width*fit.scale,this.calibration.height*fit.scale); }
    c.strokeStyle='#61E5C2'; c.lineWidth=1;
    for (let i=0;i<21;i++) {
      const p=fit.toView(this.calibration.points[i]);
      if (i%7<6) { const n=fit.toView(this.calibration.points[i+1]); c.beginPath(); c.moveTo(p.x,p.y); c.lineTo(n.x,n.y); c.stroke(); }
      if (i<14) { const n=fit.toView(this.calibration.points[i+7]); c.beginPath(); c.moveTo(p.x,p.y); c.lineTo(n.x,n.y); c.stroke(); }
    }
    for (let i=0;i<21;i++) {
      const p=fit.toView(this.calibration.points[i]); const corner=[0,6,14,20].indexOf(i)>=0;
      c.fillStyle=i===this.selected?'#FFE292':corner?'#FF8E79':'#61E5C2';
      c.beginPath(); c.arc(p.x,p.y,corner?10:6,0,Math.PI*2); c.fill();
      c.fillStyle='#122022'; c.beginPath(); c.arc(p.x,p.y,2,0,Math.PI*2); c.fill();
      c.fillStyle='#FFFFFF'; c.font='10px sans-serif'; c.fillText(keyName(i),p.x-12,p.y-13);
    }
  }
  private touch(e: TouchEvent): void {
    if (!this.screenshot || !e.touches.length) { return; }
    const p=this.fit().toImage(e.touches[0].x,e.touches[0].y);
    if (e.type===TouchType.Down) {
      this.dragStart=p; this.dragTarget=-1; let distance=22/this.fit().scale;
      for (let i=0;i<21;i++) { const k=this.calibration.points[i]; const d=Math.hypot(k.x-p.x,k.y-p.y); if (d<distance) { distance=d; this.dragTarget=i; this.selected=i; } }
      this.dragCorners=this.calibration.corners.map((a: PixelPoint) => new PixelPoint(a.x,a.y));
      this.dragAdjustments=this.calibration.adjustments.map((a: PixelPoint) => new PixelPoint(a.x,a.y));
    } else if (e.type===TouchType.Move && this.dragTarget>=-1) {
      const dx=p.x-this.dragStart.x; const dy=p.y-this.dragStart.y;
      const ci=[0,6,14,20].indexOf(this.dragTarget);
      if (this.dragTarget===-1) { this.calibration.corners=this.dragCorners.map((a: PixelPoint) => new PixelPoint(a.x+dx,a.y+dy)); }
      else if (ci>=0) { this.calibration.corners[ci]=new PixelPoint(this.dragCorners[ci].x+dx,this.dragCorners[ci].y+dy); }
      else { this.calibration.adjustments[this.dragTarget]=new PixelPoint(this.dragAdjustments[this.dragTarget].x+dx,this.dragAdjustments[this.dragTarget].y+dy); }
      recalculate(this.calibration);
    } else if (e.type===TouchType.Up || e.type===TouchType.Cancel) { this.dragTarget=-2; }
    this.draw();
  }
  private nudge(dx: number, dy: number): void {
    if (!this.calibration.width) { return; }
    for (let i=0;i<21;i++) { if (i===this.selected || (this.rowAdjust && Math.floor(i/7)===Math.floor(this.selected/7))) { this.calibration.adjustments[i].x+=dx; this.calibration.adjustments[i].y+=dy; } }
    recalculate(this.calibration); this.draw();
  }
  private saveCalibration(): void {
    try {
      this.calibration.fullScreenshotConfirmed=this.fullScreenshot;
      const d=display.getDefaultDisplaySync(); const error=validateCalibration(this.calibration,Math.max(d.width,d.height),Math.min(d.width,d.height));
      if (error) { throw new Error(error); }
      this.calibration.savedAt=Date.now(); this.write('calibration.json',JSON.stringify(this.calibration)); this.calibrated=true; this.notice='校准已保存';
    } catch (e) { const error=e as Error; this.notice=error.message; hilog.error(0xD001,'DoMiSo','%{public}s',error.stack || error.message); }
  }
  private async prepareBackend(): Promise<void> {
    this.busy=true;
    try { const ctx=this.getUIContext().getHostContext() as common.UIAbilityContext; await this.backend.prepare(this.hdc,ctx); this.system.backgroundEnabled=this.backgroundEnabled; await this.system.retainConnection(); this.notice='演奏服务已就绪'; }
    catch (e) { this.notice=(e as Error).message; }
    finally { this.busy=false; }
  }
  private async play(): Promise<void> {
    if (this.playing || this.preparing) { return; }
    this.check();
    if (!this.checked) { this.editing=true; this.notice='请先修复曲谱错误'; return; }
    if (!this.previewMode) {
      if (!this.backend.ready) { this.tab=0; this.notice='请先连接演奏服务'; return; }
      const screen=display.getDefaultDisplaySync(); const error=validateCalibration(this.calibration,Math.max(screen.width,screen.height),Math.min(screen.width,screen.height));
      if (error) { this.tab=2; this.notice=error; return; }
    }
    await this.perform(this.parsed,this.title);
  }
  private async openGame(): Promise<void> {
    if (!this.hdc.ready) { throw new Error('无线调试已断开'); }
    const screen=display.getDefaultDisplaySync();
    const mismatch=validateCalibration(this.calibration,Math.max(screen.width,screen.height),Math.min(screen.width,screen.height));
    if (mismatch) { throw new Error(mismatch); }
    const result=await this.hdc.shell('aa start -b com.miHoYo.Yuanshen -a UnityPlayerAbility');
    if (result.indexOf('start ability successfully')<0) { throw new Error('未能打开原神，请先手动打开游戏'); }
    for (let i=0;i<50;i++) {
      const current=display.getDefaultDisplaySync();
      if (current.width===this.calibration.width && current.height===this.calibration.height) { return; }
      await new Promise<void>((resolve) => { setTimeout(resolve,100); });
    }
    throw new Error('原神尚未进入匹配的横屏，请打开琴界面后重试');
  }
  private async perform(score: ScoreResult,title: string,audioPreview: boolean = this.previewMode): Promise<void> {
    const version=++this.runVersion; this.preparing=true; this.activePreview=audioPreview;
    this.activeTitle=title; this.playbackDuration=score.duration; this.elapsed=0; this.seekReady=false; this.syncBall();
    try {
      await this.stopQueue;
      if (version!==this.runVersion) { return; }
      this.system.backgroundEnabled=this.backgroundEnabled; this.system.controlsEnabled=this.mediaEnabled;
      await this.system.begin(title,score.duration,audioPreview);
      if (version!==this.runVersion) { return; }
      this.playing=true; this.paused=false; this.preparing=false; this.syncBall();
      if (audioPreview) { this.preview.setSpeed(this.speed); await this.preview.play(score); }
      else { this.player.setSpeed(this.speed); await this.player.play(score,this.calibration,this.backend,this.startDelay); }
    } catch (e) { if (version===this.runVersion) { this.notice=(e as Error).message; } }
    finally { if (version===this.runVersion) { this.playing=false; this.preparing=false; this.paused=false; this.syncBall(); await this.system.finish(); } }
  }
  private async changeMode(value: boolean): Promise<void> {
    if (value===this.previewMode && (!this.playing || this.activePreview===value)) { return; }
    await this.stopPlayback(false); this.previewMode=value;
    this.notice=value?'已切换到琴音试听':'已切换到游戏演奏';
  }
  private async selectScore(item: LibraryEntry): Promise<void> {
    const stopped=this.stopPlayback(false);
    this.scoreText=item.text; this.title=item.title; this.check(); this.notice='已选择 '+item.title;
    await stopped;
  }
  private async testNote(): Promise<void> {
    await this.stopPlayback(false);
    const sample=new ScoreParser().parse('bpm=80\n'+['+','', '-'][Math.floor(this.selected/7)]+String(this.selected%7+1));
    await this.perform(sample,keyName(this.selected)+' · 试音',true);
  }
  private async testTouch(): Promise<void> {
    if (!this.backend.ready) { this.notice='请先连接演奏服务'; return; }
    await this.stopPlayback(false);
    const screen=display.getDefaultDisplaySync();
    const error=validateCalibration(this.calibration,Math.max(screen.width,screen.height),Math.min(screen.width,screen.height));
    if (error) { this.notice=error; return; }
    const sample=new ScoreParser().parse('bpm=80\n'+['+','','-'][Math.floor(this.selected/7)]+String(this.selected%7+1));
    await this.perform(sample,keyName(this.selected)+' · 试键',false);
  }
  private setPaused(value: boolean,notify: boolean = true): void {
    if (!this.playing) { return; }
    if (this.activePreview) { this.preview.setPaused(value).catch((e: Error) => { this.notice=e.message; }); }
    else { this.player.setPaused(value); }
    this.paused=value; this.syncBall(); if (notify) { this.notice=value?'已暂停':'继续演奏'; }
  }
  private async stopPlayback(notify: boolean = true): Promise<void> {
    const version=++this.runVersion; this.playing=false; this.preparing=false; this.paused=false; this.seeking=false; this.seekReady=false; this.syncBall();
    this.player.stop();
    this.stopQueue=this.stopQueue.then(async () => { await this.preview.stop(); await this.system.finish(); })
      .catch((e: Error) => { this.notice='停止失败：'+e.message; });
    await this.stopQueue;
    if (version===this.runVersion) { this.playbackState='已停止'; if (notify) { this.notice='已停止'; } }
  }
  private updatePlayback(text: string,audioPreview: boolean): void {
    if (audioPreview!==this.activePreview || !this.playing) { return; }
    this.playbackState=text;
    this.seekReady=audioPreview?this.preview.canSeek():this.player.canSeek();
    this.elapsed=audioPreview?this.preview.elapsedMs:this.player.elapsedMs;
    this.paused=audioPreview?this.preview.isPaused():this.player.isPaused();
    this.syncBall(); this.system.update(this.elapsed,this.paused,this.speed);
    if (text==='演奏完成' || text==='试听完成') { this.notice=text; }
  }
  private showSongTitle(): void {
    this.getUIContext().getPromptAction().showDialog({title:'曲名',message:(this.playing || this.preparing)?this.activeTitle:this.title,
      buttons:[{text:'关闭',color:$r('app.color.accent')}]});
  }
  private handleSeek(value: number,mode: SliderChangeMode): void {
    if (!this.playing || !this.seekReady) { return; }
    if (mode===SliderChangeMode.Begin || mode===SliderChangeMode.Click) {
      this.resumeAfterSeek=!this.paused; this.seeking=true; this.setPaused(true,false);
    }
    this.seekValue=value;
    if (mode===SliderChangeMode.End || mode===SliderChangeMode.Click) { this.commitSeek(value); }
  }
  private async commitSeek(value: number): Promise<void> {
    const version=this.runVersion; const resume=this.resumeAfterSeek;
    try {
      if (this.activePreview) { await this.preview.seek(value); }
      else { this.player.seek(value); }
      if (version!==this.runVersion) { return; }
      this.elapsed=value; this.system.update(value,this.paused,this.speed); this.notice='已跳转到 '+this.time(value);
    } catch (e) { this.notice=(e as Error).message; }
    finally {
      if (version===this.runVersion) { this.seeking=false; if (resume && this.playing) { this.setPaused(false,false); } }
    }
  }
  private async restoreScreenshot(): Promise<void> {
    try {
      const path=this.filesDir+'/calibration_image'; if (!fs.accessSync(path)) { return; }
      const source=image.createImageSource(path); this.screenshot=await source.createPixelMap(); source.release(); this.draw();
    } catch (e) { hilog.warn(0xD001,'DoMiSo','image restore %{public}s',(e as Error).message); }
  }
  private showNotice(): void {
    if (this.notice && (this.notice!==this.lastToast || Date.now()-this.lastToastAt>2000)) { this.lastToast=this.notice; this.lastToastAt=Date.now(); this.getUIContext().getPromptAction().showToast({message:this.notice,duration:2200}); }
  }
  private async saveSettings(): Promise<void> {
    try {
      this.persistSettings();
      await this.system.applySettings(this.backgroundEnabled,this.mediaEnabled,this.backend.ready);
      this.notice='设置已保存';
    } catch (e) { this.notice='设置失败：'+(e as Error).message; }
  }
  private async openSource(url: string): Promise<void> {
    try { const context=this.getUIContext().getHostContext() as common.UIAbilityContext; await context.startAbility({action:'ohos.want.action.viewData',uri:url}); }
    catch (e) { this.notice='暂时无法打开项目链接'; }
  }
  private async showLicense(title: string,asset: string): Promise<void> {
    try {
      const context=this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.licenseHeading=title; this.licenseContent=util.TextDecoder.create('utf-8').decodeToString(await context.resourceManager.getRawFileContent(asset)); this.licenseDialog.open();
    } catch (e) { this.notice='许可文件读取失败'; }
  }
  private time(ms: number): string {
    const seconds=Math.max(0,Math.floor(ms/1000)); return Math.floor(seconds/60)+':'+String(seconds%60).padStart(2,'0');
  }
  private async verifiedCalibration(): Promise<void> {
    try {
      const ctx=this.getUIContext().getHostContext() as common.UIAbilityContext;
      const p=JSON.parse(util.TextDecoder.create('utf-8').decodeToString(await ctx.resourceManager.getRawFileContent('verified_calibration.json'))) as CalibrationProfile;
      const screen=display.getDefaultDisplaySync();
      if (Math.max(screen.width,screen.height)!==p.width || Math.min(screen.width,screen.height)!==p.height) { throw new Error('此样本只适用于已实测的2848×1320设备'); }
      this.calibration=p; this.fullScreenshot=true; this.imageLabel='已载入此前真机验证的21键坐标'; this.saveCalibration(); this.draw();
    } catch (e) { this.notice=(e as Error).message; }
  }
  private scaleModel(factor: number): void {
    if (!this.calibration.width) { return; }
    const center=new PixelPoint(this.calibration.corners.reduce((v: number,p: PixelPoint) => v+p.x,0)/4,this.calibration.corners.reduce((v: number,p: PixelPoint) => v+p.y,0)/4);
    this.calibration.corners=this.calibration.corners.map((p: PixelPoint) => new PixelPoint(center.x+(p.x-center.x)*factor,center.y+(p.y-center.y)*factor));
    recalculate(this.calibration); this.draw();
  }
  private preserveMiniBar(): void {
    clearTimeout(this.miniRestoreTimer);
    this.miniExpanded=true;
    this.tabsController.applyMiniBarStyle(HdsBarStyle.EXPAND);
    this.miniRestoreTimer=setTimeout(() => { this.tabsController.applyMiniBarStyle(HdsBarStyle.EXPAND); },100);
  }
  private async deleteScore(item: LibraryEntry): Promise<void> {
    const result=await this.getUIContext().getPromptAction().showDialog({title:'删除曲谱？',message:item.title,
      buttons:[{text:'取消',color:$r('app.color.text_secondary')},{text:'删除',color:$r('app.color.accent')}]});
    if (result.index!==1) { return; }
    try { this.library=this.library.filter((entry: LibraryEntry) => entry.id!==item.id); this.write('library.json',JSON.stringify(this.library)); this.notice='曲谱已删除'; }
    catch (e) { this.notice='删除失败：'+(e as Error).message; }
  }
  @Builder
  iconButton(icon: Resource,action: () => void,primary: boolean = false,size: number = 42) {
    Button({type:ButtonType.Circle}) {
      SymbolGlyph(icon).fontSize(20).fontColor([primary?$r('app.color.on_accent'):$r('app.color.text_primary')])
    }.width(size).height(size).backgroundColor(primary?$r('app.color.accent'):$r('app.color.control_bg')).onClick(action)
  }
  @Builder
  scoreMetrics() {
    Row({space:8}) {
      Column({space:4}) {
        Text(this.time(this.duration)).fontSize(22).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).id('ScoreDuration')
        Text('时长').fontSize(11).fontColor($r('app.color.text_secondary'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Column({space:4}) {
        Text(this.tempo).fontSize(22).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).id('ScoreBpm')
        Text('BPM').fontSize(11).fontColor($r('app.color.text_secondary'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Column({space:4}) {
        Text(String(this.noteCount)).fontSize(22).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).id('ScoreNotes')
        Text('音符').fontSize(11).fontColor($r('app.color.text_secondary'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%')
  }
  @Builder
  sectionTitle(title: string) { Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary')).width('100%') }
  @Builder
  scorePanel() {
    Column({space:16}) {
      Column({space:20}) {
        Row({space:8}) {
          SymbolGlyph($r('sys.symbol.music_note_list')).fontSize(19).fontColor([$r('app.color.accent')])
          Text('当前曲谱').fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
          this.iconButton($r('sys.symbol.pencil_line'),() => { this.editing=!this.editing; })
        }.width('100%')
        Text(this.title).fontSize(27).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).width('100%').onClick(() => { this.showSongTitle(); })
        this.scoreMetrics()
        Row({space:6}) {
          Button('游戏演奏').height(34).fontSize(13).fontColor(!this.previewMode?$r('app.color.accent'):$r('app.color.text_secondary'))
            .backgroundColor(!this.previewMode?$r('app.color.accent_soft'):Color.Transparent).id('GameMode').onClick(() => { this.changeMode(false); })
          Button('琴音试听').height(34).fontSize(13).fontColor(this.previewMode?$r('app.color.accent'):$r('app.color.text_secondary'))
            .backgroundColor(this.previewMode?$r('app.color.accent_soft'):Color.Transparent).id('PreviewMode').onClick(() => { this.changeMode(true); })
          Blank()
          Button(this.speed.toFixed(2)+'×').height(34).fontSize(12).fontColor($r('app.color.accent')).backgroundColor($r('app.color.accent_soft')).onClick(() => { this.speedDialog.open(); })
        }.width('100%')
      }.padding(22).width('100%').alignItems(HorizontalAlign.Start).borderRadius(28).backgroundColor($r('app.color.card_bg'))
      Row({space:10}) {
        Button('导入TXT').layoutWeight(1).height(44).fontSize(14).fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.card_bg')).onClick(() => { this.importText(); })
        Row() {
          PasteButton({icon:PasteIconStyle.LINES,text:PasteDescription.PASTE,buttonType:ButtonType.Capsule})
            .width('100%').height(44).fontSize(16).iconSize(18)
            .fontColor($r('app.color.text_primary')).iconColor($r('app.color.text_primary')).backgroundColor($r('app.color.card_bg'))
            .id('PasteScore').onClick((event: ClickEvent,result: PasteButtonOnClickResult) => { this.pasteScore(result); })
        }.layoutWeight(1).height(44)
      }.width('100%')
      if (this.editing) {
        Column({space:12}) {
          this.sectionTitle('编辑曲谱')
          TextInput({text:this.title,placeholder:'曲名'}).height(44).fontSize(16).backgroundColor($r('app.color.input_bg')).fontColor($r('app.color.text_primary')).onChange((value: string) => { this.title=value; })
          TextArea({text:this.scoreText,placeholder:'粘贴 DoMiSo 简谱'}).height(230).fontSize(14).backgroundColor($r('app.color.input_bg')).fontColor($r('app.color.text_primary'))
            .onChange((value: string) => { this.scoreText=value; this.checked=false; })
          Row({space:10}) {
            Button('检查').layoutWeight(1).height(40).fontColor($r('app.color.accent')).backgroundColor($r('app.color.accent_soft')).onClick(() => { this.check(); })
            Button('保存').layoutWeight(1).height(40).fontColor($r('app.color.on_accent')).backgroundColor($r('app.color.accent')).onClick(() => { this.saveScore(); })
          }
          if (!this.checked || this.parsed.warnings.length>0) { Text(this.report).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%'); }
        }.width('100%').padding(18).borderRadius(28).backgroundColor($r('app.color.card_bg'))
      }
      this.sectionTitle('我的曲库')
      if (this.library.length===0) {
        Text('保存喜欢的曲谱，随时开始演奏').fontSize(13).fontColor($r('app.color.text_secondary')).padding({top:14,bottom:20}).width('100%')
      }
      ForEach(this.library,(item: LibraryEntry) => {
        Row({space:12}) {
          SymbolGlyph($r('sys.symbol.music_note_list')).fontSize(22).fontColor([$r('app.color.accent')])
          Text(item.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
          Button({type:ButtonType.Circle}) { SymbolGlyph($r('sys.symbol.trash')).fontSize(18).fontColor([$r('app.color.text_secondary')]); }.width(36).height(36).backgroundColor(Color.Transparent).accessibilityText('删除'+item.title).onClick(() => { this.deleteScore(item); })
        }.width('100%').padding(18).borderRadius(22).backgroundColor($r('app.color.card_bg'))
          .onClick(() => { this.selectScore(item); })
          .bindContextMenu(() => { this.scoreMenu(item); },ResponseType.LongPress)
      },(item: LibraryEntry) => item.id)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  scoreMenu(item: LibraryEntry) {
    Menu() { MenuItem({content:'删除曲谱'}).onClick(() => { this.deleteScore(item); }); }
  }
  @Builder
  connectionPanel() {
    Column({space:18}) {
      Column({space:18}) {
        Row() {
          Text('无线调试').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1)
          Text(this.connectionReady?'已连接':'未连接').fontSize(12).fontColor(this.connectionReady?$r('app.color.accent'):$r('app.color.text_secondary')).id('ConnectionStatus')
        }.width('100%')
        TextInput({text:this.host,placeholder:'手机IP地址'}).height(48).backgroundColor($r('app.color.input_bg')).fontColor($r('app.color.text_primary')).onChange((value: string) => { this.host=value; })
        Row({space:12}) {
          TextInput({text:this.port,placeholder:'端口'}).type(InputType.Number).height(48).layoutWeight(1).backgroundColor($r('app.color.input_bg')).fontColor($r('app.color.text_primary')).onChange((value: string) => { this.port=value; })
          Button(this.busy?'连接中':'连接').height(48).fontColor($r('app.color.on_accent')).backgroundColor($r('app.color.accent')).enabled(!this.busy).onClick(() => { this.connect(); })
        }
        if (!this.connectionReady || this.busy) { Text(this.connection).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%'); }
        Row({space:8}) {
          Text('演奏服务').fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1)
          Text(this.backendReady?'已就绪':'未就绪').fontSize(12).fontColor(this.backendReady?$r('app.color.accent'):$r('app.color.text_secondary')).id('BackendState')
          if (this.connectionReady && !this.backendReady) { Button('重试').height(32).fontSize(12).fontColor($r('app.color.accent')).backgroundColor($r('app.color.accent_soft')).onClick(() => { this.prepareBackend(); }); }
        }.width('100%')
      }.width('100%').padding(22).borderRadius(28).backgroundColor($r('app.color.card_bg'))
      Column({space:18}) {
        this.sectionTitle('系统控制')
        Row({space:12}) {
          Column({space:5}) { Text('起播延迟').fontSize(16).fontColor($r('app.color.text_primary')); Text('原神横屏就绪后等待').fontSize(12).fontColor($r('app.color.text_secondary')); }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button(this.startDelay+' 秒').height(36).fontSize(13).fontColor($r('app.color.accent')).backgroundColor($r('app.color.accent_soft')).id('StartDelayEntry').onClick(() => { this.delayDialog.open(); })
        }.width('100%')
        Divider().color($r('app.color.divider'))
        Row({space:12}) {
          Column({space:5}) { Text('悬浮球').fontSize(16).fontColor($r('app.color.text_primary')); Text('点击悬浮球播放或暂停').fontSize(12).fontColor($r('app.color.text_secondary')); }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button(this.ballShown?'关闭':'显示').height(36).fontSize(13).fontColor($r('app.color.accent')).backgroundColor($r('app.color.accent_soft')).enabled(!this.ballBusy).id('FloatingBallEntry').onClick(() => { this.toggleBall(); })
        }.width('100%')
        Divider().color($r('app.color.divider'))
        Row({space:12}) {
          Column({space:5}) { Text('后台演奏').fontSize(16).fontColor($r('app.color.text_primary')); Text(this.backgroundStatus).fontSize(12).fontColor($r('app.color.text_secondary')); }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({type:ToggleType.Switch,isOn:this.backgroundEnabled}).selectedColor($r('app.color.accent')).onChange((value: boolean) => { this.backgroundEnabled=value; this.saveSettings(); })
        }.width('100%')
        Divider().color($r('app.color.divider'))
        Row({space:12}) {
          Column({space:5}) { Text('控制中心').fontSize(16).fontColor($r('app.color.text_primary')); Text('媒体卡片与通知控制').fontSize(12).fontColor($r('app.color.text_secondary')); }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({type:ToggleType.Switch,isOn:this.mediaEnabled}).selectedColor($r('app.color.accent')).onChange((value: boolean) => { this.mediaEnabled=value; this.saveSettings(); })
        }.width('100%')
      }.width('100%').padding(22).borderRadius(28).backgroundColor($r('app.color.card_bg'))
      Column({space:18}) {
        Text('关于与开源').fontSize(21).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).width('100%')
        Column({space:7}) {
          Row() { Text('HmDoMiSo').fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1); SymbolGlyph($r('sys.symbol.arrow_up_right')).fontSize(16).fontColor([$r('app.color.accent')]); }
          Text('github.com/xixiaotiam1219-lab/HmDoMiSo').fontSize(12).fontColor($r('app.color.accent')).width('100%')
          Text('应用源码 · MIT License').fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
        }.width('100%').onClick(() => { this.openSource('https://github.com/xixiaotiam1219-lab/HmDoMiSo'); })
        Divider().color($r('app.color.divider'))
        Column({space:7}) {
          Row() { Text('原项目 · DoMiSo-Universal').fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1); SymbolGlyph($r('sys.symbol.arrow_up_right')).fontSize(16).fontColor([$r('app.color.accent')]); }
          Text('github.com/Nigh/DoMiSo-Universal').fontSize(12).fontColor($r('app.color.accent')).width('100%')
          Text('作者 Nigh · MIT License').fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
        }.width('100%').onClick(() => { this.openSource('https://github.com/Nigh/DoMiSo-Universal'); })
        Row({space:8}) {
          Button('MIT 协议').layoutWeight(1).height(36).fontSize(12).fontColor($r('app.color.accent')).backgroundColor($r('app.color.accent_soft')).onClick(() => { this.showLicense('HmDoMiSo · MIT','hmdomiso_LICENSE.txt'); })
          Button('原项目许可').layoutWeight(1).height(36).fontSize(12).fontColor($r('app.color.accent')).backgroundColor($r('app.color.accent_soft')).onClick(() => { this.showLicense('DoMiSo-Universal · MIT','domiso_LICENSE.txt'); })
        }.width('100%')
        Button('第三方组件与许可').width('100%').height(36).fontSize(12).fontColor($r('app.color.text_secondary')).backgroundColor($r('app.color.control_bg')).onClick(() => { this.showLicense('第三方组件与许可','third_party_notices.txt'); })
      }.width('100%').padding(22).borderRadius(28).backgroundColor($r('app.color.card_bg'))
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  calibrationPanel() {
    Column({space:16}) {
      Row({space:10}) {
        Text('21键校准').fontSize(23).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1)
        this.iconButton($r('sys.symbol.picture'),() => { this.importScreenshot(); })
      }.width('100%')
      Text('四角对齐高、低音 do / ti 的琴键中心').fontSize(13).fontColor($r('app.color.text_secondary'))
      Column({space:12}) {
        if (!this.screenshot) { Text('导入完整横屏截图').fontSize(15).fontColor($r('app.color.text_secondary')).padding({top:18}); }
        Canvas(this.canvas).width('100%').height(240).borderRadius(20).backgroundColor($r('app.color.canvas_bg'))
          .onReady(() => { this.draw(); }).onAreaChange((oldArea: Area,newArea: Area) => { this.canvasWidth=Number(newArea.width); this.canvasHeight=Number(newArea.height); this.draw(); })
          .onTouch((event: TouchEvent) => { this.touch(event); })
        Row({space:8}) {
          Button('重置').height(34).fontSize(12).fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.control_bg')).onClick(() => { if (this.calibration.width) { this.calibration=resetCalibration(this.calibration.width,this.calibration.height); this.draw(); } })
          Button(this.zoom===1?'放大':'全图').height(34).fontSize(12).fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.control_bg')).onClick(() => { this.zoom=this.zoom===1?1.8:1; this.draw(); })
          Blank()
          this.iconButton($r('sys.symbol.minus'),() => { this.scaleModel(0.97); },false,34)
          this.iconButton($r('sys.symbol.plus'),() => { this.scaleModel(1.03); },false,34)
        }.width('100%')
      }.width('100%').padding(12).borderRadius(28).backgroundColor($r('app.color.card_bg'))
      Column({space:14}) {
        Row() {
          Text(keyName(this.selected)).fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
          Text('整行').fontSize(12).fontColor($r('app.color.text_secondary'))
          Toggle({type:ToggleType.Switch,isOn:this.rowAdjust}).selectedColor($r('app.color.accent')).onChange((value: boolean) => { this.rowAdjust=value; })
        }.width('100%')
        Row({space:8}) {
          Button() { SymbolGlyph($r('sys.symbol.arrow_left')).fontSize(18).fontColor([$r('app.color.text_primary')]); }.layoutWeight(1).height(42).fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.control_bg')).onClick(() => { this.nudge(-1,0); })
          Button() { SymbolGlyph($r('sys.symbol.arrow_right')).fontSize(18).fontColor([$r('app.color.text_primary')]); }.layoutWeight(1).height(42).fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.control_bg')).onClick(() => { this.nudge(1,0); })
          Button() { SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(18).fontColor([$r('app.color.text_primary')]); }.layoutWeight(1).height(42).fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.control_bg')).onClick(() => { this.nudge(0,-1); })
          Button() { SymbolGlyph($r('sys.symbol.arrow_down')).fontSize(18).fontColor([$r('app.color.text_primary')]); }.layoutWeight(1).height(42).fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.control_bg')).onClick(() => { this.nudge(0,1); })
        }.width('100%')
        Row({space:8}) { Checkbox().select(this.fullScreenshot).selectedColor($r('app.color.accent')).onChange((value: boolean) => { this.fullScreenshot=value; }); Text('完整原图，未经裁剪').fontSize(13).fontColor($r('app.color.text_secondary')); }
        Row({space:10}) {
          Button('保存校准').layoutWeight(1).height(44).fontColor($r('app.color.on_accent')).backgroundColor($r('app.color.accent')).onClick(() => { this.saveCalibration(); })
          Button('试键').height(44).fontColor($r('app.color.accent')).backgroundColor($r('app.color.accent_soft')).onClick(() => { this.testTouch(); })
          Button('试音').height(44).fontColor($r('app.color.accent')).backgroundColor($r('app.color.accent_soft')).onClick(() => { this.testNote(); })
        }.width('100%')
        Button('使用本机坐标样本').height(30).fontSize(11).fontColor($r('app.color.text_secondary')).backgroundColor(Color.Transparent).onClick(() => { this.verifiedCalibration(); })
      }.padding(18).width('100%').borderRadius(28).backgroundColor($r('app.color.card_bg'))
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  playPauseButton(size: number = 40) {
    Button({type:ButtonType.Circle}) {
      SymbolGlyph(this.playing&&!this.paused?$r('sys.symbol.pause_fill'):$r('sys.symbol.play_fill')).fontSize(size*0.52).fontColor([$r('app.color.accent')])
    }.width(size).height(size).backgroundColor(Color.Transparent).id('PlayToggle').accessibilityText(this.playing&&!this.paused?'暂停':'播放')
      .onClick(() => { if (this.playing) { this.setPaused(!this.paused); } else { this.play(); } })
  }
  @Builder
  playerDock() {
    if (this.miniExpanded) {
      Column({space:0}) {
        Row({space:8}) {
          Column({space:1}) {
            Text((this.playing || this.preparing)?this.activeTitle:this.title).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).maxLines(1).textOverflow({overflow:TextOverflow.MARQUEE}).width('100%').id('DockTitle')
            Text(this.preparing?'准备中':this.playbackState).fontSize(10).fontColor($r('app.color.text_secondary')).maxLines(1).width('100%').id('PlaybackState')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start).onClick(() => { this.showPlayer=true; })
          this.playPauseButton()
          Button({type:ButtonType.Circle}) { SymbolGlyph($r('sys.symbol.stop_circle')).fontSize(23).fontColor([$r('app.color.text_secondary')]); }
            .width(32).height(40).backgroundColor(Color.Transparent).id('StopPlayback').accessibilityText('停止').onClick(() => { this.stopPlayback(); })
        }.width('100%').height(40).padding({left:16,right:8})
        Slider({value:this.seeking?this.seekValue:this.elapsed,min:0,max:Math.max(1,this.playbackDuration),step:100,style:SliderStyle.InSet})
          .selectedColor($r('app.color.accent')).trackColor($r('app.color.accent_soft')).trackThickness(3).blockSize({width:8,height:8})
          .width('90%').height(16).enabled(this.playing && this.seekReady).id('MiniSeek').accessibilityText('播放进度')
          .onChange((value: number,mode: SliderChangeMode) => { this.handleSeek(value,mode); })
      }.width('100%').height(56)
    } else { Row() { this.playPauseButton(48); }.width('100%').height(56).justifyContent(FlexAlign.Center) }
  }
  @Builder
  playerDetails() {
    Column({space:20}) {
      Text((this.playing || this.preparing)?this.activeTitle:this.title).fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).width('100%')
      Text(this.playbackState).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
      Button(this.ballShown?'关闭悬浮球':'显示悬浮球').height(36).fontSize(13).fontColor($r('app.color.accent')).backgroundColor($r('app.color.accent_soft')).enabled(!this.ballBusy).onClick(() => { this.toggleBall(); })
      Column({space:0}) {
        Slider({value:this.seeking?this.seekValue:this.elapsed,min:0,max:Math.max(1,this.playbackDuration),step:100})
          .selectedColor($r('app.color.accent')).trackColor($r('app.color.accent_soft')).width('100%').height(40)
          .enabled(this.playing && this.seekReady).id('PlayerSeek').accessibilityText('拖动调整播放进度')
          .onChange((value: number,mode: SliderChangeMode) => { this.handleSeek(value,mode); })
        Row() {
          Text(this.time(this.seeking?this.seekValue:this.elapsed)).fontSize(12).fontColor($r('app.color.text_secondary'))
          Blank()
          Text(this.time(this.playbackDuration)).fontSize(12).fontColor($r('app.color.text_secondary'))
        }.width('100%')
      }.width('100%')
      Row({space:24}) {
        Button(this.speed.toFixed(2)+'×').width(70).height(44).fontColor($r('app.color.accent')).backgroundColor($r('app.color.accent_soft')).onClick(() => { this.speedDialog.open(); })
        this.playPauseButton(64)
        Button({type:ButtonType.Circle}) { SymbolGlyph($r('sys.symbol.stop_circle')).fontSize(32).fontColor([$r('app.color.text_secondary')]); }
          .width(64).height(64).backgroundColor(Color.Transparent).accessibilityText('停止').onClick(() => { this.stopPlayback(); })
      }.width('100%').justifyContent(FlexAlign.Center)
    }.padding({left:24,right:24,top:28,bottom:24}).width('100%')
  }
  @Builder
  navigationItem(index: number,label: string,icon: Resource) {
    Column({space:4}) {
      SymbolGlyph(icon).fontSize(21).fontColor([this.tab===index?$r('app.color.accent'):$r('app.color.text_secondary')])
      Text(label).fontSize(10).fontWeight(this.tab===index?FontWeight.Medium:FontWeight.Regular).fontColor(this.tab===index?$r('app.color.accent'):$r('app.color.text_secondary'))
    }.layoutWeight(1).height(48).justifyContent(FlexAlign.Center).borderRadius(20).backgroundColor(this.tab===index?$r('app.color.accent_soft'):Color.Transparent)
      .onClick(() => { this.tab=index; if (index===2) { setTimeout(() => { this.draw(); },30); } })
  }
  @Builder
  tabLabel(index: number,label: string,icon: Resource) {
    Column({space:4}) {
      SymbolGlyph(icon).fontSize(22).fontColor([this.tab===index?$r('app.color.accent'):$r('app.color.text_secondary')])
      Text(label).fontSize(10).fontColor(this.tab===index?$r('app.color.accent'):$r('app.color.text_secondary'))
    }.height(52).width('100%').justifyContent(FlexAlign.Center)
  }
  @Builder
  pageContent(index: number) {
    Scroll() {
      Column() { if (index===1) { this.scorePanel(); } else if (index===2) { this.calibrationPanel(); } else { this.connectionPanel(); } }
        .width('100%').padding({left:16,right:16,top:8,bottom:150})
    }.align(Alignment.Top).width('100%').height('100%').scrollBar(BarState.Off)
  }
  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor($r('app.color.page_bg')).expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.TOP,SafeAreaEdge.BOTTOM])
      Column({space:6}) {
        Row({space:12}) {
          Text('HmDoMiSo').fontSize(30).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1)
          Button() {
            Row({space:5}) { SymbolGlyph($r('sys.symbol.circle_fill')).fontSize(6).fontColor([this.backendReady?$r('app.color.accent'):$r('app.color.text_secondary')]); Text(this.backendReady?'已就绪':'未连接').fontSize(11).fontColor($r('app.color.text_secondary')); }
          }.height(30).padding({left:10,right:10}).backgroundColor($r('app.color.card_bg')).onClick(() => { this.tab=0; this.tabsController.changeIndex(2); this.preserveMiniBar(); })
        }.width('100%').padding({left:16,right:16,top:8,bottom:6})
        HdsTabs({index:this.tab===1?0:this.tab===2?1:2,controller:this.tabsController,barPosition:BarPosition.End}) {
          TabContent() { this.pageContent(1); }.tabBar(this.tabLabel(1,'曲谱',$r('sys.symbol.music_note_list'))).backgroundColor(Color.Transparent)
          TabContent() { this.pageContent(2); }.tabBar(this.tabLabel(2,'校准',$r('sys.symbol.square_grid_2x2'))).backgroundColor(Color.Transparent)
          TabContent() { this.pageContent(0); }.tabBar(this.tabLabel(0,'设置',$r('sys.symbol.gearshape'))).backgroundColor(Color.Transparent)
        }.layoutWeight(1).width('100%').barHeight(56).barOverlap(true).vertical(false).barPosition(BarPosition.End).barBackgroundColor(Color.Transparent)
          .divider({mode:DividerMode.NONE}).scrollable(false).animationDuration(0)
          .barFloatingStyle({barWidth:{smallWidth:220,mediumWidth:280,largeWidth:360},barSideMargin:16,barBottomMargin:Math.max(6,this.safeBottom),
            lightColor:$r('app.color.accent_soft'),gradientMask:{maskColor:Color.Transparent},thermoCtrl:true,
            systemMaterialEffect:{materialType:hdsMaterial.MaterialType.IMMERSIVE,materialLevel:hdsMaterial.MaterialLevel.ADAPTIVE},
            miniBar:{miniBarBuilder:() => this.playerDock(),miniBarStyle:HdsBarStyle.EXPAND,
              onBarStyleChange:(style: HdsBarStyle) => { this.miniExpanded=style===HdsBarStyle.EXPAND; }}})
          .onChange((index: number) => { this.tab=[1,2,0][index]; this.preserveMiniBar(); if (this.tab===2) { setTimeout(() => { this.draw(); },30); } })
      }.width('100%').height('100%').padding({top:this.safeTop}).expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.TOP,SafeAreaEdge.BOTTOM])
    }.width('100%').height('100%').onAreaChange((oldArea: Area,newArea: Area) => { this.windowWidth=Number(newArea.width); })
      .bindSheet($$this.showPlayer,this.playerDetails(),{height:SheetSize.MEDIUM,backgroundColor:$r('app.color.card_bg')})
  }
}
interface SavedConnection { host: string; port: string; }
interface PlaybackSettings { background: boolean; media: boolean; floatingBall?: boolean; startDelay?: number; }




