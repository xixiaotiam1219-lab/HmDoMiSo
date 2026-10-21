import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { decodeScoreBytes } from './ScoreFileCodec';

export class ImportedScore {
  id: string = '';
  title: string = '';
  text: string = '';
  error: string = '';
}

/** Reads only the single URI granted by the picker or incoming Want. */
export async function readScoreFile(uri: string): Promise<ImportedScore> {
  if (!uri.startsWith('file://')) { throw new Error('仅支持应用授权的本地TXT/DMS曲谱文件'); }
  const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
  try {
    const size = (await fs.stat(file.fd)).size;
    if (size <= 0) { throw new Error('曲谱文件为空'); }
    if (size > 2000000) { throw new Error('曲谱文件不能超过2MB'); }
    const buffer = new ArrayBuffer(size);
    const count = await fs.read(file.fd, buffer);
    if (count !== size) { throw new Error('曲谱读取不完整，请重新打开文件'); }
    const text = decodeScoreBytes(new Uint8Array(buffer, 0, count));
    const result = new ImportedScore();
    let name = new fileUri.FileUri(uri).name;
    try { name = decodeURIComponent(name); } catch (e) { /* Keep the provider's original filename. */ }
    result.title = name.replace(/\.(txt|dms)$/i, '') || '导入曲谱'; result.text = text;
    return result;
  } finally { await fs.close(file); }
}
