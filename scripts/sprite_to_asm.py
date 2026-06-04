#!/usr/bin/env python3
"""
assets/character.png (128x128 RGBA、 16 sprite grid) を読んで、 本体に
リンクする 32x32 sprite データを ASM (lwasm 形式) で出力する。

入力レイアウト (= ユーザー作成):
  128×128 px の 4x4 sprite grid、 各 sprite 32×32 px
  行順: DOWN, UP, RIGHT, LEFT  (= 0,1,2,3)
  列順: anim frame 1, 2, 3, 4  (= 0,1,2,3)
  → 合計 16 sprite (= 4 方向 × 4 frame)

出力フォーマット (= 「2 plane (R/G) 前景」 方式):
  この雛形は前景を R/G plane の 2 plane だけで描く (= B plane は背景の
  単色青に使う)。 パレットを 色2/3=赤・4/5=シアン・6/7=白 と二重化してある
  ので、 B の有無に関わらず R/G の組み合わせだけで前景色が決まる:
    R=0,G=0 → 透明 (= 背景の青が見える)
    R=1,G=0 → 赤
    R=0,G=1 → シアン
    R=1,G=1 → 白
  各 plane は 32 px × 32 line / 8 px/byte = 4 byte/line × 32 line = 128
  byte。 1 sprite = R(128) + G(128) = 256 byte。 16 sprite = 4096 byte。

  6 色に見せる仕掛け: 上の素の色は 赤/シアン/白 の 3 色だが、 横に隣り合う
  ドットへ違う色を撒く (= 誤差拡散ディザ) ことで、 赤シアン・赤白・シアン白
  のような中間色 (計 6 色相当) に見える。 量子化は Floyd-Steinberg ディザで
  赤/シアン/白 の 3 色へ落とす。

  全 16 sprite を dir-major で出力する:
    sprite_data[(dir * 4 + frame) * 256 ..]
    dir = 0:DOWN 1:UP 2:RIGHT 3:LEFT / frame = 0..3
  C 側は「現在方向の 4 frame」 (= 1024 byte) だけ sub に動的ロードする。

  C 側参照:
    extern const unsigned char sprite_data[];
    extern const unsigned int  sprite_data_len;   // = 4096
    方向 dir の frame 群 head = sprite_data + dir * 4 * 256

使い方 (= Makefile 経由で自動実行):
  python3 scripts/sprite_to_asm.py assets/character.png assets/src/sprite_data.s
"""

import sys
from pathlib import Path
from PIL import Image


