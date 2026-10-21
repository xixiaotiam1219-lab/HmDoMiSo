// Run with Node and set HMDOMISO_TYPESCRIPT to the SDK typescript.js if needed.
// Optional arguments: <project-root> <private-score.txt>. Private scores are never copied.
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const ts = require(process.env.HMDOMISO_TYPESCRIPT || 'typescript');
const root = path.resolve(process.argv[2] || path.join(__dirname, '..'));
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/core/Score.ets'), 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText;
const moduleObject = { exports: {} };
vm.runInNewContext('(function(exports){' + compiled + '\n})')(moduleObject.exports);
const { ScoreParser, scoreToCKey } = moduleObject.exports;
let checks = 0;
function parse(text) {
  const score = new ScoreParser().parse(text);
  assert.equal(score.errors.length, 0, score.errors.join('\n'));
  checks++;
  return score;
}
function timing(score, expected) {
  assert.deepEqual(Array.from(score.events, n => [n.pitch, n.start, n.end]), expected);
  checks++;
}
function rejects(text, message) {
  const score = new ScoreParser().parse(text);
  assert(score.errors.some(e => e.includes(message)), score.errors.join('\n'));
  checks++;
}

const compact = parse('1=C\nbpm75\n(+3/ -2/)|(+1/ 3/ -6/ )_(+2/ -4/)');
const spaced = parse('1=C\nbpm=75\n( +3/ -2/ ) | ( +1/ 3/ -6/ ) ( +2/ -4/ )');
assert.deepEqual(compact, spaced);
assert.equal(compact.duration, 1200);
assert.deepEqual(Array.from(compact.bpms), [75]);
assert.equal(compact.events.length, 7);
checks++;

const arp = parse('bpm=75\n-5 ~7 ~5 0');
timing(arp, [[55, 0, 800], [71, 40, 800], [67, 80, 800]]);
assert.equal(arp.duration, 1600);
const varying = parse('bpm75\n1 ~3/ ~5/ 2');
timing(varying, [[60, 0, 800], [64, 40, 400], [67, 80, 400], [62, 400, 1200]]);
const separated = parse('bpm=120\n(1/ 3/)_(2/ 4/)');
timing(separated, [[60, 0, 250], [64, 0, 250], [62, 250, 500], [65, 250, 500]]);
timing(parse('bpm=120\n(1/ 3/) ~5/ ~7/'), [[60, 0, 250], [64, 0, 250], [67, 40, 250], [71, 80, 250]]);
timing(parse('bpm=120\n(~1 ~3 ~5)/'), [[60, 0, 250], [64, 0, 250], [67, 0, 250]]);
timing(parse('bpm=120\n{1 2/ 3/}/'), [[60, 0, 125], [62, 125, 187.5], [64, 187.5, 250]]);
timing(parse('bpm=120\n1 |\n~3\n~5'), [[60, 0, 500], [64, 40, 500], [67, 80, 500]]);
timing(parse('bpm=120\n1 ~3 ~5 (2/ 4/) ~6/'), [[60, 0, 500], [64, 40, 500], [67, 80, 500], [62, 500, 750], [65, 500, 750], [69, 540, 750]]);
timing(parse('bpm=120\n1 0\nrollback=2\n(-1 -3 -5)'), [[48, 0, 500], [52, 0, 500], [55, 0, 500], [60, 0, 500]]);
timing(parse('bpm=120\n3 - - 0/ -5/'), [[64, 0, 1500], [55, 1750, 2000]]);
timing(parse('bpm=120\n1 . 2 /'), [[60, 0, 750], [62, 750, 1000]]);
const lyrics = parse('bpm=120\n1 2\n测试歌词\n---\n3 - 0');
timing(lyrics, [[60, 0, 500], [62, 500, 1000], [64, 1000, 2000]]);
assert.equal(lyrics.duration, 2500);
assert.equal(lyrics.warnings.length, 1);
const metadata = '说明 1=B\r\n======\r\n1=B\r\nbpm=120\r\n-6. 1/ +6 -\r\n测试歌词';
const transposed = scoreToCKey(metadata);
assert(transposed.startsWith('说明 1=B\n======\n1=C\n'));
assert.equal(new ScoreParser().parse(metadata).errors.length, 1, 'aggregate unsupported pitches');
const playable = parse(transposed);
assert.equal(playable.unsupportedPitches.length, 0);
assert.equal(playable.events.length, 3);
checks++;

rejects('~1', '琶音前需要');
rejects('bpm=599\n1 ~2//', '琶音时值不足');
rejects('bpm=120\n1\nrollback=1\n~3', '琶音前需要');
rejects('bpm75 bpm=90\n1', '一行只能有一个');
rejects('bpm75x\n1', '无法识别');
rejects('(1 3}', '括号不匹配');
rejects('(1 (3 5))', '不支持嵌套组');
rejects('(1\n3)', '同一行闭合');
rejects('(1 | 3)', '组内不能有小节线');
rejects('1#', '21键');
rejects('bpm30\n1', 'BPM应为');
rejects('bpm600\n1', 'BPM应为');
rejects('1 错误2 3', '无法识别');
rejects('bpm=120\n-', '无法识别');
const reuse = new ScoreParser();
reuse.parse('1 ~3');
assert(reuse.parse('~5').errors.some(e => e.includes('琶音前需要')));
checks++;

let privateResult;
if (process.argv[3]) {
  const text = fs.readFileSync(process.argv[3], 'utf8');
  const score = parse(text);
  // Independently count written non-rest notes; catch notes lost around tight delimiters.
  const body = text.slice(text.indexOf('======'));
  const tokens = body.replace(/[(){}|_]/g, ' ').split(/\s+/);
  const writtenNotes = tokens.filter(t => /^~?(-*|\+*)[1-7][#bB]?[\/.-]*$/.test(t)).length;
  assert.equal(score.events.length, writtenNotes);
  assert.deepEqual(Array.from(score.bpms), [75]);
  assert(score.events.every(n => Number.isFinite(n.start) && n.end > n.start && n.start >= 0));
  privateResult = { notes: score.events.length, groups: score.groups.length, durationMs: score.duration, bpm: Array.from(score.bpms), warnings: Array.from(score.warnings) };
  checks++;
}
console.log(JSON.stringify({ checks, privateScore: privateResult }));
