// 譜面の読み書きの確認 (node test/roundtrip.js [確認したい譜面.json ...])
//   1) いろいろな要素を入れた譜面を作って、書き出す → 読む → 書き出す で同じになるか
//   2) 引数で渡した譜面を読んで書き出し、もとの JSON と中身 (キーの順番以外) が同じか
//      (違いは curve / ease の空の [] が足されることだけのはず)
'use strict';
const fs = require('fs');
const F = require('../renderer/js/format.js');
const B = F.Beat.make;
let failed = 0;
function check(name, ok, info) {
  console.log((ok ? 'ok   ' : 'NG   ') + name + (info ? '  ' + info : ''));
  if (!ok) failed++;
}

const c = F.newChart('テスト "曲"', 180, 1);
c.bx.mystery = { z: 1, a: [1, 2.5] };
c.bx.subtitle = '-short ver.-';
c.bx.part = [{ LPB: 4, num: 8, parts: [{ LPB: 4, num: 16, parts: [] }] }];
c.bx.lyrics = [{ LPB: 4, num: 8, text: '歌詞', parts: [{ LPB: 4, num: 12, parts: [] }] }];
c.times.push({ beat: B(8), bpm: 90.5 });
c.speeds.push({ beat: B(3, 2), value: 0.75 });
const s = F.makeNote(B(1), F.centerX(1), 72, null, [{ beat: B(1, 2), x: F.centerX(4) - F.centerX(1) }, { beat: B(1), x: F.centerX(6) - F.centerX(1) }]);
s.extra.bxHead = 0; s.extra.bxCurve = true; s.extra.bxEase = [1, 2]; s.extra.bxSpeed = 1.25;
const h = F.makeNote(B(1), F.centerX(1), 77, null); h.extra.bxHeadOf = s.id;
const s2 = F.makeNote(B(2), F.centerX(3), 72, null, [{ beat: B(1, 3), x: 0 }]); s2.extra.bxHead = 4; s2.extra.bxDummy = true;
F.setAtBeats(s2, 'bxAppear', [B(1), B(3, 2)]);
const r = F.makeNote(B(2), F.centerX(3), 77, 3);
const t = F.makeNote(B(5, 3), F.centerX(6), 77, null); t.extra.bxType = 7;
const w = F.makeNote(B(3), F.centerX(5), 72, 4); F.setAtBeats(w, 'bxVanish', [B(4)]);
c.notes.push(s, h, s2, r, t, w, F.makeNote(B(3), F.centerX(0), 77, null), F.makeNote(B(3), F.centerX(0), 77, null));
const o1 = F.stringify(c);
const o2 = F.stringify(F.parse(o1));
const o3 = F.stringify(F.parse(o2));
check('作った譜面: 書き出し → 読む → 書き出し が同じ', o1 === o2 && o2 === o3);
const j = JSON.parse(o1);
check('始点の表記 (LPB・num が 2 倍) が出る', j.notes.some(n => n.LPB === 8 && n.num === 8 && n.block === 1 && n.type === 1));
check('始点ワイプ', j.notes.some(n => n.LPB === 8 && n.num === 16 && n.block === 3 && n.type === 4));
check('曲線・ease・ダミー・出現・消える・速さ', j.curve.length === 1 && j.ease.length === 1 && j.dummy.length === 1 && j.appear.length === 2 && j.disappear.length === 1 && j.speeds_each.length === 1);
check('知らないキー・part・歌詞が残る', j.mystery.z === 1 && j.mystery.a[1] === 2.5 && j.part.length === 1 && j.lyrics[0].text === '歌詞');
check('subtitle は artist のすぐ後ろ', o1.indexOf('"artist"') < o1.indexOf('"subtitle": "-short ver.-"') && o1.indexOf('"subtitle"') < o1.indexOf('"offset"'));
check('知らない type が残る', j.notes.some(n => n.type === 7));
check('数の書き方 (整数に小数点を付けない / 小数は短く)', /"BPM": 180,/.test(o1) && /"bpm": 90\.5/.test(o1) && /"speed": 0\.75/.test(o1));
check('キーの順番', o1.indexOf('"name"') < o1.indexOf('"maxBlock"') && o1.indexOf('"ease"') < o1.indexOf('"part"') && o1.indexOf('"lyrics"') < o1.indexOf('"notes"') && o1.indexOf('"mystery"') > o1.indexOf('"notes"'));

// テストプレイ: オートで全部取ると AP+ (1,111,111)、何も押さないと全部 MISS
const P = require('../renderer/js/playcore.js');
{
  const pc = P.makeChart(c);
  const g = new P.Game(pc, -10);
  g.auto(1e9);
  check('テストプレイ: オートで AP+', g.score === 1111111 && g.maxCombo === g.total && g.total > 0, 'notes ' + g.total);
  const g2 = new P.Game(pc, -10);
  g2.update(1e9);
  check('テストプレイ: 何もしないと全部 MISS', g2.miss === g2.total && g2.score === 0);
}

function sortKeys(v) {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === 'object') { const o = {}; for (const k of Object.keys(v).sort()) o[k] = sortKeys(v[k]); return o; }
  return v;
}
for (const p of process.argv.slice(2)) {
  const src = fs.readFileSync(p, 'utf8');
  const a = JSON.parse(src.replace(/^﻿/, ''));
  const out = F.stringify(F.parse(src));
  const b = JSON.parse(out);
  for (const k of ['curve', 'ease']) if (a[k] === undefined && Array.isArray(b[k]) && b[k].length === 0) delete b[k];
  // 曲名に付いた (EX) などは、iPad 版と同じく難易度に読み替えるので、名前だけはそろえて比べる
  if (typeof a.name === 'string') { const sp = F.splitName(a.name); if (sp.diff !== null) a.name = sp.title; }
  if (a.difficulty === undefined) delete b.difficulty;
  const same = JSON.stringify(sortKeys(a)) === JSON.stringify(sortKeys(b));
  check('読んで書き出しても中身が同じ: ' + p.split(/[\\/]/).pop(), same);
  check('2 回目も同じ文字: ' + p.split(/[\\/]/).pop(), F.stringify(F.parse(out)) === out);
}
if (failed) { console.log(failed + ' 件 NG'); process.exit(1); }
console.log('すべて ok');
