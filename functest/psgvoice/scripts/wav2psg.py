#!/usr/bin/env python3
# =============================================================================
# wav2psg.py — WAV から PSG (AY-3-8910) 音量 DAC 再生用データを生成する
#
# PSG にはサンプリング再生の専用機能はありませんが、音量レジスタ (R8-R10)
# の値をサンプルごとに書き換えると、対数カーブの 16 段 DAC として使えます
# (トーン/ノイズをミキサで全て止めると、出力は音量レジスタの値だけで決まる)。
#
# 処理の流れ:
#   1. WAV (RIFF PCM / mono / 16bit / 44100Hz) を読む
#   2. ローパスフィルタをかけてから 1/4 に間引き (44100 → 11025 Hz)
#   3. 各サンプルを 0..1 の目標振幅 (無音 = 0.5) に直し、PSG の対数音量
#      特性を考慮して「最も近い出力が得られる音量値 0-15」へ量子化する。
#      量子化誤差は次のサンプルへ持ち越す (誤差拡散) ことで、16 段しか
#      ない DAC でも聴感上の歪みを減らす
#   4. 2 サンプルを 1 バイト (上位ニブルが先) にパックし、アセンブラの
#      fcb 行として書き出す
#
# 出力:
#   --out  データ本体 (assets/psgdata.s、src/psgdata.asm が取り込む)
#   --defs 定数定義   (assets/psgdef.s、src/psgvoice.asm が取り込む)
#
# 使い方:
#   python3 scripts/wav2psg.py --wav assets/fm7psg.wav \
#       --out assets/psgdata.s --defs assets/psgdef.s
# =============================================================================

import argparse
import math
import struct
import sys

RATE_DIV = 4                 # 44100 / 4 = 11025 Hz
TARGET_RATE = 44100 // RATE_DIV

# PSG (AY-3-8910) の音量レジスタ値 0-15 に対する出力振幅の近似値。
# 1 段あたり約 3dB の対数特性 (データシートの D/A 変換特性)。
PSG_VOL = [
    0.0000, 0.0099, 0.0144, 0.0203,
    0.0287, 0.0405, 0.0573, 0.0809,
    0.1143, 0.1614, 0.2281, 0.3224,
    0.4556, 0.6438, 0.9098, 1.0000,
]


def read_wav(path):
    with open(path, 'rb') as f:
        b = f.read()
    if b[:4] != b'RIFF' or b[8:12] != b'WAVE':
        raise SystemExit(f'{path}: RIFF WAVE ではありません')
    off = 12
    fmt = None
    data = None
    while off + 8 <= len(b):
        cid = b[off:off + 4]
        sz = struct.unpack('<I', b[off + 4:off + 8])[0]
        if cid == b'fmt ':
            fmt = struct.unpack('<HHIIHH', b[off + 8:off + 24])
        elif cid == b'data':
            data = b[off + 8:off + 8 + sz]
        off += 8 + sz + (sz & 1)
    if fmt is None or data is None:
        raise SystemExit(f'{path}: fmt / data チャンクが見つかりません')
    wformat, ch, rate, _, _, bits = fmt
    if wformat != 1 or ch != 1 or bits != 16 or rate != 44100:
        raise SystemExit(
            f'{path}: PCM/mono/16bit/44100Hz のみ対応 '
            f'(format={wformat} ch={ch} bits={bits} rate={rate})')
    n = len(data) // 2
    samples = struct.unpack(f'<{n}h', data[:n * 2])
    return [s / 32768.0 for s in samples], rate


def lowpass_decimate(x, div):
    """窓関数付き sinc ローパス (カットオフ 0.45 x 出力ナイキスト) をかけて
    1/div に間引く。"""
    taps = 63
    fc = 0.45 / div            # 入力レートに対する正規化カットオフ
    half = taps // 2
    h = []
    for i in range(taps):
        k = i - half
        v = 2 * fc if k == 0 else math.sin(2 * math.pi * fc * k) / (math.pi * k)
        # ハミング窓
        v *= 0.54 - 0.46 * math.cos(2 * math.pi * i / (taps - 1))
        h.append(v)
    s = sum(h)
    h = [v / s for v in h]

    out = []
    n = len(x)
    for center in range(0, n, div):
        acc = 0.0
        base = center - half
        for i in range(taps):
            j = base + i
            if 0 <= j < n:
                acc += x[j] * h[i]
        out.append(acc)
    return out


def quantize(x):
    """振幅 -1..1 の列を PSG 音量値 0-15 の列にする (誤差拡散付き)。"""
    # ピーク正規化 (DAC のレンジを使い切る)
    peak = max(max(x), -min(x), 1e-9)
    gain = 0.98 / peak
    levels = []
    err = 0.0
    for v in x:
        target = (v * gain + 1.0) * 0.5 + err       # 0..1 (無音 = 0.5)
        target_c = min(1.0, max(0.0, target))
        best = min(range(16), key=lambda L: abs(PSG_VOL[L] - target_c))
        err = target - PSG_VOL[best]
        # 誤差の暴走防止 (クリップ区間で溜まり過ぎないように)
        err = min(0.5, max(-0.5, err))
        levels.append(best)
    return levels


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--wav', required=True)
    ap.add_argument('--out', required=True, help='データ本体 (psgdata.s)')
    ap.add_argument('--defs', required=True, help='定数定義 (psgdef.s)')
    args = ap.parse_args()

    x, rate = read_wav(args.wav)
    y = lowpass_decimate(x, RATE_DIV)
    levels = quantize(y)
    if len(levels) & 1:
        levels.append(levels[-1])       # 2 サンプル/バイトに揃える

    packed = bytes((levels[i] << 4) | levels[i + 1]
                   for i in range(0, len(levels), 2))

    with open(args.out, 'w') as f:
        f.write('; psgdata.s — wav2psg.py が生成した PSG 音量 DAC 用データ\n')
        f.write(f'; 元 WAV: {len(x)} サンプル @ {rate}Hz\n')
        f.write(f'; 再生用: {len(levels)} サンプル @ {TARGET_RATE}Hz '
                f'(2 サンプル/バイト、上位ニブルが先)\n')
        f.write('psgdata\n')
        for i in range(0, len(packed), 16):
            row = ','.join(f'${b:02X}' for b in packed[i:i + 16])
            f.write(f'        fcb     {row}\n')

    with open(args.defs, 'w') as f:
        f.write('; psgdef.s — wav2psg.py が生成した定数定義\n')
        f.write(f'PSGRATE   equ   {TARGET_RATE}      '
                f'; サンプルレート (Hz、公称値)\n')
        f.write(f'PSGNSMP   equ   {len(levels)}    ; サンプル数\n')
        f.write(f'PSGDATSZ  equ   {len(packed)}    '
                f'; パック後のバイト数 (2 サンプル/バイト)\n')

    dur = len(levels) / TARGET_RATE
    print(f'{args.out}: {len(packed)} bytes '
          f'({len(levels)} samples @ {TARGET_RATE}Hz = {dur:.3f}s)')


if __name__ == '__main__':
    main()
