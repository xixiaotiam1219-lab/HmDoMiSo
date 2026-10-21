// HMDOMISO_TYPESCRIPT may point at the DevEco SDK's typescript.js.
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const ts = require(process.env.HMDOMISO_TYPESCRIPT || 'typescript');
const root = path.resolve(process.argv[2] || path.join(__dirname, '..'));
const cache = {};
const files = new Map();
let closed = 0;
let shortRead = false;
const mocks = {
  '@kit.ArkTS': { util: { TextDecoder: { create: (encoding, options) => ({
    decodeToString: bytes => new TextDecoder(encoding, options).decode(bytes)
  }) } } },
  '@kit.CoreFileKit': {
    fileIo: {
      OpenMode: { READ_ONLY: 0 },
      open: async uri => { if (!files.has(uri)) throw Error('File missing'); return { fd: uri }; },
      stat: async fd => ({ size: files.get(fd).length }),
      read: async (fd, buffer) => { const data = files.get(fd); new Uint8Array(buffer).set(data); return shortRead ? data.length - 1 : data.length; },
      close: async () => { closed++; }
    },
    fileUri: { FileUri: class { constructor(uri) { this.name = uri.split('/').pop(); } } }
  }
};
function load(name) {
  if (cache[name]) return cache[name];
  const code = ts.transpileModule(fs.readFileSync(path.join(root, 'entry/src/main/ets/core', name + '.ets'), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  vm.runInNewContext('(function(require,module,exports){' + code + '\n})')(
    name => mocks[name] || load(name.replace('./', '')), module, module.exports
  );
  cache[name] = module.exports;
  return module.exports;
}
// Fixed vector derived independently from the Unicode AHK file layout:
// description "说明\r\n", score "bpm75\r\n1 ~3 ~5\r\n", header random 01 02 03 04.
const dms = Buffer.from('80fe646f6d69736f0102030408002000f48b0e660d000a0030dca9cf3fdceecf67dcd4cf58dce8cf72dca7cf61dcf9cf2cdceccf5fdcd3cf', 'hex');
const expected = '说明\r\n\n======\nbpm75\r\n1 ~3 ~5\r\n';
const { decodeScoreBytes } = load('ScoreFileCodec');
const { ScoreParser } = load('Score');
const original = Buffer.from(dms);
assert.equal(decodeScoreBytes(dms), expected);
assert.deepEqual(dms, original, 'decoder does not mutate source bytes');
const score = new ScoreParser().parse(decodeScoreBytes(dms));
assert.equal(score.errors.length, 0);
assert.equal(score.events.length, 3);
assert.deepEqual(Array.from(score.events, e => [e.start, e.end]), [[0, 800], [40, 800], [80, 800]]);
assert.equal(decodeScoreBytes(Buffer.from('bpm=120\n1 2 3')), 'bpm=120\n1 2 3');
assert.equal(decodeScoreBytes(Buffer.from('\uFEFF1 2 3')), '1 2 3');
const utf16 = Buffer.from('\uFEFF1 2 3', 'utf16le');
assert.equal(decodeScoreBytes(utf16), '1 2 3');
const bigEndian = Buffer.from(utf16); bigEndian.swap16();
assert.equal(decodeScoreBytes(bigEndian), '1 2 3');

assert.throws(() => decodeScoreBytes(dms.subarray(0, 10)), /DMS文件头/);
assert.throws(() => decodeScoreBytes(dms.subarray(0, dms.length - 1)), /DMS数据长度/);
assert.throws(() => decodeScoreBytes(Buffer.concat([dms, Buffer.from([0])])), /DMS数据长度/);
const badMagic = Buffer.from(dms); badMagic[2] = 0;
assert.throws(() => decodeScoreBytes(badMagic), /DMS文件头/);
const oddLength = Buffer.from(dms); oddLength[12] = 7; oddLength[14] = 33;
assert.throws(() => decodeScoreBytes(oddLength), /DMS数据长度/);
const noScore = Buffer.from(dms.subarray(0, 24)); noScore[14] = 0;
assert.throws(() => decodeScoreBytes(noScore), /DMS数据长度/);
assert.throws(() => decodeScoreBytes(Buffer.from([0xff, 0xc0])), /无法解码/);
assert.throws(() => decodeScoreBytes(Buffer.from(' \n ')), /没有曲谱内容/);
assert.throws(() => decodeScoreBytes(new Uint8Array()), /文件为空/);
assert.throws(() => decodeScoreBytes(new Uint8Array(2000001)), /2MB/);

(async () => {
  const { readScoreFile } = load('TextScoreImport');
  const uri = 'file://docs/Download/%E6%B5%8B%E8%AF%95.DMS'; files.set(uri, dms);
  const imported = await readScoreFile(uri);
  assert.equal(imported.title, '测试'); assert.equal(imported.text, expected); assert.equal(closed, 1);
  const plainUri = 'file://docs/Download/plain.dms'; files.set(plainUri, Buffer.from('1 2 3'));
  assert.equal((await readScoreFile(plainUri)).text, '1 2 3'); assert.equal(closed, 2);
  const broken = 'file://docs/Download/broken.dms'; files.set(broken, badMagic);
  await assert.rejects(readScoreFile(broken), /DMS文件头/); assert.equal(closed, 3);
  await assert.rejects(readScoreFile('https://example.test/score.dms'), /授权的本地/); assert.equal(closed, 3);
  shortRead = true; await assert.rejects(readScoreFile(uri), /读取不完整/); assert.equal(closed, 4); shortRead = false;
  console.log(JSON.stringify({ dms: 'fixed Unicode AHK vector, description preserved, arpeggio timing passed', text: 'UTF-8, UTF-8 BOM, UTF-16LE/BE BOM passed', validation: 'bad/truncated header, length, encoding, empty and oversized files rejected', import: 'binary/plain DMS, title, granted URI, short read and close-on-error passed' }));
})().catch(e => { console.error(e); process.exitCode = 1; });
