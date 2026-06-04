#!/usr/bin/env python3
"""
asm_bootrom.s から出した raw コードを 512 byte に整形する。

レイアウト:
    [0  : N]    実コード (lwasm --raw 出力をそのまま)
    [N  : 510]  0x00 padding
    [510: 512]  reset vector ($FFFE-$FFFF) = $FE 00 → JMP $FE00

(lwasm --raw は `org $FFFE` で自動 pad しないので、ここで詰める。)
"""

import sys
from pathlib import Path

BOOT_ROM_SIZE = 512
ENTRY_ADDR    = 0xFE00      # = code 開始アドレス。reset vector に書く値

def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: pad_bootrom.py <in.bin> <out.bin>")

    src = Path(sys.argv[1]).read_bytes()
    if len(src) > BOOT_ROM_SIZE - 2:
        raise SystemExit(
            f"boot ROM コードが大きすぎます: {len(src)} bytes "
            f"(最大 {BOOT_ROM_SIZE - 2} bytes)"
        )

    out = bytearray(BOOT_ROM_SIZE)        # 0x00 埋め
    out[:len(src)] = src
    out[-2] = (ENTRY_ADDR >> 8) & 0xFF    # $FFFE: hi
    out[-1] =  ENTRY_ADDR       & 0xFF    # $FFFF: lo

    Path(sys.argv[2]).write_bytes(out)
    print(f"wrote {sys.argv[2]}: code={len(src)} bytes, "
          f"padded to {BOOT_ROM_SIZE}, reset vec=${ENTRY_ADDR:04X}")


if __name__ == "__main__":
    main()
