# FONT.md — 同梱 8x8 bitmap font の解説

本テンプレートは [assets/src/font_data.s](../assets/src/font_data.s) として **8x8 pixel の bitmap font データ** をリンクしています (ASCII 0x20-0x7F の 96 char × 8 byte = 768 byte の `rodata` 配列)。 字形は **Press Start 2P** (8x8 グリッド設計の pixel font、 SIL Open Font License 1.1) を 8px でラスタライズしたものです。 デモ ([c_main.c](../src/c_main.c)) では `sub_draw_text` 経由で SCORE 等の表示に使います。

このドキュメントでは:

- ライセンス (OFL-1.1) の扱い
- フォントデータが作られるまでの流れ (TTF → PNG → ASM)
- `font_data.s` のフォーマット詳細

を順に解説します。

---

## 1. ライセンス (SIL Open Font License 1.1)

Press Start 2P は **SIL Open Font License 1.1 (OFL-1.1)** で配布されています。 派生物 (= bitmap 化した PNG や ASM rodata) を扱ううえで関係する条件:

- ✅ **無償で利用可** (商用含む)
- ✅ **派生物の頒布も可** (= bitmap 化した PNG や ASM rodata も含む)
- ⚠️ **派生物を頒布するなら、 OFL ライセンス全文と上流コピーライト表示を同梱する必要がある** (OFL §5 条件 2)
- ⚠️ **オリジナルの Reserved Font Name (= "Press Start 2P") を派生物の名前として使ってはいけない** (OFL §3)

本テンプレートは font 派生物 (`assets/font.png` / `assets/src/font_data.s`) と upstream TTF / OFL.txt を **git track せず**、 ビルド時に upstream から取得 + 生成します (= リポジトリは派生物を再頒布しない)。 `.gitignore` 対象:

```
assets/font.png        ← TTF から生成、 track しない
assets/src/            ← asset 由来の生成 ASM (= font_data.s 等)、 ディレクトリごと track しない
tmp/                   ← TTF / OFL.txt の DL 先、 track しない
```

人が書くソース (`src/`) と asset 由来の生成 ASM (`assets/src/`) はディレクトリで分けてあり、 生成物が `src/` に紛れ込まないようにしています。

### TTF / OFL.txt の入手先

| 用途 | URL |
| --- | --- |
| フォントページ (Google Fonts) | <https://fonts.google.com/specimen/Press+Start+2P> |
| TTF 直接ダウンロード | <https://github.com/google/fonts/raw/main/ofl/pressstart2p/PressStart2P-Regular.ttf> |
| OFL ライセンス全文 | <https://github.com/google/fonts/raw/main/ofl/pressstart2p/OFL.txt> |

Makefile が上記 URL を curl で取得して `tmp/Press_Start_2P/` 配下に保存します (詳細は次節)。

---

## 2. フォントデータが作られるまでの流れ (TTF → PNG → ASM、 全部 make で完結)

```
upstream (Google Fonts / GitHub raw)
  │
  │  curl (Makefile)             ← 一度 DL すれば以後 skip
  ▼
tmp/Press_Start_2P/PressStart2P-Regular.ttf
tmp/Press_Start_2P/OFL.txt
  │
  │  scripts/make_font_png.py     (= Makefile から自動呼び出し)
  ▼
assets/font.png                  (= 128×48 1-bit、 16x6 char grid)
  │
  │  scripts/font_to_asm.py       (= Makefile から自動呼び出し)
  ▼
assets/src/font_data.s           (= 96 char × 8 byte rodata、 生成物専用ディレクトリ)
  │
  │  lwasm + lwlink
  ▼
本体 BIN に組み込み
```

`make` 一発で全パイプラインが連鎖実行されます:

```bash
make                  # 全部やる (= 初回は TTF/OFL も DL する)
```

### 2.1 必要なツール

| ツール | 用途 |
| --- | --- |
| `curl` | TTF / OFL の DL |
| `python3` | PNG 生成 + ASM 変換 |
| `Pillow` (Python) | TTF レンダリング (= `pip install Pillow`) |
| ネットワーク接続 | 初回 DL 時のみ必要 (2 回目以降は skip) |

### 2.2 Makefile の依存関係 (抜粋)

```makefile
FONT_TTF      = ./tmp/Press_Start_2P/PressStart2P-Regular.ttf
FONT_OFL      = ./tmp/Press_Start_2P/OFL.txt
FONT_PNG      = ./assets/font.png
FONT_DATA     = ./assets/src/font_data.s

$(FONT_TTF):
	@mkdir -p $(dir $@)
	@curl -fsSL -o $@ https://github.com/google/fonts/raw/main/ofl/pressstart2p/PressStart2P-Regular.ttf

$(FONT_OFL):
	@mkdir -p $(dir $@)
	@curl -fsSL -o $@ https://github.com/google/fonts/raw/main/ofl/pressstart2p/OFL.txt

$(FONT_PNG):  $(FONT_TTF) $(FONT_OFL) ./scripts/make_font_png.py
	@mkdir -p $(dir $@)
	python3 ./scripts/make_font_png.py

$(FONT_DATA): $(FONT_PNG) ./scripts/font_to_asm.py
	@mkdir -p $(dir $@)
	python3 ./scripts/font_to_asm.py $(FONT_PNG) $@
```

`assets/src/*.s → build/*.o` 用のパターンルールが別途あり、 通常の `src/*.s` ルールと共存します。

TTF/OFL は最初の `make` で DL され、 以後はファイルが残っているので skip (= ネットワーク不要)。 完全に消す場合は `make distclean` で `tmp/Press_Start_2P/` ごと削除します (= 通常の `make clean` では消さない)。

