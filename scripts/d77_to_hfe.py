#!/usr/bin/env python3
"""
D77 ディスクイメージ → HFE (HxC Floppy Emulator) 変換ツール

D77 のセクタ列を IBM System 34 互換の MFM トラック (倍密度) として
エンコードし、HFEv1 形式で出力する。FM-7 / FM77AV の 2D ディスク
(40 trk × 2 side × 16 sec × 256 byte、250 kbit/s MFM) を対象とする。

HFE のフォーマットは公式仕様が公開されている:
  HxC Floppy Emulator - HFE file format specification
  https://hxc2001.com/floppy_drive_emulator/HFE-file-format.html
本実装はこの公開仕様のみを参照したクリーンルーム実装。

正しさは末尾の self-test (--selftest) で担保する:
  エンコードした MFM ビットストリームを再デコードし、全セクタの
  内容と CRC が入力 D77 と一致することを確認する。
"""

import argparse
import struct
import sys
from pathlib import Path

# ---- ディスクジオメトリ (FM-7 2D) ----
SECTOR_SIZE = 256
N_CODE      = 1            # セクタ長コード N=1 → 256 byte

# ---- HFE トラック寸法 ----
# 250 kbit/s, 300 rpm → cell rate 500k → 12500 byte/side のビットストリーム。
# 256 byte 単位でインターリーブするため side 長を 256 の倍数へ丸める。
DECODED_TRACK_LEN = 6272               # MFM デコード後のトラック byte 数 (= bitstream/2)
BITSTREAM_PER_SIDE = DECODED_TRACK_LEN * 2   # 12544 = 49 * 256

# ---- 標準ギャップ/同期 (IBM System 34, DD, 256B sector) ----
GAP4A, SYNC, GAP1, GAP2, GAP3 = 80, 12, 50, 22, 54
IAM_C2, IAM_FC = 0xC2, 0xFC
IDAM, DAM      = 0xFE, 0xFB
A1, C2         = 0xA1, 0xC2

# missing-clock sync の 16-cell パターン (time order, MSB first)
PAT_A1 = 0x4489   # A1*
PAT_C2 = 0x5224   # C2*


# ----------------------------------------------------------------------
# CRC-CCITT (poly 0x1021, init 0xFFFF) — アドレスマークを含めて計算
# ----------------------------------------------------------------------
def crc16(data: bytes, crc: int = 0xFFFF) -> int:
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if (crc & 0x8000) else (crc << 1) & 0xFFFF
    return crc


# ----------------------------------------------------------------------
# MFM エンコーダ: デコード済みトラック byte 列 → cell ビット列
#   通常 byte は clock=NOT(prev_data OR data) で MFM 展開。
#   A1/C2 マークは missing-clock の固定 16-cell パターンを出す。
# ----------------------------------------------------------------------
class MFMEncoder:
    def __init__(self):
        self.cells = []         # time order の cell (0/1) 列
        self.prev = 0           # 直前の data bit

    def _emit16(self, pattern: int, last_data_bit: int):
        for i in range(15, -1, -1):
            self.cells.append((pattern >> i) & 1)
        self.prev = last_data_bit

    def byte(self, b: int, mark: bool = False):
        if mark and b == A1:
            self._emit16(PAT_A1, 1)         # A1 LSB = 1
            return
        if mark and b == C2:
            self._emit16(PAT_C2, 0)         # C2 LSB = 0
            return
        for i in range(7, -1, -1):
            d = (b >> i) & 1
            c = 1 if (self.prev == 0 and d == 0) else 0
            self.cells.append(c)
            self.cells.append(d)
            self.prev = d

    def bytes(self, data: bytes):
        for b in data:
            self.byte(b)

    def packed(self, length_bytes: int) -> bytes:
        """cell 列を LSB-first で byte 化し、length_bytes へ 0x4E gap で延長。"""
        # 末尾を gap (0x4E) で埋めてトラック長を揃える
        while len(self.cells) < length_bytes * 8:
            self.byte(0x4E)
        cells = self.cells[: length_bytes * 8]
        out = bytearray(length_bytes)
        for idx, cell in enumerate(cells):
            if cell:
                out[idx >> 3] |= 1 << (idx & 7)   # LSB first
        return bytes(out)


