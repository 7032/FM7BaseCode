#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# このスクリプトは MIT ライセンスのツール D77TOT77WAV (Copyright (c) 2026
# Naomitsu.Tsugiiwa) を本テンプレートに取り込んだものです。ライセンス全文は
# 同ディレクトリの D77TOT77WAV.LICENSE.txt を参照。
"""
Generic D77 -> T77 converter for FM-7 F-BASIC.

Pipeline:
    D77 -> raw sector concatenation -> BIN
        -> using the given entry address and BIN size, decide how each
           16 KiB chunk reaches its final memory location:

           * SIMPLE pattern (entry >= $2000):
               - chunk N-1 (highest mem) loaded first, trampoline stages
                 it directly to its final position; ROM-OFF/ROM-ON toggled
                 inside the trampoline as needed
               - chunk N-2 loaded second, staged to its final, ...
               - chunk 0 loaded LAST via LOADM ",,R"; trampoline stages
                 to its final and JMPs the entry

           * ARTICLE pattern (entry < $2000, chunks span the LOADM buffer):
               - chunk 0 loaded first; trampoline COPIES it to a 16 KiB
                 stash slot in URA RAM (just past chunk N-1's final)
               - chunks 1..N-2 (if any) loaded next; staged to their final
                 positions in URA RAM (they don't overlap any buffer)
               - chunk N-1 loaded LAST via LOADM ",,R"; the "relocate2"
                 trampoline does two moves (buffer->target(N-1) reverse,
                 stash->target0 forward) and JMPs the entry

    -> each pass is one LOADM file; concatenate as a T77 tape image
       and emit a TXT operator procedure

Memory layout used by every pass:
    CLEAR ,&H13FF leaves $1400-$7FFF free for us.
    $1400-$1419   Stage 1   (26 bytes, fixed)
    $141A-$143x   Stage 2 source (22, 23, or 39 bytes; copied to $D000)
    $143x-$1FFF   zero padding
    $2000-$5FFF   LOADM buffer (16 KiB)

Trampoline templates are shipped as five small .bin files (48-65 B each)
with sentinel placeholders that this tool patches per pass:
    trampoline_fwd_int.bin    forward copy, intermediate (RTS)
    trampoline_rev_int.bin    reverse copy, intermediate
    trampoline_fwd_last.bin   forward copy, last (LDS + JMP entry)
    trampoline_rev_last.bin   reverse copy, last
    trampoline_relocate2.bin  2-move relocator, last (used by ARTICLE pattern)

Usage:
    python3 d77_to_t77_chunks.py game.d77 --addr 0x0200 \\
        [--skip N] [--size N] [--out game.t77] [--txt game.txt]
"""

import argparse
import os
import struct
import sys


# ===== FM-7 memory layout =====

CLEAR_VALUE       = 0x13FF
STAGER_LOAD_ADDR  = 0x1400
BUFFER_ADDR       = 0x2000
CHUNK_SIZE        = 0x4000
BUFFER_END        = BUFFER_ADDR + CHUNK_SIZE        # $6000
STAGE2_ADDR       = 0xD000
ENTRY_STACK       = 0xFBFF

LOADM_LO_LIMIT    = 0x0800
LOADM_HI_LIMIT    = 0x8000
URA_RAM_END       = 0xFC00

STAGE1_SIZE       = 26


# ===== D77 disk image parsing =====

_D77_FILL_BYTES = (0x00, 0xE5, 0xFF)


def _sector_is_fill(data):
    """A 'fill' sector contains a single repeated byte from the known FM-7
    format fillers ($00 / $E5 / $FF). These are what the disk formatter
    leaves on every sector not yet written by a real file."""
    if not data:
        return True
    s = set(data)
    return len(s) == 1 and next(iter(s)) in _D77_FILL_BYTES


