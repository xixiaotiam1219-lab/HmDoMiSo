import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { HdcClient } from './HdcClient';
import { PixelPoint } from './Calibration';
import { utf8, decode } from './HdcProtocol';

type RpcArgument = string | number | boolean | PixelPoint;
interface RpcParams { api: string; this: string | null; args: RpcArgument[]; message_type: string; }
interface RpcRequest { module: string; method: string; params: RpcParams; request_id: string; }
interface RpcError { code: number; message: string; }
interface RpcResponse { result: string | boolean | number | null; exception?: string | RpcError; }
class RpcPending {
  resolve: (response: RpcResponse) => void = () => {};
  reject: (error: Error) => void = () => {};
  timer: number = -1;
}

/** UITest is started only through the user's authenticated local HDC shell. */
export class TouchBackend {
  ready: boolean = false;
  onStatus: (text: string) => void = () => {};
  private tcp: socket.TCPSocket | undefined = undefined;
  private pending: RpcPending | undefined = undefined;
  private buffer: string = '';
  private driver: string = '';
  private sequence: number = 0;
  private tail: Promise<void> = Promise.resolve();
  private matrices: Map<string,string> = new Map();
  async prepare(hdc: HdcClient, context: common.UIAbilityContext): Promise<void> {
    await this.close();
    if (!hdc.ready) { throw new Error('请先连接本机无线调试'); }
    this.onStatus('校验手机端触摸服务…');
    const hash='950df1c67e0e611808c05a6f85589e93488278a5e4e20b6573665b247fe2da27';
    const remote=await hdc.shell('sha256sum /data/local/tmp/agent.so 2>/dev/null');
    if (remote.toLowerCase().indexOf(hash)<0) {
      this.onStatus('首次安装触摸服务，约需数秒…');
      const asset=await context.resourceManager.getRawFileContent('uitest_agent.so');
      const base64=new util.Base64Helper().encodeToStringSync(asset);
      await hdc.shell('umask 077; : > /data/local/tmp/domiso_agent.b64');
      for (let i=0;i<base64.length;i+=2800) {
        await hdc.shell("printf '%s' '"+base64.slice(i,i+2800)+"' >> /data/local/tmp/domiso_agent.b64");
      }
      const result=await hdc.shell('base64 -d /data/local/tmp/domiso_agent.b64 > /data/local/tmp/agent.so && chmod 700 /data/local/tmp/agent.so && sha256sum /data/local/tmp/agent.so; rm -f /data/local/tmp/domiso_agent.b64');
      if (result.toLowerCase().indexOf(hash)<0) { throw new Error('触摸服务文件校验失败'); }
    }
    await hdc.shell('uitest start-daemon singleness');
    this.onStatus('连接本机UITest触摸服务…');
    this.tcp=socket.constructTCPSocketInstance();
    this.tcp.on('message',(info: socket.SocketMessageInfo) => { this.receive(decode(new Uint8Array(info.message))); });
    this.tcp.on('error',(e) => { this.fail(new Error(`触摸服务TCP错误 ${e.code}`)); });
    this.tcp.on('close',() => { this.fail(new Error('触摸服务已断开')); });
    await this.tcp.connect({address:{address:'127.0.0.1',port:8012,family:1},timeout:5000});
    await this.tcp.setExtraOptions({TCPNoDelay:true});
    const response=await this.call('Driver.create',[],null);
    if (typeof response.result!=='string') { throw new Error('无法创建触摸Driver'); }
    this.driver=response.result; this.ready=true; this.onStatus('触摸后端已就绪');
  }
  private receive(text: string): void {
    this.buffer+=text;
    if (this.buffer.length>1000000) { this.fail(new Error('触摸服务响应过长')); return; }
    let depth=0; let quoted=false; let escaped=false; let end=-1;
    for (let i=0;i<this.buffer.length;i++) {
      const ch=this.buffer[i];
      if (quoted) { if (escaped) { escaped=false; } else if (ch==='\\') { escaped=true; } else if (ch==='"') { quoted=false; } }
      else if (ch==='"') { quoted=true; } else if (ch==='{' || ch==='[') { depth++; }
      else if (ch==='}' || ch===']') { depth--; if (depth===0) { end=i+1; break; } }
    }
    if (end<0) { return; }
    const payload=this.buffer.slice(0,end); this.buffer=this.buffer.slice(end).trimStart();
    const pending=this.pending; if (!pending) { return; } this.pending=undefined; clearTimeout(pending.timer);
    try {
      const response=JSON.parse(payload) as RpcResponse;
      if (response.exception) { pending.reject(new Error('触摸调用失败：'+JSON.stringify(response.exception))); }
      else { pending.resolve(response); }
    } catch (e) { pending.reject(e as Error); }
  }
  call(api: string,args: RpcArgument[] = [],target: string | null = this.driver): Promise<RpcResponse> {
    const run=this.tail.then(() => this.request(api,args,target));
    this.tail=run.then(() => {},() => {}); return run;
  }
  private async request(api: string,args: RpcArgument[],target: string | null): Promise<RpcResponse> {
    const tcp=this.tcp; if (!tcp) { throw new Error('触摸服务未连接'); }
    const p=new RpcPending(); const promise=new Promise<RpcResponse>((resolve,reject) => { p.resolve=resolve; p.reject=reject; });
    this.pending=p; p.timer=setTimeout(() => { this.fail(new Error('触摸服务响应超时，已停止')); },8000);
    const params: RpcParams={api:api,this:target,args:args,message_type:'hypium'};
    const message: RpcRequest={module:'com.ohos.devicetest.hypiumApiHelper',method:'callHypiumApi',params:params,request_id:String(++this.sequence)};
    try { await tcp.send({data:utf8(JSON.stringify(message)+'\n').buffer as ArrayBuffer}); }
    catch (e) { this.fail(e as Error); }
    return promise;
  }
  async matrix(pitches: number[],points: PixelPoint[]): Promise<string> {
    const key=pitches.join(',')+'|'+points.map((p: PixelPoint) => Math.round(p.x)+':'+Math.round(p.y)).join(','); const existing=this.matrices.get(key); if (existing) { return existing; }
    if (!pitches.length || pitches.length>10 || pitches.length!==points.length) { throw new Error('触摸组必须为1至10指'); }
    const response=await this.call('PointerMatrix.create',[points.length,2],null);
    if (typeof response.result!=='string') { throw new Error('无法创建和弦矩阵'); }
    const matrix=response.result;
    for (let finger=0;finger<points.length;finger++) {
      for (let step=0;step<2;step++) {
        // UITest visits fingers in order: only the last finger holds, so all go down together.
        const hold=finger===points.length-1 && step===0 ? 35 : 0;
        const p=new PixelPoint(Math.round(points[finger].x)+hold*65536,Math.round(points[finger].y));
        await this.call('PointerMatrix.setPoint',[finger,step,p],matrix);
      }
    }
    this.matrices.set(key,matrix); return matrix;
  }
  async inject(matrix: string): Promise<void> {
    if (!this.ready) { throw new Error('触摸后端未就绪'); }
    const response=await this.call('Driver.injectMultiPointerAction',[matrix,2000]);
    if (response.result!==true) { throw new Error('系统未成功注入触摸'); }
  }
  private fail(error: Error): void {
    this.ready=false; const p=this.pending; this.pending=undefined;
    if (p) { clearTimeout(p.timer); p.reject(error); } this.onStatus(error.message);
  }
  async close(): Promise<void> {
    this.fail(new Error('触摸服务未连接')); this.matrices.clear(); this.buffer=''; this.driver='';
    const tcp=this.tcp; this.tcp=undefined;
    if (tcp) { tcp.off('close'); tcp.off('message'); tcp.off('error'); await tcp.close().catch(() => {}); }
  }
}

