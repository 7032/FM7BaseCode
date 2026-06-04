#!/usr/bin/env python3
"""
assets/backimage.png (64x64 モノクロ) を読んで、 背景タイル 1 枚分の
B plane ビットマップ (= 64 line × 8 byte = 512 byte) を ASM (lwasm
rodata) で出力する。

背景は B plane 単体で描く (= 色番号 1 = パレットで青)。 タイルの各 pixel
が「明るい (= 白)」 なら B=1 (= 青)、 「暗い (= 黒)」 なら B=0 (= 黒) と
する。 これを全画面にタイル状に敷くと、 青/黒の模様背景になる。

  64x64 px = 64 line × 8 byte/line = 512 byte (= B plane だけ)。
  bit は MSB が左 px。

C 側参照:
  extern const unsigned char bgtile_data[];   // 512 byte
main 起動時に sub_load_bgtile() で sub の SUB_BGTILE_ADDR へ転送し、
DRAW_BG がそれを全画面に敷く。

使い方 (= Makefile 経由で自動実行):
  python3 scripts/bgtile_to_asm.py assets/backimage.png assets/src/bgtile_data.s
"""

import sys
from pathlib import Path
from PIL import Image

TILE_PX    = 64
TILE_BYTES = (TILE_PX // 8) * TILE_PX      # 8 × 64 = 512


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: bgtile_to_asm.py <in.png> <out.s>')

    img = Image.open(sys.argv[1])
    if img.size != (TILE_PX, TILE_PX):
        raise SystemExit(f'expected {TILE_PX}x{TILE_PX} PNG, got {img.size}')
    if img.mode not in ('RGBA', 'RGB', 'L', 'LA', '1'):
        img = img.convert('RGBA')

    data = bytearray(TILE_BYTES)
    for line in range(TILE_PX):
        for byte_col in range(TILE_PX // 8):
            for bit in range(8):
                px = img.getpixel((byte_col * 8 + bit, line))
                if isinstance(px, int):          # L or 1
                    lum, a = (255 if px else 0) if img.mode == '1' else px, 255
                elif len(px) == 2:               # LA
                    lum, a = px[0], px[1]
                elif len(px) == 4:               # RGBA
                    r, g, b, a = px
                    lum = (r * 30 + g * 59 + b * 11) // 100
                else:                            # RGB
                    r, g, b = px[:3]
                    lum, a = (r * 30 + g * 59 + b * 11) // 100, 255
                # 明るい (= 白) かつ不透明なら B=1 (= 青)
                if a >= 128 and lum >= 128:
                    data[line * (TILE_PX // 8) + byte_col] |= (1 << (7 - bit))

    lines = [
        '* ==========================================================',
        '* bgtile_data.s — 64x64 monochrome background tile (B plane)',
        '*                scripts/bgtile_to_asm.py が assets/backimage.png',
        '*                から自動生成 (= make が呼び出す)。 手で書き換えない。',
        '*                配置先 assets/src/ は git track 外。',
        '*',
        '* 512 byte = 64 line × 8 byte/line (= B plane のみ)。 bit=1 → B=1',
        '* (= 色番号 1 = 青)、 bit=0 → B=0 (= 黒)。 全画面にタイル状に敷く',
        '* (横 64px = 8 byte 周期、 縦 64 line 周期)。',
        '*',
        '* C 側参照: extern const unsigned char bgtile_data[];  // 512 byte',
        '* ==========================================================',
        '',
        '                section rodata',
        '                export  _bgtile_data',
        '',
        '_bgtile_data:',
    ]
    for row_start in range(0, TILE_BYTES, 16):
        chunk = data[row_start:row_start + 16]
        hex8 = ','.join(f'${b:02X}' for b in chunk)
        lines.append(f'                fcb     {hex8}')
    lines.append('')
    lines.append('                end')
    lines.append('')

    out = Path(sys.argv[2])
    out.parent.mkdir(exist_ok=True, parents=True)
    out.write_text('\n'.join(lines))
    print(f'wrote {out}: 64x64 bg tile = {TILE_BYTES} byte (B plane)')


if __name__ == '__main__':
    main()
