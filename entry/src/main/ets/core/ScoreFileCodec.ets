import { util } from '@kit.ArkTS';

// DoMiSo-Universal Encrypt.ahk: 16-byte header, UTF-16LE description, XOR score.
// Original format/algorithm by Nigh (MIT); see THIRD_PARTY_NOTICES.md.
const DMS_MAGIC: number[] = [0x80, 0xFE, 0x64, 0x6F, 0x6D, 0x69, 0x73, 0x6F];

function decodeText(bytes: Uint8Array, encoding: string): string {
  return util.TextDecoder.create(encoding, {fatal: true}).decodeToString(bytes)
    .replace(/^\uFEFF/, '').replace(/\u0000+$/, '');
}

export function decodeScoreBytes(bytes: Uint8Array): string {
  if (!bytes.length) { throw new Error('曲谱文件为空'); }
  if (bytes.length > 2000000) { throw new Error('曲谱文件不能超过2MB'); }
  let text = '';
  if (bytes.length >= 2 && bytes[0] === 0x80 && bytes[1] === 0xFE) {
    if (bytes.length < 16 || DMS_MAGIC.some((value: number, i: number) => bytes[i] !== value)) {
      throw new Error('DMS文件头无效或不完整');
    }
    const plainLength = bytes[12] | (bytes[13] << 8);
    const scoreLength = bytes[14] | (bytes[15] << 8);
    if (scoreLength === 0 || plainLength % 2 !== 0 || scoreLength % 2 !== 0 ||
      16 + plainLength + scoreLength !== bytes.length) { throw new Error('DMS数据长度无效或文件已损坏'); }
    const key: number[] = [0xAA, 0x55, 0xDE, 0xAD];
    for (let i = 0; i < plainLength; i++) { key[i % 4] ^= bytes[16 + i]; }
    for (let i = 0; i < 4; i++) { key[i] ^= bytes[8 + i]; }
    const scoreBytes = new Uint8Array(scoreLength);
    for (let i = 0; i < scoreLength; i++) { scoreBytes[i] = bytes[16 + plainLength + i] ^ key[i % 4]; }
    let description = '';
    try {
      description = decodeText(bytes.subarray(16, 16 + plainLength), 'utf-16le');
      text = decodeText(scoreBytes, 'utf-16le');
    } catch (e) { throw new Error('DMS文本解码失败，请检查文件是否完整'); }
    if (!text.trim()) { throw new Error('DMS文件没有曲谱内容'); }
    if (description.trim()) { text = description + '\n======\n' + text; }
  } else {
    let encoding = 'utf-8';
    if (bytes.length >= 2 && bytes[0] === 0xFF && bytes[1] === 0xFE) { encoding = 'utf-16le'; }
    else if (bytes.length >= 2 && bytes[0] === 0xFE && bytes[1] === 0xFF) { encoding = 'utf-16be'; }
    try { text = decodeText(bytes, encoding); }
    catch (e) { throw new Error('无法解码曲谱，请使用UTF-8/带BOM的UTF-16文本或原项目DMS文件'); }
    if (!text.trim()) { throw new Error('文件没有曲谱内容'); }
  }
  return text;
}