def extract_d77_payload(d77_data, trim_trailing_fill=True, verbose=False):
    """Walk the D77 track-offset table and concatenate sector data in CHR
    (cylinder, head, record) order.

    If `trim_trailing_fill` is True (default), drop trailing tracks whose
    every sector is a known fill byte ($00 / $E5 / $FF) — those are the
    parts of the floppy that the formatter wrote and no file has touched.
    Fill sectors WITHIN a track that also contains real data are kept
    intact: programs sometimes pad their data area with $E5 / $00 and the
    IPL still loads those sectors as part of the program image.

    Pass `trim_trailing_fill=False` to disable the heuristic and get the
    raw concatenation of every sector (useful when the caller wants to
    control the exact byte range via `--size`).
    """
    sectors = []
    for ti in range(164):
        off = struct.unpack('<I', d77_data[0x20 + ti * 4:0x24 + ti * 4])[0]
        if off == 0 or off >= len(d77_data):
            continue
        sec_count = struct.unpack('<H', d77_data[off + 4:off + 6])[0]
        pos = off
        for _ in range(sec_count):
            if pos + 16 > len(d77_data):
                break
            c = d77_data[pos]
            h = d77_data[pos + 1]
            r = d77_data[pos + 2]
            sz = struct.unpack('<H', d77_data[pos + 14:pos + 16])[0]
            sec_data = d77_data[pos + 16:pos + 16 + sz]
            sectors.append((c, h, r, sec_data))
            pos += 16 + sz
    sectors.sort(key=lambda s: (s[0], s[1], s[2]))

    if not trim_trailing_fill:
        payload = b''.join(s[3] for s in sectors)
        if verbose:
            print(f'    D77 raw extract   : {len(sectors)} sectors, '
                  f'{len(payload)} bytes (no fill-track trim)',
                  file=sys.stderr)
        return payload

    # Index, for each track, whether it has any non-fill content.
    track_has_data = {}
    for c, h, _, sec_data in sectors:
        if not _sector_is_fill(sec_data):
            track_has_data[(c, h)] = True
        elif (c, h) not in track_has_data:
            track_has_data.setdefault((c, h), False)

    last_used = -1
    for i, (c, h, _, _) in enumerate(sectors):
        if track_has_data.get((c, h), False):
            last_used = i

    if last_used < 0:
        if verbose:
            print('warn: D77 has no non-fill tracks; payload is empty',
                  file=sys.stderr)
        return b''

    used = sectors[:last_used + 1]
    payload = b''.join(s[3] for s in used)
    if verbose:
        total = len(sectors)
        kept = len(used)
        c, h, r, _ = used[-1]
        used_tracks = sum(1 for v in track_has_data.values() if v)
        total_tracks = len(track_has_data)
        print(f'    D77 used tracks    : {used_tracks} of {total_tracks}',
              file=sys.stderr)
        print(f'    D77 used sectors   : {kept} of {total}  '
              f'(last data-bearing track ends at C{c} H{h} R{r})',
              file=sys.stderr)
        print(f'    D77 used bytes     : {len(payload)}  '
              f'(dropped {total - kept} sectors of trailing fill)',
              file=sys.stderr)
    return payload


# ===== Trampoline template loading and patching =====

def _u16_be(v):
    return bytes([(v >> 8) & 0xFF, v & 0xFF])


def _template_dir():
    return os.path.dirname(os.path.abspath(__file__))


def _load(name):
    with open(os.path.join(_template_dir(), name), 'rb') as f:
        return bytearray(f.read())


def _patch_once(buf, sentinel, value):
    """Replace exactly one occurrence of `sentinel` (2 bytes) with `value`
    (16-bit, written big-endian). Raises if missing or duplicated."""
    i = buf.find(sentinel)
    if i < 0:
        raise RuntimeError(
            f"sentinel {sentinel.hex().upper()} not found in template")
    j = buf.find(sentinel, i + 2)
    if j >= 0:
        raise RuntimeError(
            f"sentinel {sentinel.hex().upper()} appears twice — ambiguous patch")
    if not (0 <= value <= 0xFFFF):
        raise RuntimeError(f"patch value ${value:X} out of 16-bit range")
    buf[i:i + 2] = _u16_be(value)


def make_single_chunk_trampoline(target_addr, tail, start_addr=None):
    """Build a one-move trampoline ('fwd_int', 'rev_int', 'fwd_last',
    'rev_last') with TARGET (and START for "last" variants) patched in."""
    direction = 'fwd' if target_addr <= BUFFER_ADDR else 'rev'
    name = f'trampoline_{direction}_{tail}.bin'
    buf = _load(name)
    ldy_value = target_addr if direction == 'fwd' else target_addr + CHUNK_SIZE
    _patch_once(buf, b'\xDE\xAD', ldy_value)
    if tail == 'last':
        if start_addr is None:
            raise RuntimeError("last-variant trampoline needs start_addr")
        _patch_once(buf, b'\xBE\xEF', start_addr)
    return bytes(buf), direction


def make_relocate2_trampoline(target1, stash_addr, target0, start_addr):
    """Build the 2-move relocator trampoline used as the final pass of the
    ARTICLE pattern."""
    buf = _load('trampoline_relocate2.bin')
    _patch_once(buf, b'\xDE\xAD', target1 + CHUNK_SIZE)   # M1 dst end
    _patch_once(buf, b'\xBE\xEF', stash_addr)             # M2 src
    _patch_once(buf, b'\xCA\xFE', target0)                # M2 dst
    _patch_once(buf, b'\xFA\xCE', stash_addr + CHUNK_SIZE)# M2 src end
    _patch_once(buf, b'\xD0\x0D', start_addr)             # JMP entry
    return bytes(buf)


