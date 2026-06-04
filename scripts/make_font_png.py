#!/usr/bin/env python3
"""
Press Start 2P (Google Fonts, OFL-1.1) の TTF を 8x8 にレンダリング
して assets/font.png を生成する。 必要な時だけ手動で実行する。
(Makefile からは呼ばない — 配布されている assets/font.png が真)

レイアウト:
    16 char × 6 行 のグリッド (= 128 × 48 px の 1-bit PNG)
    左上から ASCII 0x20 (space) → 0x7F の順で並ぶ。

TTF 入手先 (どちらかから取得して TTF_PATH の場所に置く):
  - Google Fonts:
      https://fonts.google.com/specimen/Press+Start+2P
  - Google Fonts GitHub raw:
      https://github.com/google/fonts/raw/main/ofl/pressstart2p/PressStart2P-Regular.ttf
  - 同 OFL ライセンス:
      https://github.com/google/fonts/raw/main/ofl/pressstart2p/OFL.txt

font 周りの解説 (採用背景 / ライセンス全文の扱い / PNG → ASM 変換
の流れ) は docs/FONT.md にまとめてある。

別の OFL 8x8 pixel font に差し替えたい場合は assets/font.png を
同形式 (128×48 1-bit、 16x6 グリッド、 0x20→0x7F 順) で上書きすれば
OK (= assets/font_to_asm.py が PNG → ASM 変換するので形式が合えば
自由)。
"""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
TTF  = ROOT / 'tmp' / 'Press_Start_2P' / 'PressStart2P-Regular.ttf'
OUT  = ROOT / 'assets' / 'font.png'

COLS = 16
ROWS = 6
CW, CH = 8, 8
N = COLS * ROWS                      # = 96 (= 0x20..0x7F)


def main():
    if not TTF.exists():
        raise SystemExit(
            f'TTF not found: {TTF}\n'
            'Makefile 経由 (= "make" を実行) なら自動で DL されます。\n'
            '手動で配置する場合は:\n'
            '  https://github.com/google/fonts/raw/main/ofl/pressstart2p/'
            'PressStart2P-Regular.ttf\n'
            'を取得して上記パスに置いてください。'
        )

    # Press Start 2P は 1em = 8px グリッドの pixel font。 8px サイズで
    # 描けばちょうど 8x8 になる。ImageFont は size = "char height in px"
    # 解釈なので、ベースライン込みで 8px 高さに収めるよう調整。
    font = ImageFont.truetype(str(TTF), 8)

    img = Image.new('1', (COLS * CW, ROWS * CH), 0)
    draw = ImageDraw.Draw(img)

    for idx in range(N):
        c = chr(0x20 + idx)
        col = idx % COLS
        row = idx // COLS
        ox, oy = col * CW, row * CH
        # Press Start 2P は描画原点が左上に近いので、 y オフセットは 0
        # でだいたい合う。 (font.getbbox を確認して微調整可)
        draw.text((ox, oy), c, fill=1, font=font)

    OUT.parent.mkdir(exist_ok=True)
    img.save(OUT)
    print(f'wrote {OUT}: {img.size[0]}x{img.size[1]} 1-bit PNG '
          f'({COLS}x{ROWS} chars, 0x20..0x7F, Press Start 2P @ 8px)')


if __name__ == '__main__':
    main()
