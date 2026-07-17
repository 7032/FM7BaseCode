# FM-7 / FM77AV マウスカーソルデモ
#   make        : ソースから mousedemo.d77 を生成する
#   make test   : ヘッドレステストを実行する
#                 (エミュレータ core は WEBM7_DIR、ROM は FM7_ROM_DIR で指定。
#                  見つからない場合はスキップして正常終了する)
#   make clean  : 生成物を削除する
#
# ビルドには lwtools の lwasm と Node.js が必要です。
# 同梱の mousedemo.d77 はそのまま実機/エミュレータで起動できます。

LWASM ?= lwasm
NODE  ?= node

all: mousedemo.d77

mousedemo_main.bin: mousedemo.asm
	$(LWASM) --6809 --format=raw -o $@ $<

mousedemo_sub.bin: mousedemo_sub.asm
	$(LWASM) --6809 --format=raw -o $@ $<

mousedemo.d77: mousedemo_main.bin mousedemo_sub.bin mkd77.mjs
	$(NODE) mkd77.mjs mousedemo_main.bin mousedemo_sub.bin $@

test: mousedemo.d77
	$(NODE) test_mousemode.mjs
	$(NODE) test_mousedemo.mjs

clean:
	rm -f mousedemo_main.bin mousedemo_sub.bin

.PHONY: all test clean