def wrap_block(trampoline, chunk_data):
    """Pack a patched trampoline + 16 KiB chunk into a single LOADM block
    that loads contiguously from STAGER_LOAD_ADDR through BUFFER_END-1."""
    assert len(chunk_data) == CHUNK_SIZE
    pad = BUFFER_ADDR - (STAGER_LOAD_ADDR + len(trampoline))
    if pad < 0:
        raise RuntimeError(
            f"trampoline overflows the buffer base: {len(trampoline)} B does "
            f"not fit between ${STAGER_LOAD_ADDR:04X} and ${BUFFER_ADDR:04X}")
    return trampoline + bytes(pad) + chunk_data


# ===== LOADM payload framing and T77 encoding =====

def make_loadm_payload(block_addr, block, exec_addr):
    out = bytearray()
    out += struct.pack('>BHH', 0x00, len(block), block_addr)
    out += block
    out += struct.pack('>BHH', 0xFF, 0x0000, exec_addr)
    return bytes(out)


# Tape FSK half-cycle durations in T77 ticks (1 tick = 16 CPU cycles =
# 8.92 us at 1.794 MHz). MARK_HALF = 50 yields a full mark cycle of
# ~893 us (~1120 Hz), matching the FM-7 leader tone on real hardware.
MARK_HALF = 50
SPACE_HALF = 0x1A
POL = 0x8000
LEADER_BYTES = 256
GAP_LEADER_BYTES = 40
DATA_PAYLOAD_SIZE = 255
WAV_SILENCE_MARKER = 0x0000


def _uart_bits(b):
    bits = [0]
    for i in range(8):
        bits.append((b >> i) & 1)
    bits.extend([1, 1])
    return bits


def _bits_to_halfcycles(bits):
    out = []
    for b in bits:
        dur = MARK_HALF if b else SPACE_HALF
        out.append(dur | POL)
        out.append(dur)
    return out


def _encode_bytes(bs):
    bits = []
    for b in bs:
        bits.extend(_uart_bits(b))
    return _bits_to_halfcycles(bits)


def _leader(n):
    return _encode_bytes(bytes([0xFF] * n))


def _chksum(b):
    return sum(b) & 0xFF


def _tape_header_block(name, attr=0x02):
    sync = bytearray([0x01, 0x3C])
    content = bytearray([0x00, 0x14])
    fn = name.upper()[:8].encode('ascii').ljust(8, b' ')
    content += fn
    content.append(attr)
    content += bytes(11)
    content.append(_chksum(content))
    return bytes(sync + content)


def _tape_data_block(payload):
    sync = bytearray([0x01, 0x3C])
    content = bytearray([0x01, 0xFF])
    chunk = bytearray(payload)
    if len(chunk) < DATA_PAYLOAD_SIZE:
        chunk += bytes(DATA_PAYLOAD_SIZE - len(chunk))
    content += chunk
    content.append(_chksum(content))
    return bytes(sync + content)


def _tape_end_block():
    sync = bytearray([0x01, 0x3C])
    content = bytearray([0xFF])
    content.append(_chksum(content))
    return bytes(sync + content)


def _build_one_tape_file(loadm_bytes, name):
    hc = []
    hc += _leader(LEADER_BYTES)
    hc += _encode_bytes(_tape_header_block(name, attr=0x02))
    pos = 0
    while pos < len(loadm_bytes):
        chunk = loadm_bytes[pos:pos + DATA_PAYLOAD_SIZE]
        hc += _leader(GAP_LEADER_BYTES)
        hc += _encode_bytes(_tape_data_block(chunk))
        pos += DATA_PAYLOAD_SIZE
    hc += _leader(GAP_LEADER_BYTES)
    hc += _encode_bytes(_tape_end_block())
    return hc


def build_t77(files, mark_inter_file_silence=True):
    hc = []
    for i, (name, loadm) in enumerate(files):
        if i > 0 and mark_inter_file_silence:
            hc.append(WAV_SILENCE_MARKER)
        hc += _build_one_tape_file(loadm, name)
        hc += _leader(64)
    hc += _leader(32)
    # T77 tape image format magic header (18 bytes, fixed).
    out = bytearray(bytes.fromhex(
        '58 4D 37 20 54 41 50 45 20 49 4D 41 47 45 20 30 00 00'.replace(' ', '')))
    for v in hc:
        out += struct.pack('>H', v)
    return bytes(out)


# ===== WAV synthesis (44.1 kHz / 16-bit signed / mono) =====
#
# Each T77 half-cycle entry has a duration (in 16-cycle ticks at the 1.794
# MHz CPU clock) and a polarity flag in bit 15. We render that as 16-bit
# signed PCM: silence = 0, the polarity-high half-cycle = +amplitude, the
# polarity-low half-cycle = -amplitude. A fractional accumulator keeps the
# emitted sample count aligned across half-cycles that are not an integer
# number of samples long.
#
# Real tape recordings show a slight roll-off at every level transition
# (a few samples of intermediate amplitude where the tape head and AC
# coupling can't quite snap from -peak to +peak). We approximate that
# with a short cosine ramp at every polarity change.

