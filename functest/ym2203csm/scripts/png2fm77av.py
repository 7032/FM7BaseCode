#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""png2fm77av.py -- PNG 画像を FM77AV 320x200 グラフィック画面用のデータへ変換する。

方式は「パレット方式」である。元画像はパレット (インデックスカラー) 画像で
実色数が 64 以下なので、**色を量子化せず**、アナログパレットの 64 エントリへ
元画像の色をそのまま設定し、画面には 6 ビット (= 64 色) の添字だけを置く。
1 チャネル 8 ビット -> 4 ビットへの丸めだけが誤差要因であり、ディザリングは
一切不要である。

===============================================================================
FM77AV 320x200 4096色モードの VRAM 構成 (サブCPU から見た配置)
===============================================================================

    1 ライン = 40 バイト (320 ドット / 8 ドット per バイト)。
    バイト内は MSB (bit7) が左端のドット。
    1 プレーン = 40 * 200 = 8000 バイト。

    12 サブプレーン構成:

        ページ0 ($D430 bit5 = 0)      ページ1 ($D430 bit5 = 1)
        ------------------------      ------------------------
        $0000  B3                     $0000  B1
        $2000  B2                     $2000  B0
        $4000  R3                     $4000  R1
        $6000  R2                     $6000  R0
        $8000  G3                     $8000  G1
        $A000  G2                     $A000  G0

    12 枚のサブプレーンから 1 ドットあたり 12 ビットのアナログパレット添字が
    組み立てられる。ビット割当は下記のとおり:

        添字 bit11..8 = G3 G2 G1 G0   (ページ0 $8000 / $A000、ページ1 $8000 / $A000)
        添字 bit7 ..4 = R3 R2 R1 R0   (ページ0 $4000 / $6000、ページ1 $4000 / $6000)
        添字 bit3 ..0 = B3 B2 B1 B0   (ページ0 $0000 / $2000、ページ1 $0000 / $2000)

    すなわち 添字 = (G<<8) | (R<<4) | B (各 4 ビット)。
    アナログパレットを恒等マップにすれば直接発色になるが、本スクリプトは
    恒等マップにせず、必要な 64 添字にだけ実際の色を設定する。

===============================================================================
本スクリプトの 6 プレーン割当 (ページ0 の 6 面のみを使う)
===============================================================================

    ページ1 は使わない (全ビット 0 のまま)。よって使える添字ビットは
    ページ0 の 6 面が担う bit11 / bit10 / bit7 / bit6 / bit3 / bit2 だけで、
    bit9 / bit8 / bit5 / bit4 / bit1 / bit0 は常に 0 になる。

    ピクセルのパレット添字 n (0..63) のビット n5..n0 を次のように割り当てる:

        n5 -> G3 プレーン (ページ0 $8000)  -> 12 ビット添字の bit11
        n4 -> G2 プレーン (ページ0 $A000)  -> 12 ビット添字の bit10
        n3 -> R3 プレーン (ページ0 $4000)  -> 12 ビット添字の bit7
        n2 -> R2 プレーン (ページ0 $6000)  -> 12 ビット添字の bit6
        n1 -> B3 プレーン (ページ0 $0000)  -> 12 ビット添字の bit3
        n0 -> B2 プレーン (ページ0 $2000)  -> 12 ビット添字の bit2

    まとめると、n を 2 ビットずつ G/R/B に分けたものが各ニブルの上位 2 ビットに
    入る形になる:

        n     = (nG << 4) | (nR << 2) | nB          (nG/nR/nB は各 2 ビット)
        添字12 = (nG << 10) | (nR << 6) | (nB << 2)

    パレットテーブル imgpal は、この「添字12」の番地へ元画像の色を書く。

===============================================================================
パレット設定の書式 (imgpal、1 エントリ 5 バイト)
===============================================================================

    FM77AV のアナログパレットは I/O $FD30-$FD34 で設定する (メインCPU 側)。
    imgpal は 1 エントリ 5 バイトで、先頭から順に下記へ書けばよい:

        + 0 : $FD30 へ書く (パレット添字の上位 4 ビット = 添字12 の bit11-8)
        + 1 : $FD31 へ書く (パレット添字の下位 8 ビット = 添字12 の bit7-0)
        + 2 : $FD32 へ書く (青 B、下位ニブルのみ有効)
        + 3 : $FD33 へ書く (赤 R、下位ニブルのみ有効)
        + 4 : $FD34 へ書く (緑 G、下位ニブルのみ有効)

    IMGPALN 個 (= 64) のエントリを先頭から順に 5 バイトずつ書けば設定完了。
    書き込みは FM77AV 以降でのみ行うこと (FM-7 には存在しない)。