SPRITE_PX     = 32
PLANE_BYTES   = (SPRITE_PX // 8) * SPRITE_PX        # 4 × 32 = 128
SPRITE_BYTES  = PLANE_BYTES * 2                     # R + G = 256
GRID_W        = 4
GRID_H        = 4
DIR_NAMES     = ['DOWN', 'UP', 'RIGHT', 'LEFT']

# 量子化先の 3 前景色。 R/G plane 割り当てと「表示色」:
#   R plane のみ = 赤 / G plane のみ = シアン(表示) / R+G = 白
# PNG 各 pixel は下の代表 RGB (赤/青/白) に最も近い色へ寄せる。
# 代表色の「青」(元画像ドット) は G plane に割り当たり、 パレット二重化
# ($05) によって画面では「シアン」として表示される。
PALETTE = [
    ('red',   (255,   0,   0), (1, 0)),   # (name, rgb, (rbit, gbit))
    ('blue',  (  0,   0, 255), (0, 1)),
    ('white', (255, 255, 255), (1, 1)),
]


def nearest(rgb):
    """rgb に最も近い前景色 index を返す (透明判定は呼び元)。"""
    best_i, best_d = 0, 1 << 30
    for i, (_n, c, _bits) in enumerate(PALETTE):
        d = (rgb[0]-c[0])**2 + (rgb[1]-c[1])**2 + (rgb[2]-c[2])**2
        if d < best_d:
            best_d, best_i = d, i
    return best_i


def sprite_to_planes(img, sox, soy):
    """32x32 sprite を [R, G] (各 128 byte) に変換 (Floyd-Steinberg ディザ)。

    plane[line*4 + byte_col] = 8 px の bitmap (MSB が左 px)。
    - alpha < 128 の pixel: 透明 = R=0,G=0 (= 背景の青が見える)
    - 不透明 pixel: 3 前景色 (代表 RGB 赤/青/白) へ誤差拡散ディザして R/G に
      立てる (G plane = 表示シアン)
    """
    plane_r = bytearray(PLANE_BYTES)
    plane_g = bytearray(PLANE_BYTES)

    # 作業用に 32x32 の float RGB と alpha を取り出す
    buf = [[None]*SPRITE_PX for _ in range(SPRITE_PX)]   # (r,g,b) or None(透明)
    for ly in range(SPRITE_PX):
        for lx in range(SPRITE_PX):
            px = img.getpixel((sox+lx, soy+ly))
            if len(px) == 4:
                r, g, b, a = px
                if a < 128:
                    buf[ly][lx] = None
                    continue
            else:
                r, g, b = px[:3]
            buf[ly][lx] = [float(r), float(g), float(b)]

    # Floyd-Steinberg 誤差拡散 (透明 pixel は誤差を運ばない/受けない)
    for ly in range(SPRITE_PX):
        for lx in range(SPRITE_PX):
            cur = buf[ly][lx]
            if cur is None:
                continue
            qi = nearest(cur)
            qc = PALETTE[qi][1]
            err = [cur[k] - qc[k] for k in range(3)]
            rbit, gbit = PALETTE[qi][2]
            bit_pos = 7 - (lx & 7)
            off = ly * 4 + (lx >> 3)
            if rbit:
                plane_r[off] |= (1 << bit_pos)
            if gbit:
                plane_g[off] |= (1 << bit_pos)
            # 誤差を近傍へ (右 7/16, 左下 3/16, 下 5/16, 右下 1/16)
            for dx, dy, w in ((1, 0, 7), (-1, 1, 3), (0, 1, 5), (1, 1, 1)):
                nx, ny = lx+dx, ly+dy
                if 0 <= nx < SPRITE_PX and 0 <= ny < SPRITE_PX:
                    nb = buf[ny][nx]
                    if nb is not None:
                        for k in range(3):
                            nb[k] += err[k] * w / 16.0

    return plane_r, plane_g


def emit_plane_bytes(lines, plane, label_comment):
    lines.append(f'* {label_comment}')
    for row_start in range(0, len(plane), 16):
        chunk = plane[row_start:row_start + 16]
        hex8 = ','.join(f'${b:02X}' for b in chunk)
        lines.append(f'                fcb     {hex8}')


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: sprite_to_asm.py <in.png> <out.s>')

    img = Image.open(sys.argv[1])
    if img.size != (GRID_W * SPRITE_PX, GRID_H * SPRITE_PX):
        raise SystemExit(
            f'expected {GRID_W * SPRITE_PX}x{GRID_H * SPRITE_PX} PNG, '
            f'got {img.size}'
        )
    if img.mode == 'P':
        img = img.convert('RGBA')
    if img.mode not in ('RGBA', 'RGB'):
        raise SystemExit(f'unsupported mode: {img.mode}')

    lines = [
        '* ==========================================================',
        '* sprite_data.s — 32x32 character sprites for FM-7 (2 plane R/G)',
        '*                scripts/sprite_to_asm.py が assets/character.png',
        '*                から自動生成 (= make が呼び出す)。 手で書き換えない。',
        '*                配置先 assets/src/ は git track 外。',
        '*',
        '* Layout: 16 sprite (= 4 方向 × 4 frame)、 dir-major',
        '*   sprite_data[(dir * 4 + frame) * 256 ..]',
        '*   dir = 0:DOWN 1:UP 2:RIGHT 3:LEFT / frame = 0..3',
        '*',
        '* Format: 各 sprite を「R plane (128 byte) + G plane (128 byte)」',
        '* = 256 byte。 前景色: R=0,G=0 透明 / R=1 赤 / G=1 シアン / R+G 白。',
        '* 隣接ドットへのディザで赤シアン/赤白/シアン白の混色 (= 6 色相当) に見せる。',
        '* 16 sprite × 256 = 4096 byte。',
        '*',
        '* C 側は「現在方向の 4 frame」 (= 1024 byte) だけ sub に動的ロード。',
        '*',
        '* C 側参照:',
        '*   extern const unsigned char sprite_data[];',
        '*   extern const unsigned int  sprite_data_len;  // = 4096',
        '*   方向 dir の frame 群 head = sprite_data + dir * 4 * 256',
        '* ==========================================================',
        '',
        '                section rodata',
        '                export  _sprite_data',
        '                export  _sprite_data_len',
        '',
        '_sprite_data:',
    ]

    total = 0
    for dir_idx in range(GRID_H):
        for frame_idx in range(GRID_W):
            sox = frame_idx * SPRITE_PX
            soy = dir_idx * SPRITE_PX
            pr, pg = sprite_to_planes(img, sox, soy)
            lines.append('')
            lines.append(f'* sprite {dir_idx*4 + frame_idx} '
                         f'({DIR_NAMES[dir_idx]}, frame {frame_idx + 1})')
            emit_plane_bytes(lines, pr, 'R plane (= 128 byte、 赤成分)')
            emit_plane_bytes(lines, pg, 'G plane (= 128 byte、 G 成分。 表示シアン)')
            total += SPRITE_BYTES

    lines.append('')
    lines.append(f'_sprite_data_len: fdb {total}')
    lines.append('')
    lines.append('                end')
    lines.append('')

    out = Path(sys.argv[2])
    out.parent.mkdir(exist_ok=True, parents=True)
    out.write_text('\n'.join(lines))
    print(f'wrote {out}: 16 sprite * 256 byte = {total} byte')


if __name__ == '__main__':
    main()