def build_track_bitstream(sectors: dict, cyl: int, head: int) -> bytes:
    """(cyl, head) の 16 セクタ → MFM ビットストリーム (BITSTREAM_PER_SIDE byte)。"""
    enc = MFMEncoder()
    enc.bytes(bytes([0x4E] * GAP4A))
    enc.bytes(bytes([0x00] * SYNC))
    for _ in range(3):
        enc.byte(C2, mark=True)
    enc.byte(IAM_FC)
    enc.bytes(bytes([0x4E] * GAP1))

    for r in range(1, 17):
        data = sectors[r]
        enc.bytes(bytes([0x00] * SYNC))
        for _ in range(3):
            enc.byte(A1, mark=True)
        idfield = bytes([cyl, head, r, N_CODE])
        enc.byte(IDAM)
        enc.bytes(idfield)
        idcrc = crc16(bytes([A1, A1, A1, IDAM]) + idfield)
        enc.bytes(struct.pack(">H", idcrc))
        enc.bytes(bytes([0x4E] * GAP2))

        enc.bytes(bytes([0x00] * SYNC))
        for _ in range(3):
            enc.byte(A1, mark=True)
        enc.byte(DAM)
        enc.bytes(data)
        datacrc = crc16(bytes([A1, A1, A1, DAM]) + data)
        enc.bytes(struct.pack(">H", datacrc))
        enc.bytes(bytes([0x4E] * GAP3))

    return enc.packed(BITSTREAM_PER_SIDE)


# ----------------------------------------------------------------------
# D77 パーサ: ヘッダのトラックテーブルからセクタを読む
# ----------------------------------------------------------------------
def parse_d77(blob: bytes) -> dict:
    """{(cyl, head): {sector: data}} と (tracks, sides) を返す。"""
    if len(blob) < 0x2B0:
        raise SystemExit("D77 が短すぎます")
    track_tbl = []
    for t in range(164):
        off = struct.unpack_from("<I", blob, 0x20 + t * 4)[0]
        if off:
            track_tbl.append((t, off))
    disk = {}
    max_cyl = max_head = 0
    for t, off in track_tbl:
        p = off
        # 1 セクタ目の header から当該トラックのセクタ数を得る
        nsec = struct.unpack_from("<H", blob, p + 4)[0]
        for _ in range(nsec):
            c = blob[p]; h = blob[p + 1]; r = blob[p + 2]
            dsize = struct.unpack_from("<H", blob, p + 14)[0]
            data = blob[p + 16 : p + 16 + dsize]
            disk.setdefault((c, h), {})[r] = data
            max_cyl = max(max_cyl, c); max_head = max(max_head, h)
            p += 16 + dsize
    return disk, max_cyl + 1, max_head + 1


# ----------------------------------------------------------------------
# HFE 書き出し
# ----------------------------------------------------------------------
def write_hfe(disk: dict, tracks: int, sides: int, out_path: str):
    header = bytearray(b"\xFF" * 512)
    header[0:8] = b"HXCPICFE"
    header[8]  = 0x00                 # formatrevision = HFEv1
    header[9]  = tracks
    header[10] = sides
    header[11] = 0x00                 # track_encoding = ISOIBM_MFM
    struct.pack_into("<H", header, 12, 250)    # bitRate kbit/s
    struct.pack_into("<H", header, 14, 300)    # floppyRPM
    header[16] = 0x07                 # floppyinterfacemode = GENERIC_SHUGART_DD
    header[17] = 0x01                 # dnu
    struct.pack_into("<H", header, 18, 1)      # track_list_offset = block 1
    header[20] = 0xFF                 # write_allowed

    track_len = BITSTREAM_PER_SIDE * 2          # 両面インターリーブの byte 数
    blocks_per_track = (track_len + 511) // 512

    # トラックLUT (block 1)
    lut = bytearray(b"\x00" * 512)
    block = 2                                    # トラックデータは block 2 から
    for cyl in range(tracks):
        struct.pack_into("<HH", lut, cyl * 4, block, track_len)
        block += blocks_per_track

    out = bytearray(header) + bytearray(lut)

    for cyl in range(tracks):
        side_bits = []
        for head in range(sides):
            sectors = disk.get((cyl, head))
            if sectors is None or len(sectors) < 16:
                raise SystemExit(f"D77 に (cyl={cyl}, head={head}) の 16 セクタが揃っていません")
            side_bits.append(build_track_bitstream(sectors, cyl, head))
        # 256 byte 単位で side0/side1 をインターリーブ
        interleaved = bytearray()
        for i in range(0, BITSTREAM_PER_SIDE, 256):
            interleaved += side_bits[0][i : i + 256]
            interleaved += side_bits[1][i : i + 256] if sides > 1 else b"\xFF" * 256
        # 512 ブロック境界へパディング
        pad = blocks_per_track * 512 - len(interleaved)
        interleaved += b"\xFF" * pad
        out += interleaved

    Path(out_path).write_bytes(out)
    return len(out), track_len, blocks_per_track