===============================================================================
出力データの並び (非圧縮ストリーム)
===============================================================================

    B3, B2, R3, R2, G3, G2 の順に 8000 バイトずつ連結した 48000 バイト。
    展開側は 8000 バイトごとに書き込み先を
    $0000 / $2000 / $4000 / $6000 / $8000 / $A000 と進める (ページ0 のみ)。

===============================================================================
RLE 圧縮形式の仕様 (6809 側の展開ルーチンはこの仕様に厳密に従うこと)
===============================================================================

    非圧縮ストリーム全体 (プレーン境界で切らない、1 本のストリーム) を
    次のトークン列へ符号化する。ストリームは終端バイトで終わる。

      制御バイト C を読む
        C == $00            : 終端。展開を終了する。
        C >= $80 (bit7 = 1) : ラン。n = C & $7F (1..127)。
                              続く 1 バイト V を読み、V を n 回出力する。
                              トークン長は 2 バイト。
        C <  $80 (bit7 = 0) : リテラル。n = C (1..127)。
                              続く n バイトをそのまま出力する。
                              トークン長は 1 + n バイト。

    - n は必ず 1..127 であり 0 にはならない ($00 は終端専用、$80 は出現しない)。
    - トークンはプレーンの境界 (8000 バイトごと) をまたぐことがある。展開側は
      「出力を 8000 バイト書いたら次の書き込み先プレーンへ切り替える」形で
      処理すること。
    - 展開後の総バイト数は IMGPLANES * IMGPLNSZ に一致する。

    6809 での展開の骨子 (X = 圧縮データ、Y = 出力先):

        loop    lda  ,x+          ; 制御バイト
                beq  done         ; $00 で終端
                bmi  runtok       ; bit7=1 ならラン
                tfr  a,b          ; リテラル: b = n
        litlp   lda  ,x+
                sta  ,y+          ; (8000 バイト境界でプレーン切替)
                decb
                bne  litlp
                bra  loop
        runtok  anda #$7F
                tfr  a,b          ; b = n
                lda  ,x+          ; 値
        runlp   sta  ,y+          ; (8000 バイト境界でプレーン切替)
                decb
                bne  runlp
                bra  loop
        done

===============================================================================
使い方
===============================================================================

    python3 scripts/png2fm77av.py                        … assets/fm77av_img.s を生成
    python3 scripts/png2fm77av.py --preview out.png      … 逆変換プレビューも書く
    python3 scripts/png2fm77av.py --text-color FFFF00    … 重ね書き文字の色を指定

    既定の入力 : assets/FM77AV.PNG
    既定の出力 : assets/fm77av_img.s

    --text-color は「画像が使っていない空きスロットへ置く色」を変えるだけなので、
    色を変えても画像本体 (imgdata の RLE ストリーム) は 1 バイトも変わらない。
