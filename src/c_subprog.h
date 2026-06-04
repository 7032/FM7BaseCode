/* ============================================================
 * c_subprog.h — サブ CPU 独自描画プログラム + キー入力 の C API
 *
 * 構成要素:
 *   - 低レベル:   sub_halt / sub_release / sub_call / sub_takeover
 *                 (= asm_test.s 実装、 sub への code/data 転送と JSR)
 *   - 高レベル:   subprog_init / sub_copy_chars / sub_cls /
 *                 sub_put_cell / sub_clr_cell /
 *                 sub_blit_sprite / sub_erase_box
 *                 (= c_subprog.c 実装、 sub 側 cmd 発行)
 *   - キー入力:   kb_init / key_check
 *                 (= asm_kbd.s 実装、 IRQ 駆動)
 *
 * 仕組みの全貌は docs/SUBPROGRAM.md。 sprite 仕様は docs/SPRITE.md。
 * 雛形のゲームロジックは docs/GAMEMAIN.md と src/c_main.c。
 * ============================================================ */

#ifndef C_SUBPROG_H
#define C_SUBPROG_H

/* sub 上のロード位置 (= asm_subprog.s の org と要一致) */
#define SUB_PROG_ADDR     0xC300
/* sprite データ配置先 ($C300+ の subprog コードと衝突回避)。
 * 注意: asm_subprog.s の SPRITE_BASE と要一致。 subprog の size は機能
 * 追加で変動するので、 make 後に subprog.bin のサイズ ($C300+size) が
 * ここを超えていないか確認すること (= 超えたら両方を後ろへ動かす)。 */
#define SUB_CHARS_ADDR    0xC700
/* 背景タイル (64x64 = 512 byte) の sub 上の配置先 (= asm_subprog.s の
 * BG_TILE と要一致)。 sprite 4 frame ($C700-$CAFF) の直後 $CB00。 */
#define SUB_BGTILE_ADDR   0xCB00

/* 共有 RAM 上の CMD レジスタ位置 (main 側、 = sub から $D393)。
 * $FC80-$FC92 は sub_call が TEST cmd 列で上書きするので、 その
 * 後ろの $FC93 から subprog の cmd を置く。 */
#define SUB_CMD_REG       ((volatile unsigned char *)0xFC93)

/* sub 描画コマンドコード (= asm_subprog.s と要一致) */
#define SUBCMD_NOP        0x00
#define SUBCMD_PUT_CELL   0x01   /* x_byte, y_line, color */
#define SUBCMD_CLR_CELL   0x02   /* x_byte, y_line */
#define SUBCMD_CLS        0x03   /* (no params) */
#define SUBCMD_BLIT       0x04   /* x_byte, y_line, sprite_id */
#define SUBCMD_ERASE_BOX  0x05   /* x_byte, y_line */
#define SUBCMD_MOVE       0x06   /* old_x, old_y, new_x, new_y, sprite_id */
#define SUBCMD_DRAW_BG    0x07   /* (no params) 背景タイルを全画面に */
#define SUBCMD_DRAW_CHAR  0x08   /* x_byte, y_line, color, glyph[8] */
#define SUBCMD_DRAW_BALL  0x09   /* x_byte, y_line, color (8x8 丸ボール) */
#define SUBCMD_ERASE_BALL 0x0A   /* x_byte, y_line (8x8 の R/G をクリアして消去) */

/* 画面寸法 */
#define SCREEN_W_BYTES    80     /* 横 80 cell (= 640 px) */
#define SCREEN_H_LINES    200    /* 縦 200 line */

/* sprite (= 32×32 pixel) */
#define SPRITE_PX_W       32
#define SPRITE_PX_H       32
#define SPRITE_W_BYTES    4      /* 32 px / 8 = 4 byte/line */
#define SPRITE_BYTES      256    /* 2 plane (R/G) × 128 byte/plane */
#define FRAMES_PER_DIR    4      /* 各方向の歩行アニメ frame 数 */
#define NUM_DIRS          4      /* DOWN/UP/RIGHT/LEFT */

/* dir index (= sprite_data の dir-major 並びの方向番号) */
#define DIR_DOWN          0
#define DIR_UP            1
#define DIR_RIGHT         2
#define DIR_LEFT          3

/* ----- 低レベル (asm_test.s 実装) ----- */
void          sub_wait_ready(void);
void          sub_halt(void);
void          sub_release(void);
void          sub_call(unsigned int addr);
void          sub_takeover(const void *code, unsigned int len,
                           unsigned int dst, unsigned int exec);

/* ----- 高レベル ----- */

/* 起動時 1 回: sub の $C300 に subprog 本体を転送 + NOP 起動 */
void          subprog_init(void);

/* 指定方向 (dir_index = 0..3) の 4 frame (= 1024 byte) を sub の $C700 に
 * 動的ロードする。 sub 側ではこの 4 frame が sprite_id 0..3 として見える。
 * 方向が変わった時だけ呼ぶ (= 同方向の移動中は frame 切替で済む)。 */
