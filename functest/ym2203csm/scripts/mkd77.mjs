#!/usr/bin/env node
// mkd77.mjs — アセンブル済みバイナリから 2D の D77 ブートディスクを組み立てる
//
// 使い方: node mkd77.mjs <main.bin> <sub.bin> <img.bin> <out.d77>
//
// ディスク構成 (2D: 40シリンダ x 2サイド x 16セクタ x 256バイト):
//   通し番号 (LBA) = シリンダ * 32 + サイド * 16 + (セクタ - 1) とみなし、
//   下記の位置へ 3 本のバイナリを並べる。
//
//   LBA       物理位置                       内容 / ロード先
//   --------  -----------------------------  ---------------------------------
//    0        シリンダ0 サイド0 セクタ1       IPL   $0100 (ブートROM が自動ロード)
//    1-15     シリンダ0 サイド0 セクタ2-16    本体  $0200-$10FF (IPL が読む)
//   16-31     シリンダ0 サイド1 セクタ1-16    本体  $1100-$20FF (IPL が読む)
//   32-43     シリンダ1 サイド0 セクタ1-12    サブCPU 用プログラム $2100-$2CFF
//   64-       シリンダ2 サイド0 セクタ1 -     画像データ (パレット + 文字色 + RLE)
//                                            メインが 1 セクタずつ読んで展開する
//
//   main.bin ($0100 起点) は LBA 0-31 (最大 8192 バイト)、
//   sub.bin  (サブ $C100 用のイメージ) は LBA 32-43 (最大 3072 バイト)、
//   img.bin  (画像データ) は LBA 64 以降に必要なだけ置く。
//   その他のセクタは $E5 フィル (未使用)。
import { readFileSync, writeFileSync } from 'fs';

const [, , mainBin, subBin, imgBin, outPath] = process.argv;
if (!mainBin || !subBin || !imgBin || !outPath) {
    console.error('usage: node mkd77.mjs <main.bin> <sub.bin> <img.bin> <out.d77>');
    process.exit(1);
}

const CYLS = 40, SIDES = 2, SPT = 16, SSIZE = 256, HEADER = 0x2B0;

// 物理位置 → 通し番号 (LBA)
const lbaOfCHS = (c, h, s) => c * SIDES * SPT + h * SPT + (s - 1);

const MAIN_LBA = 0, MAIN_SECTORS = 32;   // $0100-$20FF
const SUB_LBA = 32, SUB_SECTORS = 12;    // $2100-$2CFF
const IMG_LBA = 64;                      // シリンダ2 サイド0 から

// 画像データは 1 セクタ読むごとに RLE 展開とサブ CPU への転送 (約 20ms) を
// 挟むため、ディスク上では 3 枠おき (インターリーブ 3) に並べる。
// FDD は 300rpm (1 周 200ms、1 セクタ枠 12.5ms) で回り続けているので、
// 連番で並べると次のセクタを要求する頃には目的の枠を通り過ぎていて
// 1 回転待たされ、129 セクタで 25 秒以上かかってしまう。3 枠おき (37.5ms) なら
// 処理が間に合い、5 秒程度で読み切れる。
// 読み出し側 (src/csmdemo.asm の ISEQT) と同じ順序でなければならない。
const IMG_ORDER = [1, 4, 7, 10, 13, 16, 3, 6, 9, 12, 15, 2, 5, 8, 11, 14];

const main = readFileSync(mainBin);
const sub = readFileSync(subBin);
const img = readFileSync(imgBin);
if (main.length > MAIN_SECTORS * SSIZE) {
    throw new Error(`main.bin too large: ${main.length} > ${MAIN_SECTORS * SSIZE}`);
}
if (sub.length > SUB_SECTORS * SSIZE) {
    throw new Error(`sub.bin too large: ${sub.length} > ${SUB_SECTORS * SSIZE}`);
}
const IMG_SECTORS = Math.ceil(img.length / SSIZE);
if (IMG_LBA + IMG_SECTORS > CYLS * SIDES * SPT) {
    throw new Error(`img.bin too large: ${img.length} bytes (${IMG_SECTORS} sectors)`);
}

// 通し番号 → 中身 (存在しない通し番号は未使用セクタ)
const content = new Map();
for (let i = 0; i < MAIN_SECTORS; i++) content.set(MAIN_LBA + i, [main, i * SSIZE]);
for (let i = 0; i < SUB_SECTORS; i++) content.set(SUB_LBA + i, [sub, i * SSIZE]);
// 画像は「トラック内の読み出し順 IMG_ORDER」に沿って配置する
for (let i = 0; i < IMG_SECTORS; i++) {
    const track = Math.floor((IMG_LBA + i) / SPT);          // シリンダ*2 + サイド
    const k = (IMG_LBA + i) % SPT;                           // トラック内の読み出し順
    const c = Math.floor(track / SIDES), h = track % SIDES;
    content.set(lbaOfCHS(c, h, IMG_ORDER[k]), [img, i * SSIZE]);
}

const trackLen = SPT * (0x10 + SSIZE);
const fileSize = HEADER + CYLS * SIDES * trackLen;
const buf = Buffer.alloc(fileSize, 0);

buf.write('CSMDEMO', 0, 'ascii');     // ディスク名
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
console.log(`  main.bin ${main.length} bytes -> LBA 0-${usedMain - 1} of ${MAIN_SECTORS} ($0100-)`);
console.log(`  sub.bin  ${sub.length} bytes -> LBA ${SUB_LBA}-${SUB_LBA + usedSub - 1} of ${SUB_SECTORS} ($2100-)`);
console.log(`  img.bin  ${img.length} bytes -> LBA ${IMG_LBA}-${IMG_LBA + IMG_SECTORS - 1} ` +
            `(シリンダ2 サイド0 セクタ1 から ${IMG_SECTORS} セクタ)`);
