# GAMESUB.md — アセンブラ部分の概要

本テンプレートには C ソース ([c_main.c](../src/c_main.c) / [c_subsys.c](../src/c_subsys.c) / [c_subprog.c](../src/c_subprog.c) / [c_sound.c](../src/c_sound.c)) と並んで複数のアセンブラソース (`*.s`) が含まれます。 このドキュメントでは、 各 `.s` ファイルの「何のために存在しているか」 と「何を担当しているか」 を簡潔に説明します。

> **サウンド ([c_sound.c](../src/c_sound.c)) は asm モジュールを持ちません**。 PSG (AY-3-8910) はメイン CPU 側 I/O (`$FD0D`/`$FD0E`) なので、 メイン側 C だけで完結します (= サブ系統と独立)。 詳細は [SOUND.md](SOUND.md)。

詳細な実装や起動シーケンス、 ビルドフローは [DETAIL.md](DETAIL.md) / [SUBPROGRAM.md](SUBPROGRAM.md) を参照してください。

---

## 1. [src/asm_ipl.s](../src/asm_ipl.s) — IPL ローダー (= ブートセクタ)

ディスクの **track 0 / side 0 / sector 1** に書かれる 256 byte 以内のコード。 ブート ROM が読み込んで実行し、 続けて本体プログラム (ORG=`$0400`) を FDC で読み出して JMP します。

### 役割

1. **自己 relocate (bootstrap)**: ブート ROM が IPL を `$0100` (BASIC モード/標準) または `$0300` (DOS モード) にロードして JMP してくる (= FM77AV も同じ)。 同一 `ipl.bin` が両アドレスでロードされ得るので、 IPL は自分自身を高位 RAM (`$FB00`) にトランポリンコピーして位置非依存で動く。 本体は両ロード域を避けた `$0400` (ORG) に配置する。
2. **F-BASIC ROM overlay の解除**: `CLR $FD0F` で overlay を OFF にして `$FB00` を RAM として扱えるようにする。
3. **本体読込**: FDC (MB8877) を操作して sector 2 以降を `$0400` (ORG) へ展開。
4. **JMP `$0400` (ORG)**: main() へ実行を渡す。

### 設計のポイント

- **PCR ベース bootstrap**: `LEAX start,PCR` で「自分の今いる位置」 を取得してから relocate する。 これで `$0100` (BASIC) / `$0300` (DOS) どちらにロードされても自分の現在位置から正しくコピーできる。
- **メタデータ領域**: 先頭 2 byte に `BRA code` を置き、 直後の +2 byte 目に `body_sectors` を持つ。 ビルド時に [scripts/bin2d77.py](../scripts/bin2d77.py) が実セクタ数を書き込む。
- **FDC BUSY 待ち**: `STA FDC_CMD` の直後に `BITA #ST_BUSY` で BUSY=1 を確認する `wait_busy` ガードを挟む。 MB8877 は CMD 書込から BUSY=1 までに ~14μs 遅延があるため、 これを省くと「ロード 0 byte で完了」 と誤判定する。

### 容量制限と配置

本体は最大 **248 sector (= 62 KB)** をサポート。 track 0 / side 0 / sec 2..16 から始まり、 1 トラックを超えたら **side 0 → side 1 → 次トラックの side 0 → side 1 ...** の順 (= side-major) で配置されます。 トラック境界では IPL が `CMD_SEEK ($1B)` を発行してヘッドを移動します。 配置式: `flat = body_idx + 1; track = flat/32; side = (flat/16)%2; sec = (flat%16)+1`。 `body_sectors` フィールドは 1 byte なので技術的には最大 255 sector (~63.5 KB) まで可能ですが、 `ORG($0400)-$F9FF` の RAM 領域 (= relocate 先 `$FB00` の手前まで) を考慮して、 ORG=`$0400` なら実効上限は ~246 sector です。

---

## 2. [src/asm_crt0.s](../src/asm_crt0.s) — C 本体エントリ + CMOC ランタイム stub

IPL から `JMP $0400` (= `JMP $ORG`) で叩かれて始まる、 最小スタートアップ。

### 役割

- **割り込みマスク** (`ORCC #$50`)
- **スタックポインタ初期化** (`LDS #$FC7F`、 ブート ROM が設定した位置と同じ)
- **`JMP _main`** で C 側 main() に飛ぶ (= 戻ってこない前提なので `JSR` ではなく `JMP`)

