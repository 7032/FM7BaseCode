#!/usr/bin/env node
// mkd77.mjs — アセンブル済みバイナリから 2D の D77 ブートディスクを組み立てる
//
// 使い方: node mkd77.mjs <main.bin> <sub.bin> <out.d77>
//
// ディスク構成 (2D: 40シリンダ x 2サイド x 16セクタ x 256バイト):
//   トラック0 サイド0 セクタ 1-15 : main.bin ($0100- のメモリイメージ)
//     セクタ1 → $0100 はブートローダが自動ロードし $0100 へジャンプ
//     セクタ2-16 (サイド0) とサイド1 セクタ1-16 は IPL が $0200- へロード
//   トラック0 サイド0 セクタ16 + サイド1 セクタ1-16 :
//     sub.bin (サブCPU用プログラム、$1000-$20FF に置かれる)
//   その他のセクタ : $E5 フィル (未使用)
import { readFileSync, writeFileSync } from 'fs';

const [, , mainBin, subBin, outPath] = process.argv;
if (!mainBin || !subBin || !outPath) {
    console.error('usage: node mkd77.mjs <main.bin> <sub.bin> <out.d77>');
    process.exit(1);
}

const CYLS = 40, SIDES = 2, SPT = 16, SSIZE = 256, HEADER = 0x2B0;
const MAIN_SECTORS = 15, SUB_SECTORS = 17;   // サブは サイド0 セクタ16 + サイド1 全16

const main = readFileSync(mainBin);
const sub = readFileSync(subBin);
if (main.length > MAIN_SECTORS * SSIZE) {
    throw new Error(`main.bin too large: ${main.length} > ${MAIN_SECTORS * SSIZE}`);
}
if (sub.length > SUB_SECTORS * SSIZE) {
    throw new Error(`sub.bin too large: ${sub.length} > ${SUB_SECTORS * SSIZE}`);
}

const trackLen = SPT * (0x10 + SSIZE);
const fileSize = HEADER + CYLS * SIDES * trackLen;
const buf = Buffer.alloc(fileSize, 0);

buf.write('MOUSEDEMO', 0, 'ascii');   // ディスク名
buf[0x1A] = 0;                        // ライトプロテクトなし
buf[0x1B] = 0x00;                     // メディアタイプ: 2D
buf.writeUInt32LE(fileSize, 0x1C);    // ファイルサイズ

let pos = HEADER;
for (let idx = 0; idx < CYLS * SIDES; idx++) {
    const c = Math.floor(idx / SIDES), h = idx % SIDES;
    buf.writeUInt32LE(pos, 0x20 + idx * 4);   // トラックオフセットテーブル
    for (let s = 1; s <= SPT; s++) {
        buf[pos + 0x00] = c;                  // C
        buf[pos + 0x01] = h;                  // H
        buf[pos + 0x02] = s;                  // R
        buf[pos + 0x03] = 1;                  // N=1 → 256バイト
        buf.writeUInt16LE(SPT, pos + 0x04);   // トラック内セクタ数
        buf.writeUInt16LE(SSIZE, pos + 0x0E); // データ長
        pos += 0x10;

        let src = null, off = 0;
        if (c === 0 && h === 0) {
            if (s <= MAIN_SECTORS) { src = main; off = (s - 1) * SSIZE; }
            else { src = sub; off = (s - 1 - MAIN_SECTORS) * SSIZE; }
        } else if (c === 0 && h === 1) {
            // サイド1: サブプログラムの続き (サイド0 の残り分の後ろ)
            src = sub; off = (16 - MAIN_SECTORS + s - 1) * SSIZE;
        }
        if (src) {
            for (let i = 0; i < SSIZE; i++) {
                buf[pos + i] = (off + i < src.length) ? src[off + i] : 0x00;
            }
        } else {
            buf.fill(0xE5, pos, pos + SSIZE);
        }
        pos += SSIZE;
    }
}

writeFileSync(outPath, buf);
console.log(`${outPath}: ${fileSize} bytes (2D ${CYLS}cyl x ${SIDES}side x ${SPT}sec x ${SSIZE}B)`);
console.log(`  main.bin ${main.length} bytes -> track0 side0 sec1-${MAIN_SECTORS}`);
console.log(`  sub.bin  ${sub.length} bytes -> track0 side0 sec${MAIN_SECTORS + 1}-16 + side1 sec1-16`);