void          sub_load_dir_frames(unsigned char dir_index);

/* 1 cell (= 8x8 px) を指定色で塗る (= 旧 cell 系 API、 残置) */
void          sub_put_cell(unsigned char x_byte, unsigned char y_line,
                           unsigned char color);
void          sub_clr_cell(unsigned char x_byte, unsigned char y_line);

/* 画面全 plane を BLACK で塗潰し */
void          sub_cls(void);

/* 背景タイル (64x64 モノクロ) を sub の $CB00 に転送する (= 起動時 1 回、
 * sub_draw_bg の前に呼ぶ)。 */
void          sub_load_bgtile(void);

/* 背景を全画面に描く。 B plane に 64x64 タイル (= bgtile_data) を敷き
 * (B=1 → 色番号 1 = 青、 B=0 → 黒)、 R/G は 0 にする (= 前景は R/G だけ
 * 使い、 透明部はこの背景模様が透ける)。 事前に sub_load_bgtile が必要。 */
void          sub_draw_bg(void);

/* 32x32 sprite を VRAM に転送 (= 3 plane の bitmap を直接 sta) */
void          sub_blit_sprite(unsigned char sprite_id,
                              unsigned char x_byte, unsigned char y_line);

/* 32x32 領域を BLACK で塗潰し (= sub_blit_sprite の取消用) */
void          sub_erase_box(unsigned char x_byte, unsigned char y_line);

/* sprite を旧位置 → 新位置に atomic に移動 (= 旧位置 erase + 新位置 blit
 * を sub 側 1 回で実行 + VBlank タイミング待ち)。 ちらつき軽減用。 */
void          sub_move_sprite(unsigned char sprite_id,
                              unsigned char old_x, unsigned char old_y,
                              unsigned char new_x, unsigned char new_y);

/* テキスト表示 (= 同梱 8x8 font を VRAM に描く。 SCORE 表示等に)。
 *   col   : 文字の横位置 (= 0-79、 1 文字 = 8px = 1 byte 単位)
 *   row   : 文字の上端 line (= 0-199)
 *   str   : ASCII 文字列 (0x20-0x7F)。 範囲外は空白に
 *   color : 文字色 (0-7、 デジタル RGB)。 文字の隙間は背景が透ける */
void          sub_draw_text(unsigned char col, unsigned char row,
                            const char *str, unsigned char color);

/* キー入力 (IRQ 駆動。 IRQ ハンドラ(asm_timer.s)が $FD01 を読み _kbd_buf に格納)
 *   kb_init(): 起動時に 1 回。 $FD02 bit0 セット (キーボード IRQ 有効)
 *   key_check(): 直近に押されたキーの ASCII を返す、 なければ 0 (_kbd_buf 取り出し) */
/* 8x8 の丸ボールを (x_byte, y_line) に color で描く (= 内蔵丸 glyph の RMW、
 * 透明部は背景を残す)。 BREAK キーで投げるボール用。 */
void          sub_draw_ball(unsigned char x_byte, unsigned char y_line,
                            unsigned char color);
/* 8x8 領域の R/G をクリアしてボールを消す (背景タイルは B plane に残る)。 */
void          sub_erase_ball(unsigned char x_byte, unsigned char y_line);

void          kb_init(void);
unsigned char key_check(void);
/* BREAK キー: 押下中なら 1、 でなければ 0 ($FD04 bit1 ポーリング、 active-low)。 */
unsigned char break_check(void);
/* パレット ($FD38-$FD3F) を設定: 色1=青(背景)、 2/3=赤、 4/5=シアン、 6/7=白。
 * 前景を R/G plane だけで 3 色描くための要 (= 起動時 1 回呼ぶ)。 */
void          palette_init(void);

/* フレームペーシング (= deadline 方式)。 メイン CPU の周期タイマ IRQ (約2ms、
 * $FD02/$FD03 bit2) を IRQ ハンドラで数える経過 tick カウンタ。
 *   timer_init():  起動時 1 回。 IRQ ベクタ設置 + タイマ IRQ 許可 (FIRQ は
 *                  マスクのまま = BREAK と干渉しない)。
 *   timer_start(): 経過カウンタを 0 に戻す (= フレーム開始の起点)。
 *   timer_get():   timer_start() からの経過 tick (16-bit、 1 tick ≈ 2ms)。
 *   メインループ先頭で「timer_get() が FRAME_TARGET に達するまでロックして
 *   timer_start()」 とすると、 処理の重い/軽いに関わらず 1 フレームが
 *   FRAME_TARGET × 2ms に揃う (= IRQ は処理中も数えるので取りこぼし無し)。
 *   仕組み詳細は docs/TIMER.md。 */
void          timer_init(void);
void          timer_start(void);
unsigned      timer_get(void);

#endif