### CMOC ランタイム stub

CMOC が生成する C オブジェクトは内部で `INILIB` (= 標準ライブラリ初期化) と `_exit` (= main から戻った時の出口) を参照します。 本テンプレートは libcmoc を使わず、 初期化が必要なグローバル変数も持たないため、 リンクを通すためのダミー実体を置いてあります:

- `INILIB`: 即 `RTS` (= 何もしない)
- `_exit`: `BRA _exit` (= 無限ループで停止)

---

## 3. [src/asm_subsys.s](../src/asm_subsys.s) — サブ CPU HALT/RELEASE

メイン CPU からサブ CPU を HALT / RELEASE / CANCEL する 3 関数を提供します。 `c_subsys.c` の `subsys_call()` が共有 RAM (`$FC80-$FCFF`) にアクセスする際に必ず呼ばれます。

### なぜ必要か

FM-7 では、 メイン CPU の共有 RAM アクセスは **サブ CPU を HALT している間のみ有効** という仕様です。 サブ稼働中の write は破棄、 read は `$FF` を返します。 従って `subsys_call()` は毎回:

```
[HALT → write/read shared RAM → RELEASE]
```

の手順を踏む必要があります。 ポーリング完了待ちも `[HALT → read → RELEASE]` を繰り返して進めます。

### API

```asm
_subsys_halt:
                lda     #$80
                sta     $FD05           * bit7 = HALT 要求
.wait:          lda     $FD05
                bita    #$80
                beq     .wait           * HALT ACK (bit7=1 read-back) を待つ
                ldb     #SUB_HALT_SETTLE
.settle:        decb                    * 命令境界での HALT 受理を確実に通過させる
                bne     .settle
                rts

_subsys_release:
                clr     $FD05           * HALT 解除 = サブ稼働再開
                rts
```

`$FD05` bit7 は「HALT 受理 OR BUSY」 で 1 になるため、 サブが BUSY な状態 (= テープ起動 warm start で BASIC 稼働中など) では bit7=1 を「HALT 受理」 と取り違える余地があります。 そこで bit7=1 確認後にさらに settle で数サイクル空転し、 「次の命令境界での HALT 受理」 を確実に通過させてから戻ります。

### `sub_cancel()` — warm start (テープ起動) 対応

`$FD05` bit6 に CANCEL を発行し、 実行中の処理を中断させてサブシステム ROM のコマンド待ちループへ戻します。 テープ起動 (= BASIC 稼働中に本体へ突入する warm start) ではサブ CPU が BASIC のサブシステム処理の途中に居るため、 起動時に一度これを呼んでサブを takeover 可能なクリーン状態へ揃えます。 ディスク起動 (cold start) では既にコマンド待ちなので無害です (詳細は [CMT.md](CMT.md))。

C 側プロトタイプは [c_subsys.h](../src/c_subsys.h) に。

---

## 4. [src/asm_test.s](../src/asm_test.s) — TEST 発行 API (= sub 側プログラム転送/実行)

サブシステム ROM の拡張コマンド (CMD `$3F` = TEST) を介して、 sub の任意 RAM 番地に **コードやデータを転送 + JSR** する API。 これが「自前のサブプログラムを sub に常駐させる」 仕組みの根幹で、 雛形の sprite 描画 / VRAM 直書きは全部この上に乗っています。

### 提供する関数

```c
void sub_wait_ready(void);          /* $FD05 bit7 = 0 まで待つ */
void sub_halt(void);                /* HALT 要求 → BUSY=1 受領待ち */
void sub_release(void);             /* HALT 解除 */
void sub_call(unsigned addr);       /* sub の addr に JSR (= TEST CALL) */
void sub_takeover(const void *code, unsigned len,
                  unsigned dst, unsigned exec);
```

### `sub_takeover(code, len, dst, exec)`

最重要関数。 main RAM 上のデータを sub の任意番地に転送する。

- 共有 RAM の後半 (`$FCA0-$FCDF` = 64 byte) を chunk バッファとして使い、 **64 byte ずつ分割**して MOVE cmd で sub に運ぶ
- 全 chunk 転送後、 `exec != 0` なら `sub_call(exec)` で実行開始
- `exec = 0` で「転送のみ」 モード (= sprite データ等の純粋データ転送用)

