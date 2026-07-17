#!/usr/bin/env node
// test_mousedemo.mjs — 画面モード切替ボタン付きマウスデモのヘッドレス検証
//
// 機種マトリクス: FM-7 / FM77AV / FM77AV40 / FM77AV40EX
//   - 全機種: 640x200 8色で起動し、タイトル帯 + ボタン帯 + 背景 + カーソルを
//     全バイト厳密照合
//   - 画面最上部のタイトル "7032 - MOUSE TEST" (行1-8、白、中央寄せ) が
//     全モードで描画されること (領域非ゼロ + CG ROM 期待グリフとの照合)
//   - FM-7: ボタン(1)のみ有効。無効ボタンのクリックで何も変わらないこと
//   - FM77AV: ボタン(2)クリックで 320x200 4096色へ切替 → ボタン(1)で復帰。
//     ボタン(3)(4) は無効
//   - AV40系: ボタン(3)で 640x400 8色、ボタン(4)で 320x200 262144色へ切替
//   - 移動量スケーリング: 同一デルタ注入で全モードの物理移動量が一致する
//     (640 幅モードは X 2倍、400 ラインモードは Y 2倍、320x200 系は等倍基準)
//   - モード切替時はカーソル座標が解像度比で変換されて引き継がれる
//   - マウス方式のキー切替 (バス/インテリジェント) と離鍵・範囲外キー耐性
//
// 期待値モデル: 背景・ボタン (枠/地/CGフォントラベル)・XORカーソルを
// JS 側で完全再現し、各モードの全プレーンをバイト単位で照合する。
//
// 使い方: node test_mousedemo.mjs
//   エミュレータ core は環境変数 WEBM7_DIR で指定 (既定はリポジトリ同梱の
//   vendor/WebM7 submodule)。見つからない場合はスキップして正常終了する。
//   ROM は環境変数 FM7_ROM_DIR で指定 (fm7/ と fm77av/ のサブディレクトリを
//   持つこと)。未設定・不在の場合もスキップして正常終了する。
//   スクリーンショット (PPM) は環境変数 MOUSEDEMO_OUTDIR (既定 ./out) へ出力。

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath, pathToFileURL } from 'url';

globalThis.document = { addEventListener: () => {}, removeEventListener: () => {} };
globalThis.window = { addEventListener: () => {}, removeEventListener: () => {} };
globalThis.AudioContext = class {
    createGain() { return { gain: { value: 0, setValueAtTime: () => {}, linearRampToValueAtTime: () => {}, cancelScheduledValues: () => {} }, connect: () => {}, disconnect: () => {} }; }
    createOscillator() { return { type: '', frequency: { value: 0, setValueAtTime: () => {} }, connect: () => {}, start: () => {}, stop: () => {} }; }
    createScriptProcessor() { return { connect: () => {}, disconnect: () => {}, onaudioprocess: null }; }
    get currentTime() { return 0; }
    get destination() { return {}; }
    get sampleRate() { return 48000; }
};
globalThis.cancelAnimationFrame = () => {};

class ImageDataShim { constructor(w, h) { this.width = w; this.height = h; this.data = new Uint8ClampedArray(w * h * 4); } }
class CtxShim {
    constructor(w, h) { this.w = w; this.h = h; this.imageData = new ImageDataShim(w, h); }
    createImageData(w, h) { return new ImageDataShim(w, h); }
    putImageData(img, dx, dy, sx = 0, sy = 0, sw = img.width, sh = img.height) {
        for (let y = 0; y < sh; y++) for (let x = 0; x < sw; x++) {
            const s = ((sy + y) * img.width + (sx + x)) * 4;
            const d = ((dy + y) * this.w + (dx + x)) * 4;
            for (let k = 0; k < 4; k++) this.imageData.data[d + k] = img.data[s + k];
        }
    }
}
class CanvasShim {
    constructor() { this.width = 0; this.height = 0; this._ctx = null; }
    getContext() {
        if (!this._ctx || this._ctx.w !== this.width || this._ctx.h !== this.height) this._ctx = new CtxShim(this.width, this.height);
        return this._ctx;
    }
}

const HERE = dirname(fileURLToPath(import.meta.url));

// ---- 公開エミュレータ core (WebM7) の解決 ----
//   WEBM7_DIR で明示指定。未指定時はリポジトリ同梱の vendor/WebM7 (git
//   submodule) を探す。見つからなければテストをスキップして正常終了する。
const WEBM7_CANDIDATES = process.env.WEBM7_DIR
    ? [process.env.WEBM7_DIR]
    : [join(HERE, '../../../vendor/WebM7'), join(HERE, '../../vendor/WebM7')];
const WEBM7_DIR = WEBM7_CANDIDATES.find(d => existsSync(join(d, 'core', 'fm7.js')));
if (!WEBM7_DIR) {
    console.log('SKIP: WebM7 core が見つからないためスキップ (WEBM7_DIR を設定するか git submodule update --init を実行してください)');
    process.exit(0);
}
const { FM7 } = await import(pathToFileURL(join(WEBM7_DIR, 'core', 'fm7.js')).href);

// ---- ROM の解決 ----
//   FM7_ROM_DIR (fm7/ と fm77av/ のサブディレクトリを持つこと) で指定。
//   未設定または必要ファイル不在ならテストをスキップして正常終了する。
const R = process.env.FM7_ROM_DIR;
if (!R) {
    console.log('SKIP: ROM が無いためスキップ (FM7_ROM_DIR 未設定)');
    process.exit(0);
}
const AV = join(R, 'fm77av'), FM7R = join(R, 'fm7');
const NEED_ROMS = [
    join(FM7R, 'boot_dos.rom'), join(FM7R, 'boot_bas.rom'), join(FM7R, 'subsys_c.rom'),
    join(AV, 'fbasic30.rom'), join(AV, 'subsys_a.rom'), join(AV, 'subsys_b.rom'),
    join(AV, 'initiate.rom'),
];
const missingRoms = NEED_ROMS.filter(p => !existsSync(p));
if (missingRoms.length) {
    console.log(`SKIP: ROM が無いためスキップ (不足: ${missingRoms.join(', ')})`);
    process.exit(0);
}
const OUTDIR = process.env.MOUSEDEMO_OUTDIR || join(HERE, 'out');
mkdirSync(OUTDIR, { recursive: true });

// CG ROM フォント (サブ $D800- の 2KB、subsys_c.rom 先頭に一致)
const FONT = new Uint8Array(readFileSync(`${FM7R}/subsys_c.rom`)).slice(0, 0x800);

