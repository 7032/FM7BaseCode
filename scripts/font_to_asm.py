#!/usr/bin/env python3
"""
assets/font.png (128x48, 1-bit, 16x6 グリッド) を読んで、 本体に
リンクする 8x8 bitmap 配列を ASM (lwasm 形式) で出力する。

出力フォーマット:
    section rodata
    export font_data
font_data:
    fcb $..,$..,..., $..   * '0x20' (space)  — 8 byte / 行
    fcb $..,$..,..., $..   * '0x21' '!'
    ...
    fcb $..,$..,..., $..   * '0x7F' DEL

合計 96 char × 8 byte = 768 byte。 c_main.c から
`extern const unsigned char font_data[]` で参照する。

使い方 (= Makefile 経由で自動実行):
    python3 assets/font_to_asm.py assets/font.png assets/src/font_data.s

font 自体の解説 (採用背景 / ライセンス / PNG → ASM 全体フロー) は
docs/FONT.md を参照。
"""

import sys
from pathlib import Path
from PIL import Image

COLS = 16
ROWS = 6
CW, CH = 8, 8
N_CHARS = COLS * ROWS    # = 96 (= 0x20..0x7F)


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: font_to_asm.py <in.png> <out.s>')

    img = Image.open(sys.argv[1]).convert('1')
    if img.size != (COLS * CW, ROWS * CH):
        raise SystemExit(
            f'expected {COLS*CW}x{ROWS*CH} PNG, got {img.size}'
        )
    px = img.load()

    lines = [
        '* ==========================================================',
        '* font_data.s — 8x8 bitmap font (ASCII 0x20..0x7F, 96 chars)',
        '*                assets/font_to_asm.py が assets/font.png から',
        '*                自動生成 (= make が呼び出す)。 手で書き換えない。',
        '*                配置先 assets/src/ は git track 外。',
        '*',
        '* Glyph 出典: Press Start 2P (Google Fonts) を 8x8 pixel に',
        '* ラスタライズしたビットマップ。 SIL Open Font License 1.1',
        '* (OFL-1.1) で配布。 詳細 (採用背景 / PNG→ASM 変換手順 /',
        '* ライセンス全文取得方法) は docs/FONT.md 参照。',
        '* ==========================================================',
        '',
        '                section rodata',
        '                export  _font_data',
        '',
        '* C 側からは extern const unsigned char font_data[] で参照。',
        '* CMOC が C シンボルに `_` を付ける規約に合わせて _font_data で export。',
        '_font_data:',
    ]

    for idx in range(N_CHARS):
        col = idx % COLS
        row = idx // COLS
        ox, oy = col * CW, row * CH
        bytes8 = []
        for y in range(CH):
            b = 0
            for x in range(CW):
                if px[ox + x, oy + y]:
                    b |= (0x80 >> x)
            bytes8.append(b)
        hex8 = ','.join(f'${b:02X}' for b in bytes8)
        c = chr(0x20 + idx)
        cdisp = c if 0x20 < (0x20 + idx) < 0x7F else f'\\x{0x20+idx:02X}'
        lines.append(f'                fcb     {hex8}      * {0x20+idx:#04x} {cdisp!r}')

    lines.append('')
    lines.append('                end')
    lines.append('')

    out = Path(sys.argv[2])
    out.write_text('\n'.join(lines))
    print(f'wrote {out}: {N_CHARS} chars * {CH} bytes = {N_CHARS*CH} bytes')


if __name__ == '__main__':
    main()
