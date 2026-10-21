// Clean-room wire implementation based on OpenHarmony developtools_hdc (Apache-2.0).
import { util } from '@kit.ArkTS';
export function utf8(value: string): Uint8Array { return value.length === 0 ? new Uint8Array(0) : new util.TextEncoder().encodeInto(value); }
export function decode(value: Uint8Array): string { return util.TextDecoder.create('utf-8').decodeToString(value); }
export function concat(parts: Uint8Array[]): Uint8Array {
  const result = new Uint8Array(parts.reduce((sum: number, p: Uint8Array) => sum+p.length, 0));
  let at = 0; for (const p of parts) { result.set(p, at); at += p.length; } return result;
}
function vint(value: number): number[] {
  const result: number[] = [];
  do { const next = Math.floor(value/128); result.push(value%128 + (next ? 128 : 0)); value = next; } while (value);
  return result;
}
export function fieldInt(tag: number, value: number): Uint8Array { return new Uint8Array([tag*8, ...vint(value)]); }
export function fieldString(tag: number, value: string): Uint8Array {
  const data = utf8(value); return concat([new Uint8Array([tag*8+2, ...vint(data.length)]), data]);
}
export class ProtoField { tag: number = 0; value: number = 0; data: Uint8Array = new Uint8Array(); }
export function readFields(data: Uint8Array): ProtoField[] {
  let pos = 0; const result: ProtoField[] = [];
  const read = (): number => {
    let n = 0; let multiplier = 1;
    for (let i = 0; i < 8; i++) {
      if (pos >= data.length) { throw new Error('截断的HDC字段'); }
      const b = data[pos++]; n += (b%128)*multiplier; if (b < 128) { return n; } multiplier *= 128;
    }
    throw new Error('HDC字段过长');
  };
  while (pos < data.length) {
    const key = read(); const f = new ProtoField(); f.tag = Math.floor(key/8);
    if (key%8 === 0) { f.value = read(); }
    else if (key%8 === 2) { const size = read(); if (size > data.length-pos) { throw new Error('HDC字段长度越界'); } f.data = data.slice(pos,pos+size); pos += size; }
    else { throw new Error('不支持的HDC字段编码'); }
    result.push(f);
  }
  return result;
}
export class Handshake {
  banner: string = 'OHOS HDC'; auth: number = 0; session: number = 0;
  connectKey: string = ''; buffer: string = ''; version: string = 'Ver: 3.2.0e';
  pack(): Uint8Array {
    return concat([fieldString(1,this.banner),fieldInt(2,this.auth),fieldInt(3,this.session),
      fieldString(4,this.connectKey),fieldString(5,this.buffer),fieldString(6,this.version)]);
  }
  static unpack(data: Uint8Array): Handshake {
    const h = new Handshake();
    for (const f of readFields(data)) {
      switch (f.tag) {
        case 1: h.banner = decode(f.data); break; case 2: h.auth = f.value; break;
        case 3: h.session = f.value; break; case 4: h.connectKey = decode(f.data); break;
        case 5: h.buffer = decode(f.data); break; case 6: h.version = decode(f.data); break;
      }
    }
    return h;
  }
}
export class HdcPacket { channel: number = 0; command: number = 0; data: Uint8Array = new Uint8Array(); }
export function packet(channel: number, command: number, data: Uint8Array): Uint8Array {
  const protect = concat([fieldInt(1,channel),fieldInt(2,command),fieldInt(3,0),fieldInt(4,9)]);
  const head = new Uint8Array(11); head[0]=72; head[1]=87; head[4]=1;
  const view = new DataView(head.buffer); view.setUint16(5,protect.length,false); view.setUint32(7,data.length,false);
  return concat([head,protect,data]);
}
export class PacketReader {
  private pending: Uint8Array = new Uint8Array();
  push(chunk: Uint8Array): HdcPacket[] {
    this.pending = concat([this.pending,chunk]); const result: HdcPacket[] = [];
    while (this.pending.length >= 11) {
      const b = this.pending;
      if (b[0] !== 72 || b[1] !== 87 || b[4] !== 1) { throw new Error('daemon返回了非HDC数据'); }
      const v = new DataView(b.buffer,b.byteOffset,b.byteLength); const hs=v.getUint16(5,false); const ds=v.getUint32(7,false);
      if (hs > 1024 || ds > 4*1024*1024) { throw new Error('HDC包超出限制'); }
      if (b.length < 11+hs+ds) { break; }
      const p = new HdcPacket(); let valid = false; let checksum = 0;
      for (const f of readFields(b.slice(11,11+hs))) {
        if (f.tag === 1) { p.channel = f.value; } else if (f.tag === 2) { p.command = f.value; }
        else if (f.tag === 3) { checksum = f.value; } else if (f.tag === 4) { valid = f.value === 9; }
      }
      if (!valid) { throw new Error('HDC保护字段错误'); }
      p.data=b.slice(11+hs,11+hs+ds);
      if (checksum && p.data.reduce((a: number, n: number) => (a+n)%256,0) !== checksum) { throw new Error('HDC校验和错误'); }
      result.push(p); this.pending=b.slice(11+hs+ds);
    }
    return result;
  }
}

