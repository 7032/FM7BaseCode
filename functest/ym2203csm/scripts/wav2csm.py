#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""wav2csm.py -- 音声波形 (wav) を YM2203 CSM 音声合成パラメータへ変換する。

CSM 音声合成の原理:
    YM2203 の Ch3 を CSM モード + 3スロット独立周波数モードにすると、
    タイマ A のオーバーフロー毎に Ch3 の 4 オペレータが一斉にキーオン
    (位相リセット) される。アルゴリズム 7 (4 並列キャリア) にすれば

        タイマ A の周波数        = 音声の基本周波数 F0 (ピッチ)
        4 オペレータの周波数     = 4 本のフォルマント周波数
        4 オペレータの TL        = 各フォルマントの振幅

    となり「F0 のレートで励起される 4 本の減衰正弦波」= フォルマント合成
    による音声が得られる。

使い方:
    python3 scripts/wav2csm.py                     … 既定設定で assets/csmdata.s を生成
    python3 scripts/wav2csm.py --sweep             … パラメータ探索 (数値評価のみ)
    python3 scripts/wav2csm.py --recon <out.wav>   … チップ挙動模擬の再合成を書き出す

出力: assets/csmdata.s (lwasm 用データ、1 フレーム 14 バイト固定)
"""

from __future__ import annotations

import argparse
import os
import sys
import wave

import numpy as np
from scipy.signal import resample_poly

# =============================================================================
# チップ定数 (YM2203 / OPN、FM-7 系実装)
#   すべてここに集約する。写像式は chipmap 節の関数群に隔離してある。
# =============================================================================

OPN_CLOCK       = 1228800     # OPN 外部クロック [Hz] (FM-7/77 系)
OPN_PRESCALER   = 6           # プリスケーラ /6 ($2F → $2D の 2 段書きで確定させる。
                              #   リセット既定は /6 とは限らず、1 段書きでは
                              #   切り替わらない実装があるため 6809 側で明示する)
TIMER_A_DIV     = 12 * OPN_PRESCALER    # タイマ A: 72 * (1024-NA) クロック
TIMER_B_DIV     = 192 * OPN_PRESCALER   # タイマ B: 1152 * (256-NB) クロック

# F-Number 1 LSB あたりの出力周波数 (block=0, MUL=1)
#   f = fnum * 2^block * OPN_CLOCK / (TIMER_A_DIV * 2^21)
FNUM_UNIT_HZ    = OPN_CLOCK / (TIMER_A_DIV * (1 << 21))   # 約 0.0081377 Hz

# オペレータの MUL (逓倍) 設定。4 オペレータ共通で 2 に固定する。
#   MUL=1 では fnum=2047/block=7 でも 2132Hz が上限で F3/F4 を表現できない。
#   MUL=2 なら上限 4264Hz。
#   ★6809 側は Ch3 の $32/$36/$3A/$3E に $02 (DT=0, MUL=2) を書くこと。
OP_MUL          = 2

FNUM_MAX        = 2047        # F-Number は 11bit
BLOCK_MAX       = 7           # BLOCK は 3bit

TL_MAX          = 127         # TL は 7bit、0 が最大音量 (127 = 無音)
# ALG=7 は 4 スロット単純加算。1 オペレータの最大振幅は 8168 なので、4 本とも
# TL=0 でも合計 4x8168 = 32672 で 16bit フルスケール 32767 を超えない
# (= 下限を 0 まで使ってもクリップしない)。本デモは Ch3 しか鳴らさないため
# 他チャネルとの合算を考える必要がなく、下限 0 でチップのレンジを使い切る。
#   下限を 4 に留めるとエミュレータ実測ピークが 0.54 で頭打ちになり、
#   目標の 0.6〜0.85 に届かないことを測定で確認済み。
TL_MIN          = 0
# 全フレーム中のほぼ最大振幅 (99.5 パーセンタイル) を割り当てる TL。
# 負値にすると「それより強いフォルマントは TL_MIN で頭打ち」= 上端だけ
# 穏やかに圧縮したうえで全体を持ち上げる意味になる。
#   エミュレータ実測での調整結果 (290 フレーム、1/3 オクターブ相関つき):
#     TL_PEAK= 10 / TL_MIN=8 … peak 0.1508  RMS -33.67dBFS  相関 0.9354 (旧設定)
#     TL_PEAK=-14 / TL_MIN=0 … peak 0.6906  RMS -20.55dBFS  相関 0.9363 (採用)
#     TL_PEAK=-20 / TL_MIN=0 … peak 0.7690  RMS -19.38dBFS  相関 0.9343
TL_PEAK         = -14
TL_STEP_DB      = 0.7525      # TL 1 ステップ = 0.7525dB (8 EG 単位)

# CSM バーストの減衰 (SR=31 の実測: -20dB/2.54ms, -40dB/5.08ms, -60dB/7.26ms)
#   → 7.874 dB/ms の直線減衰 = 時定数 1.103ms の指数減衰
DECAY_DB_PER_MS = 40.0 / 5.08
DECAY_TAU_MS    = 20.0 / np.log(10.0) / DECAY_DB_PER_MS   # 約 1.103ms

TIMER_A_MAX     = 1023        # タイマ A は 10bit

# フレーム周期 = メイン CPU の周期タイマ (約 491.52Hz) の整数倍。
#   6809 側は $FD03 bit2 のポーリングで tick を数えて同期する。
#   OPN のタイマ B は同期に使わない (フラグを立てるのに $27 の許可ビットが
#   必要な実装があり、機種によってはフレーム待ちから抜けられなくなるため)。
#   ★この 2 定数は 6809 側の FRTICK と対で、片方だけ変えるとテンポがずれる。
TIMER_TICK      = 1.0 / 491.52          # [s] メイン CPU 周期タイマ 1 tick = 2.0345ms
FRAME_TICKS     = 5                     # 1 フレームの tick 数 (6809 側 FRTICK)
FRAME_PERIOD    = TIMER_TICK * FRAME_TICKS   # [s] = 0.01017253 (10.1725ms)
FRAME_RATE      = 1.0 / FRAME_PERIOD    # 約 98.304 fps

SRC_RATE        = 44100       # 入力 wav の想定サンプリング周波数
LPC_RATE        = 10000       # フォルマント抽出用のダウンサンプル先

FRAME_BYTES     = 14          # 1 フレームのバイト数 (固定)
NFORMANT        = 4           # フォルマント本数 = オペレータ数

# フォルマント探索範囲
FORMANT_FMIN    = 150.0
FORMANT_FMAX    = 4000.0   # チップの FM 合成レートが低く 4kHz 超は使い物にならない
FORMANT_BW_MAX  = 600.0

# F0 探索範囲 (有声)
#   対象音声は基本周波数がかなり高く、倍音間隔の実測で 260-630Hz に及ぶ。
#   上限を 350Hz で切ると探索範囲の端に張り付いてオクターブ誤りを誘発する。
#   80-550Hz が客観評価 (メル相関) で最良だった。
F0_MIN          = 80.0
F0_MAX          = 550.0

# 無声区間の励起レート (CSM はノイズ源を持たないので高めのレートで代用)
UNVOICED_RATE   = 460.0
UNVOICED_JITTER = 120.0


# =============================================================================
# chipmap: 物理量 → チップレジスタ値への写像 (ここだけで完結させる)
# =============================================================================

def f0_to_timer_a(f0_hz: float):
    """基本周波数 [Hz] → タイマ A レジスタ値 NA と実際に鳴る周波数。

    タイマ A 周期 = TIMER_A_DIV * (1024 - NA) / OPN_CLOCK
      → f = OPN_CLOCK / (TIMER_A_DIV * (1024 - NA))
    戻り値: (reg24, reg25, 実周波数)
      reg24 = NA の上位 8bit、reg25 = NA の下位 2bit
    """
    f0_hz = max(f0_hz, 1e-3)
    span = OPN_CLOCK / (TIMER_A_DIV * f0_hz)      # = 1024 - NA
    na = int(round(1024.0 - span))
    na = max(0, min(TIMER_A_MAX, na))
    actual = OPN_CLOCK / (TIMER_A_DIV * max(1024 - na, 1))
    return (na >> 2) & 0xFF, na & 0x03, actual


def timer_a_to_f0(reg24: int, reg25: int) -> float:
    """タイマ A レジスタ値 → 実際の励起周波数 [Hz] (逆写像、検証用)。"""
    na = ((reg24 & 0xFF) << 2) | (reg25 & 0x03)
    return OPN_CLOCK / (TIMER_A_DIV * max(1024 - na, 1))


def freq_to_block_fnum(freq_hz: float):
    """フォルマント周波数 [Hz] → (上位バイト, 下位バイト, 実周波数)。

    上位バイト = block<<3 | fnum の bit10-8、下位バイト = fnum の bit7-0。
    MUL 逓倍 (OP_MUL) を考慮した上で、fnum が最大精度になる block を選ぶ。
    """
    freq_hz = max(freq_hz, 1.0)
    # MUL 逓倍後に freq_hz になるような素の値
    unit_total = freq_hz / (FNUM_UNIT_HZ * OP_MUL)     # = fnum << block
    block = 0
    while unit_total > FNUM_MAX and block < BLOCK_MAX:
        block += 1
        unit_total /= 2.0
    fnum = int(round(unit_total))
    fnum = max(0, min(FNUM_MAX, fnum))
    actual = fnum * (1 << block) * FNUM_UNIT_HZ * OP_MUL
    hi = ((block & 7) << 3) | ((fnum >> 8) & 7)
    lo = fnum & 0xFF
    return hi, lo, actual


def block_fnum_to_freq(hi: int, lo: int) -> float:
    """(上位バイト, 下位バイト) → 実周波数 [Hz] (逆写像、検証用)。"""
    block = (hi >> 3) & 7
    fnum = ((hi & 7) << 8) | (lo & 0xFF)
    return fnum * (1 << block) * FNUM_UNIT_HZ * OP_MUL


def amp_to_tl(amp: float, amp_ref: float) -> int:
    """線形振幅 → TL (TL_MIN..127、小さいほど大音量、1 ステップ 0.7525dB)。

    amp_ref (全フレーム中のほぼ最大振幅) が TL_PEAK に来るようスケールする。
    TL_PEAK が負のときは、amp_ref 付近の強いフォルマントが TL_MIN で
    頭打ちになる (上端だけ圧縮される) 代わりに全体のレベルが上がる。
    """
    if amp <= 0.0 or amp_ref <= 0.0:
        return TL_MAX
    db = 20.0 * np.log10(amp / amp_ref)
    tl = int(round(-db / TL_STEP_DB)) + TL_PEAK
    return max(TL_MIN, min(TL_MAX, tl))


def tl_to_amp(tl: int, amp_ref: float) -> float:
    """TL → 線形振幅 (逆写像、検証用)。"""
    if tl >= TL_MAX:
        return 0.0
    return amp_ref * (10.0 ** (-TL_STEP_DB * (tl - TL_PEAK) / 20.0))


# =============================================================================
# wav 入出力
# =============================================================================

def read_wav(path: str):
    """モノラル 16bit wav を float [-1,1] で読む。"""
    with wave.open(path, 'rb') as w:
        nch, sw, fs, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if sw != 2:
        raise ValueError('16bit の wav のみ対応: %s' % path)
    x = np.frombuffer(raw, dtype='<i2').astype(np.float64) / 32768.0
    if nch > 1:
        x = x.reshape(-1, nch).mean(axis=1)
    return x, fs


def write_wav(path: str, x: np.ndarray, fs: int) -> None:
    """float 配列を 16bit wav で書き出す (ピーク 0.95 に正規化)。"""
    peak = np.max(np.abs(x)) if x.size else 1.0
    if peak > 0:
        x = x / peak * 0.95
    d = np.clip(np.round(x * 32767.0), -32768, 32767).astype('<i2')
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(fs)
        w.writeframes(d.tobytes())


# =============================================================================
# 解析: F0 推定 (YIN 系)
# =============================================================================

def yin_f0(frame: np.ndarray, fs: int, fmin: float, fmax: float, thr: float = 0.15):
    """1 フレームの F0 を YIN (累積平均正規化差分) で推定。

    戻り値 (f0, aperiodicity)。無周期性が小さいほど有声らしい。
    """
    n = len(frame)
    w = n // 2
    tau_min = max(2, int(fs / fmax))
    tau_max = min(w - 1, int(fs / fmin))
    if tau_max <= tau_min:
        return 0.0, 1.0

    x = frame - frame.mean()
    # 差分関数 d(tau) を FFT 相関で算出
    nfft = 1 << int(np.ceil(np.log2(n + w)))
    X = np.fft.rfft(x, nfft)
    acf = np.fft.irfft(X * np.conj(X), nfft)[:tau_max + 1]
    cum = np.concatenate(([0.0], np.cumsum(x * x)))
    p0 = cum[w] - cum[0]                                    # 先頭窓のパワー
    taus = np.arange(tau_max + 1)
    pt = cum[w + taus] - cum[taus]                          # ずらした窓のパワー
    d = p0 + pt - 2.0 * acf
    d = np.maximum(d, 0.0)

    # 累積平均正規化
    dn = np.ones_like(d)
    csum = np.cumsum(d[1:])
    idx = np.arange(1, tau_max + 1)
    with np.errstate(divide='ignore', invalid='ignore'):
        dn[1:] = np.where(csum > 0, d[1:] * idx / csum, 1.0)

    seg = dn[tau_min:tau_max + 1]
    # 閾値を下回る最初の谷を採る (オクターブ上げ誤りを防ぐ)
    tau = -1
    below = np.where(seg < thr)[0]
    if below.size:
        i = below[0]
        while i + 1 < len(seg) and seg[i + 1] < seg[i]:
            i += 1
        tau = tau_min + i
    else:
        tau = tau_min + int(np.argmin(seg))
    aper = float(dn[tau])

    # 放物線補間で分解能を上げる
    if 0 < tau < tau_max:
        y0, y1, y2 = d[tau - 1], d[tau], d[tau + 1]
        den = (y0 - 2 * y1 + y2)
        if abs(den) > 1e-12:
            tau = tau + 0.5 * (y0 - y2) / den
    if tau <= 0:
        return 0.0, 1.0
    return fs / tau, aper


def estimate_f0_track(x: np.ndarray, fs: int, centers: np.ndarray, cfg: dict):
    """全フレームの F0 と有声判定を求め、中央値平滑化でオクターブ誤りを潰す。"""
    win = int(0.046 * fs) // 2 * 2       # 46ms (70Hz で 3 周期以上)
    nf = len(centers)
    f0 = np.zeros(nf)
    aper = np.ones(nf)
    rms = np.zeros(nf)
    for i, c in enumerate(centers):
        s = int(round(c)) - win // 2
        seg = np.zeros(win)
        a, b = max(0, s), min(len(x), s + win)
        if b > a:
            seg[a - s:b - s] = x[a:b]
        rms[i] = np.sqrt(np.mean(seg * seg)) + 1e-12
        f0[i], aper[i] = yin_f0(seg, fs, F0_MIN, F0_MAX)

    # 有声判定: 無周期性 + 相対パワー
    ref = np.percentile(rms, 95)
    lvl_db = 20 * np.log10(rms / (ref + 1e-12))
    voiced = (aper < cfg['aper_thr']) & (lvl_db > cfg['silence_db'] + 8.0)

    # 有声フレームの F0 を中央値平滑化 (5 点)
    f0s = f0.copy()
    vi = np.where(voiced)[0]
    if vi.size >= 3:
        vf = f0[vi]
        med = np.array([np.median(vf[max(0, k - 2):k + 3]) for k in range(len(vf))])
        # オクターブ誤り補正
        for k in range(len(vf)):
            for mul in (0.5, 2.0):
                if abs(vf[k] * mul - med[k]) < abs(vf[k] - med[k]) * 0.55:
                    vf[k] = vf[k] * mul
        med2 = np.array([np.median(vf[max(0, k - 2):k + 3]) for k in range(len(vf))])
        f0s[vi] = 0.5 * vf + 0.5 * med2
        f0s[vi] = np.clip(f0s[vi], F0_MIN, F0_MAX)

    # 無声区間は高めの励起レート + フレーム毎の微小ジッタ
    rng = np.random.RandomState(12345)
    for i in range(nf):
        if not voiced[i]:
            f0s[i] = UNVOICED_RATE + (rng.rand() - 0.5) * 2.0 * UNVOICED_JITTER
    return f0s, voiced, rms, lvl_db


# =============================================================================
# 解析: LPC フォルマント抽出
# =============================================================================

def levinson(r: np.ndarray, order: int):
    """Levinson-Durbin。r は自己相関 (r[0..order])。戻り値 (a, err)。
    a[0]=1 の予測多項式 A(z)=1+a1 z^-1+... を返す。"""
    a = np.zeros(order + 1)
    a[0] = 1.0
    e = r[0]
    if e <= 0:
        return a, 0.0
    for i in range(1, order + 1):
        acc = r[i] + np.dot(a[1:i], r[i - 1:0:-1]) if i > 1 else r[i]
        k = -acc / e
        anew = a.copy()
        anew[1:i] = a[1:i] + k * a[i - 1:0:-1]
        anew[i] = k
        a = anew
        e *= (1.0 - k * k)
        if e <= 0:
            e = 1e-12
            break
    return a, e


def lpc_frame(seg: np.ndarray, order: int, lagwin_hz: float, fs: int):
    """1 フレームの LPC 係数とゲインを求める。"""
    w = np.hanning(len(seg))
    y = seg * w
    if np.max(np.abs(y)) < 1e-9:
        return None, 0.0
    r = np.correlate(y, y, 'full')[len(y) - 1: len(y) + order]
    if r[0] <= 0:
        return None, 0.0
    r = r.astype(np.float64).copy()
    # ラグ窓 (帯域幅拡張) で極が鋭くなりすぎるのを防ぐ
    lag = np.arange(len(r))
    r *= np.exp(-0.5 * (2.0 * np.pi * lagwin_hz * lag / fs) ** 2)
    r[0] *= 1.0001
    a, e = levinson(r, order)
    return a, np.sqrt(max(e, 1e-20))


def lpc_response(a: np.ndarray, gain: float, freqs: np.ndarray, fs: int,
                 preemph: float) -> np.ndarray:
    """LPC 包絡 |H(f)| をフォルマント周波数で評価する。
    プリエンファシスの逆補正 (デエンファシス) を掛けて原音の傾斜へ戻す。"""
    w = 2.0 * np.pi * freqs / fs
    z = np.exp(-1j * w)
    A = np.zeros(len(freqs), dtype=complex)
    for k, ak in enumerate(a):
        A += ak * z ** k
    h = gain / np.maximum(np.abs(A), 1e-12)
    deemph = 1.0 / np.maximum(np.abs(1.0 - preemph * z), 1e-6)
    return h * deemph


def formants_from_lpc(a: np.ndarray, fs: int, cfg: dict):
    """LPC 係数の根からフォルマント候補 (周波数, 帯域幅) を取り出す。"""
    if a is None:
        return np.zeros(0), np.zeros(0)
    rt = np.roots(a)
    rt = rt[np.imag(rt) > 0]
    if rt.size == 0:
        return np.zeros(0), np.zeros(0)
    freq = np.angle(rt) * fs / (2 * np.pi)
    mag = np.abs(rt)
    mag = np.clip(mag, 1e-9, 0.999999)
    bw = -np.log(mag) * fs / np.pi
    fmax = min(cfg['fmax'], fs * 0.5 * 0.96)
    sel = (freq >= FORMANT_FMIN) & (freq <= fmax) & (bw <= cfg['bw_max'])
    freq, bw = freq[sel], bw[sel]
    o = np.argsort(freq)
    return freq[o], bw[o]


# 帯域分割方式で使う探索区間 (F1..F4 が概ね収まる範囲。境界は重なってよい)
FORMANT_BANDS = ((150.0, 900.0), (700.0, 2200.0), (1700.0, 3200.0), (2800.0, 4000.0))


def formants_from_envelope(a: np.ndarray, gain: float, fs: int, cfg: dict,
                           mode: str):
    """LPC 包絡のピークからフォルマントを取る。

    mode='env'    : 包絡の極大点を強い順に 4 本
    mode='band4'  : F1..F4 の探索区間ごとに包絡の最大点を 1 本ずつ
                    (4 本が同じ帯域へ固まるのを防げる)
    """
    if a is None:
        return np.zeros(0), np.zeros(0)
    fmax = min(cfg['fmax'], fs * 0.5 * 0.96)
    grid = np.arange(FORMANT_FMIN, fmax, 10.0)
    h = np.abs(lpc_response(a, gain, grid, fs, cfg['preemph']))
    if mode == 'band4':
        out = []
        for lo, hi in FORMANT_BANDS:
            m = (grid >= lo) & (grid <= min(hi, fmax))
            if not m.any():
                continue
            out.append(grid[m][int(np.argmax(h[m]))])
        f = np.array(sorted(out))
        return f, np.full(len(f), 200.0)
    # 極大点
    pk = np.where((h[1:-1] > h[:-2]) & (h[1:-1] >= h[2:]))[0] + 1
    if pk.size == 0:
        return np.zeros(0), np.zeros(0)
    strong = pk[np.argsort(-h[pk])][:NFORMANT]
    f = np.sort(grid[strong])
    return f, np.full(len(f), 200.0)


def formants_from_harmonic_envelope(seg: np.ndarray, fs: int, f0: float,
                                    cfg: dict):
    """倍音ピークを結んだスペクトル包絡 (SEEVOC 系) からフォルマントを取る。

    基本周波数が高い音声では LPC の極が個々の倍音に張り付いてしまい
    フォルマントを取り違える。倍音ピークだけを拾って間を補間すれば
    倍音の櫛の影響を受けない包絡が得られる。
    """
    n = len(seg)
    nfft = 1 << int(np.ceil(np.log2(max(n, 512)))) * 1
    nfft = max(nfft * 2, 1024)
    sp = np.abs(np.fft.rfft(seg * np.hanning(n), nfft))
    fr = np.fft.rfftfreq(nfft, 1.0 / fs)
    fmax = min(cfg['fmax'], fs * 0.5 * 0.96)
    if sp.max() <= 0:
        return np.zeros(0), np.zeros(0)
    # 倍音位置の近傍でピークを拾う
    pf, pm = [], []
    k = 1
    while k * f0 < fmax:
        lo, hi = k * f0 * 0.75, k * f0 * 1.25
        m = (fr >= lo) & (fr <= hi)
        if m.any():
            j = int(np.argmax(sp[m]))
            pf.append(fr[m][j])
            pm.append(sp[m][j])
        k += 1
    if len(pf) < 3:
        return np.zeros(0), np.zeros(0)
    pf, pm = np.array(pf), np.array(pm)
    grid = np.arange(FORMANT_FMIN, fmax, 10.0)
    env = np.interp(grid, pf, 20 * np.log10(pm + 1e-12))
    # 探索区間ごとに包絡の最大点を 1 本ずつ (F1..F4 が同じ帯域へ固まらない)
    out = []
    for lo, hi in FORMANT_BANDS:
        m = (grid >= lo) & (grid <= min(hi, fmax))
        if m.any():
            out.append(grid[m][int(np.argmax(env[m]))])
    f = np.array(sorted(out))
    return f, np.full(len(f), 200.0)


def pick_formants(freq: np.ndarray, bw: np.ndarray, prev: np.ndarray, cfg: dict):
    """フォルマント候補から 4 本を選ぶ。足りない分は直前フレームの値を保持。"""
    if freq.size > NFORMANT:
        if cfg['pick'] == 'bw':
            keep = np.argsort(bw)[:NFORMANT]
            keep = np.sort(keep)
            freq, bw = freq[keep], bw[keep]
        else:   # 'low' : 周波数の低い順に 4 本 (F1..F4 の標準的な取り方)
            freq, bw = freq[:NFORMANT], bw[:NFORMANT]
    out = prev.copy()
    if freq.size == 0:
        return out
    # 選ばれた本数分だけ更新し、残りは直前フレームを保持
    out[:freq.size] = freq
    if freq.size < NFORMANT:
        # 直前値が既存フォルマントと重ならないよう最低限の間隔を確保
        for k in range(freq.size, NFORMANT):
            out[k] = max(out[k], out[k - 1] + 250.0)
    out = np.clip(np.sort(out), FORMANT_FMIN, cfg['fmax'])
    return out


# =============================================================================
# 解析本体: wav → フレームパラメータ (物理量)
# =============================================================================

def analyze(x: np.ndarray, fs: int, cfg: dict):
    """wav から 1 フレーム毎の (F0, フォルマント 4 本, 振幅 4 本) を求める。"""
    hop = fs * FRAME_PERIOD                      # 454.78125 サンプル (小数ホップ)
    nframes = int(np.floor((len(x) - 1) / hop)) + 1
    centers = np.arange(nframes) * hop

    f0, voiced, _rms_full, lvl_db = estimate_f0_track(x, fs, centers, cfg)

    # フォルマント抽出は合成帯域に合わせてダウンサンプルしてから行う
    lpc_rate = cfg['lpc_rate']
    xb = resample_poly(x, lpc_rate, fs)                          # 帯域制限版 (振幅基準用)
    xl = np.append(xb[0], xb[1:] - cfg['preemph'] * xb[:-1])     # プリエンファシス
    hop_l = lpc_rate * FRAME_PERIOD
    win_l = int(round(cfg['win_ms'] * 1e-3 * lpc_rate))

    # 振幅の基準は「合成できる帯域の RMS」を使う。
    # 全帯域 RMS を使うと 5kHz 以上のみに energy がある摩擦音で
    # 低域が過大になるため。
    rms = np.zeros(nframes)
    for i in range(nframes):
        s = int(round(i * hop_l)) - win_l // 2
        a0, b0 = max(0, s), min(len(xb), s + win_l)
        seg = xb[a0:b0] if b0 > a0 else np.zeros(1)
        rms[i] = np.sqrt(np.mean(seg * seg) * (len(seg) / max(win_l, 1))) + 1e-12

    prev = np.array([500.0, 1500.0, 2500.0, 3400.0])
    F = np.zeros((nframes, NFORMANT))
    A = np.zeros((nframes, NFORMANT))

    for i in range(nframes):
        s = int(round(i * hop_l)) - win_l // 2
        seg = np.zeros(win_l)
        a0, b0 = max(0, s), min(len(xl), s + win_l)
        if b0 > a0:
            seg[a0 - s:b0 - s] = xl[a0:b0]
        a_lpc, gain = lpc_frame(seg, cfg['order'], cfg['lagwin'], lpc_rate)
        raw = np.zeros(win_l)
        if b0 > a0:
            raw[a0 - s:b0 - s] = xb[a0:b0]
        if cfg['fsel'] == 'root':
            fr, bwv = formants_from_lpc(a_lpc, lpc_rate, cfg)
        elif cfg['fsel'] == 'harm':
            fr, bwv = formants_from_harmonic_envelope(raw, lpc_rate, f0[i], cfg)
            if fr.size == 0:
                fr, bwv = formants_from_lpc(a_lpc, lpc_rate, cfg)
        else:
            fr, bwv = formants_from_envelope(a_lpc, gain, lpc_rate, cfg, cfg['fsel'])
        f = pick_formants(fr, bwv, prev, cfg)
        prev = f
        F[i] = f
        if a_lpc is None:
            A[i] = 0.0
            continue
        if cfg['amp'] == 'band':
            # 帯域エネルギー整合: 各フォルマントが受け持つ帯域 (隣接フォルマント
            # の幾何平均で区切る) の実測パワーを、その正弦波 1 本に割り当てる。
            # 4 本しか出せない中でスペクトルの重心と総量を正しく保てる。
            sp = np.abs(np.fft.rfft(raw * np.hanning(win_l))) ** 2
            fr = np.fft.rfftfreq(win_l, 1.0 / lpc_rate)
            edges = [50.0]
            for k in range(NFORMANT - 1):
                edges.append(np.sqrt(f[k] * f[k + 1]))
            edges.append(lpc_rate / 2.0)
            e = np.array([sp[(fr >= edges[k]) & (fr < edges[k + 1])].sum()
                          for k in range(NFORMANT)])
            A[i] = np.sqrt(np.maximum(e, 0.0))
        else:
            # 各フォルマントの相対振幅 = LPC 包絡の値
            A[i] = np.abs(lpc_response(a_lpc, gain, f, lpc_rate, cfg['preemph']))

    # フォルマント軌跡の時間方向平滑化 (フレーム毎のばらつきによる
    # 「ゆらぎ」を抑えて聞き取りやすくする)
    ns = cfg['fsmooth']
    if ns >= 3:
        Fs = F.copy()
        h = ns // 2
        for i in range(nframes):
            lo, hi = max(0, i - h), min(nframes, i + h + 1)
            Fs[i] = np.median(F[lo:hi], axis=0)
        F = np.sort(Fs, axis=1)

    return centers, f0, voiced, rms, lvl_db, F, A


def amps_to_peak(A: np.ndarray, rms: np.ndarray, f0: np.ndarray,
                 lvl_db: np.ndarray, tau: float, cfg: dict) -> np.ndarray:
    """相対振幅 → 減衰正弦波バーストのピーク振幅。

    F0 レートで鳴らす減衰正弦波列の実効値は
        rms^2 = F0 * (tau/4) * sum(A_i^2)
    なので、これが原音フレームの RMS に一致するよう全体ゲインを決める。
    → 4 本の相対比を保ちつつ、全体レベルが原音の RMS 包絡に追従する。
    """
    out = np.zeros_like(A)
    for i in range(A.shape[0]):
        s = np.sum(A[i] ** 2)
        if s <= 0 or lvl_db[i] <= cfg['silence_db']:
            continue
        scale = rms[i] / np.sqrt(max(f0[i] * tau / 4.0 * s, 1e-30))
        out[i] = A[i] * scale
    return out


# =============================================================================
# チップ挙動を模した再合成 (量子化済みパラメータからの検証用合成)
# =============================================================================

def synth_from_frames(frames: np.ndarray, amp_ref: float, tau: float,
                      fs: int, nsamples: int) -> np.ndarray:
    """csmdata と同じ 14 バイト/フレームの配列から音声を再合成する。

    タイマ A レート、(block,fnum) から逆算した実周波数、TL から逆算した
    線形振幅を使い「F0 レートのトリガ毎に 4 本の減衰正弦波を鳴らす」。

    実チップの挙動に合わせて
      - トリガ毎に位相を 0 にリセット (ピッチ同期パルス)
      - トリガ毎にエンベロープも再起動するので、前のバーストは
        減衰しきっていなくても打ち切られる (加算しない)
      - TL は次のトリガで反映される (= バースト単位で振幅が変わる)
    としている。
    """
    y = np.zeros(nsamples + fs)
    hop = fs * FRAME_PERIOD
    tmax = int(fs * 0.05)
    t_all = np.arange(tmax) / fs
    env_all = np.exp(-t_all / tau)
    next_t = 0.0
    for i in range(frames.shape[0]):
        fr = frames[i]
        rate = timer_a_to_f0(fr[0], fr[1])
        freqs = np.array([block_fnum_to_freq(fr[2 + 2 * k], fr[3 + 2 * k])
                          for k in range(NFORMANT)])
        amps = np.array([tl_to_amp(fr[10 + k], amp_ref) for k in range(NFORMANT)])
        t0, t1 = i * hop / fs, (i + 1) * hop / fs
        period = 1.0 / max(rate, 1.0)
        if next_t < t0:
            next_t = t0
        while next_t < t1:
            n0 = int(round(next_t * fs))
            # 次のトリガまでが 1 バーストの長さ (打ち切り)
            blen = min(int(round(period * fs)), tmax)
            if blen > 0 and n0 + blen < len(y) and np.any(amps > 0):
                t = t_all[:blen]
                burst = np.zeros(blen)
                for k in range(NFORMANT):
                    if amps[k] > 0:
                        burst += amps[k] * np.sin(2 * np.pi * freqs[k] * t)
                y[n0:n0 + blen] = burst * env_all[:blen]
            next_t += period
    return y[:nsamples]


# =============================================================================
# 客観評価: メルスペクトル距離 / 1/3 オクターブバンド相関
# =============================================================================

def _mel_filterbank(nfft: int, fs: int, nmel: int = 40,
                    fmin: float = 60.0, fmax: float = 8000.0) -> np.ndarray:
    def hz2mel(f):
        return 2595.0 * np.log10(1.0 + f / 700.0)

    def mel2hz(m):
        return 700.0 * (10.0 ** (m / 2595.0) - 1.0)

    pts = mel2hz(np.linspace(hz2mel(fmin), hz2mel(fmax), nmel + 2))
    bins = np.floor((nfft + 1) * pts / fs).astype(int)
    fb = np.zeros((nmel, nfft // 2 + 1))
    for m in range(1, nmel + 1):
        l, c, r = bins[m - 1], bins[m], bins[m + 1]
        if c == l:
            c = l + 1
        if r <= c:
            r = c + 1
        r = min(r, nfft // 2)
        for k in range(l, c):
            fb[m - 1, k] = (k - l) / max(c - l, 1)
        for k in range(c, r):
            fb[m - 1, k] = (r - k) / max(r - c, 1)
    return fb


def log_mel(x: np.ndarray, fs: int, nfft: int = 1024, hop: int = 256,
            nmel: int = 40) -> np.ndarray:
    fb = _mel_filterbank(nfft, fs, nmel)
    w = np.hanning(nfft)
    nfr = max(1, (len(x) - nfft) // hop + 1)
    out = np.zeros((nfr, nmel))
    for i in range(nfr):
        seg = x[i * hop:i * hop + nfft] * w
        sp = np.abs(np.fft.rfft(seg)) ** 2
        out[i] = fb @ sp
    return 10.0 * np.log10(out + 1e-10)


def third_octave(x: np.ndarray, fs: int, nfft: int = 1024, hop: int = 256):
    """1/3 オクターブバンドの対数スペクトル (100Hz-8kHz)。"""
    centers = 100.0 * (2.0 ** (np.arange(0, 20) / 3.0))
    centers = centers[centers < min(8000.0, fs / 2 * 0.95)]
    freqs = np.fft.rfftfreq(nfft, 1.0 / fs)
    w = np.hanning(nfft)
    nfr = max(1, (len(x) - nfft) // hop + 1)
    out = np.zeros((nfr, len(centers)))
    masks = [(freqs >= c / 2 ** (1 / 6)) & (freqs < c * 2 ** (1 / 6)) for c in centers]
    for i in range(nfr):
        seg = x[i * hop:i * hop + nfft] * w
        sp = np.abs(np.fft.rfft(seg)) ** 2
        for b, m in enumerate(masks):
            out[i, b] = sp[m].sum() if m.any() else 0.0
    return 10.0 * np.log10(out + 1e-10)


def evaluate(ref: np.ndarray, tst: np.ndarray, fs: int) -> dict:
    """原音と再合成の距離を測る。両者は RMS を揃えてから比較する。"""
    n = min(len(ref), len(tst))
    ref, tst = ref[:n].copy(), tst[:n].copy()
    ref /= (np.sqrt(np.mean(ref ** 2)) + 1e-12)
    tst /= (np.sqrt(np.mean(tst ** 2)) + 1e-12)
    mr, mt = log_mel(ref, fs), log_mel(tst, fs)
    k = min(len(mr), len(mt))
    mr, mt = mr[:k], mt[:k]
    # 無音フレームを除外 (対数領域の底で相関が水増しされるのを防ぐ)
    act = mr.max(axis=1) > (mr.max() - 45.0)
    mr, mt = mr[act], mt[act]
    rmse = float(np.sqrt(np.mean((mr - mt) ** 2)))
    corr = float(np.corrcoef(mr.ravel(), mt.ravel())[0, 1])
    tr, tt = third_octave(ref, fs), third_octave(tst, fs)
    k = min(len(tr), len(tt))
    tr, tt = tr[:k][act[:k]], tt[:k][act[:k]]
    tcorr = float(np.corrcoef(tr.ravel(), tt.ravel())[0, 1])
    # フレーム毎相関の平均 (時間変化の追従性)
    fc = []
    for i in range(len(mr)):
        a, b = mr[i] - mr[i].mean(), mt[i] - mt[i].mean()
        d = np.linalg.norm(a) * np.linalg.norm(b)
        if d > 1e-9:
            fc.append(float(np.dot(a, b) / d))
    return {'mel_rmse_db': rmse, 'mel_corr': corr,
            'third_oct_corr': tcorr, 'frame_corr': float(np.mean(fc)) if fc else 0.0}


# =============================================================================
# フレーム → 14 バイト列
# =============================================================================

def build_frames(f0: np.ndarray, F: np.ndarray, P: np.ndarray,
                 amp_ref: float) -> np.ndarray:
    """物理量 → 1 フレーム 14 バイトのチップパラメータ列。"""
    n = len(f0)
    out = np.zeros((n, FRAME_BYTES), dtype=np.uint8)
    for i in range(n):
        r24, r25, _ = f0_to_timer_a(f0[i])
        out[i, 0] = r24
        out[i, 1] = r25
        for k in range(NFORMANT):
            hi, lo, _ = freq_to_block_fnum(F[i, k])
            out[i, 2 + 2 * k] = hi
            out[i, 3 + 2 * k] = lo
            out[i, 10 + k] = amp_to_tl(P[i, k], amp_ref)
    return out


def write_asm(path: str, frames: np.ndarray, src_name: str, src_sec: float,
              tau_ms: float) -> int:
    """lwasm 用のデータファイルを出力する。戻り値はデータ部のバイト数。"""
    n = frames.shape[0]
    lines = []
    lines.append('* 自動生成 -- scripts/wav2csm.py が出力。手で編集しない')
    lines.append('* YM2203 CSM 音声合成データ (Ch3 CSM + 3スロット独立周波数 + アルゴリズム 7)')
    lines.append('* フレーム周期 %.4fms (= メイン CPU 周期タイマ %d tick、%.3f フレーム/秒)'
                 % (FRAME_PERIOD * 1000.0, FRAME_TICKS, FRAME_RATE))
    lines.append('* 総フレーム数 %d (再生時間 %.3f 秒)' % (n, n * FRAME_PERIOD))
    lines.append('* 元波形 %s (%.3f 秒 / %d Hz モノラル)' % (src_name, src_sec, SRC_RATE))
    lines.append('*')
    lines.append('* 1 フレーム %d バイトの並び:' % FRAME_BYTES)
    lines.append('*   [0]     タイマ A レジスタ $24 に書く値 (NA の上位 8bit)')
    lines.append('*   [1]     タイマ A レジスタ $25 に書く値 (NA の下位 2bit)')
    lines.append('*   [2..9]  フォルマント 1..4 の (block<<3|fnum上位3bit, fnum下位8bit) を 4 組')
    lines.append('*   [10..13] フォルマント 1..4 の TL 値 (%d..%d、小さいほど大音量、%d=無音)'
                 % (TL_MIN, TL_MAX, TL_MAX))
    lines.append('*')
    lines.append('* 前提となる Ch3 の設定 (6809 側の初期化で必ず合わせること):')
    lines.append('*   $B2 = $07                 FB=0, ALG=7 (4 キャリア並列)')
    lines.append('*   $32/$36/$3A/$3E = $%02X     DT=0, MUL=%d (MUL=1 だと 2132Hz が上限で足りない)'
                 % (OP_MUL, OP_MUL))
    lines.append('*   $52/$56/$5A/$5E = $1F     KS=0, AR=31 (瞬時アタック)')
    lines.append('*   $62/$66/$6A/$6E = $00     AM=0, DR=0')
    lines.append('*   $72/$76/$7A/$7E = $1F     SR=31 (最速減衰: -40dB / 5.08ms)')
    lines.append('*   $82/$86/$8A/$8E = $0F     SL=0, RR=15')
    lines.append('*   $2F → $2D = $00 の 2 段書き   プリスケーラ 1/%d に確定させる' % OPN_PRESCALER)
    lines.append('*        (1 段書きでは 1/6 にならずピッチが 1 オクターブずれる実装がある)')
    lines.append('*   $27 = 初回 $81、以後毎フレーム $B1')
    lines.append('*        b7-6 は独立した許可ビットではなく Ch3 の 2 ビットのモード番号:')
    lines.append('*          00=通常 / 01=Ch3 特殊 / 10=CSM (特殊を含む) / 11=未定義')
    lines.append('*        CSM は 10 ちょうどでなければならない。11 (b6 も立てる) を書くと')
    lines.append('*        CSM と認めずキーオンを一切起こさない実装があり、完全な無音になる')
    lines.append('*        b5,b4=フラグクリア (毎フレーム) / b0=タイマA 有効')
    lines.append('*        b3,b2 (フラグ許可) と b1 (タイマB) は不要なので 0 のままにする')
    lines.append('*        0 を書くとタイマがリロードされキーオンが欠落する')
    lines.append('* フレーム同期はメイン CPU の周期タイマ ($FD03 bit2) を %d tick 数える'
                 % FRAME_TICKS)
    lines.append('*')
    lines.append('* フォルマント 1..4 と Ch3 スロットの対応 (F-Num は高位→低位の順に書くこと):')
    lines.append('*   フォルマント1 → F-Num $AD/$A9、TL $42')
    lines.append('*   フォルマント2 → F-Num $AC/$A8、TL $46')
    lines.append('*   フォルマント3 → F-Num $AE/$AA、TL $4A')
    lines.append('*   フォルマント4 → F-Num $A6/$A2、TL $4E')
    lines.append('*   (4 本とも並列キャリアなので割当自体は任意だが、周波数と TL は')
    lines.append('*    必ず同じスロットの組で書くこと)')
    lines.append('*')
    lines.append('* 再合成検証時の減衰時定数 %.2fms (= SR=31 の実測 -7.87dB/ms)' % tau_ms)
    lines.append('')
    lines.append('CSMFRAMES  equ %d' % n)
    lines.append('CSMFRSIZE  equ %d' % FRAME_BYTES)
    lines.append('csmdata')
    for i in range(n):
        vals = ','.join('$%02X' % v for v in frames[i])
        lines.append('    fcb %s' % vals)
    lines.append('')
    with open(path, 'w', encoding='utf-8', newline='\n') as fp:
        fp.write('\n'.join(lines))
    return n * FRAME_BYTES


# =============================================================================
# 変換一式
# =============================================================================

DEFAULT_CFG = {
    'order': 14,            # LPC 次数 (10kHz サンプル)
    'win_ms': 16.0,         # 分析窓長。F0 が高いので短めが有利
    'preemph': 0.97,        # プリエンファシス係数
    'lagwin': 40.0,         # ラグ窓 (帯域幅拡張) [Hz]
    'bw_max': FORMANT_BW_MAX,
    'pick': 'bw',           # 候補が 5 本以上ある時は帯域幅の狭い順に 4 本
    'aper_thr': 0.55,       # 有声判定のしきい値 (YIN の無周期性)
    'silence_db': -42.0,    # これ以下のフレームは無音 (TL=127)
    'tau_ms': DECAY_TAU_MS,  # 再合成の減衰時定数 = 実機 SR=31 相当
    'lpc_rate': LPC_RATE,
    'fmax': FORMANT_FMAX,
    'op_mul': OP_MUL,
    'amp': 'band',          # 振幅は帯域エネルギー整合
    'fsel': 'root',         # フォルマントは LPC の根から
    'fsmooth': 3,           # フォルマント軌跡の中央値平滑化フレーム数
}


def convert(x: np.ndarray, fs: int, cfg: dict):
    """解析 → チップパラメータ化 → 再合成 → 評価まで一気に行う。"""
    global OP_MUL
    OP_MUL = cfg['op_mul']          # 写像関数群が参照するオペレータ逓倍
    tau = cfg['tau_ms'] * 1e-3
    centers, f0, voiced, rms, lvl_db, F, A = analyze(x, fs, cfg)
    P = amps_to_peak(A, rms, f0, lvl_db, tau, cfg)
    # TL=0 を最大振幅に割り当ててチップのダイナミックレンジを使い切る
    nz = P[P > 0]
    amp_ref = float(np.percentile(nz, 99.5)) if nz.size else 1.0
    frames = build_frames(f0, F, P, amp_ref)
    y = synth_from_frames(frames, amp_ref, tau, fs, len(x))
    met = evaluate(x, y, fs)
    return {'frames': frames, 'recon': y, 'metrics': met, 'amp_ref': amp_ref,
            'f0': f0, 'voiced': voiced, 'F': F, 'P': P}


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    ap = argparse.ArgumentParser(description='wav を YM2203 CSM パラメータへ変換する')
    ap.add_argument('--wav', default=os.path.join(root, 'assets', 'FM77AV.wav'))
    ap.add_argument('--out', default=os.path.join(root, 'assets', 'csmdata.s'))
    ap.add_argument('--recon', default=None, help='再合成 wav の出力先')
    ap.add_argument('--sweep', action='store_true', help='パラメータ探索を行う')
    ap.add_argument('--order', type=int, default=DEFAULT_CFG['order'])
    ap.add_argument('--tau-ms', type=float, default=DEFAULT_CFG['tau_ms'])
    ap.add_argument('--pick', default=DEFAULT_CFG['pick'], choices=['low', 'bw'])
    ap.add_argument('--win-ms', type=float, default=DEFAULT_CFG['win_ms'])
    ap.add_argument('--lagwin', type=float, default=DEFAULT_CFG['lagwin'])
    ap.add_argument('--bw-max', type=float, default=DEFAULT_CFG['bw_max'])
    args = ap.parse_args()

    x, fs = read_wav(args.wav)
    if fs != SRC_RATE:
        x = resample_poly(x, SRC_RATE, fs)
        fs = SRC_RATE
    x = x / (np.max(np.abs(x)) + 1e-12) * 0.99

    if args.sweep:
        rows = []
        for order in (12, 14, 16, 18):
            for tau_ms in (2.5, 3.5, 5.0, 7.0, 10.0):
                for pick in ('low', 'bw'):
                    cfg = dict(DEFAULT_CFG, order=order, tau_ms=tau_ms, pick=pick)
                    r = convert(x, fs, cfg)
                    m = r['metrics']
                    rows.append((order, tau_ms, pick, m['mel_rmse_db'],
                                 m['mel_corr'], m['third_oct_corr'], m['frame_corr']))
                    print('order=%2d tau=%4.1fms pick=%-3s  melRMSE=%6.2fdB '
                          'melCorr=%.4f 1/3octCorr=%.4f frameCorr=%.4f'
                          % rows[-1], flush=True)
        rows.sort(key=lambda t: -(t[4] + t[6]))
        print('\n--- 上位 5 設定 (melCorr + frameCorr 順) ---')
        for r in rows[:5]:
            print('order=%2d tau=%4.1fms pick=%-3s melRMSE=%.2f melCorr=%.4f '
                  '1/3oct=%.4f frameCorr=%.4f' % r)
        return 0

    cfg = dict(DEFAULT_CFG, order=args.order, tau_ms=args.tau_ms, pick=args.pick,
               win_ms=args.win_ms, lagwin=args.lagwin, bw_max=args.bw_max)
    r = convert(x, fs, cfg)
    nbytes = write_asm(args.out, r['frames'], os.path.basename(args.wav),
                       len(x) / fs, cfg['tau_ms'])
    m = r['metrics']
    print('フレーム数      : %d' % r['frames'].shape[0])
    print('データ長        : %d バイト (%.2f KB)' % (nbytes, nbytes / 1024.0))
    print('有声フレーム    : %d / %d' % (int(r['voiced'].sum()), len(r['voiced'])))
    print('メル対数距離    : %.2f dB (RMSE)' % m['mel_rmse_db'])
    print('メル相関        : %.4f' % m['mel_corr'])
    print('1/3 オクターブ相関: %.4f' % m['third_oct_corr'])
    print('フレーム内相関  : %.4f' % m['frame_corr'])
    print('出力            : %s' % args.out)
    if args.recon:
        write_wav(args.recon, r['recon'], fs)
        print('再合成 wav      : %s' % args.recon)
    return 0


if __name__ == '__main__':
    sys.exit(main())
