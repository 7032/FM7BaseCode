/* ============================================================
 * c_subprog.c — サブ独自描画プログラムへの C 側 wrapper
 *
 * 全関数共通の流れ:
 *   1. sub_halt()                    // sub を HALT (= 共有 RAM 書込許可)
 *   2. SUB_CMD_REG[0..N] = (cmd, パラメータ...)
 *   3. sub_call(SUB_PROG_ADDR)       // sub に $C300 を JSR させる
 *
 * 仕組み:
 *   sub_call は内部で:
 *     - sub_halt (= 上の 1 と冪等)
 *     - TEST cmd 列 ($FC80-$FC8E) を build
 *     - release で sub を動かす → TEST コマンド処理 が CALL $C300 を実行
 *     - wait_ready で sub の動作再開を確認
 *   sub 側で $C300 entry が動き、 SUB_CMD_REG ($D393) を見て対応する
 *   handler に分岐 → 描画 → handler 末尾で clr CMD_REG → rts。
 *
 * 注意:
 *   - SUB_CMD_REG への write は HALT 中 (= 1 と sub_call 内 halt の間)
 *     にしか反映されない (実機準拠仕様)。 順序を守ること。
 *   - sub_release を 1 と sub_call の間に挟まない (= 挟むと sub が前回
 *     の TEST cmd 残骸で動いてしまう race の元)。
 *
 * 詳細は docs/SUBPROGRAM.md §4。
 * ============================================================ */

#include "c_subprog.h"

/* sub プログラム本体 (= bin2asm.py で asm_subprog.s から生成された rodata 配列)。
 * extern 宣言だけして実体は assets/src/subprog_data.s。 */
extern const unsigned char subprog_bin[];
extern const unsigned int  subprog_len;

/* sprite データ (= sprite_to_asm.py で character.png から生成、
 * 16 sprite × 256 byte = 4096 byte)。 実体は assets/src/sprite_data.s。 */
extern const unsigned char sprite_data[];
extern const unsigned int  sprite_data_len;

/* 8x8 bitmap font (= ASCII 0x20-0x7F の 96 char × 8 byte)。
 * char c の glyph head = font_data + (c - 0x20) * 8。 実体は font_data.s。 */
extern const unsigned char font_data[];

/* 背景タイル (64x64 モノクロ = B plane 512 byte)。 実体は bgtile_data.s。 */
extern const unsigned char bgtile_data[];


/* ----- 起動時の一度きり初期化 ------------------------------------ */

void subprog_init(void)
{
    /* CMD_REG を NOP に設定してから subprog を sub の $C300 に転送し、
     * sub_call($C300) で起動する (= 起動直後 entry は cmd=NOP を見て
     * done → rts するだけ、 起動チェック用)。 */
    SUB_CMD_REG[0] = SUBCMD_NOP;
    sub_takeover(subprog_bin, subprog_len, SUB_PROG_ADDR, SUB_PROG_ADDR);
}

void sub_load_dir_frames(unsigned char dir_index)
{
    /* sprite_data は dir-major (= dir 0 の frame 0..3、 dir 1 の...) で
     * 16 sprite 並ぶ。 そのうち指定方向の 4 frame (= 連続 1024 byte) を
     * sub の $C700 に転送 (exec=0 で CALL skip = 転送のみ)。
     *
     * 転送後、 sub から見ると $C700 + frame*256 が frame f の sprite に
     * なるので、 sub_move_sprite / sub_blit_sprite の sprite_id 引数に
     * そのまま frame index (0..3) を渡せばよい。 */
    const unsigned char *src = &sprite_data[(unsigned int)dir_index
                                            * FRAMES_PER_DIR * SPRITE_BYTES];
    sub_takeover(src, FRAMES_PER_DIR * SPRITE_BYTES, SUB_CHARS_ADDR, 0);
}


/* ----- 描画 cmd (= 各関数とも 1 回 sub_call で 1 cmd 実行) ------- */

/* 1 cell (= 8x8 px) を単色塗り。 color は FM-7 デジタル RGB の bit
 * (bit0=B, bit1=R, bit2=G)。 例: 1=BLUE, 4=GREEN, 7=WHITE。 */
void sub_put_cell(unsigned char x_byte, unsigned char y_line, unsigned char color)
{
    sub_halt();
    SUB_CMD_REG[0] = SUBCMD_PUT_CELL;
    SUB_CMD_REG[1] = x_byte;
    SUB_CMD_REG[2] = y_line;
    SUB_CMD_REG[3] = color;
    sub_call(SUB_PROG_ADDR);
}

/* 1 cell (= 8x8 px) を BLACK で塗潰し。 PUT_CELL の color=0 と等価。 */
void sub_clr_cell(unsigned char x_byte, unsigned char y_line)
{
    sub_halt();
    SUB_CMD_REG[0] = SUBCMD_CLR_CELL;
    SUB_CMD_REG[1] = x_byte;
    SUB_CMD_REG[2] = y_line;
    sub_call(SUB_PROG_ADDR);
}

/* VRAM 全 plane (= 48 KB) を $00 で clear。 起動時 1 回呼ぶ想定 (=
 * サブシステム ROM 起動メッセージを完全消去するため)。 192ms かかる。 */
void sub_cls(void)
{
    sub_halt();
    SUB_CMD_REG[0] = SUBCMD_CLS;
    sub_call(SUB_PROG_ADDR);
}

