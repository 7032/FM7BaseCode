# GAMEMAIN.md — `c_main.c` ゲームロジック解説

[src/c_main.c](../src/c_main.c) はゲーム本体の C ソースです。 雛形では「backimage.png を 64x64 タイルで敷いた背景の上を、 character.png 由来の 32x32 sprite が **歩行アニメ**しながらテンキー 8/2/4/6 で動く」 demo になっています。 sprite の透明部分には背景が透けて見え、 移動しても背景は壊れません。

描画は B/R/G 3 plane (8色) の VRAM を **背景=B plane 単体・前景=R/G 2 plane** に分担します。 パレット (`$FD38-$FD3F`) を再割当して、 前景は R/G だけ立てれば B(背景)の有無に関わらず色が決まり、 R=G=0 が自動的に背景透過 (= マスク不要) になります。 前景色は bit0=R, bit1=G の 2bit color で、 `0=透明 / 1=赤 / 2=シアン / 3=白` です。 配色・パレットの詳細は [SPRITE.md](SPRITE.md) を参照。

このドキュメントは「起動シーケンス」 と「メインループ」 に分けて解説します。 描画は サブシステム ROM の PRINT 経由ではなく、 sub に転送した自前プログラムが VRAM を直接書く方式です。 仕組み詳細は [SUBPROGRAM.md](SUBPROGRAM.md) と [SPRITE.md](SPRITE.md) を参照。

---

## 1. 起動シーケンス (= `main()` 冒頭)

```c
unsigned char x        = 30, y = 80;
unsigned char dir      = 0;          /* 0 = 停止 */
unsigned char dir_idx  = DIR_DOWN;   /* 現在向いてる方向 (= sub 常駐 4 frame) */
unsigned char frame    = 0;          /* 歩行アニメ frame (0..3) */
unsigned char anim_cnt = 0;          /* frame を進めるカウンタ */

/* 0. サブ CPU に CANCEL を発行しコマンド待ちへ戻す (= テープ起動 warm start 対策) */
sub_cancel();
/* 1. cursor OFF */
{ unsigned char p = 0x00; subsys_call(SCMD_CURSOR, &p, 1); }
/* 2. sub idle 待ち (← 重要) */
delay_loop(500);
/* 3. subprog 本体ロード + NOP 起動 */
subprog_init();
/* 4. 初期方向 (DOWN) の 4 frame を sub に動的ロード */
sub_load_dir_frames(dir_idx);
/* 5. パレットを設定 (背景=青 / 前景= 赤・シアン・白) */
palette_init();
/* 6. 背景タイル (64x64) を sub に転送 */
sub_load_bgtile();
/* 7. 背景タイルを全画面に敷く (= VRAM clear も兼ねる) */
sub_draw_bg();
/* 8. キーボード IRQ 有効化 (= 実体は次の timer_init が IRQ を解禁し IRQ 駆動で読む) */
kb_init();
/* 9. メインタイマ IRQ 許可 + IRQ ベクタ設置 (約2msごとに経過 tick を数える) → カウンタ 0 */
timer_init();  timer_start();
/* 10. PSG サウンド初期化 + BGM 開始 (= メイン側 I/O。 サブ系統と独立) */
sound_init();
/* 11. 初期 sprite (DOWN frame 0) を描画 */
sub_blit_sprite(frame, x, y);
/* 12. SCORE 等のテキストを初期表示 (メインループで毎フレーム上書きし直す) */
sub_draw_text(...);
```

### 1.0 サブ CANCEL (step 0)