### 2.3 個別ステップ

#### TTF → PNG (`scripts/make_font_png.py`)

Python + Pillow で TTF を 8px サイズでレンダリングし、 16 列 × 6 行の char grid を 1-bit PNG に書き出します。

```bash
python3 scripts/make_font_png.py
```

#### PNG → ASM (`scripts/font_to_asm.py`)

PNG の各 8×8 char セルを上から 1 行ずつ読み、 1 byte (= 8 pixel の MSB-first bit pattern) に変換して `fcb` で書き出します。

```bash
python3 scripts/font_to_asm.py assets/font.png assets/src/font_data.s
```

### 2.4 別フォントへの差し替え

別 OFL pixel font に差し替えたい場合の選択肢:

**A. 別 TTF を使う**: Makefile の `$(FONT_TTF)` / `$(FONT_OFL)` ルール内の curl URL を新フォントの URL に書き換えて `make distclean && make`。

**B. PNG を手書きする**: `assets/font.png` を 128×48 1-bit (= 16 char × 6 行 × 8x8) で自分で作って直接置く → 依存関係を満たすため TTF にも `touch` する (= 古い TTF より新しいタイムスタンプにする)。

いずれの場合も新フォントのライセンス (= OFL なら帰属表記 / その他なら個別確認) は自分でハンドリングしてください。

---

## 3. `font_data.s` フォーマット詳細

[assets/src/font_data.s](../assets/src/font_data.s) は `scripts/font_to_asm.py` が自動生成する lwasm 形式の ASM ソースです。 構造:

```asm
                section rodata
                export  _font_data

_font_data:
                fcb     $00,$00,$00,$00,$00,$00,$00,$00      * 0x20 ' '
                fcb     $38,$38,$38,$30,$30,$00,$30,$00      * 0x21 '!'
                fcb     $6C,$6C,$6C,$00,$00,$00,$00,$00      * 0x22 '"'
                ...
                fcb     $00,$00,$00,$00,$00,$6C,$6C,$00      * 0x7f '\x7f'

                end
```

- **エクスポート名**: `_font_data` (= CMOC が C シンボルに `_` プレフィクスを付ける規約に合わせる)
- **C 側参照**: `extern const unsigned char font_data[]`
- **配置セクション**: `rodata` (= リンカが他の `rodata` と並べる、 `$ORG` 起点に乗る)
- **データ並び**: ASCII 0x20 から 0x7F の順、 1 文字 = 8 byte (= 上から 1 行ずつ)
- **bit 順**: byte 内は **MSB が左 pixel** (= 0x80 が pixel 0、 0x01 が pixel 7)

### 1 char (8 byte) のデコード例

`0x41 'A'` のデータ (例):

```
fcb $38,$6C,$C6,$C6,$FE,$C6,$C6,$00
```

各 byte を bit pattern として並べると:

```
$38 = 00111000  →   ###
$6C = 01101100  →  ## ##
$C6 = 11000110  → ##   ##
$C6 = 11000110  → ##   ##
$FE = 11111110  → #######
$C6 = 11000110  → ##   ##
$C6 = 11000110  → ##   ##
$00 = 00000000  →
```

つまり `A` の字形がそのまま読めます。 byte ごとに「`.` = 0、 `#` = 1」 でテキスト化すれば人間にも確認可能。

### 直接描画への組込

VRAM に直書きする場合の擬似コード:

```c
extern const unsigned char font_data[];

/* (col, row) に ASCII 文字 c を Green plane へ描画 */
void draw_char(unsigned char c, unsigned char col, unsigned char row) {
    if (c < 0x20 || c >= 0x80) return;
    const unsigned char *glyph = &font_data[(c - 0x20) * 8];
    /* Green plane VRAM の (col*8, row*8) に 8 byte 縦に流し込む */
    /* ... VRAM 直書き処理 ... */
}
```

Green plane / VRAM 切替の手順は別途実装が必要 (= サブシステム経由 or DMA 等)。 雛形では `sub_draw_text` (= subprog の `DRAW_CHAR` cmd) がこの描画を担当します ([SUBPROGRAM.md](SUBPROGRAM.md) §3 参照)。

---

## 4. 関連ファイル

| ファイル | 役割 | git track |
| --- | --- | --- |
| [scripts/font_to_asm.py](../scripts/font_to_asm.py) | PNG → ASM 変換 (Makefile 自動呼び出し) | ✓ |
| [scripts/make_font_png.py](../scripts/make_font_png.py) | TTF → PNG 生成 (Makefile 自動呼び出し) | ✓ |
| `assets/font.png` | 128×48 1-bit PNG (= make 再生成) | ✗ (.gitignore) |
| `assets/src/font_data.s` | 96 char × 8 byte rodata (= make 再生成) | ✗ (.gitignore) |
| `tmp/Press_Start_2P/PressStart2P-Regular.ttf` | upstream TTF (= make が curl で DL) | ✗ (.gitignore) |
| `tmp/Press_Start_2P/OFL.txt` | OFL ライセンス全文 (= make が curl で DL) | ✗ (.gitignore) |

## 5. 関連ドキュメント

- [README.md](../README.md) — 環境構築 / ビルド / 実行
- [DETAIL.md](DETAIL.md) — プロジェクト全体の詳細
- [GAMEMAIN.md](GAMEMAIN.md) — `c_main.c` のゲームロジック解説
- [GAMESUB.md](GAMESUB.md) — アセンブラ部分の概要 (`font_data.s` の §9 も参照)