import math

WAV_SAMPLE_RATE   = 44100
WAV_AMPLITUDE     = 24000      # ~73 % of full-scale, leaves headroom
WAV_SILENCE_LVL   = 0
WAV_HIGH_LVL      =  WAV_AMPLITUDE
WAV_LOW_LVL       = -WAV_AMPLITUDE
WAV_RAMP_SAMPLES  = 3          # cos-shaped transition width

CPU_CLOCK_HZ      = 1_794_000
TICK_SCALE_CY     = 16
WAV_SAMPLES_PER_TICK = WAV_SAMPLE_RATE * TICK_SCALE_CY / CPU_CLOCK_HZ


def _cos_ramp(src, dst, n):
    """Return n samples ramping from `src` toward `dst` along a raised
    cosine. The intermediate sample lands at the midpoint (DC center for
    a -peak-to-+peak swing), matching the way an analog tape recording
    shows one near-zero sample flanked by two part-amplitude samples on
    either side of each polarity flip."""
    out = []
    for k in range(n):
        t = (k + 1) / (n + 1)
        shape = (1 - math.cos(math.pi * t)) / 2
        out.append(int(round(src + (dst - src) * shape)))
    return out


_RAMP_S_TO_H = struct.pack(f'<{WAV_RAMP_SAMPLES}h',
                           *_cos_ramp(WAV_SILENCE_LVL, WAV_HIGH_LVL, WAV_RAMP_SAMPLES))
_RAMP_S_TO_L = struct.pack(f'<{WAV_RAMP_SAMPLES}h',
                           *_cos_ramp(WAV_SILENCE_LVL, WAV_LOW_LVL,  WAV_RAMP_SAMPLES))
_RAMP_H_TO_L = struct.pack(f'<{WAV_RAMP_SAMPLES}h',
                           *_cos_ramp(WAV_HIGH_LVL,    WAV_LOW_LVL,  WAV_RAMP_SAMPLES))
_RAMP_L_TO_H = struct.pack(f'<{WAV_RAMP_SAMPLES}h',
                           *_cos_ramp(WAV_LOW_LVL,     WAV_HIGH_LVL, WAV_RAMP_SAMPLES))
_BYTES_HIGH  = struct.pack('<h', WAV_HIGH_LVL)
_BYTES_LOW   = struct.pack('<h', WAV_LOW_LVL)
_BYTES_SIL   = struct.pack('<h', WAV_SILENCE_LVL)


def _i16le_run(value_bytes, count):
    """Repeat a 2-byte sample word `count` times."""
    return value_bytes * count


def _silence_samples(seconds):
    n = int(round(seconds * WAV_SAMPLE_RATE))
    return _i16le_run(_BYTES_SIL, n)


def _halfcycles_to_samples(hc):
    """Render a list of T77 half-cycle entries to 16-bit signed PCM, with
    a short cosine ramp at every polarity change to soften the otherwise
    perfectly-square edges."""
    out = bytearray()
    acc = 0.0
    prev_pol = None        # None = coming from silence
    for entry in hc:
        dur = entry & 0x7FFF
        if dur == 0:
            continue                          # silence cue, skipped
        pol = (entry & 0x8000) != 0
        acc += dur * WAV_SAMPLES_PER_TICK
        n = int(acc)
        acc -= n
        if n <= 0:
            continue
        if prev_pol is None:
            ramp = _RAMP_S_TO_H if pol else _RAMP_S_TO_L
        elif prev_pol == pol:
            ramp = b''
        else:
            ramp = _RAMP_L_TO_H if pol else _RAMP_H_TO_L
        body_bytes = _BYTES_HIGH if pol else _BYTES_LOW
        ramp_n = len(ramp) // 2
        if ramp_n and n > ramp_n:
            out += ramp
            out += _i16le_run(body_bytes, n - ramp_n)
        else:
            out += _i16le_run(body_bytes, n)
        prev_pol = pol
    return bytes(out)


def _wrap_wav(samples):
    """Build a canonical RIFF/WAVE container around the raw PCM bytes."""
    n = len(samples)
    bits_per_sample = 16
    channels = 1
    byte_rate = WAV_SAMPLE_RATE * channels * bits_per_sample // 8
    block_align = channels * bits_per_sample // 8
    fmt = struct.pack('<IHHIIHH',
                      16,                # fmt chunk size
                      1,                 # PCM
                      channels,
                      WAV_SAMPLE_RATE,
                      byte_rate,
                      block_align,
                      bits_per_sample)
    return (b'RIFF' + struct.pack('<I', 36 + n) + b'WAVE'
            + b'fmt ' + fmt
            + b'data' + struct.pack('<I', n) + samples)


