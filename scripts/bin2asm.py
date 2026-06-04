#!/usr/bin/env python3
"""
任意のバイナリファイルを lwasm 形式の rodata 配列に変換する。
sub_takeover で sub に送るプログラム本体を、 main 側 ROM に rodata
として埋め込むために使う。

出力フォーマット:
    section rodata
    export _<sym>_bin
    export _<sym>_len
_<sym>_bin:
    fcb $XX,$XX,...    * 16 byte / 行
    ...
_<sym>_len: fdb <total_bytes>

使い方:
    python3 tools/bin2asm.py <in.bin> <out.s> <symbol_name>

C 側からは:
    extern const unsigned char  symbol_bin[];
    extern const unsigned int   symbol_len;
"""

import sys
from pathlib import Path


BYTES_PER_LINE = 16


def main():
    if len(sys.argv) != 4:
        raise SystemExit('usage: bin2asm.py <in.bin> <out.s> <symbol>')

    src  = Path(sys.argv[1])
    dst  = Path(sys.argv[2])
    sym  = sys.argv[3]
    data = src.read_bytes()

    lines = [
        '* ==========================================================',
        f'* {dst.name} — {src.name} ({len(data)} byte) を rodata 配列に化けた',
        '*                tools/bin2asm.py が自動生成。 手で書き換えない。',
        '* ==========================================================',
        '',
        '                section rodata',
        f'                export  _{sym}_bin',
        f'                export  _{sym}_len',
        '',
        f'_{sym}_bin:',
    ]

    for i in range(0, len(data), BYTES_PER_LINE):
        chunk = data[i:i + BYTES_PER_LINE]
        hexs  = ','.join(f'${b:02X}' for b in chunk)
        lines.append(f'                fcb     {hexs}')

    lines.append('')
    lines.append(f'_{sym}_len:     fdb     {len(data)}')
    lines.append('')
    lines.append('                end')
    lines.append('')

    dst.parent.mkdir(exist_ok=True, parents=True)
    dst.write_text('\n'.join(lines))
    print(f'wrote {dst}: {len(data)} bytes as _{sym}_bin + _{sym}_len')


if __name__ == '__main__':
    main()