/* 背景タイル (64x64 = 512 byte) を sub の $CB00 に転送 (= 純データ転送)。 */
void sub_load_bgtile(void)
{
    sub_takeover(bgtile_data, 512, SUB_BGTILE_ADDR, 0);
}

/* 背景を 64x64 タイル模様で全画面に敷く。 B plane にタイル (青/黒)、
 * R/G は 0。 前景の透明部 (R=G=0) はこの背景模様が透ける。
 * 事前に sub_load_bgtile が必要。 */
void sub_draw_bg(void)
{
    sub_halt();
    SUB_CMD_REG[0] = SUBCMD_DRAW_BG;
    sub_call(SUB_PROG_ADDR);
}

/* 32x32 sprite (= sprite_id 0-3) を (x_byte, y_line) を左上に bitmap
 * 描画。 3 plane (B/R/G) 全部に書込む (= 透明部分は黒で塗潰し)。 */
void sub_blit_sprite(unsigned char sprite_id,
                     unsigned char x_byte, unsigned char y_line)
{
    sub_halt();
    SUB_CMD_REG[0] = SUBCMD_BLIT;
    SUB_CMD_REG[1] = x_byte;
    SUB_CMD_REG[2] = y_line;
    SUB_CMD_REG[3] = sprite_id;
    sub_call(SUB_PROG_ADDR);
}

/* 32x32 領域を 3 plane とも BLACK で塗潰し (= sub_blit_sprite の取消)。 */
void sub_erase_box(unsigned char x_byte, unsigned char y_line)
{
    sub_halt();
    SUB_CMD_REG[0] = SUBCMD_ERASE_BOX;
    SUB_CMD_REG[1] = x_byte;
    SUB_CMD_REG[2] = y_line;
    sub_call(SUB_PROG_ADDR);
}

/* sprite を (old_x, old_y) から (new_x, new_y) に atomic 移動。
 * sub 側で「旧位置 erase → 新位置 blit」 を連続実行 + 描画前に VBlank
 * タイミング待ちを入れるので、 別々に呼ぶよりちらつきが少ない。 */
void sub_move_sprite(unsigned char sprite_id,
                     unsigned char old_x, unsigned char old_y,
                     unsigned char new_x, unsigned char new_y)
{
    sub_halt();
    SUB_CMD_REG[0] = SUBCMD_MOVE;
    SUB_CMD_REG[1] = old_x;
    SUB_CMD_REG[2] = old_y;
    SUB_CMD_REG[3] = new_x;
    SUB_CMD_REG[4] = new_y;
    SUB_CMD_REG[5] = sprite_id;
    sub_call(SUB_PROG_ADDR);
}

/* 1 文字 (8x8 glyph) を (col, row) に color で描く内部 helper。
 * glyph の 8 byte を共有 RAM に積んで DRAW_CHAR cmd を発行する。 */
static void draw_glyph(unsigned char col, unsigned char row,
                       const unsigned char *glyph, unsigned char color)
{
    unsigned char i;
    sub_halt();
    SUB_CMD_REG[0] = SUBCMD_DRAW_CHAR;
    SUB_CMD_REG[1] = col;
    SUB_CMD_REG[2] = row;
    SUB_CMD_REG[3] = color;
    for (i = 0; i < 8; i++) {
        SUB_CMD_REG[4 + i] = glyph[i];   /* glyph → $D397-$D39E */
    }
    sub_call(SUB_PROG_ADDR);
}

/* 8x8 の丸ボールを 1 個描画 (= 内蔵丸 glyph を color で RMW 描画)。 */
void sub_draw_ball(unsigned char x_byte, unsigned char y_line, unsigned char color)
{
    sub_halt();
    SUB_CMD_REG[0] = SUBCMD_DRAW_BALL;
    SUB_CMD_REG[1] = x_byte;
    SUB_CMD_REG[2] = y_line;
    SUB_CMD_REG[3] = color;
    sub_call(SUB_PROG_ADDR);
}

/* 8x8 領域の R/G をクリアしてボールを消す (背景タイルは B plane に残る)。 */
void sub_erase_ball(unsigned char x_byte, unsigned char y_line)
{
    sub_halt();
    SUB_CMD_REG[0] = SUBCMD_ERASE_BALL;
    SUB_CMD_REG[1] = x_byte;
    SUB_CMD_REG[2] = y_line;
    sub_call(SUB_PROG_ADDR);
}

/* テキスト表示。 文字列を 1 文字ずつ、 同梱 font の glyph を取り出して
 * sub に描かせる。 font は sub に常駐させず、 char ごとに 8 byte を
 * 共有 RAM 経由で送るだけなので軽い。
 *   col は 1 文字進むごとに +1 (= 8px 単位)。 改行などの制御はしない
 *   (= SCORE 表示のような短い 1 行用途を想定)。 */
void sub_draw_text(unsigned char col, unsigned char row,
                   const char *str, unsigned char color)
{
    while (*str) {
        unsigned char c = (unsigned char)*str;
        unsigned idx;                         /* 16bit (×8 で 256 を超えるため) */
        if (c < 0x20 || c > 0x7F) c = 0x20;   /* 範囲外は空白に */
        idx = (unsigned char)(c - 0x20);
        draw_glyph(col, row, &font_data[idx * 8], color);
        col++;
        str++;
    }
}