def build_wav(files, head_silence=5.0, gap_silence=5.0, tail_silence=5.0):
    """Render each LOADM file's tape stream to PCM samples with DC-center
    silences inserted at the head, between files, and at the tail."""
    samples = bytearray()
    samples += _silence_samples(head_silence)
    for i, (name, loadm) in enumerate(files):
        if i > 0:
            samples += _silence_samples(gap_silence)
        hc = _build_one_tape_file(loadm, name)
        samples += _halfcycles_to_samples(hc)
    samples += _silence_samples(tail_silence)
    return _wrap_wav(bytes(samples))


# ===== Placement puzzle: deciding the pass plan =====

def split_into_chunks(binary):
    chunks = []
    pos = 0
    while pos < len(binary):
        ch = binary[pos:pos + CHUNK_SIZE]
        if len(ch) < CHUNK_SIZE:
            ch = ch + bytes(CHUNK_SIZE - len(ch))
        chunks.append(ch)
        pos += CHUNK_SIZE
    return chunks


def trim_trailing_zeros(data):
    """Drop trailing zero bytes (typical of empty D77 sectors past the data
    region). Returns the trimmed bytes — at least 1 byte if any non-zero
    exists; empty bytes if `data` is all zero."""
    end = len(data)
    while end > 0 and data[end - 1] == 0:
        end -= 1
    return data[:end]


def plan_passes(start_addr, n_chunks):
    """Return a list of pass descriptors in tape order.

    Each descriptor is a dict with at least:
        'kind'         : 'stage_jmp' | 'stage_back' | 'stash' | 'relocate2'
        'chunk_idx'    : 0..n-1
        'is_last'      : True for the final pass (LOADM ",,R")
        'target'       : the destination this pass writes to
                          (chunk's final, or stash address)
        plus extra fields for 'relocate2'.
    """
    targets = [start_addr + i * CHUNK_SIZE for i in range(n_chunks)]

    if n_chunks == 1:
        return [{
            'kind': 'stage_jmp',
            'chunk_idx': 0,
            'target': targets[0],
            'entry': start_addr,
            'is_last': True,
        }]

    # SIMPLE pattern (any N >= 2 with start_addr >= $2000):
    # Stage chunks one at a time, highest memory first, lowest last. Each
    # non-last chunk's final is at $6000 or above, so subsequent passes'
    # LOADM blocks ($1400-$5FFF) cannot clobber an already-placed chunk.
    if targets[1] >= BUFFER_END:                    # start_addr >= $2000
        passes = []
        for tape_idx, chunk_idx in enumerate(range(n_chunks - 1, -1, -1)):
            is_last = (tape_idx == n_chunks - 1)
            t = targets[chunk_idx]
            if is_last:
                passes.append({'kind': 'stage_jmp', 'chunk_idx': chunk_idx,
                              'target': t, 'entry': start_addr,
                              'is_last': True})
            else:
                passes.append({'kind': 'stage_back', 'chunk_idx': chunk_idx,
                              'target': t, 'is_last': False})
        return passes

    # ARTICLE pattern (N == 2 with start_addr < $2000):
    # Stash chunk 0 in URA RAM during pass 1; the final pass loads chunk 1
    # and runs a relocator that moves both chunks into their final places
    # before JMPing the entry.
    if n_chunks == 2:
        t0, t1 = targets[0], targets[1]
        stash_addr = max(t1 + CHUNK_SIZE, 0x8000)
        if stash_addr + CHUNK_SIZE > URA_RAM_END:
            raise RuntimeError(
                f"no room for URA RAM stash: would end at "
                f"${stash_addr + CHUNK_SIZE:04X} (> ${URA_RAM_END:04X})")
        return [
            {'kind': 'stash', 'chunk_idx': 0, 'target': stash_addr,
             'is_last': False},
            {'kind': 'relocate2', 'chunk_idx': 1,
             'target': t1, 'target0': t0, 'stash_addr': stash_addr,
             'entry': start_addr, 'is_last': True},
        ]

    # N >= 3 with start_addr < $2000: would need multiple URA RAM stashes,
    # which don't fit in the ~31 KiB URA RAM region.
    raise NotImplementedError(
        f"binary of {n_chunks} chunks ({n_chunks * CHUNK_SIZE // 1024} "
        f"KiB) with entry ${start_addr:04X} (< $2000) needs more URA RAM "
        f"stash than the FM-7 can offer (single 16 KiB slot only). Either:\n"
        f"  - trim the binary to <= 32 KiB with --skip / --size, or\n"
        f"  - move the entry address to $2000 or above (SIMPLE pattern "
        f"is unrestricted in N there).")


# ===== Per-pass code emission =====

