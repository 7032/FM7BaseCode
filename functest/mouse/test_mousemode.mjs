#!/usr/bin/env node
// test_mousemode.mjs — マウス接続モード (setMouseMode) とプロトコルの単体テスト
//
// マウス接続仕様の検証項目一式を、OPN レジスタ
// ($FD15/$FD16 の実 I/O 手順) と $FDE8 の読み書きで直接駆動して検証する。
//
//   - フェーズ遷移 / ラッチとクリア / 符号(2の補数) / int8 クランプ
//   - ボタンとトリガマスク / ポート選択不一致フォールバック / タイムアウトリセット
//   - mode='none' 時の不活性 (reg 15 操作でフェーズが進まない)
//   - モード排他: 'bus' で intel 不応答、'intel1'/'intel2' で $FDE8 が $80、
//     'none' で両方式とも未接続応答
//   - モード切替時の位相・ラッチ・累積リセット
//   - setMouseEnabled(true) → 'bus' 相当の互換動作、setMousePort の追従
//   - FM-7: FM Sound Card 無効時は OPN ゲートによりマウス不応答
//
// 機種マトリクス: FM77AV / FM77AV40 / FM77AV40EX / FM-7 (FM Sound Card 有効)
//
// 使い方: node test_mousemode.mjs
//   エミュレータ core は環境変数 WEBM7_DIR で指定 (未指定時はリポジトリ直下の
//   vendor/WebM7 を探す)。見つからない場合はスキップして正常終了する。
//   ROM は環境変数 FM7_ROM_DIR で指定 (fm7/ と fm77av/ のサブディレクトリを
//   持つこと)。未設定・不在の場合もスキップして正常終了する。

import { readFileSync, existsSync } from 'fs';
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

const HERE = dirname(fileURLToPath(import.meta.url));

// ---- 公開エミュレータ core (WebM7) の解決 ----
//   WEBM7_DIR で明示指定。未指定時はリポジトリ直下の vendor/WebM7 を探す。
//   見つからなければテストをスキップして正常終了する。
const WEBM7_CANDIDATES = process.env.WEBM7_DIR
    ? [process.env.WEBM7_DIR]
    : [join(HERE, '../../../vendor/WebM7'), join(HERE, '../../vendor/WebM7')];
const WEBM7_DIR = WEBM7_CANDIDATES.find(d => existsSync(join(d, 'core', 'fm7.js')));
if (!WEBM7_DIR) {
    console.log('SKIP: WebM7 core が見つからないためスキップ (WEBM7_DIR を設定するか vendor/WebM7 に配置してください)');
    process.exit(0);
}
const { FM7 } = await import(pathToFileURL(join(WEBM7_DIR, 'core', 'fm7.js')).href);
const { usToCycles } = await import(pathToFileURL(join(WEBM7_DIR, 'core', 'scheduler.js')).href);

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