### 設計のポイントと落とし穴

- **スタックオフセット計算**: `pshs u,y` + `leas -5,s` の +9 シフト。 引数アクセス時に必ず +5 する。
- **`wait_ready` 削除**: `_sub_halt` / `_sub_call` 冒頭から `wait_ready` を削った。 環境によって `_subBusy=true` が残留し `wait_ready` が永久 hang するのを回避 (= #3)

---

## 5. [src/asm_subprog.s](../src/asm_subprog.s) — サブ CPU 上で動く独自描画プログラム

sub の `$C300` に常駐して、 共有 RAM 経由で渡される cmd を 1 つずつ処理する。 雛形の VRAM 直書き描画 (前景 sprite / 背景タイル) はこのプログラムが担当しています。

### 配色モデル (背景=B / 前景=R・G)

本テンプレートは FM-7 の 3 plane (B/R/G) VRAM を **背景 = B plane 単体・前景 = R/G 2 plane** に役割分担しています。

- **パレット (`$FD38-$FD3F`)** で論理色番号 → 物理色を再割当します (値 = `G*4 + R*2 + B` = デジタル GRB)。 `palette_init()` ([asm_kbd.s](../src/asm_kbd.s)) が次のように設定します: 色0=黒 (`$00`) / 色1=青 (`$01`, 背景) / 色2=赤 (`$02`) / 色3=赤 (`$02`) / 色4=シアン (`$05`) / 色5=シアン (`$05`) / 色6=白 (`$07`) / 色7=白 (`$07`)。
- パレットを **2/3=赤・4/5=シアン・6/7=白 と二重化**してあるのが狙いです。 こうすると前景は R/G だけ立てればよく、 B (背景) の有無に関わらず前景色が決まります。 さらに R=G=0 が自動的に背景透過になる (= マスク不要) ため、 前景描画は B plane に一切触れずに済みます。
- **前景 color コード**: `bit0=R`, `bit1=G`。 `0`=透明 / `1`=赤 / `2`=シアン / `3`=白。 (旧来の `bit0=B, bit1=R, bit2=G` の 8 色 color とは別物です)

### 背景タイル (DRAW_BG)

背景は単色塗りではなく **64x64 モノクロ画像 ([assets/backimage.png](../assets/backimage.png)) を全画面にタイル敷き**します。

- `$07` DRAW_BG は「R/G plane を全クリア + B plane に 64x64 タイルを全画面 (200 line × 80 byte) に敷く」 cmd です。 横 64px (8 byte) 周期・縦 64 line 周期で繰り返します。
- タイルデータ ([scripts/bgtile_to_asm.py](../scripts/bgtile_to_asm.py) が生成、 後述 §10.5) は起動時に C API `sub_load_bgtile()` で sub の `$CB00` へ転送します (`sub_draw_bg()` の前に呼ぶ)。 明ドット = B1 = 色番号 1 = 青、 暗ドット = B0 = 黒 になります。

### 提供 cmd

| code | 名前 | 動作 |
|---|---|---|
| `$00` | NOP | 動作確認用 |
| `$01` | PUT_CELL | 8x8 cell を前景 (R/G 2 plane) 単色で塗り |
| `$02` | CLR_CELL | 8x8 cell の R/G をクリア (= 前景を消す。 背景 B は残る) |
| `$03` | CLS | VRAM 全 plane 48 KB clear |
| `$04` | BLIT_SPRITE | 32x32 sprite を VRAM の R/G 2 plane へ上書き (store) で転送 |
| `$05` | ERASE_BOX | 32x32 領域の R/G をクリア (= 前景を消す。 背景 B は残る) |
| `$06` | MOVE_SPRITE | sprite を消去 → 新位置へ再描画 (= ERASE_BOX 相当 + BLIT_SPRITE) |
| `$07` | DRAW_BG | R/G plane を全クリアし、 B plane に 64x64 モノクロタイルを全画面に敷く |
| `$08` | DRAW_CHAR | 8x8 文字 glyph を R/G に上書き (store) で描画 (立った bit が前景 color、 外側は 0 = B 背景が透ける) |
| `$09` | DRAW_BALL | 8x8 の丸を R/G に上書き (store) で描画。 雛形ではシアンボール (`color=2`) を最大 3 連射で使う。 params: `$D394`=x_byte, `$D395`=y_line, `$D396`=color |
| `$0A` | ERASE_BALL | ボール 8x8 の R/G をクリアして消去 (背景 B が残るので塗り直し不要)。 params: `$D394`=x_byte, `$D395`=y_line |

> sub の cmd は `$00`-`$0A` まで (= NOP / PUT_CELL / CLR_CELL / CLS / BLIT_SPRITE / ERASE_BOX / MOVE_SPRITE / DRAW_BG / DRAW_CHAR / DRAW_BALL / ERASE_BALL)。 フレーム同期用の VSync cmd は存在しません (= フレームペーシングは main 側がメイン CPU の周期タイマ IRQ (約2ms) を数える経過 tick の deadline 方式で行う。 後述「フレームペーシング」 参照)。

### ボール (DRAW_BALL / ERASE_BALL)

`$09` DRAW_BALL は 8x8 の丸を描く。 雛形ではシアンボール (前景 `color=2` = G のみ) を使う。 描画は DRAW_CHAR と同じ R/G への上書き (store) 方式で、 丸 glyph の立った bit に前景 color を、 外側 (glyph=0) には 0 を毎回ストアする (= セルを置換するので前の絵は自動で消える)。 外側は R/G=0 になるが背景は B plane が別に保持しているので青が透ける。 丸 glyph は subprog 内蔵の `BALL_GLYPH` を使う。 `$0A` ERASE_BALL は同じ 8x8 領域の R/G をクリアして消去する (背景 B=青が残るので塗り直しは不要)。

C 側 API は次の通り (実体 [c_subprog.c](../src/c_subprog.c)、 宣言 [c_subprog.h](../src/c_subprog.h)):

```c
void sub_draw_ball(unsigned char x_byte, unsigned char y_line, unsigned char color);
void sub_erase_ball(unsigned char x_byte, unsigned char y_line);
```

動作: BREAK を押すと今キャラが向いている方向 (`dir_idx`: DOWN=0 / UP=1 / RIGHT=2 / LEFT=3) へシアンボールを投げる。 **最大 3 個まで同時** に飛ばせる (= `BALL_MAX=3` の 3 連射)。 BREAK の立ち上がりエッジごとに、 空きスロットがあれば 1 個発射する。 速度は横が `BALL_STEP_X=2` byte(=16px)/フレーム、 縦が `BALL_STEP_Y=8` line/フレーム。 横はキャラ横移動 (1 byte/フレーム) の倍速にしてある (= キャラと同速だと弾速が遅く見づらいため)。 画面端 (`bx>79` または `by>192`、 または端で進めない) に達したら消える。

> ボール消去は対象 8x8 の R/G をクリアするだけ (= 前景を消す) で、 背景 B plane (青の背景) はそのまま残ります。 退避バッファや背景再生成は不要です。 SCORE 文字は前景 (R/G) なので、 キャラ移動後に毎フレーム `sub_draw_text` で再描画して消えないようにしています。

### 設計のポイント

- **VRAM gate**: `$D409` を read で OPEN にしないと VRAM への sta が反映されない。 entry の冒頭で `lda VRAM_GATE` を毎回実行
- **cmd 完了時の `clr CMD_REG`**: handler の末尾で `$D393` を `$00` (NOP) に戻す。 TEST コマンド処理 の再 コマンド処理 で 2 重実行されるのを防ぐガード
- **subprog コード領域 (`$C300-$C6FF`) への自己書込み禁止**: 動作確認マーカー等は領域外 (`$C000-$C2FF` 等) に書く (= コード領域に書くと命令の opcode を壊すため)
- **メモリマップ (現状)**: sub 側は次のように配置している。

  | 範囲 | 用途 |
  |---|---|
  | `$C200-$C2FF` | subprog 作業変数 |
  | `$C300-$C6FF` | subprog コード |
  | `$C700-$CAFF` | sprite データ (現在方向 4 frame × 256 byte) |
  | `$CB00-$CCFF` | 背景タイル (64x64 モノクロ = B plane 512 byte) |
  | `$D000-` | サブシステム作業域 (触らない) |

  sprite base は `SPRITE_BASE` ([asm_subprog.s](../src/asm_subprog.s)) と `SUB_CHARS_ADDR` ([c_subprog.h](../src/c_subprog.h)) が `$C700` で一致。 背景タイル base は `$CB00` で、 起動時に `sub_load_bgtile()` が転送する。

詳細は [SUBPROGRAM.md §3](SUBPROGRAM.md#3-サブプログラム本体-asm_subprogs)。

---

## 6. [src/asm_kbd.s](../src/asm_kbd.s) — キーボード入力 (IRQ 駆動)

FM-7 はサブ CPU がキーボード scan して結果を `$FD01` に流します。 メインループでは IRQ を解禁している (= フレームペーシング、 §7) ため、 キーボード入力は **IRQ 駆動**です: メインタイマと共用の IRQ ハンドラ ([asm_timer.s](../src/asm_timer.s)) がキーボード IRQ (`$FD03` bit0) で `$FD01` を読み (= IRQ を ack)、 共有バッファ `_kbd_buf` に格納します。 `key_check()` はそのバッファを取り出して返すだけです。 詳細は [TIMER.md §6](TIMER.md)。

### API

```c
void          kb_init(void);            /* $FD02 bit0 セット = IRQ 有効化 */
unsigned char key_check(void);          /* 押されてれば ASCII、 なければ 0 */
unsigned char break_check(void);        /* BREAK 押下中 1 / 非押下 0 ($FD04 bit1) */
void          palette_init(void);       /* パレット ($FD38-$FD3F) を本テンプレ配色に設定 */
```

### パレット初期化 (`palette_init`)

`palette_init()` は本テンプレートの配色モデル (背景=B / 前景=R・G) を成立させるため、 パレットレジスタ `$FD38-$FD3F` (論理色 0..7 に対応) に物理色を書き込みます。 各レジスタの値は `G*4 + R*2 + B` (= デジタル GRB) で、 起動時に main から 1 回呼びます。

| 論理色 | 値 | 物理色 | 用途 |
|---|---|---|---|
| 0 | `$00` | 黒 | 背景の暗部 |
| 1 | `$01` | 青 | 背景の明部 |
| 2 / 3 | `$02` | 赤 | 前景 (赤) |
| 4 / 5 | `$05` | シアン | 前景 (G) |
| 6 / 7 | `$07` | 白 | 前景 (白) |

色 2/3=赤・4/5=シアン・6/7=白 と **2 つずつ同じ物理色に二重化**してある点が要です。 前景は R/G だけ立てれば B (背景) の有無に関わらず同じ色相になり、 R=G=0 (前景 color `0`) が自動的に背景透過になります。 これにより前景描画でマスク plane を持たずに済みます。 詳しくは §5「配色モデル」 を参照。

### BREAK キー

BREAK キーは通常のキー入力 (`$FD01`) には流れず、 メイン側 `$FD04` の bit1 に出ます (active-low: 0=押下, 1=非押下)。 `break_check()` は `$FD04` bit1 をポーリングし、 押下中なら 1、 非押下なら 0 を返します (実体 [asm_kbd.s](../src/asm_kbd.s)、 宣言 [c_subprog.h](../src/c_subprog.h))。

毎フレーム `break_check()` を読み、 前回 0・今回 1 の立ち上がりエッジで「キャラの向き (`dir_idx`) へシアンボールを発射」 するのが基本パターンです (雛形の `c_main.c` が `brk_prev` でエッジ検出)。 雛形では最大 3 連射 (`BALL_MAX=3`) で、 立ち上がりエッジごとに空きスロットがあれば 1 個ずつ発射します。

### フレームペーシング (フレームレート安定化)

FM-7 (初代) は **メイン CPU から VSYNC を検出できません** (= サブの表示 status `$D430` や `$FD12` は FM77AV 以降でのみ有効で、 初代では無効＝即通過してしまう)。 そのため「真の VBlank 同期」 は使わず、 **メイン CPU の周期タイマ IRQ (約2ms、 `$FD02`/`$FD03` bit2) を IRQ ハンドラで数える「経過 tick カウンタ」を使い、 経過 tick が `FRAME_TARGET` に達するまでロックする deadline 方式** (= フレームペーシング) を採っています。 起動時に `timer_init()` で IRQ ベクタ設置 + タイマ IRQ 許可 + IRQ 解禁、 メインループ先頭で `timer_get()` が `FRAME_TARGET` に達するまでロックして `timer_start()` で 0 に戻します。 固定 busy-wait と違い、 CPU 速度でなく実時間 (約2ms 単位) を基準に周期が揃います。

これにより、 移動中 (重い MOVE_SPRITE を発行するフレーム) も停止中もループ 1 周の所要時間がほぼ一定になり、 弾やキャラの速度がばらつきません (= 以前は停止フレームだけ速くなっていました)。 全体をゆっくりにしたいときは `FRAME_TARGET` を増やします。 ポーリングでなく IRQ で数えるのは「処理中に過ぎた tick も取りこぼさず数える」 ため (= ステータスフラグは単一ラッチ)。 **IRQ であって FIRQ ではない**ので、 FIRQ 要因の BREAK (`$FD04` bit1) と干渉しません (BREAK は `break_check()` がポーリング)。 詳細は [TIMER.md](TIMER.md) を参照。

### 連続移動の実装

`key_check()` は「キーが押された瞬間」 にだけ ASCII を返すので、 「方向キーを押しっぱなしで動き続ける」 には main loop 側で「最後押下キーを保持する」 必要があります。 雛形の `c_main.c` がそのパターンを実装してます。

詳細は [SUBPROGRAM.md §8](SUBPROGRAM.md#8-キー入力-asm_kbds)。

---

## 7. [src/asm_runtime.s](../src/asm_runtime.s) — CMOC ランタイムヘルパ (MUL16)

CMOC が乗算式を生成する際に呼ぶ `MUL16` (= 16x16 → 16 unsigned multiply) のアセンブラ実装。

### なぜ必要か

CMOC は 16 bit 乗算を、 自前のランタイム関数 `MUL16` の `LBSR` で実現します。 libcmoc 一式をリンクすればこのランタイムも入りますが、 本テンプレートは libcmoc 非使用なので必要な関数だけ最小実装で持っています。

なお C 側で `*8` のような 2 のべき乗倍は `<< 3` に書き換えれば `MUL16` を呼ばずに済みます。

---

## 8. [src/asm_bootrom.s](../src/asm_bootrom.s) — 自前ブート ROM (任意)

FM-7 内蔵ブート ROM (= 通常は BASIC モードの BASIC モードのブート ROM) が行うディスク起動の役割をオリジナル実装で書き起こした、 512 byte の `$FE00-$FFFF` 用 ROM。 `make bootrom` で別途ビルドします。

### 実機 FM-7 / FM77AV では不要

実機には内蔵ブート ROM (= 通常 BASIC モードのブート ROM) があり、 そちらが「起動可能ディスクがあれば sector 1 を `$0100` (BASIC モード) にロードして JMP」 を担います。 本 ROM が必要になるのは:

- **実機ブート ROM (= 著作物) を入手できない環境**: 代わりに `$FE00-$FFFF` に流し込めるエミュレータや自前ハードで使う
- **自前ハード起こし / ROM 差し替え**: 実機の boot ROM をオリジナルに差し替えたい場合

### 仕様

実機ブート ROM (= BASIC モードのブート ROM / BASIC モード) と同じ規約に合わせてあります:
- sector 1 を `$0100` に読み込む (= BASIC モード標準。 DOS モードなら `$0300`)
- `JMP $0100` で IPL に制御を渡す
- IPL 入口は `DP = $00`, `SP = $FC7F` (= 実機ブート ROM 準拠)
- 末尾 2 byte (`$FFFE-$FFFF`) に reset vector `$FE 00`

サイズ整形 (= 512 byte ぴったり + reset vector 埋め込み) は lwasm 単独でやりにくいため、 後段で [scripts/pad_bootrom.py](../scripts/pad_bootrom.py) が処理します。

---

## 9. [assets/src/font_data.s](../assets/src/font_data.s) — 8x8 bitmap font データ

Press Start 2P (Google Fonts) を 8x8 pixel にラスタライズしたビットマップ。 ASCII 0x20-0x7F の 96 char × 8 byte = 768 byte を `rodata` セクションに置きます。

### 用途

雛形では未使用 (= リンク保持のため `c_main.c` 冒頭で 1 byte だけダミー読みしてる)。 将来、 sprite に文字を重ねたり、 独自字形を Green plane に直接描画したくなった時にここから持ってきます。

### 再生成 / フォーマット / ライセンス

詳細は [FONT.md](FONT.md)。

---

## 10. [assets/src/sprite_data.s](../assets/src/sprite_data.s) — 32x32 sprite データ (= 生成物)

[assets/character.png](../assets/character.png) を [scripts/sprite_to_asm.py](../scripts/sprite_to_asm.py) で変換した 32x32 pixel bitmap。 前景 plane の **R plane (128 byte) + G plane (128 byte) = 256 byte/sprite** です (旧来の B/R/G/mask 4 面 512 byte からの変更)。 16 sprite (= 4 方向 × 4 frame) で 4096 byte。

`sprite_to_asm.py` は character.png を **Floyd-Steinberg ディザで 赤/シアン/白 の 3 色へ量子化**し、 R/G 2 plane に出力します。 横隣接ドットの混色 (赤シアン / 赤白 / シアン白) で 6 色相当に見せます。 描画 (BLIT_SPRITE / MOVE_SPRITE) は R/G plane への単純な上書き (store) で、 透明 (R=G=0) は R/G に 0 が入りますが背景は B plane (= R/G とは独立) に保持されていて青が透けます。 消去は R/G を 0 クリアするだけです (= 背景タイルは B plane に残るので背景の塗り直しも退避バッファも不要)。

sprite データは sub 側の sprite base (`$C700` 起点) に転送されます (base は `SPRITE_BASE` / `SUB_CHARS_ADDR` で `$C700` に統一)。 sub のメモリマップは §5「メモリマップ (現状)」 を参照。

詳細は [SPRITE.md](SPRITE.md)。

---

## 10.5. [assets/src/bgtile_data.s](../assets/src/bgtile_data.s) — 64x64 背景タイルデータ (= 生成物)

[assets/backimage.png](../assets/backimage.png) を [scripts/bgtile_to_asm.py](../scripts/bgtile_to_asm.py) で変換した 64x64 pixel のモノクロ背景タイル。 **B plane 512 byte (= 64 line × 8 byte)** として出力され、 `bgtile_data[]` (`extern const unsigned char bgtile_data[]`、 512 byte) として export されます。

### フォーマット

`bgtile_to_asm.py` は 64x64 画像の各ドットを明 / 暗の 2 値に量子化し、 明 = B1 (= 色番号 1 = 青) / 暗 = B0 (= 黒) として 1 line 8 byte の B plane bitmap に詰めます。 R/G plane は持ちません (= 前景専用)。

### 転送と描画

起動時に C API `sub_load_bgtile()` がこの 512 byte を sub の **`$CB00`** へ転送します (`sub_draw_bg()` を呼ぶ前に 1 回)。 描画は sub cmd `$07` DRAW_BG が担当し、 R/G plane を全クリアした上で B plane に 64x64 タイルを全画面 (200 line × 80 byte) に横 8 byte 周期・縦 64 line 周期で敷き詰めます。 配色モデルの詳細は §5「配色モデル」 / 「背景タイル」 を参照。

---

## 11. [assets/src/subprog_data.s](../assets/src/subprog_data.s) — subprog バイナリの C 配列化 (= 生成物)

[asm_subprog.s](../src/asm_subprog.s) を raw アセンブルした `subprog.bin` (= sub の `$C300` で動くコード) を `bin2asm.py` で C 配列化したもの。 `_subprog_bin[]` + `_subprog_len` として export され、 main 起動時の `sub_takeover` で sub に転送されます。

---

## 12. 関連ドキュメント

- [README.md](../README.md) — 環境構築 / ビルド / 実行
- [DETAIL.md](DETAIL.md) — 全ソースファイルの詳細解説、 起動シーケンス、 Makefile の中身、 ハマりポイント
- [GAMEMAIN.md](GAMEMAIN.md) — `c_main.c` のゲームロジック解説
- [SUBPROGRAM.md](SUBPROGRAM.md) — 自前サブプログラムによる独自描画 (= asm_test.s + asm_subprog.s + asm_kbd.s の全貌)
- [SPRITE.md](SPRITE.md) — sprite データ形式 + sprite_to_asm.py
- [FONT.md](FONT.md) — 同梱 8x8 font (Press Start 2P, OFL-1.1) 解説