def build_pass(pass_desc, chunks):
    """Return (loadm_payload, info_dict) for one pass."""
    k = pass_desc['kind']
    ci = pass_desc['chunk_idx']
    info = {'kind': k, 'chunk_idx': ci, 'is_last': pass_desc['is_last']}

    if k == 'stage_jmp':
        tramp, direction = make_single_chunk_trampoline(
            target_addr=pass_desc['target'],
            tail='last',
            start_addr=pass_desc['entry'])
        block = wrap_block(tramp, chunks[ci])
        info['variant'] = f'{direction}_last'
        info['target'] = pass_desc['target']
        info['entry'] = pass_desc['entry']
        return make_loadm_payload(STAGER_LOAD_ADDR, block, STAGER_LOAD_ADDR), info

    if k == 'stage_back':
        tramp, direction = make_single_chunk_trampoline(
            target_addr=pass_desc['target'],
            tail='int')
        block = wrap_block(tramp, chunks[ci])
        info['variant'] = f'{direction}_int'
        info['target'] = pass_desc['target']
        return make_loadm_payload(STAGER_LOAD_ADDR, block, STAGER_LOAD_ADDR), info

    if k == 'stash':
        # Stash always targets URA RAM, hence reverse copy.
        tramp, direction = make_single_chunk_trampoline(
            target_addr=pass_desc['target'],
            tail='int')
        assert direction == 'rev', "stash should always go to URA RAM"
        block = wrap_block(tramp, chunks[ci])
        info['variant'] = 'rev_int (stash)'
        info['target'] = pass_desc['target']
        return make_loadm_payload(STAGER_LOAD_ADDR, block, STAGER_LOAD_ADDR), info

    if k == 'relocate2':
        tramp = make_relocate2_trampoline(
            target1=pass_desc['target'],
            stash_addr=pass_desc['stash_addr'],
            target0=pass_desc['target0'],
            start_addr=pass_desc['entry'])
        block = wrap_block(tramp, chunks[ci])
        info['variant'] = 'relocate2'
        info['target'] = pass_desc['target']
        info['target0'] = pass_desc['target0']
        info['stash_addr'] = pass_desc['stash_addr']
        info['entry'] = pass_desc['entry']
        return make_loadm_payload(STAGER_LOAD_ADDR, block, STAGER_LOAD_ADDR), info

    raise RuntimeError(f"unknown pass kind: {k}")


# ===== Procedure text =====

def build_txt(start_addr, n_chunks, tape_files, t77_name, real_size):
    lines = []
    lines.append(f"=== {t77_name} ロード手順 (FM-7 F-BASIC) ===")
    lines.append("")
    lines.append(f"  エントリアドレス     : ${start_addr:04X}")
    lines.append(f"  実データ             : {real_size} bytes "
                 f"({real_size / 1024:.1f} KiB)")
    lines.append(f"  16 KiB チャンク数    : {n_chunks}")
    pad_total = n_chunks * CHUNK_SIZE - real_size
    if pad_total > 0:
        lines.append(f"  末尾ゼロパディング   : {pad_total} bytes")
    lines.append("")
    lines.append("  最終メモリ配置:")
    for i in range(n_chunks):
        a = start_addr + i * CHUNK_SIZE
        lines.append(f"    チャンク#{i}  -> ${a:04X}-${a + CHUNK_SIZE - 1:04X}")
    lines.append("")
    lines.append("  (PC 側で D77 -> T77/WAV/TXT を変換する手順は README.TXT を参照)")
    lines.append("")
    lines.append("──────────────────────────────────────────────────")
    lines.append(" 操作手順 (F-BASIC OK プロンプトで以下を順に入力)")
    lines.append("──────────────────────────────────────────────────")
    lines.append("")
    lines.append(f"  CLEAR ,&H{CLEAR_VALUE:04X}")
    lines.append("")
    for i, info in enumerate(tape_files):
        idx = f"[{i + 1}/{len(tape_files)}]"
        if info['is_last']:
            lines.append(f"  {idx} {info['name']}  チャンク#{info['chunk_idx']} "
                         f"({info['variant']}, 最終)")
            lines.append(f"        LOADM \"CAS:\",,R")
            if info['kind'] == 'relocate2':
                lines.append(
                    f"        ; auto-exec で relocator が動作:")
                lines.append(
                    f"        ;   M1 reverse  ${BUFFER_ADDR:04X}-${BUFFER_END-1:04X} "
                    f"-> ${info['target']:04X}-${info['target']+CHUNK_SIZE-1:04X}")
                lines.append(
                    f"        ;   M2 forward  ${info['stash_addr']:04X}-"
                    f"${info['stash_addr']+CHUNK_SIZE-1:04X} "
                    f"-> ${info['target0']:04X}-${info['target0']+CHUNK_SIZE-1:04X}")
                lines.append(
                    f"        ;   LDS #$FBFF / JMP ${info['entry']:04X}")
            else:
                lines.append(
                    f"        ; auto-exec で stager が動作:")
                lines.append(
                    f"        ;   バッファ -> ${info['target']:04X} "
                    f"({info['variant'].split('_')[0]} copy)")
                lines.append(f"        ;   LDS #$FBFF / JMP ${info['entry']:04X}")
            lines.append("")
        else:
            lines.append(f"  {idx} {info['name']}  チャンク#{info['chunk_idx']} "
                         f"({info['variant']})")
            lines.append(f"        LOADM \"CAS:\"")
            lines.append(f"        EXEC &H{STAGER_LOAD_ADDR:04X}")
            if info['kind'] == 'stash':
                lines.append(
                    f"        ; stager がチャンクを URA RAM (${info['target']:04X}-"
                    f"${info['target']+CHUNK_SIZE-1:04X}) へ退避")
            else:
                lines.append(
                    f"        ; stager がチャンクを最終位置 ${info['target']:04X}-"
                    f"${info['target']+CHUNK_SIZE-1:04X} へ配置")
            lines.append("")
    lines.append("──────────────────────────────────────────────────")
    lines.append(" 補足")
    lines.append("──────────────────────────────────────────────────")
    lines.append("")
    lines.append(f"  - CLEAR ,&H{CLEAR_VALUE:04X} で MEMSIZ を $13FF に下げ、")
    lines.append("    $1400-$7FFF をユーザ作業域として確保する")
    lines.append("")
    lines.append("  - 各 LOADM ブロックは単一連続 ($1400-$5FFF) で構成:")
    lines.append("      $1400-$1419  Stage 1                      (26 B)")
    lines.append("      $141A-$143x  Stage 2 source (22/23/39 B)")
    lines.append("      $143x-$1FFF  ゼロパディング")
    lines.append("      $2000-$5FFF  16 KiB バッファ")
    lines.append("")
    lines.append("  - Stage 1 は IRQ マスク + ROM OFF + Stage 2 を $D000 (URA RAM)")
    lines.append("    へコピーして JMP $D000。Stage 2 は最終コピー(/ relocate) を")
    lines.append("    実行し、中間パスなら ROM ON + RTS、最終パスなら LDS + JMP entry")
    lines.append("")
    lines.append("  - EXEC は必ず明示的にアドレスを指定すること")
    lines.append("    (引数なし EXEC は実機で挙動が不安定)")
    lines.append("")
    return "\n".join(lines) + "\n"


