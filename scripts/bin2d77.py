#!/usr/bin/env python3
"""
FM-7 用 D77 ディスクイメージ生成ツール

ディスク先頭の配置 (= asm_ipl.s の read 順と一致):
    body_idx 0   → (track 0, side 0, sec 2)   ← IPL の次から
    body_idx 14  → (track 0, side 0, sec 16)
    body_idx 15  → (track 0, side 1, sec 1)   ← side wrap
    body_idx 30  → (track 0, side 1, sec 16)
    body_idx 31  → (track 1, side 0, sec 1)   ← track wrap (SEEK)
    ...
    一般式: flat  = body_idx + 1
            track = flat / 32
            side  = (flat / 16) % 2
            sec   = (flat % 16) + 1

IPL バイナリ先頭 +2 オフセットの body_sectors を本体のセクタ数で
書き換え、 本体を上記の順序で disk に置く。 本体の上限は IPL relocate
先 ($FB00) の手前 $FA00 までで、 (RELOC_FLOOR - ORG)/256 sector
(= ORG=$0400 なら 246 sector ≈ 61 KB)。 body_sectors は 1 byte なので
ハード上限は 255。 ORG は --org で渡す (Makefile が config.mk から供給)。
"""

import argparse
import struct
from pathlib import Path

SECTOR_SIZE   = 256
SECTORS_TRACK = 16
TRACKS        = 40
SIDES         = 2
HEADER_SIZE   = 0x2B0

IPL_META_OFFSET = 0x02       # ipl バイナリの body_sectors の位置 (+2)
RELOC_FLOOR     = 0xFA00     # IPL relocate 先 $FB00 の手前マージン (本体はここまで)
HARD_MAX_SECTORS = 255       # body_sectors フィールドが 1 byte


def body_location(body_idx: int) -> tuple:
    """body sector index → (track, side, sector). asm_ipl.s の read 順と一致。"""
    flat = body_idx + 1          # IPL が flat=0 を占めるので +1
    track = flat // (SECTORS_TRACK * SIDES)
    side  = (flat // SECTORS_TRACK) % SIDES
    sec   = (flat % SECTORS_TRACK) + 1
    return (track, side, sec)


def build_disk_header(name: str, total_size: int) -> bytes:
    name_bytes = name.encode("ascii", errors="replace")[:16].ljust(17, b"\x00")
    h = bytearray(HEADER_SIZE)
    h[0:17] = name_bytes
    h[0x1A] = 0x00                  # 書き込み許可
    h[0x1B] = 0x00                  # 2D
    struct.pack_into("<I", h, 0x1C, total_size)
    offset = HEADER_SIZE
    for t in range(TRACKS * SIDES):
        struct.pack_into("<I", h, 0x20 + t * 4, offset)
        offset += SECTORS_TRACK * (16 + SECTOR_SIZE)
    return bytes(h)


def build_sector(track: int, side: int, sector: int, data: bytes) -> bytes:
    sid = bytearray(16)
    sid[0] = track
    sid[1] = side
    sid[2] = sector
    sid[3] = 0x01                   # N = 1 (256B)
    sid[4] = SECTORS_TRACK
    sid[5] = 0x00                   # 倍密度
    sid[6] = 0x00
    sid[7] = 0x00
    payload = data.ljust(SECTOR_SIZE, b"\x00")
    # dataSize はディスク上の実体長 (= 256B 固定) を書く。
    # ここを len(data) にすると D77 パーサが次セクタ header を
    # 中途半端な位置から読み始めるので、空セクタの先がすべて壊れる。
    struct.pack_into("<H", sid, 14, len(payload))
    return bytes(sid) + payload


def split_sectors(blob: bytes) -> list:
    return [blob[i:i + SECTOR_SIZE] for i in range(0, len(blob), SECTOR_SIZE)]


def patch_ipl_meta(ipl: bytes, body_sectors: int) -> bytes:
    """IPL 先頭 +2 オフセットの body_sectors を書き換える。"""
    ipl = bytearray(ipl)
    ipl[IPL_META_OFFSET] = body_sectors & 0xFF
    return bytes(ipl)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipl",  required=True)
    ap.add_argument("--body", required=True)
    ap.add_argument("--name", default="DISK")
    ap.add_argument("--org", default="0x0400",
                    help="本体ロードアドレス (= config.mk ORG)。 上限計算に使用")
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()

    org = int(args.org, 0)
    max_body_sectors = min((RELOC_FLOOR - org) // SECTOR_SIZE, HARD_MAX_SECTORS)

    ipl  = Path(args.ipl).read_bytes()
    body = Path(args.body).read_bytes()

    if len(ipl) > SECTOR_SIZE:
        raise SystemExit(f"IPL が 256B を超えています: {len(ipl)} bytes")

    body_sectors = (len(body) + SECTOR_SIZE - 1) // SECTOR_SIZE
    if body_sectors > max_body_sectors:
        raise SystemExit(
            f"本体が大きすぎます (ORG={args.org} では最大 {max_body_sectors} sector "
            f"= {max_body_sectors * SECTOR_SIZE // 1024} KB まで対応): "
            f"body_sectors={body_sectors}, body_bytes={len(body)}"
        )

    ipl_patched = patch_ipl_meta(ipl, body_sectors)
    body_sec    = split_sectors(body)

    # body_idx → (track, side, sector) で逆引き辞書を作る
    body_map = {}
    for idx in range(body_sectors):
        body_map[body_location(idx)] = body_sec[idx]

    total_size = HEADER_SIZE + TRACKS * SIDES * SECTORS_TRACK * (16 + SECTOR_SIZE)
    out = bytearray(build_disk_header(args.name, total_size))

    for t in range(TRACKS):
        for h in range(SIDES):
            for s in range(1, SECTORS_TRACK + 1):
                if t == 0 and h == 0 and s == 1:
                    data = ipl_patched
                else:
                    data = body_map.get((t, h, s), b"")
                out += build_sector(t, h, s, data)

    Path(args.output).write_bytes(out)
    last_t, last_h, last_s = body_location(body_sectors - 1) if body_sectors else (0, 0, 1)
    print(f"wrote {args.output}: ipl=1sec, body={body_sectors}sec "
          f"(last @ T{last_t}/S{last_h}/sec{last_s}), body_bytes={len(body)}")


if __name__ == "__main__":
    main()
