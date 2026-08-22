#!/usr/bin/env node
// mkd77.mjs — アセンブル済みバイナリから 2D の D77 ブートディスクを組み立てる
//
// 使い方: node mkd77.mjs <main.bin> <sub.bin> <psgdata.bin> <out.d77>
//
// ディスク構成 (2D: 40シリンダ x 2サイド x 16セクタ x 256バイト):
//   通し番号 (LBA) = シリンダ * 32 + サイド * 16 + (セクタ - 1) とみなし、
//   下記の位置へ 3 本のバイナリを並べる。
//
//   LBA       物理位置                       内容 / ロード先
//   --------  -----------------------------  ---------------------------------
//    0        シリンダ0 サイド0 セクタ1       IPL   $0100 (ブートROM が自動ロード)
//    1-3      シリンダ0 サイド0 セクタ2-4     本体  $0200-$04FF (IPL が読む)
//    4-15     シリンダ0 サイド0 セクタ5-16    サブCPU 用プログラム $0500-$10FF
//   16-51     シリンダ0 サイド1 セクタ1 -     PSG 音声データ $1100- (連続配置、
//             シリンダ1 サイド1 セクタ4       IPL がトラック単位で読む)
//
//   main.bin ($0100 起点) は LBA 0-3 (最大 1024 バイト)、
//   sub.bin  (サブ $C100 用のイメージ) は LBA 4-15 (最大 3072 バイト)、
//   psgdata.bin ($1100 起点) は LBA 16-51 (最大 9216 バイト)。
//   その他のセクタは $E5 フィル (未使用)。
//
//   セクタ連結 (LBA 0 の IPL を除く) が「$0200 起点の平坦なメモリ像」に
//   一致するよう詰めて配置してある。make t77 はこの性質を利用して、
//   D77 をそのまま単一チャンクのテープイメージへ変換する。
import { readFileSync, writeFileSync } from 'fs';

const [, , mainBin, subBin, psgBin, outPath] = process.argv;
if (!mainBin || !subBin || !psgBin || !outPath) {
    console.error('usage: node mkd77.mjs <main.bin> <sub.bin> <psgdata.bin> <out.d77>');
    process.exit(1);
}

const CYLS = 40, SIDES = 2, SPT = 16, SSIZE = 256, HEADER = 0x2B0;

// 物理位置 → 通し番号 (LBA)
const lbaOfCHS = (c, h, s) => c * SIDES * SPT + h * SPT + (s - 1);

const MAIN_LBA = 0, MAIN_SECTORS = 4;    // $0100-$04FF
const SUB_LBA = 4, SUB_SECTORS = 12;     // $0500-$10FF
const PSG_LBA = 16, PSG_SECTORS = 36;    // $1100-$34FF (IPL の読込範囲内)

const main = readFileSync(mainBin);
const sub = readFileSync(subBin);
const psg = readFileSync(psgBin);
if (main.length > MAIN_SECTORS * SSIZE) {
    throw new Error(`main.bin too large: ${main.length} > ${MAIN_SECTORS * SSIZE}`);
}
if (sub.length > SUB_SECTORS * SSIZE) {
    throw new Error(`sub.bin too large: ${sub.length} > ${SUB_SECTORS * SSIZE}`);
}
if (psg.length > PSG_SECTORS * SSIZE) {
    throw new Error(`psgdata.bin too large: ${psg.length} > ${PSG_SECTORS * SSIZE}`);
}

// 通し番号 → 中身 (存在しない通し番号は未使用セクタ)
const content = new Map();
for (let i = 0; i < MAIN_SECTORS; i++) content.set(MAIN_LBA + i, [main, i * SSIZE]);
for (let i = 0; i < SUB_SECTORS; i++) content.set(SUB_LBA + i, [sub, i * SSIZE]);
const psgUsed = Math.ceil(psg.length / SSIZE);
for (let i = 0; i < psgUsed; i++) content.set(PSG_LBA + i, [psg, i * SSIZE]);

const trackLen = SPT * (0x10 + SSIZE);
const fileSize = HEADER + CYLS * SIDES * trackLen;
const buf = Buffer.alloc(fileSize, 0);

buf.write('PSGVOICE', 0, 'ascii');    // ディスク名
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

        const ent = content.get(lbaOfCHS(c, h, s));
        if (ent) {
            const [src, off] = ent;
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
const usedMain = Math.ceil(main.length / SSIZE), usedSub = Math.ceil(sub.length / SSIZE);
console.log(`${outPath}: ${fileSize} bytes (2D ${CYLS}cyl x ${SIDES}side x ${SPT}sec x ${SSIZE}B)`);
console.log(`  main.bin    ${main.length} bytes -> LBA 0-${usedMain - 1} of ${MAIN_SECTORS} ($0100-)`);
console.log(`  sub.bin     ${sub.length} bytes -> LBA ${SUB_LBA}-${SUB_LBA + usedSub - 1} of ${SUB_SECTORS} ($0500-)`);
console.log(`  psgdata.bin ${psg.length} bytes -> LBA ${PSG_LBA}-${PSG_LBA + psgUsed - 1} of ${PSG_SECTORS} ($1100-)`);
