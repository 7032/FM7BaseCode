# =============================================================
# FM-7/FM77AV プログラム用テンプレートMakefile (CMOC + LWASM/LWLINK)
#
# プロジェクト名と本体開始アドレスは config.mk に集約。
# このファイルは触らなくて済むのが理想。
# =============================================================

include config.mk

# 使用するツール類
CMOC      = cmoc
LWASM     = lwasm
LWLINK    = lwlink

# フォルダ
#   SRC        : 人が書く / git track するソース
#   ASSETS_SRC : asset から生成された ASM (= gitignore、 make 再生成)
SCRIPTS      = ./scripts
SRC          = ./src
ASSETS_SRC   = ./assets/src
BUILD        = ./build

BIN          = $(BUILD)/$(NAME).bin
IPL          = $(BUILD)/ipl.bin
D77          = $(BUILD)/$(NAME).d77
HFE          = $(BUILD)/$(NAME).hfe     # HFE (HxC Floppy Emulator) 形式 (D77 から MFM 変換)
T77          = $(BUILD)/$(NAME).t77      # FM-7 カセットテープ(CMT)イメージ (D77 と同一内容)
WAV          = $(BUILD)/$(NAME).wav      # CMT ロード用 FSK 音声 (44.1kHz/16bit/mono)
CMTPROC      = $(BUILD)/$(NAME).cmt.txt   # CMT ロード操作手順テキスト
T77TOOL      = $(SCRIPTS)/d77_to_t77_chunks.py
T77_TRAMPS   = $(SCRIPTS)/trampoline_fwd_int.bin $(SCRIPTS)/trampoline_rev_int.bin \
               $(SCRIPTS)/trampoline_fwd_last.bin $(SCRIPTS)/trampoline_rev_last.bin \
               $(SCRIPTS)/trampoline_relocate2.bin
BOOTROM      = $(BUILD)/bootrom.bin    # 自前ブート ROM (DOS モードのブート ROM 代替、別ターゲット)
LINK_SCRIPT  = $(BUILD)/link.script    # config.mk の ORG から自動生成

C_SRCS       = $(SRC)/c_main.c $(SRC)/c_subsys.c $(SRC)/c_subprog.c $(SRC)/c_sound.c
ASM_SRCS     = $(SRC)/asm_crt0.s $(SRC)/asm_subsys.s $(SRC)/asm_runtime.s \
               $(SRC)/asm_test.s $(SRC)/asm_kbd.s $(SRC)/asm_timer.s

# font パイプライン (= TTF DL → PNG → ASM)。 派生物は git track 外で
# build artifact 扱い (= リーガル的に「フォント派生物の頒布元」 にならない
# ようにする設計)。 詳細は docs/FONT.md。
FONT_DIR        = ./tmp/Press_Start_2P
FONT_TTF        = $(FONT_DIR)/PressStart2P-Regular.ttf
FONT_OFL        = $(FONT_DIR)/OFL.txt
FONT_PNG        = ./assets/font.png
FONT_DATA       = $(ASSETS_SRC)/font_data.s
FONT_TO_PNG     = $(SCRIPTS)/make_font_png.py
FONT_TO_ASM     = $(SCRIPTS)/font_to_asm.py
FONT_URL_TTF    = https://github.com/google/fonts/raw/main/ofl/pressstart2p/PressStart2P-Regular.ttf
FONT_URL_OFL    = https://github.com/google/fonts/raw/main/ofl/pressstart2p/OFL.txt

# sprite パイプライン (= character.png → ASM)。 元 PNG はユーザー作成 asset
# として git track。 生成された ASM は assets/src/ (= gitignore) へ出す。
SPRITE_PNG      = ./assets/character.png
SPRITE_DATA     = $(ASSETS_SRC)/sprite_data.s
SPRITE_TO_ASM   = $(SCRIPTS)/sprite_to_asm.py

# 背景タイル パイプライン (= 64x64 モノクロ backimage.png → B plane 512 byte)
BGTILE_PNG      = ./assets/backimage.png
BGTILE_DATA     = $(ASSETS_SRC)/bgtile_data.s
BGTILE_TO_ASM   = $(SCRIPTS)/bgtile_to_asm.py

# 生成 ASM (= asset 由来) も同じく build/*.o に流すが、 ソース置場が src/
# ではなく assets/src/ なので別パターンルールを用意する。 ASM_SRCS と
# GEN_ASM_SRCS を分けることで「人が書く / 生成する」 のラインを明確に。
# sub プログラム (= $C300 にロードして sub で実行する独自描画コード)
# は raw bin として lwasm でアセンブル → tools/bin2asm.py で C 配列に
# 化けて main 側に rodata として埋め込む。 詳細は docs/SUBPROGRAM.md。
SUBPROG_SRC     = $(SRC)/asm_subprog.s
SUBPROG_BIN     = $(BUILD)/subprog.bin
SUBPROG_DATA    = $(ASSETS_SRC)/subprog_data.s