let failures = 0;
const check = (label, cond, extra = '') => {
    console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}${extra ? '  (' + extra + ')' : ''}`);
    if (!cond) failures++;
};

const realLog = console.log;
const quiet = (fn) => {
    console.log = () => {}; console.warn = () => {};
    try { return fn(); } finally { console.log = realLog; }
};

const bootInstance = ({ machine = 'fm77av', mouseEnabled = true, openBus = false, disk = 'mousedemo.d77' } = {}) => {
    const fm7 = new FM7();
    quiet(() => {
        fm7.loadFBasicROM(new Uint8Array(readFileSync(`${AV}/fbasic30.rom`)));
        fm7.loadBootROM(new Uint8Array(readFileSync(`${FM7R}/boot_dos.rom`)));
        fm7.loadBootBasROM(new Uint8Array(readFileSync(`${FM7R}/boot_bas.rom`)));
        fm7.loadSubROM(new Uint8Array(readFileSync(`${FM7R}/subsys_c.rom`)));
        fm7.loadSubROM_A(new Uint8Array(readFileSync(`${AV}/subsys_a.rom`)));
        fm7.loadSubROM_B(new Uint8Array(readFileSync(`${AV}/subsys_b.rom`)));
        try { fm7.loadCGROM(new Uint8Array(readFileSync(`${AV}/subsyscg.rom`))); } catch (e) {}
        fm7.loadInitiateROM(new Uint8Array(readFileSync(`${AV}/initiate.rom`)));
        fm7.setMachineType(machine);
        fm7.fdc.loadDisk(0, new Uint8Array(readFileSync(join(HERE, disk))).buffer);
        if (mouseEnabled) fm7.setMouseEnabled(true);
        if (openBus) {
            // マウス I/F 非搭載機を模擬: $FDE8 の読みは常に $FF (実装外の読み値)
            fm7._mouseBusRead = () => 0xFF;
            fm7._mouseBusWrite = () => {};
        }
        fm7.reset();
    });
    return fm7;
};

const step = (fm7, n) => quiet(() => { for (let i = 0; i < n; i++) fm7.scheduler.exec(16667); });
const waitFor = (fm7, cond, maxFrames, stepSize = 5) => {
    for (let f = 0; f < maxFrames; f += stepSize) {
        step(fm7, stepSize);
        if (cond()) return true;
    }
    return cond();
};

// ポインタ移動の注入 (UI 層と同じ符号変換: ポインタ移動量の逆符号を渡す)
//   バス/インテリジェント両方式とも同じ注入で同一方向へカーソルが動く
//   (バスは移動量を符号反転してラッチ、インテリジェントは符号反転なしのため
//    デモ側が方式毎に符号を揃える)
const injectPointerMove = (fm7, dx, dy) => fm7.addMouseDelta(-dx, -dy);

// 共有RAM オフセット: SH_METH は $FC9D → index 0x1D
const SH_METH_IDX = 0x1D;
// 生読み値: SH_RAW は $FC9E → index 0x1E (12バイト: BUS[0-3]/P1[4-7]/P2[8-11])
const SH_RAW_IDX = 0x1E, SH_R15P1_IDX = 0x2A, SH_R15P2_IDX = 0x2B;

// 共有RAMから生読み値のスナップショットを取る (サブが描画中の値と一致する)
const rawSnapshot = (fm7) => {
    const s = fm7.sharedRAM, b = i => s[SH_RAW_IDX + i];
    return {
        raw: [b(0), b(1), b(2), b(3), b(4), b(5), b(6), b(7), b(8), b(9), b(10), b(11)],
        r15p1: s[SH_R15P1_IDX], r15p2: s[SH_R15P2_IDX], sel: s[SH_METH_IDX],
    };
};
// テスト用の分かりやすいアクセサ
const readRaw = (fm7) => {
    const s = rawSnapshot(fm7);
    return {
        bus: s.raw.slice(0, 4), p1: s.raw.slice(4, 8), p2: s.raw.slice(8, 12),
        r15p1: s.r15p1, r15p2: s.r15p2, sel: s.sel,
    };
};
const allEq = (arr, v) => arr.every(x => x === v);

// キー注入 (方式切替。ASCII モードで '0'/'1'/'2' → $30/$31/$32)
const pressKey = (fm7, code) => {
    fm7.keyboard.keyDown({ code, preventDefault() {}, ctrlKey: false, shiftKey: false });
    step(fm7, 3);
    fm7.keyboard.keyUp({ code, preventDefault() {}, ctrlKey: false, shiftKey: false });
    step(fm7, 6);
};

// 方式切替: JS 側デバイス接続 (setMouseMode) とデモのキー選択を整合させる
const switchMethod = (fm7, jsMode, key) => {
    fm7.setMouseMode(jsMode);       // JS 側: 接続デバイスを切替 (bus / intel1 / intel2)
    pressKey(fm7, key);             // デモ側: 方式選択キーを送る
    step(fm7, 10);
};

// =====================================================================
// 期待値モデル: 背景 + ボタン + カーソルを JS 側で完全再現する
//   (mousedemo_sub.asm のテーブル・式と 1:1 対応)
// =====================================================================
const MODES = {
    0: { bpl: 80, h: 200, colors: { W: [1, 1, 1], D: [1, 0, 0], R: [0, 1, 0] } },
    1: { bpl: 40, h: 200, colors: { W: [15, 15, 15], D: [8, 0, 0], R: [0, 15, 0] } },
    2: { bpl: 80, h: 400, colors: { W: [1, 1, 1], D: [1, 0, 0], R: [0, 1, 0] } },
    3: { bpl: 40, h: 200, colors: { W: [63, 63, 63], D: [32, 0, 0], R: [0, 63, 0] } },
};
// モード別: ポインタ 1 カウント → 画面ピクセル数 (640 幅は X2倍、400 ラインは Y2倍)
const DSCALE = { 0: [2, 1], 1: [1, 1], 2: [2, 2], 3: [1, 1] };
// モード切替時の座標引継ぎ (解像度比で変換、デモ本体と同一の規則)
const convertPos = (from, to, x, y) => {
    const W = m => (m === 1 || m === 3) ? 320 : 640;
    const H = m => (m === 2) ? 400 : 200;
    return [W(to) === W(from) ? x : (W(to) > W(from) ? x * 2 : x >> 1),
            H(to) === H(from) ? y : (H(to) > H(from) ? y * 2 : y >> 1)];
};
// プレーン集合: {arr(モードのVRAM配列名), base, chan(0=B 1=R 2=G), mask}
const planeSets = (fm7, mode) => {
    const v = fm7.display.vram, p1 = fm7.display.vramPage1, p2 = fm7.display.vramPage2;
    if (mode === 0) return [
        { a: v, base: 0x0000, chan: 0, mask: 1 }, { a: v, base: 0x4000, chan: 1, mask: 1 },
        { a: v, base: 0x8000, chan: 2, mask: 1 }];
    if (mode === 1) {
        const out = [];
        for (const [pg, mh, ml] of [[v, 8, 4], [p1, 2, 1]]) {
            out.push({ a: pg, base: 0x0000, chan: 0, mask: mh }, { a: pg, base: 0x2000, chan: 0, mask: ml },
                     { a: pg, base: 0x4000, chan: 1, mask: mh }, { a: pg, base: 0x6000, chan: 1, mask: ml },
                     { a: pg, base: 0x8000, chan: 2, mask: mh }, { a: pg, base: 0xA000, chan: 2, mask: ml });
        }
        return out;
    }
    if (mode === 2) return [
        { a: v, base: 0, chan: 0, mask: 1 }, { a: p1, base: 0, chan: 1, mask: 1 }, { a: p2, base: 0, chan: 2, mask: 1 }];
    // mode 3: バンク0=ビット5/4, 1=3/2, 2=1/0
    const out = [];
    [[v, 0x20, 0x10], [p1, 0x08, 0x04], [p2, 0x02, 0x01]].forEach(([pg, mh, ml]) => {
        out.push({ a: pg, base: 0x0000, chan: 0, mask: mh }, { a: pg, base: 0x2000, chan: 0, mask: ml },
                 { a: pg, base: 0x4000, chan: 1, mask: mh }, { a: pg, base: 0x6000, chan: 1, mask: ml },
                 { a: pg, base: 0x8000, chan: 2, mask: mh }, { a: pg, base: 0xA000, chan: 2, mask: ml });
    });
    return out;
};

// ---- 背景 1 バイト (モード/チャネル/マスク/バイト列/ライン) ----
const MSKT = [0xFF, 0xFE, 0xFC, 0xF8, 0xF0, 0xE0, 0xC0, 0x80];
const bgByte = (mode, chan, mask, bx, y) => {
    if (mode === 0 || mode === 2) {                    // 8 色縦帯 (帯 = bx/10)
        return (((bx / 10) | 0) >> chan) & 1 ? 0xFF : 0x00;
    }
    if (mode === 1) {                                  // 4096 色グラデーション
        if (chan === 1) return (((bx >> 1) & 15) & mask) ? 0xFF : 0x00;
        if (chan === 2) return (((y >> 3) & 15) & mask) ? 0xFF : 0x00;
        const vv = bx * 8 + y, q = vv >> 3, f = vv & 7;
        const qb = ((q & 15) & mask) ? 0xFF : 0x00;
        const q1b = (((q + 1) & 15) & mask) ? 0xFF : 0x00;
        return ((MSKT[f] & qb) | (~MSKT[f] & q1b)) & 0xFF;
    }
    // mode 3: B=bx+(y>>3), R=bx, G=y>>2
    const vv = chan === 0 ? bx + (y >> 3) : chan === 1 ? bx : (y >> 2);
    return (vv & mask) ? 0xFF : 0x00;
};

// ---- レイアウト (asm のテーブル・定数と同一) ----
// タイトル: 帯 = 行0-9 (黒地・全幅)、文字列 = 行1-8 (白、中央寄せ)
const TITLE = '7032 - MOUSE TEST';
const TITLE_COL = (mode) => (mode === 1 || mode === 3) ? 11 : 31;  // (bpl-17)/2
const TITLE_ROW = 1, TITLE_BAND_H = 10;
// ボタン帯 = 行12-27 (タイトルの下の段)、ラベル = 行17-24
const BTN_TOP = 12, BTN_H = 16, LABEL_ROW = 17;
const BTABW = [[1, 18, 6], [21, 18, 24], [41, 18, 46], [61, 18, 64]];
const BTABN = [[0, 9, 2], [10, 9, 11], [20, 9, 21], [30, 9, 32]];
const LABW = ['640x200 8', '320x200 4096', '640x400 8', '320x200 262K'];
const LABN = ['640x8', '320x4K', '640x400', '262K'];
// ステータス表示: 方式帯 (行29-38 黒地 + 行30 方式名) + 左右ボタンインジケータ
//   (行41-52、押下中は白=点灯 / 非押下は暗色=消灯、黒ラベル)。全モード共通の列。
const STATUS_ROW = 29, STATUS_H = 10, METHOD_ROW = 30, METHOD_COL = 1;
const METHOD_STR = ['MOUSE: BUS', 'MOUSE: INTELLIGENT P1', 'MOUSE: INTELLIGENT P2'];
const IND_ROW = 41, IND_H = 12, IND_LABEL_ROW = 44;
const IND_LEFT = { col: 1, w: 8, lcol: 2, label: 'LEFT' };
const IND_RIGHT = { col: 10, w: 9, lcol: 11, label: 'RIGHT' };
// 生読み値 3 行 (BUS/P1/P2) + 操作案内 (mousedemo_sub.asm の RAWALL/ROWBLD と一致)
//   帯 = 行53-92 (黒地・全幅)、各行は col0 から白文字 (TINK=1) で描く
const RAW_BAND_ROW = 53, RAW_BAND_H = 40;
const RAW_ROW_LINES = [54, 63, 72];        // BUS / P1 / P2
const RAW_LABELS = ['BUS ', 'P1  ', 'P2  '];
const GUIDE_ROW = 84, GUIDE_STR = 'KEY 0:BUS 1:INT-P1 2:INT-P2';
const hex2 = (v) => v.toString(16).toUpperCase().padStart(2, '0');
// method 行の文字列を組み立てる (ROWBLD と 1:1)
const rawRowString = (sel, method, rawBytes4, r15) => {
    const marker = (method === sel) ? '>' : ' ';
    let s = marker + RAW_LABELS[method] +
        hex2(rawBytes4[0]) + ' ' + hex2(rawBytes4[1]) + ' ' +
        hex2(rawBytes4[2]) + ' ' + hex2(rawBytes4[3]);
    if (method !== 0) s += ' R15:' + hex2(r15);
    return s;
};

// ---- 1 プレーン分の期待イメージを生成 ----
//   method: 表示中の方式 (0=バス / 1=インテリジェントP1 / 2=P2)
//   pressed: 左ボタン押下 (カーソル色 + 左インジケータ), btnR: 右ボタン押下 (右インジケータ)
const expectedPlane = (mode, chan, mask, enMask, curMode, cx, cy, pressed, method = 0, btnR = false, raw = null) => {
    const { bpl, h, colors } = MODES[mode];
    const buf = new Uint8Array(bpl * h);
    for (let y = 0; y < h; y++)
        for (let bx = 0; bx < bpl; bx++) buf[y * bpl + bx] = bgByte(mode, chan, mask, bx, y);
    const cbyte = (t) => (t[chan] & mask) ? 0xFF : 0x00;
    const fillRect = (c0, w, r0, nr, v) => {
        for (let r = r0; r < r0 + nr; r++) for (let c = c0; c < c0 + w; c++) buf[r * bpl + c] = v;
    };
    // タイトル帯 (行0-9、黒地) + タイトル文字列 (行1-8、白、中央寄せ)
    fillRect(0, bpl, 0, TITLE_BAND_H, 0x00);
    {
        const ink = cbyte(colors.W);
        const tc = TITLE_COL(mode);
        for (let k = 0; k < TITLE.length; k++) {
            const code = TITLE.charCodeAt(k);
            for (let r = 0; r < 8; r++)
                buf[(TITLE_ROW + r) * bpl + tc + k] = ink ? FONT[code * 8 + r] : 0x00;
        }
    }
    // ボタン (行 12-27)
    const btab = (mode === 1 || mode === 3) ? BTABN : BTABW;
    const labs = (mode === 1 || mode === 3) ? LABN : LABW;
    for (let i = 0; i < 4; i++) {
        const [col, w, lcol] = btab[i];
        const en = (enMask >> i) & 1;
        const fill = cbyte(en ? colors.W : colors.D);
        const frame = cbyte(i === curMode ? colors.R : [0, 0, 0]);
        fillRect(col, w, BTN_TOP, BTN_H, fill);
        fillRect(col, w, BTN_TOP, 2, frame);
        fillRect(col, w, BTN_TOP + BTN_H - 2, 2, frame);
        fillRect(col, 1, BTN_TOP, BTN_H, frame);
        fillRect(col + w - 1, 1, BTN_TOP, BTN_H, frame);
        const s = labs[i];
        for (let k = 0; k < s.length; k++) {
            const code = s.charCodeAt(k);
            for (let r = 0; r < 8; r++) {
                const g = FONT[code * 8 + r];
                buf[(LABEL_ROW + r) * bpl + lcol + k] = fill ? (~g) & 0xFF : 0x00;
            }
        }
    }
    // ステータス: 方式帯 (行29-38 黒 + 行30 方式名、白、TINK=1) ----
    fillRect(0, bpl, STATUS_ROW, STATUS_H, 0x00);
    {
        const ink = cbyte(colors.W);
        const s = METHOD_STR[method];
        for (let k = 0; k < s.length; k++) {
            const code = s.charCodeAt(k);
            for (let r = 0; r < 8; r++)
                buf[(METHOD_ROW + r) * bpl + METHOD_COL + k] = ink ? FONT[code * 8 + r] : 0x00;
        }
    }
    // 左右ボタンインジケータ (行41-52、点灯=白地/消灯=暗地、黒ラベル TINK=0)
    for (const [ind, lit] of [[IND_LEFT, pressed], [IND_RIGHT, btnR]]) {
        const fill = cbyte(lit ? colors.W : colors.D);
        fillRect(ind.col, ind.w, IND_ROW, IND_H, fill);
        for (let k = 0; k < ind.label.length; k++) {
            const code = ind.label.charCodeAt(k);
            for (let r = 0; r < 8; r++)
                buf[(IND_LABEL_ROW + r) * bpl + ind.lcol + k] = fill ? (~FONT[code * 8 + r]) & 0xFF : 0x00;
        }
    }
    // 生読み値 3 行 (BUS/P1/P2) + 操作案内 (raw スナップショットが与えられた時のみ)
    if (raw) {
        const ink = cbyte(colors.W);
        const drawStr = (row, col, str) => {
            for (let k = 0; k < str.length; k++) {
                const code = str.charCodeAt(k);
                for (let r = 0; r < 8; r++)
                    buf[(row + r) * bpl + col + k] = ink ? FONT[code * 8 + r] : 0x00;
            }
        };
        fillRect(0, bpl, RAW_BAND_ROW, RAW_BAND_H, 0x00);
        drawStr(GUIDE_ROW, 0, GUIDE_STR);
        for (let mth = 0; mth < 3; mth++) {
            const bytes = raw.raw.slice(mth * 4, mth * 4 + 4);
            const r15 = mth === 1 ? raw.r15p1 : raw.r15p2;
            drawStr(RAW_ROW_LINES[mth], 0, rawRowString(raw.sel, mth, bytes, r15));
        }
    }
    // カーソル XOR (押下中は青チャネルのみ)
    if (!(pressed && chan !== 0)) {
        const col = cx >> 3, sft = cx & 7;
        for (let r = 0; r < 12; r++) {
            const yy = cy + r;
            if (yy >= h) break;
            const pat = (SHAPE[r] << 8) >> sft;
            const hi = (pat >> 8) & 0xFF, lo = pat & 0xFF;
            if (hi) buf[yy * bpl + col] ^= hi;
            if (lo && col < bpl - 1) buf[yy * bpl + col + 1] ^= lo;
        }
    }
    return buf;
};

// カーソル形状 (mousedemo_sub.asm SHAPE と同一)
const SHAPE = [0x80, 0xC0, 0xE0, 0xF0, 0xF8, 0xFC, 0xFE, 0xF8, 0xD8, 0x8C, 0x0C, 0x06];

// ---- 現モードの全プレーンを期待値と厳密照合 (mismatch バイト数を返す) ----
const exactMismatch = (fm7, mode, enMask, cx, cy, pressed = false, method = 0, btnR = false) => {
    const { bpl, h } = MODES[mode];
    const raw = rawSnapshot(fm7);
    let bad = 0;
    for (const pl of planeSets(fm7, mode)) {
        const want = expectedPlane(mode, pl.chan, pl.mask, enMask, mode, cx, cy, pressed, method, btnR, raw);
        for (let off = 0; off < bpl * h; off++) {
            if (fm7.display.vram !== null && pl.a[pl.base + off] !== want[off]) bad++;
        }
    }
    return bad;
};

// カーソルが (x,y) に完全に見えているか (先頭プレーンのカーソルセルのみ照合)
const cursorVisibleAt = (fm7, mode, enMask, x, y, method = 0, btnR = false) => {
    const { bpl, h } = MODES[mode];
    const pl = planeSets(fm7, mode)[0];
    const raw = rawSnapshot(fm7);
    const want = expectedPlane(mode, pl.chan, pl.mask, enMask, mode, x, y, false, method, btnR, raw);
    const col = x >> 3;
    for (let r = 0; r < 12; r++) {
        const yy = y + r;
        if (yy >= h) break;
        for (const c of [col, col + 1]) {
            if (c >= bpl) continue;
            if (pl.a[pl.base + yy * bpl + c] !== want[yy * bpl + c]) return false;
        }
    }
    return true;
};

// タイトル "7032 - MOUSE TEST" が描画されているか
//   (タイトル領域の VRAM が非ゼロ + 全モードで CG ROM 期待グリフと完全一致)
const titleDrawn = (fm7, mode) => {
    const { bpl, colors } = MODES[mode];
    // 白 (タイトル文字色) のビットが立つ最初のプレーンで照合する
    const pl = planeSets(fm7, mode).find(p => (colors.W[p.chan] & p.mask));
    const tc = TITLE_COL(mode);
    let nonzero = 0;
    for (let k = 0; k < TITLE.length; k++) {
        const code = TITLE.charCodeAt(k);
        for (let r = 0; r < 8; r++) {
            const got = pl.a[pl.base + (TITLE_ROW + r) * bpl + tc + k];
            if (got !== FONT[code * 8 + r]) return false;   // 期待グリフと不一致
            if (got !== 0) nonzero++;
        }
    }
    return nonzero > 0;                                     // 領域が非ゼロであること
};

const writePPM = (fm7, label) => {
    const canvas = new CanvasShim();
    quiet(() => fm7.display.render(canvas, true));
    const ctx = canvas.getContext();
    const W = canvas.width, H = canvas.height;
    const header = `P6\n${W} ${H}\n255\n`;
    const buf = Buffer.alloc(header.length + W * H * 3);
    buf.write(header, 0);
    let off = header.length;
    const data = ctx.imageData.data;
    for (let i = 0; i < W * H; i++) {
        buf[off++] = data[i * 4]; buf[off++] = data[i * 4 + 1]; buf[off++] = data[i * 4 + 2];
    }
    const p = join(OUTDIR, `mousedemo_${label}.ppm`);
    writeFileSync(p, buf);
    realLog(`  [ppm] ${p}`);
};

const S = (fm7) => fm7.sharedRAM;               // 共有RAM (サブ $D380- に対応)
const bootDemo = (fm7) =>
    waitFor(fm7, () => S(fm7)[0x10] === 0xA5 && S(fm7)[0x11] >= 1, 1200);

// 大きな移動は 1 ラッチの符号付き 8 ビット範囲を超えないよう分割して注入する
// (目標はピクセル座標。現モードの移動量スケールでポインタデルタへ換算する)
const moveTo = (fm7, pos, x, y) => {
    const [kx, ky] = DSCALE[pos.mode];
    let dx = (x - pos.x) / kx, dy = (y - pos.y) / ky;
    if (!Number.isInteger(dx) || !Number.isInteger(dy))
        throw new Error(`moveTo: (${pos.x},${pos.y})->(${x},${y}) はモード${pos.mode}のスケールで割り切れない`);
    while (dx !== 0 || dy !== 0) {
        const sx = Math.max(-100, Math.min(100, dx));
        const sy = Math.max(-100, Math.min(100, dy));
        injectPointerMove(fm7, sx, sy);
        dx -= sx; dy -= sy;
        step(fm7, 2);
    }
    pos.x = x; pos.y = y;
};

// クリック 1 回 (押して待って離す)。モード切替なら mack の変化を待つ
const clickAt = (fm7, pos, x, y, { expectMode = null } = {}) => {
    moveTo(fm7, pos, x, y);
    waitFor(fm7, () => cursorVisibleAt(fm7, pos.mode, pos.en, x, y), 240, 2);
    const cnt = S(fm7)[0x11];
    fm7.setMouseButtons(true, false);
    if (expectMode !== null) {
        waitFor(fm7, () => S(fm7)[0x13] === expectMode, 900, 5);
        [pos.x, pos.y] = convertPos(pos.mode, expectMode, pos.x, pos.y);
        pos.mode = expectMode;
    } else {
        waitFor(fm7, () => S(fm7)[0x11] > cnt, 240, 2);
    }
    const cntR = S(fm7)[0x11];
    fm7.setMouseButtons(false, false);
    // 離した更新をサブが描き終えるまで待つ (mode3 は 18 面再描画で遅く、
    // step だけでは取りこぼす。SH_CNT の前進 → 安定で処理完了を確認する)
    waitFor(fm7, () => S(fm7)[0x11] > cntR, 400, 2);
    settle(fm7);
};

// サブの描画完了カウンタ (SH_CNT) が安定するまで待つ (保留更新の描き切りを保証)
const settle = (fm7, quietFrames = 8, maxFrames = 160) => {
    let stable = 0, last = -1;
    for (let i = 0; i < maxFrames && stable < quietFrames; i++) {
        step(fm7, 1);
        const c = S(fm7)[0x11];
        if (c === last) stable++; else { stable = 0; last = c; }
    }
};

// ボタン中心座標 (現モードのレイアウトで。ボタン帯 = 行12-27 → 中心 y=20)
const btnCenter = (mode, i) => {
    const t = (mode === 1 || mode === 3) ? BTABN : BTABW;
    const [col, w] = t[i];
    return [(col * 8 + (col + w) * 8) >> 1, 20];
};

// =====================================================================
// 機種別スイート
// =====================================================================
const LVLOF = { fm7: 0, fm77av: 1, fm77av40: 2, fm77av40ex: 2 };
const ENOF = { fm7: 0x01, fm77av: 0x03, fm77av40: 0x0F, fm77av40ex: 0x0F };
const DISPMODE = [0, 1, 3, 2];   // デモのモード番号 → core displayMode

const suite = (machine) => {
    console.log(`=== [${machine}] ブート → 機種判別 + 初期 640x200 8色 ===`);
    const fm7 = bootInstance({ machine });
    const en = ENOF[machine];
    const pos = { x: 320, y: 100, mode: 0, en };
    check('ブートしサブ側の初期描画が完了', bootDemo(fm7),
          `bg=$${S(fm7)[0x10].toString(16)} cnt=${S(fm7)[0x11]}`);
    check(`機種レベル判別 (${LVLOF[machine]})`, S(fm7)[0x12] === LVLOF[machine], `lvl=${S(fm7)[0x12]}`);
    check('初期モード 640x200 8色 (displayMode=0)', fm7.display.displayMode === 0,
          `displayMode=${fm7.display.displayMode}`);
    check('デジタルパレット恒等 (0-7)', [...Array(8).keys()].every(i => (fm7.display.palette[i] & 7) === i));
    check('初期画面が期待値と全プレーン一致 (背景+タイトル+ボタン+カーソル)',
          exactMismatch(fm7, 0, en, 320, 100) === 0, `mismatch=${exactMismatch(fm7, 0, en, 320, 100)}`);
    check(`タイトル "${TITLE}" が最上部に描画 (非ゼロ+期待グリフ一致)`, titleDrawn(fm7, 0));
    writePPM(fm7, `${machine}_mode0_boot`);

    // 静止可視率
    {
        let visible = 0;
        const N = 30;
        for (let i = 0; i < N; i++) { step(fm7, 1); if (cursorVisibleAt(fm7, 0, en, 320, 100)) visible++; }
        check('静止カーソルの可視率 100%', visible === N, `${visible}/${N}`);
    }

    // ポインタ移動 (640 幅モード: X 移動量は 2 倍にスケーリングされる)
    {
        const cnt = S(fm7)[0x11];
        injectPointerMove(fm7, 100, 60);
        pos.x = 520; pos.y = 160;
        const moved = waitFor(fm7, () => S(fm7)[0x11] > cnt, 240, 2);
        step(fm7, 6);
        check('デルタ(+100,+60)でカーソルが (520,160) へ (640幅: X 2倍・右・下=正)',
              moved && cursorVisibleAt(fm7, 0, en, 520, 160),
              `cnt ${cnt} -> ${S(fm7)[0x11]}`);
        check('移動後も全プレーン期待値一致 (旧位置消去)', exactMismatch(fm7, 0, en, 520, 160) === 0,
              `mismatch=${exactMismatch(fm7, 0, en, 520, 160)}`);
    }

    if (machine === 'fm7') {
        // 無効ボタン(2)(3)(4) をクリックしても何も変わらない
        for (const i of [1, 2, 3]) {
            const [bx, by] = btnCenter(0, i);
            clickAt(fm7, pos, bx, by);
            check(`無効ボタン(${i + 1}) クリックで変化なし (FM-7)`,
                  fm7.display.displayMode === 0 && S(fm7)[0x13] === 0,
                  `displayMode=${fm7.display.displayMode} mack=${S(fm7)[0x13]}`);
        }
        check('クリック後も画面が期待値と一致', exactMismatch(fm7, 0, en, pos.x, pos.y) === 0,
              `mismatch=${exactMismatch(fm7, 0, en, pos.x, pos.y)}`);
        writePPM(fm7, `${machine}_mode0_after_disabled_clicks`);
        return fm7;
    }

    // ---- ボタン(2): 320x200 4096色へ ----
    {
        const [bx, by] = btnCenter(0, 1);
        clickAt(fm7, pos, bx, by, { expectMode: 1 });
        check('ボタン(2)クリックで 320x200 4096色へ (displayMode=1)',
              fm7.display.displayMode === 1 && S(fm7)[0x13] === 1,
              `displayMode=${fm7.display.displayMode} mack=${S(fm7)[0x13]}`);
        check('アナログパレット恒等 ($123/$ABC)',
              fm7._analogPalette[0x123] === 0x123 && fm7._analogPalette[0xABC] === 0xABC);
        check('切替時に位置を比率変換して引継ぎ (640幅 240,20 → 320幅 120,20)',
              pos.x === 120 && pos.y === 20 && cursorVisibleAt(fm7, 1, en, 120, 20),
              `pos=(${pos.x},${pos.y})`);
        check('4096色画面が期待値と全プレーン一致 (12面)',
              exactMismatch(fm7, 1, en, pos.x, pos.y) === 0,
              `mismatch=${exactMismatch(fm7, 1, en, pos.x, pos.y)}`);
        check('4096色モードでもタイトルが描画 (320幅レイアウト)', titleDrawn(fm7, 1));
        writePPM(fm7, `${machine}_mode1_4096`);
    }
    // ---- 4096色モードでのカーソル移動 (等倍=基準) + 左ボタン色変化 ----
    {
        const cnt = S(fm7)[0x11];
        injectPointerMove(fm7, 60, 40);
        pos.x = 180; pos.y = 60;
        waitFor(fm7, () => S(fm7)[0x11] > cnt, 240, 2);
        step(fm7, 6);
        check('4096色モードでデルタ(+60,+40) → (+60px,+40行) 等倍移動',
              cursorVisibleAt(fm7, 1, en, 180, 60), '');
        const cnt2 = S(fm7)[0x11];
        fm7.setMouseButtons(true, false);
        waitFor(fm7, () => S(fm7)[0x11] > cnt2, 240, 2);
        step(fm7, 6);
        check('左ボタン押下で青チャネルのみ反転 (カーソル色変化)',
              exactMismatch(fm7, 1, en, 180, 60, true) === 0,
              `mismatch=${exactMismatch(fm7, 1, en, 180, 60, true)}`);
        const cnt3 = S(fm7)[0x11];
        fm7.setMouseButtons(false, false);
        waitFor(fm7, () => S(fm7)[0x11] > cnt3, 240, 2);
        step(fm7, 6);
        check('解放で元の表示に戻る', exactMismatch(fm7, 1, en, 180, 60, false) === 0, '');
    }

    if (machine === 'fm77av') {
        // 無効ボタン(3)(4): 320幅レイアウトのボタン3/4 をクリック
        for (const i of [2, 3]) {
            const [bx, by] = btnCenter(1, i);
            clickAt(fm7, pos, bx, by);
            check(`無効ボタン(${i + 1}) クリックで変化なし (FM77AV)`,
                  fm7.display.displayMode === 1 && S(fm7)[0x13] === 1,
                  `displayMode=${fm7.display.displayMode} mack=${S(fm7)[0x13]}`);
        }
        check('クリック後も 4096色画面が期待値と一致',
              exactMismatch(fm7, 1, en, pos.x, pos.y) === 0,
              `mismatch=${exactMismatch(fm7, 1, en, pos.x, pos.y)}`);
    } else {
        // ---- AV40系: ボタン(3) 640x400 8色 ----
        {
            const [bx, by] = btnCenter(1, 2);
            clickAt(fm7, pos, bx, by, { expectMode: 2 });
            check('ボタン(3)クリックで 640x400 8色へ (displayMode=3)',
                  fm7.display.displayMode === 3 && S(fm7)[0x13] === 2,
                  `displayMode=${fm7.display.displayMode} mack=${S(fm7)[0x13]}`);
            check('切替時に位置を比率変換して引継ぎ (320x200 196,20 → 640x400 392,40)',
                  pos.x === 392 && pos.y === 40 && cursorVisibleAt(fm7, 2, en, 392, 40),
                  `pos=(${pos.x},${pos.y})`);
            check('640x400 画面が期待値と全プレーン一致 (3面 x 32000バイト)',
                  exactMismatch(fm7, 2, en, pos.x, pos.y) === 0,
                  `mismatch=${exactMismatch(fm7, 2, en, pos.x, pos.y)}`);
            check('640x400 モードでもタイトルが描画', titleDrawn(fm7, 2));
            writePPM(fm7, `${machine}_mode2_640x400`);
            // 400 ライン空間: 同一デルタで X/Y とも 2 倍スケーリング
            const cnt = S(fm7)[0x11];
            injectPointerMove(fm7, 40, 80);
            pos.x = 472; pos.y = 200;
            waitFor(fm7, () => S(fm7)[0x11] > cnt, 240, 2);
            step(fm7, 6);
            check('640x400 でデルタ(+40,+80) → (+80px,+160行) 移動 (X/Y 2倍)',
                  cursorVisibleAt(fm7, 2, en, 472, 200), '');
            // Y > 199 へのカーソル移動
            moveTo(fm7, pos, 472, 280);
            waitFor(fm7, () => cursorVisibleAt(fm7, 2, en, 472, 280), 240, 2);
            check('640x400 でカーソルが (472,280) へ移動 (Y>199)',
                  cursorVisibleAt(fm7, 2, en, 472, 280), '');
        }
        // ---- AV40系: ボタン(4) 320x200 262144色 ----
        {
            const [bx, by] = btnCenter(2, 3);
            clickAt(fm7, pos, bx, by, { expectMode: 3 });
            check('ボタン(4)クリックで 320x200 262144色へ (displayMode=2)',
                  fm7.display.displayMode === 2 && S(fm7)[0x13] === 3,
                  `displayMode=${fm7.display.displayMode} mack=${S(fm7)[0x13]}`);
            check('切替時に位置を比率変換して引継ぎ (640x400 560,20 → 320x200 280,10)',
                  pos.x === 280 && pos.y === 10 && cursorVisibleAt(fm7, 3, en, 280, 10),
                  `pos=(${pos.x},${pos.y})`);
            check('262144色画面が期待値と全プレーン一致 (18面)',
                  exactMismatch(fm7, 3, en, pos.x, pos.y) === 0,
                  `mismatch=${exactMismatch(fm7, 3, en, pos.x, pos.y)}`);
            check('262144色モードでもタイトルが描画', titleDrawn(fm7, 3));
            writePPM(fm7, `${machine}_mode3_262k`);
        }
    }

    // ---- ボタン(1): 640x200 8色へ復帰 ----
    {
        const cur = pos.mode;
        const [bx, by] = btnCenter(cur, 0);
        clickAt(fm7, pos, bx, by, { expectMode: 0 });
        check('ボタン(1)クリックで 640x200 8色へ復帰 (displayMode=0)',
              fm7.display.displayMode === 0 && S(fm7)[0x13] === 0,
              `displayMode=${fm7.display.displayMode} mack=${S(fm7)[0x13]}`);
        check('復帰時も位置を比率変換して引継ぎ (320幅 36,20 → 640幅 72,20)',
              pos.x === 72 && pos.y === 20 && cursorVisibleAt(fm7, 0, en, 72, 20),
              `pos=(${pos.x},${pos.y})`);
        check('復帰後の画面が期待値と全プレーン一致',
              exactMismatch(fm7, 0, en, pos.x, pos.y) === 0,
              `mismatch=${exactMismatch(fm7, 0, en, pos.x, pos.y)}`);
        writePPM(fm7, `${machine}_mode0_back`);
    }
    return fm7;
};

for (const machine of ['fm7', 'fm77av', 'fm77av40', 'fm77av40ex']) suite(machine);

// =====================================================================
console.log('=== 移動量スケーリング: 同一デルタ(+40,+20)で物理移動が全モード一致 (fm77av40) ===');
{
    const fm7 = bootInstance({ machine: 'fm77av40' });
    const en = 0x0F;
    const pos = { x: 320, y: 100, mode: 0, en };
    check('ブートし初期描画完了', bootDemo(fm7), `cnt=${S(fm7)[0x11]}`);
    // [モード, 開始位置(ピクセル), 期待移動(ピクセル)]。0→1→2→3 の順に切替
    const cases = [
        [0, [200, 60], [80, 20]],    // 640x200 8色     : X 2倍 / Y 等倍
        [1, [100, 60], [40, 20]],    // 320x200 4096色  : 等倍 (基準)
        [2, [200, 120], [80, 40]],   // 640x400 8色     : X/Y とも 2倍
        [3, [100, 60], [40, 20]],    // 320x200 262144色: 等倍 (基準)
    ];
    for (const [mode, [sx, sy], [ex, ey]] of cases) {
        if (pos.mode !== mode) {
            const [bx, by] = btnCenter(pos.mode, mode);
            const [wx, wy] = convertPos(pos.mode, mode, bx, by);
            clickAt(fm7, pos, bx, by, { expectMode: mode });
            check(`モード${mode}切替時の位置引継ぎ (${bx},${by})→(${wx},${wy})`,
                  pos.x === wx && pos.y === wy && cursorVisibleAt(fm7, mode, en, wx, wy),
                  `pos=(${pos.x},${pos.y})`);
        }
        moveTo(fm7, pos, sx, sy);
        waitFor(fm7, () => cursorVisibleAt(fm7, mode, en, sx, sy), 240, 2);
        const cnt = S(fm7)[0x11];
        injectPointerMove(fm7, 40, 20);
        waitFor(fm7, () => S(fm7)[0x11] > cnt, 240, 2);
        step(fm7, 6);
        pos.x = sx + ex; pos.y = sy + ey;
        check(`モード${mode}: デルタ(+40,+20) → (+${ex}px,+${ey}行)`,
              cursorVisibleAt(fm7, mode, en, pos.x, pos.y) && exactMismatch(fm7, mode, en, pos.x, pos.y) === 0,
              `期待位置 (${pos.x},${pos.y})`);
    }
}

// =====================================================================
console.log('=== マウス未接続 / I/F 非搭載相当でも安全なこと (fm77av) ===');
{
    const fm7d = bootInstance({ machine: 'fm77av', mouseEnabled: false });
    check('未接続でもブートし初期描画完了', bootDemo(fm7d), `cnt=${S(fm7d)[0x11]}`);
    let visible = 0;
    const N = 30;
    for (let i = 0; i < N; i++) { step(fm7d, 1); if (cursorVisibleAt(fm7d, 0, 3, 320, 100)) visible++; }
    check('未接続時のカーソル可視率 100% (中央に静止)', visible === N, `${visible}/${N}`);

    const fm7e = bootInstance({ machine: 'fm77av', openBus: true });
    check('I/F 非搭載相当 ($FDE8=常に$FF) でもブート', bootDemo(fm7e), `cnt=${S(fm7e)[0x11]}`);
    let vis2 = 0;
    for (let i = 0; i < N; i++) { step(fm7e, 1); if (cursorVisibleAt(fm7e, 0, 3, 320, 100)) vis2++; }
    check('I/F 非搭載時もカーソル中央静止・暴走しない', vis2 === N && S(fm7e)[0x11] === 1,
          `${vis2}/${N} cnt=${S(fm7e)[0x11]}`);
}

// =====================================================================
// マウス方式のキー切替 + 各方式でカーソル移動 + 左右ボタンインジケータ
// =====================================================================
// 各 L/R 組合せでインジケータが左右個別に反映されることを厳密照合する
const checkButtonIndicators = (fm7, pos, en, methodCode) => {
    for (const [l, r] of [[false, false], [true, false], [false, true], [true, true]]) {
        const cnt = S(fm7)[0x11];
        fm7.setMouseButtons(l, r);
        waitFor(fm7, () => S(fm7)[0x11] > cnt, 300, 2);
        step(fm7, 6);
        const mm = exactMismatch(fm7, pos.mode, en, pos.x, pos.y, l, methodCode, r);
        check(`  ボタン 左=${l ? 'ON ' : 'off'} 右=${r ? 'ON ' : 'off'} が左右インジケータへ個別反映`,
              mm === 0, `mismatch=${mm}`);
    }
    fm7.setMouseButtons(false, false);
    step(fm7, 10);
};

// 現在の方式でデルタを注入しカーソルが動くこと (mode0: X 2倍 / Y 等倍)
const checkMoves = (fm7, pos, en, methodCode, dx, dy, label) => {
    const cnt = S(fm7)[0x11];
    injectPointerMove(fm7, dx, dy);
    pos.x += dx * 2; pos.y += dy;
    waitFor(fm7, () => S(fm7)[0x11] > cnt, 300, 2);
    step(fm7, 6);
    check(`  ${label}: デルタ注入でカーソルが (${pos.x},${pos.y}) へ移動`,
          cursorVisibleAt(fm7, pos.mode, en, pos.x, pos.y, methodCode) &&
          exactMismatch(fm7, pos.mode, en, pos.x, pos.y, false, methodCode) === 0,
          `pos=(${pos.x},${pos.y})`);
};

console.log("=== マウス方式のキー切替 ('0'/'1'/'2') + 各方式で移動・左右ボタン表示 ===");
for (const machine of ['fm77av', 'fm77av40', 'fm77av40ex']) {
    console.log(`--- [${machine}] ---`);
    const fm7 = bootInstance({ machine });       // 既定はバスマウス接続
    const en = ENOF[machine];
    const pos = { x: 320, y: 100, mode: 0, en };
    check('ブートし初期描画完了', bootDemo(fm7), `cnt=${S(fm7)[0x11]}`);
    check('初期方式 BUS (SH_METH=0) + 方式表示 "MOUSE: BUS" を含め画面一致',
          S(fm7)[SH_METH_IDX] === 0 && exactMismatch(fm7, 0, en, 320, 100, false, 0, false) === 0,
          `meth=${S(fm7)[SH_METH_IDX]} mm=${exactMismatch(fm7, 0, en, 320, 100, false, 0, false)}`);

    // ---- バスマウス: 移動 + 左右ボタン ----
    checkMoves(fm7, pos, en, 0, 30, 20, 'BUS');
    checkButtonIndicators(fm7, pos, en, 0);
    writePPM(fm7, `${machine}_method_bus`);

    // ---- キー '1' → インテリジェント ポート1 ----
    switchMethod(fm7, 'intel1', 'Digit1');
    check("キー'1'で INTELLIGENT P1 (SH_METH=1) + 方式表示更新 (全プレーン一致)",
          S(fm7)[SH_METH_IDX] === 1 && exactMismatch(fm7, 0, en, pos.x, pos.y, false, 1, false) === 0,
          `meth=${S(fm7)[SH_METH_IDX]} mm=${exactMismatch(fm7, 0, en, pos.x, pos.y, false, 1, false)}`);
    checkMoves(fm7, pos, en, 1, 20, 15, 'intel1 (OPN 経由読み)');
    checkButtonIndicators(fm7, pos, en, 1);
    writePPM(fm7, `${machine}_method_intel1`);

    // ---- キー '2' → インテリジェント ポート2 ----
    switchMethod(fm7, 'intel2', 'Digit2');
    check("キー'2'で INTELLIGENT P2 (SH_METH=2) + 方式表示更新 (全プレーン一致)",
          S(fm7)[SH_METH_IDX] === 2 && exactMismatch(fm7, 0, en, pos.x, pos.y, false, 2, false) === 0,
          `meth=${S(fm7)[SH_METH_IDX]} mm=${exactMismatch(fm7, 0, en, pos.x, pos.y, false, 2, false)}`);
    checkMoves(fm7, pos, en, 2, -20, -10, 'intel2 (ポート2)');
    checkButtonIndicators(fm7, pos, en, 2);
    writePPM(fm7, `${machine}_method_intel2`);

    // ---- キー '0' → バスへ復帰 ----
    switchMethod(fm7, 'bus', 'Digit0');
    check("キー'0'で BUS へ復帰 (SH_METH=0) + 方式表示更新 (全プレーン一致)",
          S(fm7)[SH_METH_IDX] === 0 && exactMismatch(fm7, 0, en, pos.x, pos.y, false, 0, false) === 0,
          `meth=${S(fm7)[SH_METH_IDX]} mm=${exactMismatch(fm7, 0, en, pos.x, pos.y, false, 0, false)}`);
    checkMoves(fm7, pos, en, 0, 15, 10, 'BUS 復帰後');
}

// =====================================================================
// 生読み値 3 行表示 (BUS/P1/P2) の中身検証 + 操作案内の描画
//   コアは一度に 1 デバイスのみ接続 (選択中方式)。よって選択中系統だけが
//   実データを返し、非接続系統はセンチネル (バス非接続=$80 / インテリ非接続=$FF)
//   を返す。これを共有RAMの生値セルで検証する。
// =====================================================================
// 操作案内の文字列が VRAM に描画されているか (行84, col0)
const guideDrawn = (fm7, mode) => {
    const { bpl, colors } = MODES[mode];
    const pl = planeSets(fm7, mode).find(p => (colors.W[p.chan] & p.mask));
    let nonzero = 0;
    for (let k = 0; k < GUIDE_STR.length; k++) {
        const code = GUIDE_STR.charCodeAt(k);
        for (let r = 0; r < 8; r++) {
            const got = pl.a[pl.base + (GUIDE_ROW + r) * bpl + k];
            if (got !== FONT[code * 8 + r]) return false;
            if (got !== 0) nonzero++;
        }
    }
    return nonzero > 0;
};

console.log('=== 生読み値 3 行 (BUS/P1/P2) の中身 + 選択強調 + 操作案内 (fm77av40) ===');
{
    const fm7 = bootInstance({ machine: 'fm77av40' });   // 既定 = バス接続
    const en = 0x0F;
    const pos = { x: 320, y: 100, mode: 0, en };
    check('ブートし初期描画完了', bootDemo(fm7), `cnt=${S(fm7)[0x11]}`);
    // 起動直後 (バス選択・静止): BUS は接続 ($80、bit7=1)、P1/P2 は非接続 ($FF)
    {
        const r = readRaw(fm7);
        check('生値: 起動時 BUS 系統が接続応答 (bit7=1・全FFでない)',
              (r.bus[0] & 0x80) !== 0 && !allEq(r.bus, 0xFF),
              `BUS=${r.bus.map(hex2).join(' ')}`);
        check('生値: バス選択中は P1/P2 が非接続 (全 FF)',
              allEq(r.p1, 0xFF) && allEq(r.p2, 0xFF),
              `P1=${r.p1.map(hex2).join(' ')} P2=${r.p2.map(hex2).join(' ')}`);
        check('生値: ストローブ reg15 値 (P1=$13 / P2=$6C) を提示',
              r.r15p1 === 0x13 && r.r15p2 === 0x6C,
              `R15P1=${hex2(r.r15p1)} R15P2=${hex2(r.r15p2)}`);
        check('生値: 選択中 = BUS (SH_METH=0)', r.sel === 0, `sel=${r.sel}`);
        check('操作案内 "KEY 0:BUS 1:INT-P1 2:INT-P2" が描画', guideDrawn(fm7, 0));
    }
    // バス移動が BUS 生バイトに現れる (診断の要)。バスマウスはラッチ毎に移動量を
    // 1 回返し、以後は静止値 ($80) に戻る過渡的挙動のため、細かい時間刻みで捕捉する。
    {
        injectPointerMove(fm7, 40, 24);
        let sawMove = false, snap = null;
        for (let i = 0; i < 80 && !sawMove; i++) {
            quiet(() => fm7.scheduler.exec(200));   // 0.2ms 刻みで過渡を捉える
            const b = readRaw(fm7).bus;
            if (!allEq(b, 0x80) && !allEq(b, 0xFF)) { sawMove = true; snap = b; }
        }
        check('生値: バス移動が BUS 生バイトに現れる (ラッチ毎の移動量)',
              sawMove, snap ? snap.map(hex2).join(' ') : 'no non-idle sample');
        step(fm7, 4);
    }
    // intel1 選択: BUS 非接続 ($80)、P1 応答 (非 FF)、P2 非接続 ($FF)
    {
        switchMethod(fm7, 'intel1', 'Digit1');
        const cnt = S(fm7)[0x11];
        injectPointerMove(fm7, 20, 10);
        waitFor(fm7, () => S(fm7)[0x11] > cnt, 300, 2);
        step(fm7, 6);
        const r = readRaw(fm7);
        check('生値: intel1 選択で P1 が応答 (全 FF でない) / BUS=$80 / P2=$FF',
              !allEq(r.p1, 0xFF) && allEq(r.bus, 0x80) && allEq(r.p2, 0xFF),
              `BUS=${r.bus.map(hex2).join(' ')} P1=${r.p1.map(hex2).join(' ')} P2=${r.p2.map(hex2).join(' ')}`);
        check('生値: 選択中 = P1 (SH_METH=1、P1 行を強調)', r.sel === 1, `sel=${r.sel}`);
    }
    // intel2 選択: P1 非接続 ($FF)、P2 応答 (非 FF)
    {
        switchMethod(fm7, 'intel2', 'Digit2');
        const cnt = S(fm7)[0x11];
        injectPointerMove(fm7, -20, -10);
        waitFor(fm7, () => S(fm7)[0x11] > cnt, 300, 2);
        step(fm7, 6);
        const r = readRaw(fm7);
        check('生値: intel2 選択で P2 が応答 (全 FF でない) / P1=$FF',
              !allEq(r.p2, 0xFF) && allEq(r.p1, 0xFF),
              `P1=${r.p1.map(hex2).join(' ')} P2=${r.p2.map(hex2).join(' ')}`);
        check('生値: 選択中 = P2 (SH_METH=2、P2 行を強調)', r.sel === 2, `sel=${r.sel}`);
    }
}

// マウス操作では方式が絶対に変わらないこと (fm77av40)
console.log('=== マウス操作 (移動・ボタン) では方式が変わらない (fm77av40) ===');
{
    const fm7 = bootInstance({ machine: 'fm77av40' });
    const en = 0x0F;
    const pos = { x: 320, y: 100, mode: 0, en };
    bootDemo(fm7);
    switchMethod(fm7, 'intel1', 'Digit1');
    check('intel1 選択済み', S(fm7)[SH_METH_IDX] === 1);
    // 大きめの移動と全ボタン操作を行っても SH_METH は 1 のまま
    for (let i = 0; i < 8; i++) { injectPointerMove(fm7, (i % 2 ? -30 : 30), 20); step(fm7, 4); }
    fm7.setMouseButtons(true, true); step(fm7, 8);
    fm7.setMouseButtons(false, false); step(fm7, 8);
    check('移動・ボタン操作後も方式は intel1 のまま (キー以外で変わらない)',
          S(fm7)[SH_METH_IDX] === 1, `meth=${S(fm7)[SH_METH_IDX]}`);
}

// =====================================================================
// キー入力の頑健性: 離鍵 / ブレークコード / オートリピート / 範囲外キー
// =====================================================================
// キーイベントを組み立てる小ヘルパ (down/up は _heldKeys を正しく辿らせる)
const kd = (fm7, code) => fm7.keyboard.keyDown({ code, preventDefault() {}, ctrlKey: false, shiftKey: false });
const ku = (fm7, code) => fm7.keyboard.keyUp({ code, preventDefault() {}, ctrlKey: false, shiftKey: false });

console.log('=== キー入力の頑健性: 離鍵/ブレーク/オートリピート/範囲外キー (fm77av) ===');
{
    const fm7 = bootInstance({ machine: 'fm77av' });
    const en = ENOF['fm77av'];
    const pos = { x: 320, y: 100, mode: 0, en };
    bootDemo(fm7);

    // ---- (1) ブレークコード注入耐性 ----
    // core 既定は _enableBreakCodes=false で keyUp が FIFO に何も積まない。
    // ここでは一時的にブレークを有効化し、keyUp で 0x31|$80=$B1 等のブレークが
    // FIFO に積まれても、デモの範囲判定 (suba #$30 → bmi/bhi) が負値として弾き、
    // 離鍵で方式が変化しないことを検証する。終了時に必ず false へ戻す。
    const savedBreak = fm7.keyboard._enableBreakCodes;
    fm7.keyboard._enableBreakCodes = true;
    try {
        // intel1 へ: keyDown('1')→keyUp('1')。keyUp で break $B1 が積まれる
        fm7.setMouseMode('intel1');
        kd(fm7, 'Digit1'); step(fm7, 4); ku(fm7, 'Digit1'); step(fm7, 14);
        check('ブレーク有効: intel1 が離鍵($B1)後も方式保持 (SH_METH=1・表示一致)',
              S(fm7)[SH_METH_IDX] === 1 && exactMismatch(fm7, 0, en, pos.x, pos.y, false, 1, false) === 0,
              `meth=${S(fm7)[SH_METH_IDX]} mm=${exactMismatch(fm7, 0, en, pos.x, pos.y, false, 1, false)}`);
        // バスへ: keyDown('0')→keyUp('0')。keyUp で break $B0 が積まれる
        fm7.setMouseMode('bus');
        kd(fm7, 'Digit0'); step(fm7, 4); ku(fm7, 'Digit0'); step(fm7, 14);
        check('ブレーク有効: バスが離鍵($B0)後も方式保持 (SH_METH=0・表示一致)',
              S(fm7)[SH_METH_IDX] === 0 && exactMismatch(fm7, 0, en, pos.x, pos.y, false, 0, false) === 0,
              `meth=${S(fm7)[SH_METH_IDX]} mm=${exactMismatch(fm7, 0, en, pos.x, pos.y, false, 0, false)}`);
    } finally {
        fm7.keyboard._enableBreakCodes = savedBreak;   // 既定(false)へ必ず復帰
    }
    check('テスト後 _enableBreakCodes を既定(false)へ復帰済み',
          fm7.keyboard._enableBreakCodes === false, `${fm7.keyboard._enableBreakCodes}`);

    // ---- (2) オートリピート耐性 (ブレーク無効の既定モードで実施) ----
    // 同一キー '1' を keyUp 無しで2回注入 (= オートリピートで同一メイクコードが
    // 2 個積まれる状態)。2 度目の同一方式再選択は無反応 (SH_METH 不変・再描画
    // されず SH_CNT 不変) であることを確認する。
    switchMethod(fm7, 'bus', 'Digit0');                // まず既知の状態 (バス) へ
    check('オートリピート前提: バス方式に整地', S(fm7)[SH_METH_IDX] === 0, `meth=${S(fm7)[SH_METH_IDX]}`);
    fm7.setMouseMode('intel1');                        // JS デバイスは intel1 に接続
    kd(fm7, 'Digit1'); step(fm7, 12);                  // 1 回目: bus→intel1 へ切替 + 再描画
    const cnt1 = S(fm7)[0x11];
    check('オートリピート1回目で intel1 へ切替 (SH_METH=1)',
          S(fm7)[SH_METH_IDX] === 1, `meth=${S(fm7)[SH_METH_IDX]}`);
    kd(fm7, 'Digit1'); step(fm7, 14);                  // 2 回目: 同一方式の再選択
    check('オートリピート2回目(同一方式再選択)は無反応 (SH_METH=1・SH_CNT 不変=再描画なし)',
          S(fm7)[SH_METH_IDX] === 1 && S(fm7)[0x11] === cnt1,
          `meth=${S(fm7)[SH_METH_IDX]} cnt ${cnt1}->${S(fm7)[0x11]}`);
    check('オートリピート中も画面が期待値と一致 (再描画なし・intel1 表示のまま)',
          exactMismatch(fm7, 0, en, pos.x, pos.y, false, 1, false) === 0,
          `mm=${exactMismatch(fm7, 0, en, pos.x, pos.y, false, 1, false)}`);
    ku(fm7, 'Digit1'); step(fm7, 8);

    // ---- (3) 範囲外キー無視 ----
    // '0'..'2' 以外のキー ('3' / 'A' / '9') を注入しても方式が変わらないこと
    const methBefore = S(fm7)[SH_METH_IDX];
    const cntBefore = S(fm7)[0x11];
    for (const code of ['Digit3', 'KeyA', 'Digit9']) {
        kd(fm7, code); step(fm7, 4); ku(fm7, code); step(fm7, 6);
    }
    check("範囲外キー('3'/'A'/'9')注入でも方式不変・再描画なし",
          S(fm7)[SH_METH_IDX] === methBefore && S(fm7)[0x11] === cntBefore,
          `meth ${methBefore}->${S(fm7)[SH_METH_IDX]} cnt ${cntBefore}->${S(fm7)[0x11]}`);
    check('範囲外キー注入後も画面が期待値と一致', exactMismatch(fm7, 0, en, pos.x, pos.y, false, 1, false) === 0,
          `mm=${exactMismatch(fm7, 0, en, pos.x, pos.y, false, 1, false)}`);
}

// =====================================================================
console.log('=== FM-7: FM音源カード無効時はインテリジェント選択でも暴走しない ===');
{
    const fm7 = bootInstance({ machine: 'fm7' });   // FM-7 は FM音源カード無効が既定
    const en = ENOF['fm7'];
    check('ブートし初期描画完了', bootDemo(fm7), `cnt=${S(fm7)[0x11]}`);
    const N = 30;
    // '1' 選択: 方式表示は更新される。だが OPN 応答なし → カーソルは静止
    switchMethod(fm7, 'intel1', 'Digit1');
    check("キー'1'で方式表示は INTELLIGENT P1 に更新 (SH_METH=1)",
          S(fm7)[SH_METH_IDX] === 1, `meth=${S(fm7)[SH_METH_IDX]}`);
    injectPointerMove(fm7, 60, 60);                 // 応答しないので無視される筈
    let visible = 0;
    for (let i = 0; i < N; i++) { step(fm7, 1); if (cursorVisibleAt(fm7, 0, en, 320, 100, 1)) visible++; }
    check('FM-7 intel1 選択時もカーソル中央静止・暴走しない', visible === N, `${visible}/${N}`);
    // '2' も同様
    switchMethod(fm7, 'intel2', 'Digit2');
    injectPointerMove(fm7, -60, -60);
    let vis2 = 0;
    for (let i = 0; i < N; i++) { step(fm7, 1); if (cursorVisibleAt(fm7, 0, en, 320, 100, 2)) vis2++; }
    check('FM-7 intel2 選択時もカーソル中央静止・暴走しない', vis2 === N, `${vis2}/${N}`);
    // '0' でバス復帰 → 再び動く
    switchMethod(fm7, 'bus', 'Digit0');
    const cnt = S(fm7)[0x11];
    injectPointerMove(fm7, 20, 10);
    waitFor(fm7, () => S(fm7)[0x11] > cnt, 300, 2); step(fm7, 6);
    check('FM-7 バス復帰でカーソルが再び動く',
          cursorVisibleAt(fm7, 0, en, 360, 110, 0), `期待 (360,110)`);
}

// =====================================================================
console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
