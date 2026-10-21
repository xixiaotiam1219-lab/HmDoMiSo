import { AbilityConstant, ConfigurationConstant, UIAbility, Want, Configuration } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, display } from '@kit.ArkUI';
import { SystemPlayback } from '../core/SystemPlayback';
import { ImportedScore, readScoreFile } from '../core/TextScoreImport';

export default class EntryAbility extends UIAbility {
  private incomingVersion: number = 0;
  private mainWindow: window.Window | undefined = undefined;
  private system: SystemPlayback = SystemPlayback.getInstance();
  onCreate(want: Want,launchParam: AbilityConstant.LaunchParam): void {
    this.system.initialize(this.context);
    this.system.dispatch(want); this.openIncomingFile(want);
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
  }
  onNewWant(want: Want,launchParam: AbilityConstant.LaunchParam): void { this.system.dispatch(want); this.openIncomingFile(want); }
  private async openIncomingFile(want: Want): Promise<void> {
    const stream=want.parameters?.['ability.params.stream'];
    let uri=want.uri || ''; let count=0;
    if (typeof stream==='string') { if (!uri) { uri=stream; } count=1; }
    else if (Array.isArray(stream)) {
      const uris=stream as string[]; count=uris.length;
      if (!uri && uris.length && typeof uris[0]==='string') { uri=uris[0]; }
    }
    if (!uri && !count) { return; }
    const version=++this.incomingVersion;
    let result=new ImportedScore();
    try {
      if (count>1) { throw new Error('一次只能打开一份TXT曲谱'); }
      result=await readScoreFile(uri);
    } catch (e) { result.error='打开TXT失败：'+(e as Error).message; }
    if (version!==this.incomingVersion) { return; }
    result.id=Date.now().toString()+'-'+version;
    AppStorage.setOrCreate('externalScoreRequest',JSON.stringify(result));
  }
  onWindowStageCreate(stage: window.WindowStage): void {
    this.mainWindow=stage.getMainWindowSync();
    this.mainWindow.setWindowLayoutFullScreen(true).then(() => { this.updateInsets(); }).catch((e: Error) => { hilog.warn(0xD001,'DoMiSoWindow','%{public}s',e.message); });
    this.mainWindow.on('avoidAreaChange',() => { this.updateInsets(); });
    this.mainWindow.on('windowSizeChange',() => { this.updateInsets(); });
    this.updateBars(this.context.config);
    stage.loadContent('pages/Index',(error) => { if (error.code) { hilog.error(0xD001,'DoMiSoWindow','%{public}s',error.message); } else { this.updateInsets(); } });
  }
  private updateInsets(): void {
    if (!this.mainWindow) { return; }
    const density=display.getDefaultDisplaySync().densityPixels;
    const top=this.mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const navigation=this.mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    AppStorage.setOrCreate('safeTop',top.topRect.height/density);
    AppStorage.setOrCreate('safeBottom',navigation.bottomRect.height/density);
  }
  private updateBars(config: Configuration): void {
    if (!this.mainWindow) { return; }
    const dark=config.colorMode===ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.mainWindow.setWindowSystemBarProperties({statusBarColor:'#00000000',navigationBarColor:'#00000000',
      statusBarContentColor:dark?'#FFFFFF':'#181818',navigationBarContentColor:dark?'#FFFFFF':'#181818'}).catch(() => {});
  }
  onConfigurationUpdate(config: Configuration): void { this.updateBars(config); this.updateInsets(); }
  onWindowStageDestroy(): void {
    this.mainWindow?.off('avoidAreaChange'); this.mainWindow?.off('windowSizeChange'); this.mainWindow=undefined;
  }
  onDestroy(): void { this.system.onStop(); this.system.destroy().catch(() => {}); }
}