# ===== Main =====

def parse_addr(s):
    s = s.strip()
    try:
        if s.lower().startswith('0x') or s.lower().startswith('&h'):
            v = int(s[2:], 16)
        elif s.startswith('$'):
            v = int(s[1:], 16)
        else:
            v = int(s, 0)
    except ValueError:
        print(f'error: アドレス/数値の書式が不正です: {s!r} '
              f'(例: 0x0200 / $0200 / &H0200 / 512)', file=sys.stderr)
        sys.exit(1)
    if not 0 <= v <= 0xFFFF:
        print(f'error: アドレス/数値が $0000-$FFFF の範囲外です: {s!r}',
              file=sys.stderr)
        sys.exit(1)
    return v


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('src', help='input D77 file')
    ap.add_argument('--addr', required=True, type=parse_addr,
                    help='entry / load-start address (e.g. 0x0200)')
    ap.add_argument('--skip', type=parse_addr, default=256,
                    help='bytes to skip from extracted payload (default 256, '
                         'i.e. one sector — typical FM-7 IPL boot sector at '
                         'C0 H0 R1 is skipped automatically; pass --skip 0 '
                         'to disable)')
    ap.add_argument('--size', type=parse_addr, default=None,
                    help='bytes to use from payload (default: all)')
    ap.add_argument('-o', '--out', default=None, help='output T77 path')
    ap.add_argument('-t', '--txt', default=None, help='output TXT procedure path')
    ap.add_argument('-w', '--wav', default=None,
                    help='output WAV path (default: <src>.wav). '
                         'Use --no-wav to skip WAV generation.')
    ap.add_argument('--no-wav', action='store_true',
                    help='do not emit a WAV file alongside the T77')
    ap.add_argument('--silence', type=float, default=5.0,
                    help='WAV silence (sec) at head, between LOADMs, and tail '
                         '(default: 5.0)')
    ap.add_argument('--no-wav-silence-cue', action='store_true',
                    help='omit the 0x0000 inter-file cue marker in the T77')
    args = ap.parse_args()

    if not os.path.isfile(args.src):
        print(f'error: input not found: {args.src}', file=sys.stderr)
        return 1

    base, _ = os.path.splitext(args.src)
    out_t77 = args.out or (base + '.t77')
    out_txt = args.txt or (base + '.txt')
    out_wav = args.wav or (base + '.wav')

    with open(args.src, 'rb') as f:
        d77 = f.read()

    # --size given => honor it exactly, skip the auto-trim heuristic.
    # --size absent => trim trailing fill tracks ($00 / $E5 / $FF formatter
    # fill) so we don't see the empty back half of the floppy.
    trim = (args.size is None)
    payload = extract_d77_payload(d77, trim_trailing_fill=trim, verbose=True)
    print(f'[+] D77 payload          : {len(payload)} bytes '
          + ('(auto-trim: trailing fill tracks dropped)' if trim
             else '(raw extract, no auto-trim because --size was given)'))

    body = payload[args.skip:]
    if args.size is not None:
        body = body[:args.size]
    real_size = len(body)
    print(f'[+] working binary       : {real_size} bytes '
          f'(skip={args.skip}, size={args.size if args.size is not None else "auto"})')

    if real_size == 0:
        print('error: working binary is empty', file=sys.stderr)
        return 1

    chunks = split_into_chunks(body)
    n = len(chunks)
    print(f'[+] split into           : {n} x 16 KiB chunk(s)')

    if args.addr < LOADM_LO_LIMIT:
        print(f'note: entry address ${args.addr:04X} is below LOADM lower limit '
              f'${LOADM_LO_LIMIT:04X}, but it is reached by the trampoline copy '
              f'so this is fine.', file=sys.stderr)
    if args.addr + n * CHUNK_SIZE - 1 > 0xFFFF:
        print(f'warn: last chunk extends past $FFFF; trailing bytes lost.',
              file=sys.stderr)

    try:
        plan = plan_passes(args.addr, n)
    except (NotImplementedError, RuntimeError) as e:
        print('error: CMTロード不可 — 本体がテープ多段ロードの収容上限を超えています。',
              file=sys.stderr)
        print(f'       エントリ ${args.addr:04X} / {n} チャンク '
              f'({n * CHUNK_SIZE // 1024} KiB) では裏RAM退避枠が不足します。',
              file=sys.stderr)
        print(f'       詳細: {e}', file=sys.stderr)
        print('       対策: 本体を 32 KiB 以下に収めるか、エントリを $2000 以上にする。',
              file=sys.stderr)
        return 1
    print(f'[+] plan_passes -> {len(plan)} pass(es):')
    tape_files = []
    for i, p in enumerate(plan):
        loadm, info = build_pass(p, chunks)
        info['name'] = f'C{i + 1:02d}'
        info['loadm'] = loadm
        tape_files.append(info)
        tail = ' LAST' if info['is_last'] else ''
        if info['kind'] == 'relocate2':
            print(f'    tape[{i + 1}/{len(plan)}]  {info["name"]}  '
                  f'[relocate2] chunk#{info["chunk_idx"]} '
                  f'-> ${info["target"]:04X} (M1) + '
                  f'${info["target0"]:04X} (M2) JMP ${info["entry"]:04X}{tail}')
        else:
            print(f'    tape[{i + 1}/{len(plan)}]  {info["name"]}  '
                  f'[{info["variant"]:14s}] chunk#{info["chunk_idx"]} '
                  f'-> ${info["target"]:04X}{tail}')

    t77 = build_t77([(info['name'], info['loadm']) for info in tape_files],
                    mark_inter_file_silence=not args.no_wav_silence_cue)
    with open(out_t77, 'wb') as f:
        f.write(t77)
    print(f'\n[+] T77 written          -> {out_t77} ({len(t77)} bytes)')

    txt = build_txt(args.addr, n, tape_files,
                    os.path.basename(out_t77), real_size)
    with open(out_txt, 'w', encoding='utf-8') as f:
        f.write(txt)
    print(f'[+] procedure written    -> {out_txt}')

    if not args.no_wav:
        wav = build_wav([(info['name'], info['loadm']) for info in tape_files],
                        head_silence=args.silence,
                        gap_silence=args.silence,
                        tail_silence=args.silence)
        with open(out_wav, 'wb') as f:
            f.write(wav)
        dur = (len(wav) - 44) / WAV_SAMPLE_RATE / 2   # 16-bit mono
        print(f'[+] WAV written          -> {out_wav}  '
              f'({len(wav)} bytes, ~{dur:.1f} s, {WAV_SAMPLE_RATE} Hz 16-bit mono, '
              f'{args.silence:.1f}s silence head/gaps/tail)')

    print('\n--- procedure summary ---')
    print(f'  CLEAR ,&H{CLEAR_VALUE:04X}')
    for i, info in enumerate(tape_files):
        if info['is_last']:
            print(f'  LOADM "CAS:",,R     ; tape[{i+1}] {info["variant"]}')
        else:
            print(f'  LOADM "CAS:"        ; tape[{i+1}] {info["variant"]}')
            print(f'  EXEC &H{STAGER_LOAD_ADDR:04X}')

    return 0


if __name__ == '__main__':
    sys.exit(main())
