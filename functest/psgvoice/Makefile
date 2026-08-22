# FM-7 PSG 音量 DAC 音声再生デモ
#   make        : ソースから psgvoice.d77 を生成する
#   make t77    : psgvoice.d77 から CMT (カセットテープ) 用の
#                 psgvoice.t77 / psgvoice.wav / psgvoice.cmt.txt を生成する
#   make clean  : 生成物を削除する
#
# ビルドには lwtools の lwasm と Node.js が必要です。
# make t77 には Python 3 も必要です (標準ライブラリのみ)。
# 音声データ (assets/psgdata.s / assets/psgdef.s) は scripts/wav2psg.py が
# assets/fm7psg.wav から生成します。wav2psg.py が無い環境では
# 同梱済みの assets/psgdata.s / psgdef.s をそのまま使います。
# 同梱の psgvoice.d77 はそのまま実機/エミュレータで起動できます。

LWASM  ?= lwasm
NODE   ?= node
PYTHON ?= python3

all: psgvoice.d77

# wav2psg.py がある時だけ WAV から音声データを作り直す
ifneq ($(wildcard scripts/wav2psg.py),)
assets/psgdata.s assets/psgdef.s: assets/fm7psg.wav scripts/wav2psg.py
	$(PYTHON) scripts/wav2psg.py --wav assets/fm7psg.wav \
	    --out assets/psgdata.s --defs assets/psgdef.s
endif

psgvoice_main.bin: src/psgvoice.asm assets/psgdef.s
	$(LWASM) --6809 --format=raw -I assets -o $@ src/psgvoice.asm

psgvoice_sub.bin: src/psgvoice_sub.asm
	$(LWASM) --6809 --format=raw -o $@ src/psgvoice_sub.asm

psgdata.bin: src/psgdata.asm assets/psgdata.s
	$(LWASM) --6809 --format=raw -I assets -o $@ src/psgdata.asm

psgvoice.d77: psgvoice_main.bin psgvoice_sub.bin psgdata.bin scripts/mkd77.mjs
	$(NODE) scripts/mkd77.mjs psgvoice_main.bin psgvoice_sub.bin psgdata.bin $@

# ---- CMT (カセットテープ) 用: make t77 ----
# psgvoice.d77 のセクタ連結は「IPL 256 バイト + $0200 起点の平坦なメモリ像」
# なので、リポジトリ共通の変換ツール (scripts/d77_to_t77_chunks.py) に
# そのまま食わせられる。--addr はテープ用エントリ TAPENT (= $0200)。
# 生成物: psgvoice.t77 (テープイメージ) / psgvoice.wav (FSK 音声) /
#         psgvoice.cmt.txt (F-BASIC でのロード手順)
T77TOOL = ../../scripts/d77_to_t77_chunks.py
TAPE_ENTRY = 0x0200

t77: psgvoice.t77

psgvoice.t77: psgvoice.d77 $(wildcard $(T77TOOL))
	@test -f $(T77TOOL) || { \
	    echo "error: 変換ツール $(T77TOOL) が見つかりません。"; \
	    echo "       このフォルダはリポジトリ一式 (scripts/ を含む) の中で使ってください。"; \
	    exit 1; }
	$(PYTHON) $(T77TOOL) psgvoice.d77 --addr $(TAPE_ENTRY) \
	    -o psgvoice.t77 -w psgvoice.wav -t psgvoice.cmt.txt
	@# FM-7 の F-BASIC 3.0 はカセットのデバイス記述子が CAS0: (CAS: は
	@# Bad File Descriptor になる)。手順テキストを実機の表記に合わせる。
	sed -i 's/"CAS:"/"CAS0:"/g' psgvoice.cmt.txt

# WAV と手順テキストは T77 と同じ 1 回の変換でまとめて生成される
psgvoice.wav psgvoice.cmt.txt: psgvoice.t77
	@:

clean:
	rm -f psgvoice_main.bin psgvoice_sub.bin psgdata.bin
	rm -f psgvoice.t77 psgvoice.wav psgvoice.cmt.txt

.PHONY: all t77 clean