テープ起動 (= BASIC 稼働中に `LOADM,,R` で本体へ突入する warm start) では、 サブ CPU が BASIC のサブシステム処理の途中に居て、 後続の takeover が期待する「コマンド待ちループ」 状態になっていません。 起動時に一度 `sub_cancel()` を呼んでサブを既知のコマンド待ち状態へ揃えます。 ディスク起動 (cold start) では既にコマンド待ちなので無害です (詳細は [CMT.md](CMT.md) と [GAMESUB.md §3](GAMESUB.md#3-srcasm_subsyss--サブ-cpu-haltrelease))。

### 1.1 cursor OFF (step 1)

サブシステム ROM が起動時に `$0000-` 起点にカーソル blink を継続的に書込むので、 `SCMD_CURSOR` を `$00` で発行して止めます。

### 1.2 sub idle 待ち (step 2)

`subsys_call` から戻った時点でも sub は内部処理中で、 直後の `subprog_init` の `sub_takeover` が race して subprog 初回 chunk を取り零します。 `delay_loop(500)` で吸収。

### 1.3 subprog ロード + 方向別 frame ロード (step 3-4)

```c
subprog_init();              /* subprog コードを sub の $C300 に */
sub_load_dir_frames(dir_idx);/* 現在方向の 4 frame (= 1024 byte) を sub の $C700 に */
```

16 sprite (= 4 方向 × 4 frame) は console RAM (4KB) に丸ごと載らないので、 「今向いてる方向の 4 frame」 だけ sub に常駐させ、 方向が変わった時に load し直します (= 動的ロード)。 sub からはこの 4 frame が常に sprite_id 0..3 として見えます。

### 1.4 パレット設定 + 背景タイル (step 5-7)

```c
palette_init();      /* パレット ($FD38-$FD3F) を再割当 */
sub_load_bgtile();   /* 背景タイル 64x64 (= B plane 512 byte) を sub の $CB00 へ */
sub_draw_bg();       /* タイルを全画面に敷く (= R/G clear + B にタイル) */
```

`palette_init()` は論理色番号→物理色 (= デジタル GRB、 値 = G\*4 + R\*2 + B) を設定します。 色0=黒 / 色1=青(背景) / 色2,3=赤 / 色4,5=シアン / 色6,7=白。 2/3=赤・4/5=シアン・6/7=白 と二重化してあるのは、 前景は R/G だけ立てれば B(背景)の有無に関わらず色が決まるようにするためです (= マスク不要)。

`sub_load_bgtile()` は背景タイル backimage.png 由来の 64x64 モノクロ画像 (= B plane 512 byte) を sub の `$CB00` へ転送します。 `sub_draw_bg()` の前に 1 回だけ呼びます。

`sub_draw_bg()` は「R/G plane を全クリア + B plane に 64x64 タイルを全画面 (200line × 80byte) に敷く」 処理です。 横 64px (= 8byte) 周期・縦 64line 周期でタイルが繰り返されます。 内部で R/G を clear するので起動メッセージの消去も兼ねます。 sprite はこの背景の上を動きます。

### 1.5 キー有効化 + タイマ起動 + 初期描画 (step 8-11)

`kb_init` でキーボード IRQ を有効化し、 `timer_init()` で IRQ ベクタ設置 + メインタイマ/キーボード IRQ 許可 + IRQ 解禁、 `timer_start()` で経過カウンタを 0 にします (= 以後メインタイマ IRQ が約2msごとに経過 tick を数え、 メインループは `timer_get()` の deadline 方式でペーシングする。 キー入力も同じ IRQ ハンドラで読む。 §2.7 / [TIMER.md](TIMER.md))。 続いて `sub_blit_sprite(0, 30, 80)` で DOWN frame 0 を描画。 `sub_blit_sprite` は `src_R` / `src_G` を R/G plane へそのまま上書き (store) するので、 透明部分 (R=G=0) は R/G に 0 が入りますが、 背景は B plane に分離されていて触らないため B (= 青) がそのまま残ります。 退避バッファは不要です。 最後に `sub_draw_text` で SCORE 等を初期表示します (= メインループ先頭で毎フレーム上書きし直す)。

---

## 2. メインループ — キー保持 + 連続移動 + 歩行アニメ

```c
for (;;) {
    unsigned char k;
    unsigned char nx, ny;

    /* フレームペーシング (deadline): 前フレーム開始からの経過 tick が
     * FRAME_TARGET に達するまで待って timer_start() でリセット。 spin は待ちの
     * スピン回数 (= デバッグ表示用)。 PACE_SAFETY_CAP でハング防止。 */
    unsigned spin = 0;
    while (timer_get() < FRAME_TARGET && spin < PACE_SAFETY_CAP) spin++;
    timer_start();
    sub_draw_text(2, 4, /* "SCORE " + spin の 5 桁 */ ..., 2);
    sound_tick();                  /* BGM 進行 + SE 減衰 (毎フレーム。 §2.8) */

    k = key_check();

    /* キー解釈 */
    if (k == KEY_UP || k == KEY_DOWN || k == KEY_LEFT || k == KEY_RIGHT) {
        if (k != dir) {
            unsigned char new_idx = key_to_dir_index(k);
            dir = k;
            if (new_idx != dir_idx) {       /* 方向が変わった */
                dir_idx = new_idx;
                sub_load_dir_frames(dir_idx);  /* その方向の 4 frame を load */
                frame = 0; anim_cnt = 0;
            }
        }
    } else if (k != 0) {
        dir = 0;                            /* 方向キー以外 → 停止 */
    }
    if (dir == 0) continue;                 /* 入力なし (k==0) は dir 保持 */

    /* 移動計算 (端で据え置き) */
    nx = x; ny = y;
    switch (dir) { ... STEP_X_BYTES / STEP_Y_LINES ... }

    if (nx == x && ny == y) continue;       /* 端で動けない → 何もしない */

    /* 歩行アニメ: ANIM_PERIOD 回ごとに frame を進める */
    anim_cnt++;
    if (anim_cnt >= ANIM_PERIOD) { anim_cnt = 0; frame = (frame + 1) & 3; }

    /* atomic move (= 旧位置の R/G clear + 新位置へ store blit) */
    sub_move_sprite(frame, x, y, nx, ny);
    x = nx; y = ny;
}
```

### 2.1 キー保持の挙動

| key_check() | 動作 |
|---|---|
| `0` (入力なし) | dir 保持 → 連続移動継続 |
| 方向キー (8/2/4/6) | dir 更新。 方向が変わったら 4 frame を load し直し |
| その他のキー | 停止 (dir = 0) |

### 2.2 歩行アニメ

`ANIM_PERIOD` (= 3) 回移動するごとに frame を `0→1→2→3→0...` と進めます。 sub には現在方向の 4 frame が常駐してるので、 frame index をそのまま `sub_move_sprite` の sprite_id に渡せます。 方向が変わった時だけ `sub_load_dir_frames` で 4 frame を入れ替え (= 1024 byte 転送)、 同方向の移動中は転送不要で frame 切替だけ。

### 2.3 atomic move + 背景保持

`sub_move_sprite` は sub 側で次を 1 回の呼び出しで連続実行します:

1. 旧位置の R/G plane を 0 クリアして sprite を消す (= 背景の B=青 はそのまま残る)
2. 新位置に sprite を R/G plane へ上書き (store) blit (= 32x32 セルの R/G を sprite データでそのまま置換。 透明 (src_R=src_G=0) の pixel は R/G に 0 が入る)

これで「背景を壊さず」 sprite が動きます。 背景は B plane 単体、 前景は R/G 2 plane に分離してあるので、 透明 pixel に 0 が入っても背景 (B=青) は B plane に保持されていて透けます。 描画はセルを毎回置換するので前フレームの残像も自動で消え、 OR/RMW も別途クリアも不要です。 消去 (旧位置) も R/G を 0 クリアするだけで済み、 背景の塗り直しや退避バッファは要りません (= 退避バッファが sprite で汚れて残像が出る問題を構造的に回避)。

フレーム周期の安定化はメインループ側のフレームペーシングで行います (= 後述 §2.7)。

### 2.4 状態変数

| 変数 | 初期値 | 意味 |
|---|---|---|
| `x` / `y` | 30 / 80 | sprite 左上 (byte / line) |
| `dir` | `0` | 0=停止、 方向キー ASCII |
| `dir_idx` | `DIR_DOWN` | 現在方向 (= sub 常駐 4 frame の方向) |
| `frame` | `0` | 歩行アニメ frame (0..3) |
| `anim_cnt` | `0` | frame を進めるカウンタ |
| `ball_on[3]` | 全 `0` | 各スロットの使用中フラグ (1=飛行中)。 最大 `BALL_MAX` (=3) 個まで同時 |
| `ball_x[3]` / `ball_y[3]` | — | 各ボール位置 (byte / line) |
| `ball_d[3]` | — | 各ボール飛行方向 (dir_idx と同じ DOWN=0/UP=1/RIGHT=2/LEFT=3) |
| `brk_prev` | `0` | 前フレームの `break_check()` 値 (立ち上がりエッジ検出用) |

### 2.5 移動 step / 画面端

| 方向 | step |
|---|---|
| 横 (4/6) | `STEP_X_BYTES = 1` byte = 8 pixel |
| 縦 (8/2) | `STEP_Y_LINES = 4` line |

端で動けない場合は **何もしない** (= `continue`)。 描画 (消去→再描画) は実際に位置が変わる時だけ行い、 動けないのに毎ループ描画を繰り返す無駄とちらつきを避ける。 向きを変えても、 実際に動き出すまで画面の sprite は据え置き。

### 2.6 BREAK キーでボール発射

BREAK キーは通常のキー入力 (`$FD01`) には流れず、 メイン側 `$FD04` の bit1 に出ます (0=押下、 active-low)。 `asm_kbd.s` の `break_check()` が `$FD04` bit1 を読み、 押下中 `1` / 非押下 `0` を返します (宣言は `c_subprog.h`)。

メインループでは毎フレーム `break_check()` を読み、 **前回 0・今回 1 の立ち上がりエッジ** (= `brk_prev` で記憶) ごとに、 空きスロットがあれば 1 個だけ発射します。 押しっぱなしでは連射しません (立ち上がりごとに 1 個)。 ボールは最大 `BALL_MAX` (= 3) 個まで同時に飛ばせます (= 3 連射)。

```c
unsigned char brk = break_check();
if (brk && !brk_prev) {                      /* 立ち上がりエッジ */
    unsigned char s;
    for (s = 0; s < BALL_MAX; s++) {         /* 空きスロットを探す */
        if (!ball_on[s]) {
            ball_on[s] = 1;
            ball_x[s] = x; ball_y[s] = y;     /* キャラ位置から発射 */
            ball_d[s] = dir_idx;              /* 今向いてる方向へ */
            break;                            /* 1 個だけ発射 */
        }
    }
}
brk_prev = brk;
```

発射されたボールは今キャラが向いている方向 (`dir_idx`: DOWN=0 / UP=1 / RIGHT=2 / LEFT=3) へ飛びます。 空きスロットがある限り **最大 3 個まで同時** に飛行します (= 3 連射。 3 個飛行中は次の立ち上がりを無視)。 各ボールは毎フレーム `ball_d[s]` 方向へ `sub_erase_ball` (旧位置消去) → 位置更新 → `sub_draw_ball` (新位置描画) で進みます。 色は **シアン** (`BALL_COLOR = 2`、 前景 color の bit0=R/bit1=G でシアン)。 速度は横 `BALL_STEP_X = 2` byte (= 16px) / 縦 `BALL_STEP_Y = 8` line / フレームです。 横はキャラ移動 (= 1 byte/フレーム) と同速だと見づらいので、 倍速の 2 byte/フレームにしています。 画面端 (`ball_x[s] > 79` または `ball_y[s] > 192`、 または端で進めない) に達したボールは消して `ball_on[s] = 0` に戻し、 スロットを解放します。

### 2.7 フレームレート安定化 (= フレームペーシング)

FM-7 (初代) はメイン CPU 側から VSYNC (= 垂直帰線) を検出する手段がありません。 サブ側の表示 status (`$D430`) や `$FD12` は FM77AV 以降でのみ有効で、 初代 FM-7 では無効 (= 待っても即通過する) ため、 「真の VBlank 同期」 はメインループから取れません。

そこで本サンプルは **メイン CPU の周期タイマ IRQ (約2ms、 `$FD02`/`$FD03` bit2) を IRQ ハンドラで数える「経過 tick カウンタ」** を使い、 「**前フレーム開始からの経過 tick が `FRAME_TARGET` に達するまでロックする**」 deadline 方式でペーシングします。 起動時に `timer_init()` で IRQ ベクタ設置 + タイマ IRQ 許可 + IRQ 解禁をしておきます。 メインループ先頭で「`timer_get()` が `FRAME_TARGET` に達するまでロックして `timer_start()` で 0 に戻す」 だけです。

```c
timer_init();  timer_start();                  /* タイマ IRQ 許可 + 経過カウンタ 0 */
for (;;) {
    unsigned g = 0;
    while (timer_get() < FRAME_TARGET && g < PACE_SAFETY_CAP) g++;  /* deadline までロック */
    timer_start();                              /* 次フレームの起点に戻す */
    /* ... キー入力 / 移動 / ボール更新 / 描画 ... */
}
```

移動中は重い `sub_move_sprite` (= MOVE_SPRITE 発行) が走り、 停止中は描画がほとんど無いので、 何もしないとループ周期が状況でばらつき、 弾やキャラの速度が変わってしまいます (= 以前は停止フレームだけ速かった)。 経過 tick (= 実時間 約2ms 単位) を基準に 1 フレームを `FRAME_TARGET × 約2ms` に揃えるため、 処理の重い/軽いに関わらず速度が安定します。 **ポーリングではなく IRQ で数える**のが要点で、 こうすると処理の最中に過ぎた tick も取りこぼさず数えられます (= ステータスフラグは単一ラッチなのでポーリングだと「何 tick 過ぎたか」 が分からず deadline が組めない)。 待ちのスピン回数 `g` (= spin) は `SCORE` 欄にデバッグ表示します (= 安定した値なら順調、 `PACE_SAFETY_CAP` 付近に張り付くならタイマ IRQ 未発火)。

> **BREAK との両立 (なぜ IRQ で FIRQ でないか)**: BREAK (`$FD04` bit1) は FIRQ 要因で、 押下中ずっとレベルでアサートし続けます。 FIRQ を許可すると BREAK 押下中ずっと再発火してメインループが餓死します (= 実際に起きた)。 メインの周期タイマは **IRQ 要因** (`$FD02`/`$FD03` bit2) なので、 **IRQ だけ許可し FIRQ はマスクのまま**にすれば BREAK と干渉しません (BREAK は従来どおり `break_check()` が `$FD04` bit1 をポーリング)。 **仕組み・検証ポイントの詳細は [docs/TIMER.md](TIMER.md)** を参照。 機種依存の挙動 (IRQ ベクタ `$FFF8` の RAM 設置・タイマ周期) はエミュ/実機で要検証で、 未発火でもハングしないよう `PACE_SAFETY_CAP` で頭打ちにしてあります。

### 2.8 サウンド (PSG)

効果音と BGM は **PSG (AY-3-8910、 矩形波 3ch + ノイズ)** で鳴らします。 PSG は **メイン CPU 側 I/O** (`$FD0D`/`$FD0E`) なので、 グラフィックのサブシステム (HALT/共有 RAM/subprog) とは独立に `c_main` 側だけで完結します。 チャンネルは **ch A=ボール発射音 (ノイズ) / ch B=歩行音 / ch C=単音 BGM** に固定。 発音は**フレーム駆動**で、 メインループ先頭のフレームペーシング (= `timer_get()` 待ち) の直後 (= 全 `continue` の前) に `sound_tick()` を毎フレーム 1 回呼び、 BGM 進行と SE の減衰/リリースを進めます。 発射の瞬間に `sfx_ball()` (§2.6)、 歩行アニメが 1 歩進む瞬間に `sfx_walk()` (§2.2) を呼びます。 詳細は [docs/SOUND.md](SOUND.md)。

---

## 3. 描画 API (= sub-side で実行)

| 関数 | 動作 |
|---|---|
| `sub_load_bgtile()` | 背景タイル 64x64 (= B plane 512 byte) を sub の `$CB00` へ転送 (= `sub_draw_bg` の前に 1 回) |
| `sub_draw_bg()` | R/G plane を全クリア + B plane に 64x64 タイルを全画面に敷く (= 背景) |
| `sub_load_dir_frames(dir)` | 指定方向の 4 frame を sub に動的ロード |
| `sub_blit_sprite(id, x, y)` | R/G plane へ上書き (store) blit (= 初期描画用、 背景は既にある) |
| `sub_move_sprite(id, ox, oy, nx, ny)` | 旧位置の R/G clear + 新位置へ上書き (store) blit (= 移動用) |
| `sub_erase_box(x, y)` | R/G を 0 クリア (= sprite 消去、 背景の B は残る) |
| `sub_draw_text(col, row, str, color)` | 8x8 font で文字列を R/G に描画 (= SCORE 等) |
| `sub_draw_ball(x, y, color)` | 8x8 の丸 glyph (BALL_GLYPH) を R/G に上書き (store) 描画 (= ボール、 立った bit が color、 外側は 0 = B 背景が透ける)。 x=byte, y=line |
| `sub_erase_ball(x, y)` | 8x8 の R/G を 0 クリアしてボールを消去 (= 背景の B は残る)。 x=byte, y=line |
| `sub_cls()` | VRAM 全 clear |

詳細は [SUBPROGRAM.md §3-4](SUBPROGRAM.md#3-サブプログラム本体-asm_subprogs) 参照。

---

## 4. キーボード入力

`asm_kbd.s` の `key_check()` は「押された瞬間に ASCII を返す、 なければ 0」。 キー入力は **IRQ 駆動**で、 メインタイマと共用の IRQ ハンドラ ([asm_timer.s](../src/asm_timer.s)) がキーボード IRQ で `$FD01` を読んでバッファ (`_kbd_buf`) に格納し、 `key_check()` はそれを取り出すだけです (= フレームペーシングで IRQ を解禁しているため。 [TIMER.md §6](TIMER.md) 参照)。 連続移動は main loop 側で「dir 変数に保持」 して実現。 詳細は [SUBPROGRAM.md §8](SUBPROGRAM.md#8-キー入力-asm_kbds)。

---

## 5. 調整パラメータ

| 名前 | デフォルト | 意味 |
|---|---|---|
| `STEP_X_BYTES` | `1` | 横移動 step (= 8 pixel) |
| `STEP_Y_LINES` | `4` | 縦移動 step |
| `ANIM_PERIOD` | `3` | 何回移動ごとに歩行 frame を進めるか |
| `KEY_UP` 等 | `'8'/'2'/'4'/'6'` | テンキー対応 ASCII |
| `BALL_COLOR` | `2` | ボールの色 (= シアン。 前景 color の bit0=R, bit1=G で 2=G のみ) |
| `BALL_STEP_X` | `2` | ボール横移動 step (= 16 pixel。 キャラ横移動の倍速) |
| `BALL_STEP_Y` | `8` | ボール縦移動 step (= 8 line) |
| `BALL_MAX` | `3` | 同時に飛べるボールの最大数 (= 3 連射) |
| `FRAME_TARGET` | `16` | 1 フレームに使う tick 数 (1 tick ≈ 2ms。 `16`≒32ms/30fps)。 大きいほど全体がゆっくり。 deadline 方式 (§2.7 / [TIMER.md](TIMER.md)) |

> **既知の制限 (初心者注意):** 前景描画は R/G セルの上書き (store) なので、 前景どうし (キャラ・ボール・SCORE 文字はいずれも R/G) が重なると、 後から描いたものが下の前景の R/G を 0 で潰します (背景の B=青 は plane が別なので残ります)。 例えばボールがキャラや SCORE の上を通ると、 その部分が一時的に欠けて見えます。 本サンプルでは許容とし、 **メインループ先頭で毎フレーム `sub_draw_text` を上書き描画** する (= spin 値のデバッグ HUD) ので、 SCORE 欄が欠けても次フレームで復帰します。

---

## 6. 拡張アイディア

- **複数 sprite 同時表示**: x/y/dir を配列化して敵キャラ追加 (= 描画を sequential に発行)
- **背景タイルの差し替え**: backimage.png を別の 64x64 モノクロ画像に差し替えて再生成 ([SPRITE.md §9](SPRITE.md#9-将来拡張のヒント))
- **当たり判定**: 各 sprite の (x, y, 32, 32) 矩形で AABB
- **スコア HUD**: `sub_put_cell` か、 別途テキスト描画 cmd を subprog に追加
- **タイル mapping 背景**: 32×32 cell の tilemap を subprog cmd として追加
- **subsys_call の完了検出**: `delay_loop(500)` を撤廃して cmd 別の完了検出に

---

## 7. 関連ドキュメント

- [README.md](../README.md) — 環境構築 / ビルド / 実行
- [DETAIL.md](DETAIL.md) — プロジェクト全体の詳細
- [SUBPROGRAM.md](SUBPROGRAM.md) — sub-side 独自描画の全貌
- [SPRITE.md](SPRITE.md) — sprite データ形式
- [GAMESUB.md](GAMESUB.md) — アセンブラ部分の概要
