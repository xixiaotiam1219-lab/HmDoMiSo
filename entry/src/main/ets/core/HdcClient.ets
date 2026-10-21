import { socket } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Handshake, PacketReader, HdcPacket, packet, utf8, decode } from './HdcProtocol';

class ShellPending {
  output: string = '';
  resolve: (value: string) => void = () => {};
  reject: (reason: Error) => void = () => {};
  timer: number = -1;
}
export class HdcClient {
  ready: boolean = false;
  status: string = '未连接';
  onStatus: (value: string) => void = () => {};
  private tcp: socket.TCPSocket | undefined = undefined;
  private reader: PacketReader = new PacketReader();
  private key: cryptoFramework.KeyPair | undefined = undefined;
  private authResolve: () => void = () => {};
  private authReject: (e: Error) => void = () => {};
  private authTimer: number = -1;
  private channel: number = 100;
  private shells: Map<number, ShellPending> = new Map();
  private incoming: Promise<void> = Promise.resolve();
  private update(value: string): void { this.status=value; this.onStatus(value); }
  private async identity(filesDir: string): Promise<void> {
    const gen=cryptoFramework.createAsyKeyGenerator('RSA3072'); const b64=new util.Base64Helper();
    const path=filesDir+'/hdc_identity.json';
    if (fs.accessSync(path)) {
      const saved = JSON.parse(fs.readTextSync(path)) as IdentityData;
      this.key=await gen.convertKey({data:b64.decodeSync(saved.publicKey)},{data:b64.decodeSync(saved.privateKey)});
    } else {
      this.key=await gen.generateKeyPair(); const saved: IdentityData = {
        publicKey:b64.encodeToStringSync(this.key.pubKey.getEncoded().data),
        privateKey:b64.encodeToStringSync(this.key.priKey.getEncoded().data)
      };
      const file=fs.openSync(path,fs.OpenMode.CREATE|fs.OpenMode.WRITE_ONLY);
      try { fs.writeSync(file.fd,JSON.stringify(saved)); } finally { fs.closeSync(file); }
    }
  }
  async connect(host: string, port: number, filesDir: string): Promise<void> {
    await this.close();
    if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(host) || host.split('.').some((s: string) => Number(s)>255) || port<1 || port>65535 || !Number.isInteger(port)) {
      throw new Error('请输入手机无线调试显示的IPv4地址与端口');
    }
    this.update('生成本安装独立调试身份…'); await this.identity(filesDir);
    this.reader=new PacketReader(); this.tcp=socket.constructTCPSocketInstance(); this.incoming=Promise.resolve();
    this.tcp.on('message',(info: socket.SocketMessageInfo) => {
      this.incoming=this.incoming.then(async () => {
        for (const p of this.reader.push(new Uint8Array(info.message))) { await this.receive(p); }
      }).catch((e: Error) => { this.fail(e); });
    });
    this.tcp.on('close',() => { this.fail(new Error('无线调试连接已断开')); });
    this.tcp.on('error',(e) => { this.fail(new Error(`TCP错误 ${e.code}`)); });
    this.update('连接手机无线调试daemon…');
    await this.tcp.connect({address:{address:host,port:port,family:1},timeout:8000});
    await this.tcp.setExtraOptions({TCPNoDelay:true,keepAlive:true});
    const auth = new Promise<void>((resolve,reject) => {
      this.authResolve=resolve; this.authReject=reject;
      this.authTimer=setTimeout(() => { this.fail(new Error('认证超时；请检查系统调试授权弹窗、地址和端口')); },90000);
    });
    const h=new Handshake(); h.session=Math.floor(Math.random()*1000000000)+1; h.connectKey=host+':'+port;
    h.buffer='authtype'.padEnd(16,' ')+'1'.padEnd(16,' ')+'1';
    await this.send(0,1,h.pack()); await auth;
    const check=await this.shell('echo DOMISO_HDC_OK');
    if (check.indexOf('DOMISO_HDC_OK')<0) { await this.close(); throw new Error('已认证但shell探测未通过'); }
    this.update('已认证 · 手机内HDC shell可用');
  }
  private async receive(p: HdcPacket): Promise<void> {
    if (p.command===1) {
      const h=Handshake.unpack(p.data);
      if (h.banner!=='OHOS HDC') { throw new Error('HDC握手banner不匹配'); }
      if (h.auth===3) {
        if (!this.key) { throw new Error('本地身份未就绪'); }
        if (h.buffer.indexOf('authtype')<0) { throw new Error('daemon不支持RSA3072/SHA512认证'); }
        const encoded=new util.Base64Helper().encodeToStringSync(this.key.pubKey.getEncoded().data);
        h.buffer='GenshinDoMiSo-phone\f-----BEGIN PUBLIC KEY-----\n'+(encoded.match(/.{1,64}/g)||[]).join('\n')+'\n-----END PUBLIC KEY-----\n';
        this.update('请在系统弹窗允许 GenshinDoMiSo-phone 调试身份'); await this.send(0,1,h.pack());
      } else if (h.auth===2) {
        if (!this.key) { throw new Error('本地身份未就绪'); }
        const sign=cryptoFramework.createSign('RSA3072|PSS|SHA512|MGF1_SHA512');
        await sign.init(this.key.priKey); sign.setSignSpec(cryptoFramework.SignSpecItem.PSS_SALT_LEN_NUM,64);
        const signature=await sign.sign({data:utf8(h.buffer)});
        h.buffer=new util.Base64Helper().encodeToStringSync(signature.data); await this.send(0,1,h.pack());
      } else if (h.auth===4) {
        if (h.buffer.indexOf('UNAUTHORIZED')>=0 || h.buffer.indexOf('[E000')>=0) { throw new Error('系统未授权调试：'+h.buffer); }
        clearTimeout(this.authTimer); this.ready=true; this.update('调试身份认证通过'); this.authResolve();
      } else if (h.auth===5 || h.auth===6) { throw new Error(`daemon认证方式${h.auth}尚不支持：`+h.buffer); }
      return;
    }
    const pending=this.shells.get(p.channel);
    if (!pending) { return; }
    if (p.command===2) {
      this.shells.delete(p.channel); clearTimeout(pending.timer); pending.resolve(pending.output);
      if (p.data[0]>0) { await this.send(p.channel,2,new Uint8Array([p.data[0]-1])); }
    } else if (p.command===10 || p.command===2001) {
      pending.output+=decode(p.data); if (pending.output.length>2000000) { throw new Error('shell输出过长'); }
    } else if (p.command===9) { pending.output+=decode(p.data.slice(1)); }
  }
  private async send(channel: number, command: number, data: Uint8Array): Promise<void> {
    if (!this.tcp) { throw new Error('HDC未连接'); }
    await this.tcp.send({data:packet(channel,command,data).buffer as ArrayBuffer});
  }
  async shell(command: string, timeout: number = 15000): Promise<string> {
    if (!this.ready) { throw new Error('请先完成手机无线调试认证'); }
    const channel=++this.channel; const pending=new ShellPending();
    const promise=new Promise<string>((resolve,reject) => { pending.resolve=resolve; pending.reject=reject; });
    pending.timer=setTimeout(() => { this.shells.delete(channel); pending.reject(new Error('shell执行超时')); this.send(channel,2,new Uint8Array([1])).catch(() => {}); },timeout);
    this.shells.set(channel,pending);
    try { await this.send(channel,1001,utf8(command+'\0')); } catch (e) { clearTimeout(pending.timer); this.shells.delete(channel); pending.reject(e as Error); }
    return promise;
  }
  private fail(e: Error): void {
    clearTimeout(this.authTimer); this.ready=false; this.update(e.message); this.authReject(e);
    for (const p of this.shells.values()) { clearTimeout(p.timer); p.reject(e); } this.shells.clear();
  }
  async close(): Promise<void> {
    this.fail(new Error('未连接')); const old=this.tcp; this.tcp=undefined;
    if (old) { old.off('close'); old.off('error'); old.off('message'); await old.close().catch(() => {}); }
  }
}
interface IdentityData { publicKey: string; privateKey: string; }
