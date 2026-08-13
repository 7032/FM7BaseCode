# FM77AV YM2203 CSM 音声デモ + 全画面画像
#   make        : ソースから ym2203csm.d77 を生成する
#   make image  : assets/fm77av_img.s を assets/FM77AV.PNG から作り直す
#                 (パレット割当の山登り最適化に 1 分ほどかかるため、
#                  既定のビルドでは再生成しない)
#   make clean  : 生成物を削除する
#
# ビルドには lwtools の lwasm と Node.js が必要です。
# 音声パラメータ (assets/csmdata.s) は scripts/wav2csm.py が
# assets/FM77AV.wav から生成します。wav2csm.py が無い環境では
# 同梱済みの assets/csmdata.s をそのまま使います。
# 画像データ (assets/fm77av_img.s) は同梱済みで、make image のときだけ
# scripts/png2fm77av.py で作り直します。
# 同梱の ym2203csm.d77 はそのまま実機/エミュレータで起動できます。

LWASM  ?= lwasm
NODE   ?= node
PYTHON ?= python3

all: ym2203csm.d77

# wav2csm.py がある時だけ WAV から音声パラメータを作り直す
ifneq ($(wildcard scripts/wav2csm.py),)
assets/csmdata.s: assets/FM77AV.wav scripts/wav2csm.py
	$(PYTHON) scripts/wav2csm.py --wav assets/FM77AV.wav --out $@
endif

# 画像データは明示的に make image したときだけ作り直す (生成に時間がかかる)
image:
	$(PYTHON) scripts/png2fm77av.py --input assets/FM77AV.PNG \
	    --out assets/fm77av_img.s --preview out/fm77av_img_preview.png

csmdemo_main.bin: src/csmdemo.asm assets/csmdata.s
	$(LWASM) --6809 --format=raw -I assets -o $@ src/csmdemo.asm

csmdemo_sub.bin: src/csmdemo_sub.asm
	$(LWASM) --6809 --format=raw -o $@ src/csmdemo_sub.asm

csmdemo_img.bin: src/csmdemo_img.asm assets/fm77av_img.s
	$(LWASM) --6809 --format=raw -I assets -o $@ src/csmdemo_img.asm

ym2203csm.d77: csmdemo_main.bin csmdemo_sub.bin csmdemo_img.bin scripts/mkd77.mjs
	$(NODE) scripts/mkd77.mjs csmdemo_main.bin csmdemo_sub.bin csmdemo_img.bin $@

clean:
	rm -f csmdemo_main.bin csmdemo_sub.bin csmdemo_img.bin

.PHONY: all clean image