GEN_ASM_SRCS = $(FONT_DATA) $(SPRITE_DATA) $(BGTILE_DATA) $(SUBPROG_DATA)

C_OBJS       = $(C_SRCS:$(SRC)/%.c=$(BUILD)/%.o)
ASM_OBJS     = $(ASM_SRCS:$(SRC)/%.s=$(BUILD)/%.o)
GEN_ASM_OBJS = $(GEN_ASM_SRCS:$(ASSETS_SRC)/%.s=$(BUILD)/%.o)
OBJS         = $(ASM_OBJS) $(GEN_ASM_OBJS) $(C_OBJS)

.PHONY: all bin bootrom t77 clean

# デフォルトターゲット: 3 つの成果物 (IPL + 本体 BIN + 自前ブート ROM) と
# それらを束ねた D77、 さらに D77 から変換した HFE を全部生成する
all: $(D77) $(HFE) $(BOOTROM)

bin: $(BIN)

# 自前ブート ROM だけビルド (= DOS モードのブート ROM 代替)
bootrom: $(BOOTROM)

build:
	mkdir -p build

# C → オブジェクト
#   --intdir で .s / .lst を build/ に追いやり、ルートに散らかさない
#   ヘッダ全部を依存に列挙 (= header 変更時の再 compile 漏れ防止。
#   小規模プロジェクトなので $(wildcard) で雑に拾えば十分)。
C_HEADERS = $(wildcard $(SRC)/*.h)

$(BUILD)/%.o: $(SRC)/%.c $(C_HEADERS) | build
	$(CMOC) -c --intermediate --intdir=$(BUILD) -O2 -o $@ $<

# ASM (オブジェクト形式) → オブジェクト
$(BUILD)/%.o: $(SRC)/%.s | build
	$(LWASM) --obj -o $@ $<

# 生成 ASM (assets/src/*.s) → オブジェクト
$(BUILD)/%.o: $(ASSETS_SRC)/%.s | build
	$(LWASM) --obj -o $@ $<

# lwlink 用スクリプト生成 (config.mk の ORG を反映)
#   全セクション ($(ORG) 起点 で連続) を明示し、CMOC が生成する
#   rodata / start / initgl_* が他アドレスで解決される事故
#   (= JMP _main が誤アドレスを指す等) を防ぐ。
$(LINK_SCRIPT): config.mk Makefile | build
	@printf 'section code   load %s\nsection rodata\nsection initgl_start\nsection initgl\nsection initgl_end\nsection start\nsection program_end\nsection rwdata\nsection bss\n' '$(ORG)' > $@

# リンクして本体 BIN
$(BIN): $(OBJS) $(LINK_SCRIPT)
	$(LWLINK) --raw --script=$(LINK_SCRIPT) --output=$@ $(OBJS)

# IPL は単独で raw アセンブル
#   BODY_LOAD (= 本体配置先 = config.mk の ORG) を -D で渡す
$(IPL): $(SRC)/asm_ipl.s config.mk | build
	$(LWASM) --raw -D BODY_LOAD=$(ORG) -o $@ $<

# ---- font パイプライン (TTF DL → PNG → ASM、 全部 make で完結) ----
# Press Start 2P (Google Fonts, OFL-1.1) を upstream から DL し、 8x8
# bitmap PNG → 6809 ASM rodata に変換する。 TTF/OFL の一度 DL すれば
# 再 DL は不要 (依存関係で skip)。 派生物 (PNG/ASM) は assets/ や src/
# にいるが gitignore で track 外。 詳細は docs/FONT.md 参照。

$(FONT_TTF):
	@mkdir -p $(FONT_DIR)
	@echo "  DL  $@"
	@curl -fsSL -o $@ $(FONT_URL_TTF)

$(FONT_OFL):
	@mkdir -p $(FONT_DIR)
	@echo "  DL  $@"
	@curl -fsSL -o $@ $(FONT_URL_OFL)

# TTF → 128x48 1-bit PNG (= 16 char × 6 行の 8x8 bitmap grid)
$(FONT_PNG): $(FONT_TTF) $(FONT_OFL) $(FONT_TO_PNG)
	@mkdir -p $(dir $@)
	python3 $(FONT_TO_PNG)

# PNG → 6809 ASM (rodata の _font_data: 96 char × 8 byte)
$(FONT_DATA): $(FONT_PNG) $(FONT_TO_ASM)
	@mkdir -p $(dir $@)
	python3 $(FONT_TO_ASM) $(FONT_PNG) $@

# ---- sprite パイプライン (PNG → ASM) ----
# 32x32 RGBA character.png を 4x4 cell × 8 色 + 透明にダウンサンプリング
# した rodata 配列 (= 16 sprite × 16 byte = 256 byte) を生成する。
# 詳細は assets/sprite_to_asm.py 冒頭コメント参照。
$(BGTILE_DATA): $(BGTILE_PNG) $(BGTILE_TO_ASM)
	@mkdir -p $(dir $@)
	python3 $(BGTILE_TO_ASM) $(BGTILE_PNG) $@

$(SPRITE_DATA): $(SPRITE_PNG) $(SPRITE_TO_ASM)
	@mkdir -p $(dir $@)
	python3 $(SPRITE_TO_ASM) $(SPRITE_PNG) $@

# ---- sub プログラム (= $C300 で動くサブ CPU 独自コード) ----
# org $C300 で raw bin にアセンブル → bin2asm.py で _subprog_bin[] と
# _subprog_len を持つ rodata に変換 → main 本体にリンク埋め込み。
# main 起動時に sub_takeover でこのバイナリを sub の $C300 へ送り、
# sub_call($C300) で実行。 詳細は docs/SUBPROGRAM.md。
$(SUBPROG_BIN): $(SUBPROG_SRC) | build
	$(LWASM) --raw -o $@ $<

$(SUBPROG_DATA): $(SUBPROG_BIN) $(SCRIPTS)/bin2asm.py
	@mkdir -p $(dir $@)
	python3 $(SCRIPTS)/bin2asm.py $(SUBPROG_BIN) $@ subprog

# 自前ブート ROM ($FE00-$FFFF, 512 byte)
#   lwasm --raw は org 跳びで自動 pad しないので、後段の
#   tools/pad_bootrom.py で 512 byte 整形 + reset vector を埋める。
$(BOOTROM): $(SRC)/asm_bootrom.s | build
	$(LWASM) --raw -o $@.raw $<
	python3 $(SCRIPTS)/pad_bootrom.py $@.raw $@

# D77 は IPL と本体 BIN を結合
$(D77): $(IPL) $(BIN)
	python3 $(SCRIPTS)/bin2d77.py \
	    --ipl $(IPL) \
	    --body $(BIN) \
	    --name $(NAME) \
	    --org $(ORG) \
	    -o $@

# HFE は D77 を IBM System 34 互換 MFM へ変換 (HxC Floppy Emulator 形式)。
# HFE のフォーマットは公式仕様が公開されている (詳細は docs/DETAIL.md)。
$(HFE): $(D77) $(SCRIPTS)/d77_to_hfe.py
	python3 $(SCRIPTS)/d77_to_hfe.py $(D77) -o $@

# ---- T77 / WAV (CMT カセットテープ) ----
# `make t77` で D77 と同じイメージを CMT ロード向けに変換し、T77 テープ
# イメージ・WAV(FSK 音声)・操作手順テキストを同時生成する。D77 を
# 16KiB チャンクへ分解し、各 LOADM ブロックにトランポリンを付けて裏 RAM
# 経由で最終配置する方式 (詳細は docs/CMT.md)。
#
# 本体エントリ ($(ORG)) が $2000 未満の場合、テープ多段ロードの裏 RAM
# 退避枠が 16KiB 1 枠しか取れず実質上限 32KiB。これを超えると変換ツールが
# 「CMTロード不可」エラーで終了し make が停止する。
t77: $(T77) $(WAV)

# T77/WAV/手順テキストは 1 回の変換でまとめて生成される。WAV は T77 生成の
# 副産物なので $(T77) に依存させ、recipe の二重実行を防ぐ。
$(T77): $(D77) $(T77TOOL) $(T77_TRAMPS)
	python3 $(T77TOOL) $(D77) --addr $(ORG) -o $(T77) -w $(WAV) -t $(CMTPROC)

$(WAV): $(T77)
	@:

# 通常クリーン:
#   build/         : ビルド成果物
#   assets/font.png: TTF→PNG 生成物
#   assets/src/    : PNG→ASM 生成物のディレクトリごと
# build/ の rm は WSL+Windows FS で permission denied が起きること
# があるので `-` で続行可能にしておく (= 本質エラーではない)。
# TTF / OFL は upstream DL なので clean では残す (= 再 DL 不要)。
clean:
	-rm -rf build
	rm -rf $(FONT_PNG) $(ASSETS_SRC)

# 強制的に全部捨てたい時は `make distclean` (= TTF/OFL も削除 → 次回 DL 発生)
distclean: clean
	rm -rf $(FONT_DIR)

.PHONY: distclean