# ----------------------------------------------------------------------
# Self-test: ビットストリームを再デコードして CRC とセクタ一致を検証
# ----------------------------------------------------------------------
def _cells_from_bits(bitstream: bytes):
    cells = []
    for b in bitstream:
        for i in range(8):
            cells.append((b >> i) & 1)      # LSB first
    return cells


def _find_sync(cells, start):
    """A1* (0x4489) を 3 連で探す。見つかれば直後の cell index を返す。"""
    target = [(PAT_A1 >> i) & 1 for i in range(15, -1, -1)]
    i = start
    n = len(cells)
    while i + 48 <= n:
        if cells[i : i + 16] == target and \
           cells[i + 16 : i + 32] == target and \
           cells[i + 32 : i + 48] == target:
            return i + 48
        i += 1
    return -1


def _read_bytes(cells, pos, count):
    """pos の cell から MFM data bit を count byte 分読む (clock を捨てて data を拾う)。"""
    out = bytearray()
    for _ in range(count):
        b = 0
        for _bit in range(8):
            d = cells[pos + 1]              # cell = [clock, data]
            b = (b << 1) | d
            pos += 2
        out.append(b)
    return bytes(out), pos


def selftest(disk, tracks, sides) -> int:
    checked = 0
    for cyl in range(tracks):
        for head in range(sides):
            sectors = disk[(cyl, head)]
            bits = build_track_bitstream(sectors, cyl, head)
            cells = _cells_from_bits(bits)
            found = {}
            pos = 0
            while True:
                sync = _find_sync(cells, pos)
                if sync < 0:
                    break
                mark, p2 = _read_bytes(cells, sync, 1)
                if mark[0] == IDAM:
                    idf, p3 = _read_bytes(cells, sync, 1 + 4 + 2)
                    if crc16(bytes([A1, A1, A1]) + idf) != 0:
                        raise SystemExit(f"ID CRC NG @cyl{cyl}/head{head}")
                    pending_r = idf[3]      # R
                    pos = p3
                elif mark[0] == DAM:
                    df, p3 = _read_bytes(cells, sync, 1 + SECTOR_SIZE + 2)
                    if crc16(bytes([A1, A1, A1]) + df) != 0:
                        raise SystemExit(f"DATA CRC NG @cyl{cyl}/head{head}")
                    found[pending_r] = df[1 : 1 + SECTOR_SIZE]
                    pos = p3
                else:
                    pos = sync + 16
            for r in range(1, 17):
                if found.get(r) != sectors[r]:
                    raise SystemExit(f"セクタ不一致 @cyl{cyl}/head{head}/sec{r}")
                checked += 1
    return checked


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("d77")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--selftest", action="store_true",
                    help="エンコード結果を再デコードして全セクタ一致を検証")
    args = ap.parse_args()

    blob = Path(args.d77).read_bytes()
    disk, tracks, sides = parse_d77(blob)

    if args.selftest:
        n = selftest(disk, tracks, sides)
        print(f"self-test OK: {n} セクタを round-trip 検証 (CRC 一致)")

    size, tlen, blk = write_hfe(disk, tracks, sides, args.output)
    print(f"wrote {args.output}: {tracks}trk x {sides}side, "
          f"track_len={tlen}B ({blk}blk/trk), file={size}B")


if __name__ == "__main__":
    main()