let failures = 0;
const check = (label, cond, extra = '') => {
    console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}${extra ? '  (' + extra + ')' : ''}`);
    if (!cond) failures++;
};
const hex = (arr) => arr.map(v => '$' + v.toString(16).toUpperCase().padStart(2, '0')).join(' ');
const eq = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);

const realLog = console.log;
const quiet = (fn) => {
    console.log = () => {}; console.warn = () => {};
    try { return fn(); } finally { console.log = realLog; }
};

const makeMachine = (machine, { fmCard = false } = {}) => {
    const fm7 = new FM7();
    quiet(() => {
        fm7.loadFBasicROM(new Uint8Array(readFileSync(`${AV}/fbasic30.rom`)));
        fm7.loadBootROM(new Uint8Array(readFileSync(`${FM7R}/boot_dos.rom`)));
        fm7.loadBootBasROM(new Uint8Array(readFileSync(`${FM7R}/boot_bas.rom`)));
        fm7.loadSubROM(new Uint8Array(readFileSync(`${FM7R}/subsys_c.rom`)));
        fm7.loadSubROM_A(new Uint8Array(readFileSync(`${AV}/subsys_a.rom`)));
        fm7.loadSubROM_B(new Uint8Array(readFileSync(`${AV}/subsys_b.rom`)));
        fm7.loadInitiateROM(new Uint8Array(readFileSync(`${AV}/initiate.rom`)));
        fm7.setMachineType(machine);
        if (fmCard) fm7.setFMCard(true);
        fm7.reset();
    });
    return fm7;
};

// ---- 実 I/O 手順 (CPU が行うのと同じ $FD15/$FD16 経由) ----
// OPN レジスタ書き込み: ADDRESS → WRITEDAT
const opnWriteReg = (fm7, reg, val) => {
    fm7._mainWrite(0xFD16, reg);
    fm7._mainWrite(0xFD15, 0x03);   // ADDRESS
    fm7._mainWrite(0xFD15, 0x00);   // INACTIVE
    fm7._mainWrite(0xFD16, val);
    fm7._mainWrite(0xFD15, 0x02);   // WRITEDAT
    fm7._mainWrite(0xFD15, 0x00);
};
// OPN ポート A 読み出し: selreg=14 → JOYSTICK モードでデータバスを読む
const opnReadPortA = (fm7) => {
    fm7._mainWrite(0xFD16, 14);
    fm7._mainWrite(0xFD15, 0x03);   // ADDRESS
    fm7._mainWrite(0xFD15, 0x00);
    fm7._mainWrite(0xFD15, 0x09);   // JOYSTICK
    const v = fm7._mainRead(0xFD16);
    fm7._mainWrite(0xFD15, 0x00);
    return v;
};
// バスマウス $FDE8
const busLatch = (fm7) => fm7._mainWrite(0xFDE8, 0x03);
const busRead = (fm7) => fm7._mainRead(0xFDE8);
// ストローブのタイムアウト判定は scheduler.mainCyclesTotal の比較のみなので、
// CPU を走らせずにサイクル計上だけ進める
const advanceUs = (fm7, us) => { fm7.scheduler.mainCyclesTotal += usToCycles(us); };

// reg 15 ストローブ駆動ヘルパ (ポート選択 + トリガビット + ストローブレベル)
class IntelDriver {
    constructor(fm7, port) {
        this.fm7 = fm7;
        this.port = port;
        this.level = false;
        this.trigger = true;
        this.write();
    }
    get strobeBit() { return this.port === 1 ? 0x10 : 0x20; }
    get base() {
        return (this.port === 1 ? 0x00 : 0x40) |
               (this.trigger ? (this.port === 1 ? 0x03 : 0x0C) : 0x00);
    }
    write(raw = null) {
        opnWriteReg(this.fm7, 15, raw !== null ? raw : (this.base | (this.level ? this.strobeBit : 0)));
    }
    edge() { this.level = !this.level; this.write(); }
    read() { return opnReadPortA(this.fm7); }
    sample() {
        const out = [];
        for (let i = 0; i < 4; i++) { this.edge(); out.push(this.read()); }
        return out;
    }
}

// =====================================================================
// インテリジェントマウス プロトコル一式 (指定ポートで)
// =====================================================================
const intelSuite = (fm7, port, label) => {
    console.log(`--- [${label}] intel${port}: プロトコル一式 ---`);
    fm7.setMouseMode(`intel${port}`);
    const d = new IntelDriver(fm7, port);
    // ボタン開放 + トリガ有効: 応答は $C0 | $30 | ニブル = $F0 | ニブル

    // フェーズ遷移 + 符号 (dx=+18=$12, dy=-3=$FD)
    fm7.addMouseDelta(18, -3);
    let s = d.sample();
    check('フェーズ順 X上位→X下位→Y上位→Y下位 (dx=+18, dy=-3)',
          eq(s, [0xF1, 0xF2, 0xFF, 0xFD]), hex(s));
    const x = ((s[0] & 0x0F) << 4) | (s[1] & 0x0F);
    const yb = ((s[2] & 0x0F) << 4) | (s[3] & 0x0F);
    check('2の補数の符号付き8bit (X=+18, Y=-3)',
          x === 0x12 && ((yb << 24) >> 24) === -3, `X=$${x.toString(16)} Y=$${yb.toString(16)}`);

    // ラッチ時に累積がクリアされる (直後のシーケンスは 0)
    s = d.sample();
    check('ラッチ後に累積クリア (次サンプルは 0)', eq(s, [0xF0, 0xF0, 0xF0, 0xF0]), hex(s));

    // シーケンス途中の delta はラッチ済み値に混入せず、次のフェーズ 0 で反映
    fm7.addMouseDelta(0x34, 0x56);
    d.edge();                        // フェーズ 0 → ラッチ (0x34, 0x56)
    fm7.addMouseDelta(1, 1);         // 読み出し中の delta
    let mid = [d.read()];
    for (let i = 0; i < 3; i++) { d.edge(); mid.push(d.read()); }
    check('シーケンス途中の delta は現サンプルに混入しない',
          eq(mid, [0xF3, 0xF4, 0xF5, 0xF6]), hex(mid));
    s = d.sample();
    check('途中の delta は次のフェーズ 0 でラッチされる',
          eq(s, [0xF0, 0xF1, 0xF0, 0xF1]), hex(s));

    // int8 クランプ (+300 → +127=$7F、-500 → -127=$81)
    fm7.addMouseDelta(300, -500);
    s = d.sample();
    check('int8 クランプ (+300→+127, -500→-127)',
          eq(s, [0xF7, 0xFF, 0xF8, 0xF1]), hex(s));

    // ボタンとトリガマスク (フェーズ 0 で静止して読む)
    fm7.setMouseButtons(true, false);           // 左押下 (active low: bit4=0)
    check('左ボタン押下が bit4 に反映 (トリガ有効)',
          (d.read() & 0x30) === 0x20, `$${d.read().toString(16)}`);
    d.trigger = false; d.write();               // トリガビットでマスク
    check('トリガマスク時はボタンビットが 0',
          (d.read() & 0x30) === 0x00, `$${d.read().toString(16)}`);
    d.trigger = true; d.write();
    fm7.setMouseButtons(false, false);
    check('ボタン解放で bit4-5 が 1 に戻る',
          (d.read() & 0x30) === 0x30, `$${d.read().toString(16)}`);
    check('bit6-7 は常に 1', (d.read() & 0xC0) === 0xC0);

    // ポート選択不一致フォールバック
    fm7.addMouseDelta(0x25, 0);
    d.edge();                                    // ラッチ → フェーズ 1
    check('一致ポートでは X 上位を応答', d.read() === 0xF2, `$${d.read().toString(16)}`);
    const other = (port === 1 ? 0x40 : 0x00) | (d.level ? d.strobeBit : 0);
    d.write(other);                              // 別ポート選択 (ストローブレベルは維持)
    const fb = d.read();
    check('ポート選択不一致でゲームパッド読みへフォールバック', fb === 0xFF, `$${fb.toString(16)}`);
    d.write();                                   // 元のポート選択へ戻す
    check('ポート選択復帰で応答再開 (フェーズ維持)', d.read() === 0xF2, `$${d.read().toString(16)}`);
    for (let i = 0; i < 3; i++) d.edge();        // シーケンスを完了させる

    // タイムアウトリセット (2 ms 超の停止で次エッジがフェーズ先頭に戻る)
    fm7.addMouseDelta(0x34, 0);
    d.edge();                                    // ラッチ → フェーズ 1
    d.edge();                                    // フェーズ 2
    check('停止前はフェーズ 2 (X 下位)', d.read() === 0xF4, `$${d.read().toString(16)}`);
    fm7.addMouseDelta(0x2A, 0);
    advanceUs(fm7, 2500);
    d.edge();                                    // タイムアウト → フェーズ 0 で再ラッチ → 1
    check('タイムアウト後の再開でフェーズ先頭へ (新規ラッチの X 上位)',
          d.read() === 0xF2, `$${d.read().toString(16)}`);
    for (let i = 0; i < 3; i++) d.edge();

    // モード排他: intel 選択中は $FDE8 が未接続値
    busLatch(fm7);
    check(`intel${port} 選択中は $FDE8 読みが未接続値 $80`, busRead(fm7) === 0x80,
          `$${busRead(fm7).toString(16)}`);
};

// =====================================================================
// バスマウス応答一式 (mode='bus' で)
// =====================================================================
const busSuite = (fm7, label) => {
    console.log(`--- [${label}] bus: プロトコル一式とモード排他 ---`);
    fm7.setMouseMode('bus');
    // バスマウス規約: 符号反転ラッチ、読み順 X下位→X上位→Y下位→Y上位、bit7=1
    fm7.addMouseDelta(5, -2);                    // ラッチ値: X=-5=$FB, Y=+2=$02
    busLatch(fm7);
    const s = [busRead(fm7), busRead(fm7), busRead(fm7), busRead(fm7)];
    check('$FDE8 読み順と符号反転 (dx=+5→$FB, dy=-2→$02)',
          eq(s, [0x8B, 0x8F, 0x82, 0x80]), hex(s));
    fm7.setMouseButtons(true, false);
    check('$FDE8 ボタン bit4 反映 (押下=1)', (busRead(fm7) & 0x30) === 0x10);
    fm7.setMouseButtons(false, false);

    // モード排他: bus 選択中はインテリジェントマウスが不応答
    const d = new IntelDriver(fm7, 1);
    for (let i = 0; i < 4; i++) d.edge();
    check('bus 選択中は reg 15 エッジでフェーズが進まない', fm7._mouseIntelPhase === 0,
          `phase=${fm7._mouseIntelPhase}`);
    check('bus 選択中はポート A 読みがフォールバック ($FF)', d.read() === 0xFF,
          `$${d.read().toString(16)}`);
};

// =====================================================================
// mode='none' の不活性
// =====================================================================
const noneSuite = (fm7, label) => {
    console.log(`--- [${label}] none: 両方式とも未接続応答 ---`);
    fm7.setMouseMode('none');
    busLatch(fm7);
    check(`none 時は $FDE8 が未接続値 $80`, busRead(fm7) === 0x80, `$${busRead(fm7).toString(16)}`);
    const d = new IntelDriver(fm7, 1);
    for (let i = 0; i < 4; i++) d.edge();
    check('none 時は reg 15 の方向ビット操作でフェーズが進まない',
          fm7._mouseIntelPhase === 0, `phase=${fm7._mouseIntelPhase}`);
    check('none 時のポート A 読みはフォールバック ($FF)', d.read() === 0xFF);
    fm7.addMouseDelta(5, 5);
    check('none 時は addMouseDelta が累積されない',
          fm7._mouseAccDX === 0 && fm7._mouseAccDY === 0,
          `acc=(${fm7._mouseAccDX},${fm7._mouseAccDY})`);
};

// =====================================================================
// 機種マトリクス: OPN が使える構成でインテリジェントマウスを検証
// =====================================================================
const CONFIGS = [
    ['fm77av', 'fm77av', {}],
    ['fm77av40', 'fm77av40', {}],
    ['fm77av40ex', 'fm77av40ex', {}],
    ['fm7+fmcard', 'fm7', { fmCard: true }],
];
for (const [label, machine, opt] of CONFIGS) {
    console.log(`=== [${label}] ===`);
    const fm7 = makeMachine(machine, opt);
    noneSuite(fm7, label);
    busSuite(fm7, label);
    intelSuite(fm7, 1, label);
    intelSuite(fm7, 2, label);
}

// =====================================================================
console.log('=== モード切替リセット (fm77av) ===');
{
    const fm7 = makeMachine('fm77av');
    fm7.setMouseMode('bus');
    fm7.addMouseDelta(9, 9);
    busLatch(fm7);
    busRead(fm7);                                // フェーズ 1 まで進める
    fm7.setMouseButtons(true, true);
    fm7.setMouseMode('intel1');
    check('bus→intel1 切替でバス側の位相・ラッチ・累積・ボタンがリセット',
          fm7._mouseBusPhase === 0 && fm7._mouseBusDX === 0 && fm7._mouseBusDY === 0 &&
          fm7._mouseAccDX === 0 && fm7._mouseAccDY === 0 && fm7._mouseBtn === 0x30);

    const d = new IntelDriver(fm7, 1);
    fm7.addMouseDelta(7, 0);
    d.edge();                                    // ラッチ → フェーズ 1
    fm7.addMouseDelta(2, 0);
    fm7.setMouseMode('bus');
    check('intel1→bus 切替で intel 側の位相・ラッチ・累積・ストローブがリセット',
          fm7._mouseIntelPhase === 0 && fm7._mouseIntelDX === 0 && fm7._mouseIntelDY === 0 &&
          !fm7._mouseIntelStrobe && fm7._mouseIntelLastEdge === 0 &&
          fm7._mouseAccDX === 0 && fm7._mouseAccDY === 0);

    fm7.setMouseMode('intel1');
    fm7.setMouseMode('intel2');
    check('intel1→intel2 切替でポートが 2 へ', fm7._intelMousePort === 2);
    check('不正値は none に丸める', (fm7.setMouseMode('garbage'), fm7._mouseMode === 'none'));
}

// =====================================================================
console.log('=== 既存 API 互換 (fm77av) ===');
{
    const fm7 = makeMachine('fm77av');
    fm7.setMouseEnabled(true);
    check("setMouseEnabled(true) は 'bus' 相当", fm7._mouseMode === 'bus');
    fm7.addMouseDelta(3, 0);
    busLatch(fm7);
    const xlo = busRead(fm7);
    check('互換ラッパー経由でバスマウスが応答 (X下位=$D)', xlo === 0x8D,
          `$${xlo.toString(16)}`);
    fm7.setMouseEnabled(false);
    check("setMouseEnabled(false) は 'none' 相当", fm7._mouseMode === 'none');
    check('無効化後は $FDE8 が未接続値 $80', busRead(fm7) === 0x80);

    fm7.setMousePort(2);
    check("非 intel モード中の setMousePort はポートのみ設定",
          fm7._mouseMode === 'none' && fm7._intelMousePort === 2);
    fm7.setMouseMode('intel1');
    fm7.setMousePort(2);
    check("intel モード中の setMousePort(2) でモードが 'intel2' へ追従",
          fm7._mouseMode === 'intel2' && fm7._intelMousePort === 2);
    const d = new IntelDriver(fm7, 2);
    fm7.addMouseDelta(18, -3);
    const s = d.sample();
    check('追従後にポート 2 で応答', eq(s, [0xF1, 0xF2, 0xFF, 0xFD]), hex(s));

    quiet(() => fm7.reset());
    check("reset() は接続モードとポート選択を保持", fm7._mouseMode === 'intel2' && fm7._intelMousePort === 2);
    check('reset() でハード位相はクリア',
          fm7._mouseIntelPhase === 0 && fm7._mouseIntelDX === 0 && fm7._mouseIntelDY === 0);
    const d2 = new IntelDriver(fm7, 2);
    fm7.addMouseDelta(1, 1);
    const s2 = d2.sample();
    check('reset() 後も同モードで応答継続', eq(s2, [0xF0, 0xF1, 0xF0, 0xF1]), hex(s2));
}

// =====================================================================
console.log('=== FM-7: FM Sound Card ゲート ===');
{
    const fm7 = makeMachine('fm7');              // FM Sound Card 無効
    fm7.setMouseMode('intel1');
    check('カード無効時は $FD16 読みがオープンバス ($FF)', fm7._mainRead(0xFD16) === 0xFF);
    const d = new IntelDriver(fm7, 1);
    for (let i = 0; i < 4; i++) d.edge();
    check('カード無効時は reg 15 書き込みがゲートされフェーズが進まない',
          fm7._mouseIntelPhase === 0, `phase=${fm7._mouseIntelPhase}`);
    fm7.setFMCard(true);                         // カード有効化で応答開始
    const d2 = new IntelDriver(fm7, 1);
    fm7.addMouseDelta(18, -3);
    const s = d2.sample();
    check('カード有効化後は intel1 が応答', eq(s, [0xF1, 0xF2, 0xFF, 0xFD]), hex(s));
    check('カード有効でもバスマウス非選択なので $FDE8 は $80', busRead(fm7) === 0x80);
}

// =====================================================================
console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