"""

from __future__ import annotations

import argparse
import os
import sys

import numpy as np

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    sys.stderr.write("Pillow (PIL) が必要です: pip install Pillow\n")
    raise

# =============================================================================
# 画面定数
# =============================================================================

SCR_W          = 320                    # 横ドット数
SCR_H          = 200                    # 縦ライン数
BYTES_PER_LINE = SCR_W // 8             # 40
PLANE_SIZE     = BYTES_PER_LINE * SCR_H # 8000 バイト / 1 サブプレーン
NPLANES        = 6                      # 使うサブプレーン数 (ページ0 のみ)
NPAL           = 64                     # パレットエントリ数 (6 ビット添字)

# ページ0 の 6 サブプレーン。
#   (名前, サブCPU 窓のオフセット, 12 ビット添字でのビット位置, 添字 n でのビット位置)
# 添字ビット位置はエミュレータ実装 (vendor/WebM7/core/display.js の
# _render320x200 における 12 ビット添字の組み立て) と一致させてある。
PLANES = [
    ("B3", 0x0000, 3, 1),
    ("B2", 0x2000, 2, 0),
    ("R3", 0x4000, 7, 3),
    ("R2", 0x6000, 6, 2),
    ("G3", 0x8000, 11, 5),
    ("G2", 0xA000, 10, 4),
]

# RLE のトークン最大長 (制御バイトの bit0-6)
RLE_MAX_RUN = 127
RLE_MAX_LIT = 127

# パレット割当の最適化 (山登り法)。乱数種と反復回数を固定して結果を決定的にする。
OPT_ITERS = 60000
OPT_SEED  = 20260813

# 重ね書き文字 ("PUSH ANY KEY") の既定色。空きスロットへこの色を置く。
# 画像の背景 (暗い制服・キーボードの黒い縁) に対して輝度差・色差が最大になる
# 黄色を既定とする。--text-color RRGGBB で差し替えられる。
DEF_TEXT_COLOR = "FFFF00"


# =============================================================================
# 添字の写像
# =============================================================================

def n_to_idx12(n: int) -> int:
    """6 ビットのピクセル添字 n を 12 ビットのアナログパレット添字へ写す。

    ページ1 が全 0 なので bit9/8/5/4/1/0 は必ず 0 になる。
    """
    idx = 0
    for _name, _ofs, idxbit, nbit in PLANES:
        if (n >> nbit) & 1:
            idx |= 1 << idxbit
    return idx


# =============================================================================
# パレット構築
# =============================================================================

def build_palette(im: Image.Image):
    """PNG のパレットをそのまま読み、#000000 を添字 0 に置いた 64 色を作る。

    戻り値 (pal_rgb, index_map, info):
        pal_rgb   : (64,3) uint8。実際の色 (8 ビット)。未使用エントリは黒
        index_map : 元 PNG のパレット添字 -> 新添字 (0..63) の写像 (256 要素)
        info      : 報告用の辞書
    """
    if im.mode != "P":
        raise SystemExit("入力 PNG はパレット形式 (mode 'P') でなければならない")

    src_pal = im.getpalette() or []
    idx_img = np.array(im)
    used = np.unique(idx_img)

    # 使われている添字の色を、元パレットの添字順に重複なく並べる
    colors = []          # 実色 (tuple)
    color_pos = {}       # 実色 -> 新添字
    index_map = np.zeros(256, dtype=np.uint8)

    # 添字 0 は必ず #000000
    colors.append((0, 0, 0))
    color_pos[(0, 0, 0)] = 0

    for i in used:
        i = int(i)
        c = tuple(src_pal[3 * i:3 * i + 3])
        if c not in color_pos:
            color_pos[c] = len(colors)
            colors.append(c)
        index_map[i] = color_pos[c]

    if len(colors) > NPAL:
        raise SystemExit("実色数 %d + 黒 が %d を超えた。パレット方式は使えない"
                         % (len(colors) - 1, NPAL))

    n_real = len(colors) - 1        # 黒を除いた実色数
    black_in_image = (0, 0, 0) in {tuple(src_pal[3 * int(i):3 * int(i) + 3]) for i in used}

    pal_rgb = np.zeros((NPAL, 3), dtype=np.uint8)
    for k, c in enumerate(colors):
        pal_rgb[k] = c

    info = {
        "n_used_index": int(len(used)),
        "n_real_colors": n_real,
        "black_in_image": black_in_image,
        "n_entries": len(colors),
        "n_spare": NPAL - len(colors),
    }
    return pal_rgb, index_map, info


def optimize_palette_order(colorpix: np.ndarray,
                           iters: int, seed: int, verbose: bool = False):
    """パレット添字の割当順を入れ替えて RLE 圧縮後サイズを小さくする。

    パレットは「添字 -> 色」の対応表そのものなので、**どの色をどの添字へ
    置くかは完全に自由**である。一方 6 枚のビットプレーンの内容は添字の
    ビットパターンで決まるため、割当を変えると圧縮率が大きく変わる。
    そこで山登り法 (2 スロットの入れ替え) で圧縮後サイズを最小化する。

    添字 0 は #000000 に固定する (指定)。乱数種と反復回数を固定してあるので
    結果は決定的で、何度実行しても同じデータになる。

    引数 colorpix : 色 ID (0=黒、1.. が実色) の画像 (200,320)
    戻り値 (slot_of_color, size)
        slot_of_color : 色 ID -> パレット添字 (長さ NPAL の int32)
    """
    rng = np.random.RandomState(seed)

    slot_of_color = np.arange(NPAL, dtype=np.int32)   # 初期は恒等 (元の並び)
    best = rle_size(build_planes_np(slot_of_color[colorpix]))
    base = best

    # 入れ替え候補の添字は 1..63 (0 は黒で固定)
    for _ in range(iters):
        a, b = rng.randint(1, NPAL, size=2)
        if a == b:
            continue
        cand = slot_of_color.copy()
        # 添字 a に居る色と添字 b に居る色を交換する
        ia = np.flatnonzero(cand == a)
        ib = np.flatnonzero(cand == b)
        cand[ia] = b
        cand[ib] = a
        s = rle_size(build_planes_np(cand[colorpix]))
        if s < best:
            best = s
            slot_of_color = cand
    if verbose:
        sys.stderr.write("パレット順最適化: %d -> %d バイト\n" % (base, best))
    return slot_of_color, best


def parse_rgb(s: str):
    """"RRGGBB" / "#RRGGBB" を (R,G,B) の 8 ビット組へ変換する。"""
    t = s.strip().lstrip("#")
    if len(t) != 6:
        raise SystemExit("--text-color は RRGGBB の 6 桁 16 進で指定する (指定: %s)" % s)
    try:
        v = int(t, 16)
    except ValueError:
        raise SystemExit("--text-color が 16 進として解釈できない (指定: %s)" % s)
    return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)


def pal_to_4bit(pal_rgb: np.ndarray) -> np.ndarray:
    """8 ビット RGB を 4 ビット (0..15) へ四捨五入する。255/15 = 17。"""
    return np.rint(pal_rgb.astype(np.float64) / 17.0).astype(np.int32).clip(0, 15)


# =============================================================================
# プレーン化
# =============================================================================

def build_planes_np(pix: np.ndarray) -> np.ndarray:
    """6 ビット添字画像 (200,320) から非圧縮のプレーンストリームを作る。

    プレーン順は PLANES のとおり B3, B2, R3, R2, G3, G2。
    各プレーン 8000 バイト、1 ライン 40 バイトで MSB が左端。
    """
    chunks = []
    for _name, _ofs, _idxbit, nbit in PLANES:
        bits = ((pix >> nbit) & 1).astype(np.uint8)
        packed = np.packbits(bits, axis=1, bitorder="big")   # (200,40)
        assert packed.shape == (SCR_H, BYTES_PER_LINE)
        chunks.append(packed.reshape(-1))
    data = np.concatenate(chunks)
    assert data.size == NPLANES * PLANE_SIZE
    return data


def build_planes(pix: np.ndarray) -> bytes:
    return build_planes_np(pix).tobytes()


def planes_to_pix(data: bytes) -> np.ndarray:
    """プレーンストリームを 6 ビット添字画像へ逆変換する (検証用)。"""
    pix = np.zeros((SCR_H, SCR_W), dtype=np.int32)
    for i, (_name, _ofs, _idxbit, nbit) in enumerate(PLANES):
        raw = np.frombuffer(data[i * PLANE_SIZE:(i + 1) * PLANE_SIZE],
                            dtype=np.uint8).reshape(SCR_H, BYTES_PER_LINE)
        bits = np.unpackbits(raw, axis=1, bitorder="big").astype(np.int32)
        pix |= bits << nbit
    return pix


# =============================================================================
# RLE 圧縮 (仕様はファイル冒頭のコメントを参照)
# =============================================================================

def rle_encode(data: bytes) -> bytes:
    """非圧縮ストリームを RLE トークン列へ符号化する。

    トークン: 制御バイト C
        C == $00        終端
        C bit7 = 1      ラン    n = C & $7F、続く 1 バイトを n 回
        C bit7 = 0      リテラル n = C、続く n バイトをそのまま
    """
    out = bytearray()
    n = len(data)
    i = 0
    lit_start = 0     # 未出力のリテラル区間の開始位置

    def flush_literal(end: int) -> None:
        s = lit_start
        while s < end:
            k = min(RLE_MAX_LIT, end - s)
            out.append(k)
            out.extend(data[s:s + k])
            s += k

    while i < n:
        v = data[i]
        j = i + 1
        while j < n and data[j] == v:
            j += 1
        run = j - i
        # ラン 3 以上でのみラントークンにする
        #   (ラン 2 はリテラルへ含めた方が短いか同じ: 2 バイト vs 2 バイト +
        #    リテラル再開の制御バイト 1 バイト)
        if run >= 3:
            flush_literal(i)
            while run > 0:
                k = min(RLE_MAX_RUN, run)
                out.append(0x80 | k)
                out.append(v)
                run -= k
            i = j
            lit_start = i
        else:
            i = j
    flush_literal(n)
    out.append(0x00)      # 終端
    return bytes(out)


def rle_size(data: np.ndarray) -> int:
    """rle_encode の出力長だけを numpy で高速に求める (パレット順の探索用)。

    rle_encode と厳密に同じ結果を返すこと。
    """
    n = data.size
    if n == 0:
        return 1
    starts = np.concatenate(([0], np.flatnonzero(data[1:] != data[:-1]) + 1))
    lengths = np.diff(np.concatenate((starts, [n])))

    is_run = lengths >= 3
    # ラン: 長さ L を 127 ごとに分割し、各トークン 2 バイト
    run_cost = int((-(-lengths[is_run] // RLE_MAX_RUN) * 2).sum())

    # リテラル: ラン化しない区間が連続する塊ごとに (合計長 + 制御バイト数)
    lit_cost = 0
    mask = ~is_run
    if mask.any():
        # 連続する True の塊へ分割し、累積和で各塊の合計長を一括算出する
        m = mask.astype(np.int8)
        bounds = np.flatnonzero(np.diff(np.concatenate(([0], m, [0]))))
        cum = np.concatenate(([0], np.cumsum(lengths)))
        totals = cum[bounds[1::2]] - cum[bounds[0::2]]
        lit_cost = int(totals.sum() + (-(-totals // RLE_MAX_LIT)).sum())
    return run_cost + lit_cost + 1      # +1 は終端バイト


def rle_decode(enc: bytes, expect: int) -> bytes:
    """rle_encode の逆 (自己検証用)。6809 側実装の参照モデルでもある。"""
    out = bytearray()
    i = 0
    while i < len(enc):
        c = enc[i]
        i += 1
        if c == 0x00:
            break
        if c & 0x80:
            k = c & 0x7F
            out += bytes([enc[i]]) * k
            i += 1
        else:
            k = c
            out += enc[i:i + k]
            i += k
    if len(out) != expect:
        raise RuntimeError("RLE 展開長 %d が期待値 %d と一致しない" % (len(out), expect))
    return bytes(out)


# =============================================================================
# 画質評価
# =============================================================================

def evaluate(orig: np.ndarray, recon: np.ndarray):
    """平均色差 (RGB ユークリッド距離の平均) と PSNR [dB] を返す。"""
    a = orig.astype(np.float64)
    b = recon.astype(np.float64)
    diff = a - b
    mean_dist = float(np.sqrt((diff ** 2).sum(axis=2)).mean())
    mse = float((diff ** 2).mean())
    psnr = float("inf") if mse == 0.0 else 10.0 * np.log10(255.0 ** 2 / mse)
    return mean_dist, psnr


# =============================================================================
# アセンブラソース出力
# =============================================================================

def emit_asm(path: str, enc: bytes, raw_len: int, pal4: np.ndarray,
             info: dict, src_png: str, txt_slot: int, txt_mode: str) -> None:
    txt_r, txt_g, txt_b = (int(pal4[txt_slot][0]), int(pal4[txt_slot][1]),
                           int(pal4[txt_slot][2]))
    lines = []
    a = lines.append
    a("* 自動生成 -- scripts/png2fm77av.py が出力。手で編集しない")
    a("* FM77AV 320x200 グラフィック画面用イメージデータ (パレット方式 + RLE 圧縮)")
    a("* 元画像 %s (320x200、実色数 %d)"
      % (os.path.basename(src_png), info["n_real_colors"]))
    a("* 非圧縮 %d バイト -> 圧縮後 %d バイト (%.1f%%)"
      % (raw_len, len(enc), 100.0 * len(enc) / raw_len))
    a("*")
    a("* ---------------------------------------------------------------------")
    a("* 方式")
    a("* ---------------------------------------------------------------------")
    a("*   元画像はパレット画像で実色数が 64 以下なので、色を量子化せず")
    a("*   アナログパレットの 64 エントリへ元画像の色をそのまま設定し、")
    a("*   画面には 6 ビットのパレット添字だけを置く。誤差は 1 チャネル")
    a("*   8 ビット -> 4 ビットの丸めだけ。ディザリングは行っていない。")
    a("*")
    a("* ---------------------------------------------------------------------")
    a("* VRAM 構成 (320x200 4096色モード、サブCPU から見た配置)")
    a("* ---------------------------------------------------------------------")
    a("*   1 ライン 40 バイト (MSB が左端のドット)、1 プレーン 8000 バイト。")
    a("*   ページ0 ($D430 bit5=0): $0000 B3 / $2000 B2 / $4000 R3 / $6000 R2 /")
    a("*                           $8000 G3 / $A000 G2")
    a("*   ページ1 ($D430 bit5=1): $0000 B1 / $2000 B0 / $4000 R1 / $6000 R0 /")
    a("*                           $8000 G1 / $A000 G0")
    a("*   12 枚から 1 ドット 12 ビットのアナログパレット添字が作られる:")
    a("*     添字 = (G<<8) | (R<<4) | B  (各 4 ビット、B3/R3/G3 が各ニブルの MSB)")
    a("*")
    a("* ---------------------------------------------------------------------")
    a("* プレーンとパレット添字ビットの対応 (本データの割当)")
    a("* ---------------------------------------------------------------------")
    a("*   ページ1 は使わない (全ビット 0)。よってページ0 の 6 面が担う")
    a("*   12 ビット添字の bit11/10/7/6/3/2 だけが有効で、他は常に 0。")
    a("*   ピクセルのパレット添字 n (0..63) のビット割当:")
    a("*")
    a("*     n bit5 -> G3 プレーン (ページ0 $8000) -> 12 ビット添字 bit11")
    a("*     n bit4 -> G2 プレーン (ページ0 $A000) -> 12 ビット添字 bit10")
    a("*     n bit3 -> R3 プレーン (ページ0 $4000) -> 12 ビット添字 bit7")
    a("*     n bit2 -> R2 プレーン (ページ0 $6000) -> 12 ビット添字 bit6")
    a("*     n bit1 -> B3 プレーン (ページ0 $0000) -> 12 ビット添字 bit3")
    a("*     n bit0 -> B2 プレーン (ページ0 $2000) -> 12 ビット添字 bit2")
    a("*")
    a("*   すなわち n = (nG<<4)|(nR<<2)|nB (各 2 ビット) に対し")
    a("*            12 ビット添字 = (nG<<10)|(nR<<6)|(nB<<2)")
    a("*   imgpal はこの 12 ビット添字の番地へ色を書く。")
    a("*")
    a("* ---------------------------------------------------------------------")
    a("* パレットテーブル imgpal (1 エントリ 5 バイト、IMGPALN 個)")
    a("* ---------------------------------------------------------------------")
    a("*   先頭から順に、そのまま下記の I/O へ書けばよい (メインCPU 側):")
    a("*     +0 -> $FD30   パレット添字の上位 4 ビット (12 ビット添字の bit11-8)")
    a("*     +1 -> $FD31   パレット添字の下位 8 ビット (12 ビット添字の bit7-0)")
    a("*     +2 -> $FD32   青 B (下位ニブルのみ有効)")
    a("*     +3 -> $FD33   赤 R (下位ニブルのみ有効)")
    a("*     +4 -> $FD34   緑 G (下位ニブルのみ有効)")
    a("*   これを IMGPALN 回繰り返す。FM77AV 以降でのみ書き込むこと")
    a("*   (FM-7 には $FD30-$FD34 は無い)。")
    a("*")
    a("* ---------------------------------------------------------------------")
    a("* 展開後データの並び (非圧縮ストリーム)")
    a("* ---------------------------------------------------------------------")
    a("*   B3, B2, R3, R2, G3, G2 の順に 8000 バイトずつ連結 (ページ0 のみ)。")
    a("*   合計 48000 バイト。展開側は 8000 バイトごとに書き込み先を")
    a("*   $0000 / $2000 / $4000 / $6000 / $8000 / $A000 と進める。")
    a("*   ページ1 は全 0 のままにすること (クリアしておく)。")
    a("*")
    a("* ---------------------------------------------------------------------")
    a("* RLE 圧縮形式 (imgdata はこの形式の 1 本のストリーム)")
    a("* ---------------------------------------------------------------------")
    a("*   制御バイト C を読む")
    a("*     C = $00        : 終端 (展開終了)")
    a("*     C bit7 = 1     : ラン。n = C & $7F (1..127)。続く 1 バイト V を")
    a("*                      n 回出力する。トークン長 2 バイト")
    a("*     C bit7 = 0     : リテラル。n = C (1..127)。続く n バイトを")
    a("*                      そのまま出力する。トークン長 1+n バイト")
    a("*   n は必ず 1..127 ($00 は終端専用、$80 は出現しない)。")
    a("*   トークンはプレーン境界 (8000 バイト) をまたぐことがある。展開側は")
    a("*   出力バイト数を数え、8000 バイトごとに書き込み先を切り替えること。")
    a("*   展開後の総バイト数は IMGPLANES * IMGPLNSZ に一致する。")
    a("*")
    a("* 展開ルーチンの骨子 (X=圧縮データ、Y=出力先):")
    a("*   loop   lda ,x+ / beq done / bmi runtok")
    a("*          tfr a,b")
    a("*   litlp  lda ,x+ / sta ,y+ / decb / bne litlp / bra loop")
    a("*   runtok anda #$7F / tfr a,b / lda ,x+")
    a("*   runlp  sta ,y+ / decb / bne runlp / bra loop")
    a("*   done")
    a("")
    a("* ---------------------------------------------------------------------")
    a("* 重ね書き文字用の色 IMGTXTCOL")
    a("* ---------------------------------------------------------------------")
    if txt_mode == "spare":
        a("*   画像が使っていない空きスロットへ文字色 (RGB4 = %X%X%X) を置いた。"
          % (txt_r, txt_g, txt_b))
        a("*   このスロットの添字 IMGTXTCOL = %d で文字を描けば、画像の発色を" % txt_slot)
        a("*   一切変えずに文字を重ねられる。空きスロットの色を変えるだけなので")
        a("*   文字色を変えても imgdata (画像本体) は 1 バイトも変わらない。")
    else:
        a("*   空きスロットが無いため、画像が使っている色のうち指定色に最も近い")
        a("*   ものを選んだ (色は書き換えていない)。IMGTXTCOL = %d、RGB4 = %X%X%X"
          % (txt_slot, txt_r, txt_g, txt_b))
    a("*   文字を重ねる側は、ページ0 の 6 面それぞれについて")
    a("*     そのプレーンが担う IMGTXTCOL のビットが 1 なら 字形ビットを OR、")
    a("*     0 なら 字形ビットの反転を AND")
    a("*   すればよい (地の画像を壊さない read-modify-write)。")
    a("*")
    a("IMGPALN    equ %d" % NPAL)
    a("IMGPLANES  equ %d" % NPLANES)
    a("IMGPLNSZ   equ %d" % PLANE_SIZE)
    a("IMGDATSZ   equ %d" % len(enc))
    a("IMGTXTCOL  equ %d" % txt_slot)
    a("")
    a("* パレット: 1 エントリ 5 バイト = $FD30,$FD31,$FD32,$FD33,$FD34 の順")
    a("imgpal")
    for n in range(NPAL):
        idx = n_to_idx12(n)
        r4, g4, b4 = int(pal4[n][0]), int(pal4[n][1]), int(pal4[n][2])
        a("    fcb $%02X,$%02X,$%02X,$%02X,$%02X   * n=%2d idx=$%03X RGB4=%X%X%X%s"
          % ((idx >> 8) & 0x0F, idx & 0xFF, b4, r4, g4, n, idx, r4, g4, b4,
             "  <- IMGTXTCOL (重ね書き文字の色)" if n == txt_slot else ""))
    a("")
    a("* 文字色の添字を 1 バイトで置く (imgpal の直後)。")
    a("*   このソースをそのまま raw アセンブルすると")
    a("*     +$0000..+$013F  imgpal    (64 エントリ x 5 バイト = 320)")
    a("*     +$0140          imgtxtcol (1 バイト)")
    a("*     +$0141..        imgdata   (IMGDATSZ バイト)")
    a("*   という 1 本のバイナリになる。読み込む側はこの並びを前提にしてよい。")
    a("imgtxtcol")
    a("    fcb IMGTXTCOL")
    a("")
    a("* イメージ本体 (RLE ストリーム)")
    a("imgdata")
    for off in range(0, len(enc), 16):
        chunk = enc[off:off + 16]
        a("    fcb " + ",".join("$%02X" % b for b in chunk))
    a("")
    with open(path, "w", encoding="utf-8", newline="\n") as fp:
        fp.write("\n".join(lines))


# =============================================================================
# メイン
# =============================================================================

def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)

    ap = argparse.ArgumentParser(
        description="PNG を FM77AV 320x200 用データ (パレット方式) へ変換する")
    ap.add_argument("--input", default=os.path.join(root, "assets", "FM77AV.PNG"),
                    help="入力 PNG (320x200、パレット形式)")
    ap.add_argument("--out", default=os.path.join(root, "assets", "fm77av_img.s"),
                    help="出力アセンブラソース")
    ap.add_argument("--preview", default=None,
                    help="逆変換したプレビュー PNG の出力先")
    ap.add_argument("--opt-iters", type=int, default=OPT_ITERS,
                    help="パレット順の最適化反復回数 (0 で最適化しない、既定 %d)" % OPT_ITERS)
    ap.add_argument("--opt-seed", type=int, default=OPT_SEED,
                    help="パレット順の最適化に使う乱数種 (既定 %d)" % OPT_SEED)
    ap.add_argument("--text-color", default=DEF_TEXT_COLOR, metavar="RRGGBB",
                    help="重ね書き文字の色を 24 ビット 16 進で指定 (既定 %s)"
                         % DEF_TEXT_COLOR)
    args = ap.parse_args()

    txt_rgb8 = parse_rgb(args.text_color)
    txt_rgb4 = np.rint(np.array(txt_rgb8, dtype=np.float64) / 17.0).astype(np.int32).clip(0, 15)

    im = Image.open(args.input)
    if im.size != (SCR_W, SCR_H):
        raise SystemExit("入力画像は %dx%d でなければならない (実際 %dx%d)"
                         % (SCR_W, SCR_H, im.size[0], im.size[1]))

    pal_rgb, index_map, info = build_palette(im)

    # ピクセルを色 ID (0=黒、1.. が実色) へ写す
    colorpix = index_map[np.array(im)].astype(np.int32)
    assert int(colorpix.max()) < NPAL

    # 色 ID -> パレット添字 の割当を圧縮率で最適化する (添字 0 は黒に固定)
    baseline = rle_size(build_planes_np(colorpix))
    if args.opt_iters > 0:
        slot_of_color, _ = optimize_palette_order(colorpix, args.opt_iters, args.opt_seed)
    else:
        slot_of_color = np.arange(NPAL, dtype=np.int32)

    # 添字 -> 色 の並びへ直す (パレットテーブルはこの順で出す)
    color_at_slot = np.empty(NPAL, dtype=np.int32)
    color_at_slot[slot_of_color] = np.arange(NPAL, dtype=np.int32)
    pal4 = pal_to_4bit(pal_rgb[color_at_slot])

    # ---- 画像に重ねる文字用の色を決める ----
    #   画像が 64 色未満なら空きスロットが残る。そこへ指定色を置けば、画像の
    #   発色を一切変えずに文字を重ねられる (どのピクセルもその添字を使って
    #   いないため)。空きスロットの色を差し替えるだけなので、文字色を変えても
    #   画像本体 (プレーンデータ = imgdata) は 1 バイトも変わらない。
    #   空きが無い場合は既存色を潰さず、指定色に最も近い色を選ぶ。
    if info["n_spare"] > 0:
        spare_color = info["n_entries"]          # 未使用の色 ID (最小のもの)
        txt_slot = int(slot_of_color[spare_color])
        pal4[txt_slot] = txt_rgb4
        txt_mode = "spare"
    else:
        d = np.abs(pal4.astype(np.int32) - txt_rgb4[None, :]).sum(axis=1)
        txt_slot = int(np.argmin(d))
        txt_mode = "existing"

    pix = slot_of_color[colorpix]
    raw = build_planes(pix)
    enc = rle_encode(raw)
    if rle_decode(enc, len(raw)) != raw:
        raise RuntimeError("RLE の自己検証に失敗した")
    if rle_size(np.frombuffer(raw, dtype=np.uint8)) != len(enc):
        raise RuntimeError("rle_size と rle_encode が一致しない")

    # 逆変換 (実機の発色を再現): プレーン -> 添字 -> 4 ビット色 -> 8 ビット
    pix2 = planes_to_pix(raw)
    if not np.array_equal(pix2, pix):
        raise RuntimeError("プレーン化の自己検証に失敗した")
    recon = (pal4[pix2] * 17).astype(np.uint8)

    orig = np.array(im.convert("RGB"))
    md, psnr = evaluate(orig, recon)

    emit_asm(args.out, enc, len(raw), pal4, info, args.input, txt_slot, txt_mode)

    if args.preview:
        d = os.path.dirname(os.path.abspath(args.preview))
        if d:
            os.makedirs(d, exist_ok=True)
        Image.fromarray(recon).save(args.preview)

    print("入力          : %s" % args.input)
    print("出力          : %s" % args.out)
    print("元画像の実色数: %d 色 (#000000 は%s)"
          % (info["n_real_colors"], "含まれる" if info["black_in_image"] else "含まれない"))
    print("パレット      : %d エントリ使用 / %d (空き %d、空きは黒で埋める)"
          % (info["n_entries"], NPAL, info["n_spare"]))
    print("文字色        : IMGTXTCOL = %d  RGB4=%X%X%X (指定 #%s) %s"
          % (txt_slot, int(pal4[txt_slot][0]), int(pal4[txt_slot][1]),
             int(pal4[txt_slot][2]), args.text_color.upper(),
             "空きスロットへ設定" if txt_mode == "spare"
             else "空き無しのため既存色のうち最も近いものを選択"))
    print("非圧縮        : %d バイト (%d プレーン x %d)" % (len(raw), NPLANES, PLANE_SIZE))
    print("圧縮後        : %d バイト (%.1f%%)" % (len(enc), 100.0 * len(enc) / len(raw)))
    print("  (パレット順の最適化なしなら %d バイト / %.1f%%、反復 %d 回)"
          % (baseline, 100.0 * baseline / len(raw), args.opt_iters))
    print("パレット表    : %d バイト (%d エントリ x 5)" % (NPAL * 5, NPAL))
    print("平均色差      : %.4f" % md)
    print("PSNR          : %.2f dB" % psnr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
