* ============================================================
* asm_subprog.s — サブ CPU 上で動く独自描画プログラム (2 plane 前景方式)
*
* main から TEST MOVE で sub の $C300 に転送され、 sub_call($C300) で
* 実行される。 1 回の呼び出しで「共有 RAM のコマンドコードを見て 1 つ
* だけ処理し、 RTS で main に戻る」 設計。
*
* sub CPU memory layout:
*   $0000-$3FFF : VRAM B plane (= 背景の単色青。 $FF 固定、 前景は触らない)
*   $4000-$7FFF : VRAM R plane (= 前景の赤成分)
*   $8000-$BFFF : VRAM G plane (= 前景の G 成分。 表示上はシアン)
*   $C200-$C2FF : subprog 作業変数 (= コード領域外の安全な RAM)
*   $C300-$C6FF : subprog コード本体
*   $C700-$CAFF : sprite データ (= 現在方向 4 frame × 256 byte 常駐)
*   $D380-$D3FF : 共有 RAM (= main $FC80-$FCFF と mapped)
*
* 配色方式 (= 2 plane 前景):
*   背景は B plane 単体 (色番号 1 = パレットで青)。 前景は R/G plane だけ
*   使い、 パレットを 2/3=赤・4/5=シアン・6/7=白 と二重化してあるので B の
*   有無に関わらず R/G の組合せだけで前景色が決まる:
*     R=0,G=0 透明 (背景の青) / R=1 赤 / G=1 シアン / R+G 白
*   sprite/glyph/ball 描画は R/G plane への単純な上書き (store) で行う。
*   透明 (src_R=src_G=0) pixel は R/G に 0 が入るが、 背景は B plane に分離
*   してある (= R/G とは独立) ので、 そこは B の青がそのまま透ける。 つまり
*   透過は「B plane を触らないこと」で成立し、 OR/RMW は不要 (= 前景は毎回
*   セルごと置換するので前の文字/弾/キャラの残像も自動で消える)。
*   消去は R/G を 0 クリアするだけ (= B の青が残る。 退避バッファ不要)。
*
* 前景 color コード (= cmd パラメータ): bit0=R, bit1=G
*   0 透明 / 1 赤 / 2 シアン / 3 白
*
* 通信プロトコル (= sub 側 $D393 から):
*   $D393 : CMD code
*     $00 NOP / $01 PUT_CELL / $02 CLR_CELL / $03 CLS
*     $04 BLIT_SPRITE / $05 ERASE_BOX / $06 MOVE_SPRITE / $07 DRAW_BG
*     $08 DRAW_CHAR / $09 DRAW_BALL / $0A ERASE_BALL
*   $D394+: cmd 別パラメータ
*
* 自己破壊注意: subprog コード領域 ($C300+) に書込むマーカーは禁止。
* ============================================================

CMD_REG         equ     $D393
PARAM           equ     $D394
VRAM_GATE       equ     $D409

* sub 表示ステータス ($D430、 FM77AV のみ有効、 FM-7 では無効)
SUB_STATUS      equ     $D430
VBLANK_TIMEOUT  equ     8000

VRAM_LINE_BYTES equ     80
VRAM_B_BASE     equ     $0000
VRAM_R_BASE     equ     $4000
VRAM_G_BASE     equ     $8000

* 作業変数 (= subprog コード領域外の RAM)
TMP_MASK        equ     $C201           * glyph/blit の mask byte 一時保存
BG_LINECNT      equ     $C203           * bg_fill_box の残り line 数
DC_LINECNT      equ     $C204           * glyph 描画の残り line 数
BG_LINE         equ     $C205           * do_draw_bg の現在 line (0-199)

* sprite データ配置先 ($C700、 = SUB_CHARS_ADDR と一致)。
* 1 sprite = [R 128][G 128] = 256 byte (= 2 plane 前景方式)。
*   R=0,G=0 透明 / R=1 赤 / G=1 シアン / R+G 白。 B plane は背景の単色青
*   ($FF) のまま触らない。
* ※ subprog コードが伸びた時はここを後ろへ動かす ($C300+size を超えない値、
*   かつ sprite 4 frame = 1024 byte が $D000 手前に収まること)。
SPRITE_BASE     equ     $C700
SPRITE_H_LINES  equ     32
SPRITE_PLANE    equ     128             * 1 plane の byte 数 (R/G 各)

* 背景タイル (64x64 モノクロ = B plane 512 byte) の配置先。 sprite 4 frame
* ($C700-$CAFF) の直後 $CB00。 $CB00+512=$CD00 (= $D000 手前で安全)。
* main が起動時に sub_load_bgtile で転送する (= SUB_BGTILE_ADDR と一致)。
BG_TILE         equ     $CB00
BG_TILE_W       equ     8               * 64px / 8 = 8 byte/line
BG_TILE_H       equ     64              * 64 line 周期

                org     $C300

* ---- エントリ (sub_call($C300) で呼ばれる) ----
                lda     VRAM_GATE       * VRAM gate OPEN (read で開く)
                lda     CMD_REG
                beq     done            * $00 NOP
                cmpa    #$01
                lbeq    do_put_cell
                cmpa    #$02
                lbeq    do_clr_cell
                cmpa    #$03
                lbeq    do_cls
                cmpa    #$04
                lbeq    do_blit_sprite
                cmpa    #$05
                lbeq    do_erase_box
                cmpa    #$06
                lbeq    do_move_sprite
                cmpa    #$07
                lbeq    do_draw_bg
                cmpa    #$08
                lbeq    do_draw_char
                cmpa    #$09
                lbeq    do_draw_ball
                cmpa    #$0A
                lbeq    do_erase_ball
done:
                rts


* ============================================================
* $01 PUT_CELL — 8x8 px cell を前景単色で塗る (R/G plane)
*   $D394 = x_byte, $D395 = y_line, $D396 = color (0-3: bit0=R, bit1=G)
*   B plane (背景の青) は触らない。
* ============================================================
do_put_cell:
                ldb     PARAM+1
                lda     #VRAM_LINE_BYTES
                mul
                addb    PARAM
                adca    #0
                tfr     d,x
                ldb     PARAM+2         * color
                clra                    * A = R 値 ($00/$FF)
                bitb    #$01
                beq     .pc_nr
                lda     #$FF
.pc_nr:         pshs    a
                clra                    * A = G 値
                bitb    #$02
                beq     .pc_ng
                lda     #$FF
.pc_ng:         pshs    a
                ldb     #8
.pc_line:
                lda     1,s             * R
                sta     VRAM_R_BASE,x
                lda     ,s              * G
                sta     VRAM_G_BASE,x
                leax    VRAM_LINE_BYTES,x
                decb
                bne     .pc_line
                leas    2,s
                clr     CMD_REG
                rts


* ============================================================
* $02 CLR_CELL — 8x8 px cell の R/G を 0 クリア (= 背景の青に戻す)
*   $D394 = x_byte, $D395 = y_line
* ============================================================
do_clr_cell:
                ldb     PARAM+1
                lda     #VRAM_LINE_BYTES
                mul
                addb    PARAM
                adca    #0
                tfr     d,x
                ldb     #8
.cc_line:
                clr     VRAM_R_BASE,x
                clr     VRAM_G_BASE,x
                leax    VRAM_LINE_BYTES,x
                decb
                bne     .cc_line
                clr     CMD_REG
                rts


* ============================================================
* $03 CLS — VRAM 全 plane を $00 clear (48 KB)
*   ※ 背景の青も消えるので、 通常は直後に DRAW_BG で塗り直す。
* ============================================================
do_cls:
                ldx     #VRAM_B_BASE
                ldd     #$C000
.cls_loop:
                clr     ,x+
                subd    #1
                bne     .cls_loop
                clr     CMD_REG
                rts


* ============================================================
* $04 BLIT_SPRITE — 32x32 sprite を上書き (store) で描画 (R/G 2 plane)
*   $D394 = x_byte, $D395 = y_line, $D396 = sprite_id
* ============================================================
do_blit_sprite:
                ldb     PARAM+2         * sprite_id
                lbsr    sprite_src      * Y = sprite source (R plane 先頭)
                ldu     #PARAM          * U → (x, y)
                lbsr    mask_blit_2plane
                clr     CMD_REG
                rts


* ============================================================
* $05 ERASE_BOX — 32x32 領域の R/G を 0 クリアして sprite を消す
*   $D394 = x_byte, $D395 = y_line
* ============================================================
do_erase_box:
                ldu     #PARAM          * U → (x, y)
                lbsr    bg_fill_box
                clr     CMD_REG
                rts


* ============================================================
* $06 MOVE_SPRITE — 旧位置を消す + 新位置に sprite を描く (atomic)
*   $D394 = old_x, $D395 = old_y
*   $D396 = new_x, $D397 = new_y
*   $D398 = sprite_id
*
* ※ VBlank 待ちはここでは行わない。 FM-7 は main から VSYNC を取れない
*   ため (= サブ $D430 / $FD12 は FM77AV 以降のみ有効)、 周期の安定化は
*   main 側のフレームペーシング (= サブの 20ms タイマアテンションを FIRQ で
*   数える経過 tick の deadline 方式。 asm_timer.s) で行う。 移動中/停止中で
*   待ちがばらつかないよう一本化 (詳細は asm_timer.s / docs/TIMER.md)。
* ============================================================
do_move_sprite:
                ldu     #PARAM          * U → old (x, y)
                lbsr    bg_fill_box     * 旧位置の R/G を 0 クリア
                ldb     PARAM+4         * sprite_id
                lbsr    sprite_src
                ldu     #PARAM+2        * U → new (x, y)
                lbsr    mask_blit_2plane
                clr     CMD_REG
                rts


* ============================================================
* $07 DRAW_BG — 背景タイル (青/黒) を全画面に敷く
*   背景は B plane 単体: B=1 の pixel は色番号 1 (= パレットで青)。
*   R/G plane は 0 にしておく (= 前景は R/G だけ使い、 R=G=0 が背景透過)。
*   塗るのは表示領域 200 line × 80 byte = $3E80 byte。
* ============================================================
do_draw_bg:
                * --- R/G plane を 0 クリア ($4000-$BFFF = 32 KB) ---
                ldx     #VRAM_R_BASE
                ldd     #$8000          * 32768 byte (clr は D 不変)
.bg_clrrg:
                clr     ,x+
                subd    #1
                bne     .bg_clrrg

                * --- B plane に 64x64 タイルを敷く (200 line × 80 byte) ---
                ldx     #VRAM_B_BASE    * X = B plane write ptr
                clr     BG_LINE         * line = 0
.bg_oline:
                * U = BG_TILE + (line & 63) * 8  (= タイルの該当行 8 byte)
                lda     BG_LINE
                anda    #BG_TILE_H-1    * line & 63
                ldb     #BG_TILE_W      * × 8
                mul                     * D = tile_line * 8
                addd    #BG_TILE
                tfr     d,u             * U → タイル行 (8 byte)
                * 1 line = 80 byte = タイル幅 8 byte を 10 回
                ldb     #10             * 10 タイル/line
.bg_ocol:
                lda     0,u
                sta     ,x+
                lda     1,u
                sta     ,x+
                lda     2,u
                sta     ,x+
                lda     3,u
                sta     ,x+
                lda     4,u
                sta     ,x+
                lda     5,u
                sta     ,x+
                lda     6,u
                sta     ,x+
                lda     7,u
                sta     ,x+
                decb
                bne     .bg_ocol
                inc     BG_LINE
                lda     BG_LINE
                cmpa    #200
                bne     .bg_oline
                clr     CMD_REG
                rts


* ============================================================
* $08 DRAW_CHAR — 8x8 文字 (glyph) を 1 文字描画 (R/G 2 plane)
*   $D394 = x_byte, $D395 = y_line
*   $D396 = color (bit0=R, bit1=G)、 $D397-$D39E = glyph 8 byte
* ============================================================
do_draw_char:
                ldb     PARAM+1         * y_line
                lda     #VRAM_LINE_BYTES
                mul
                addb    PARAM
                adca    #0
                tfr     d,x
                ldy     #PARAM+3        * Y → glyph
                lda     #8
                sta     DC_LINECNT
                bra     glyph_rg_loop   * 共通 glyph 描画へ (Y=glyph, X=VRAM)


* ============================================================
* $09 DRAW_BALL — 8x8 の丸ボールを 1 個描画 (R/G 2 plane)
*   $D394 = x_byte, $D395 = y_line, $D396 = color (bit0=R, bit1=G)
*   glyph は内蔵 BALL_GLYPH。
* ============================================================
do_draw_ball:
                ldb     PARAM+1
                lda     #VRAM_LINE_BYTES
                mul
                addb    PARAM
                adca    #0
                tfr     d,x
                ldy     #BALL_GLYPH     * Y → 丸 glyph
                lda     #8
                sta     DC_LINECNT
                * fall through to glyph_rg_loop

* --- 共通: 8 line の glyph を R/G plane へ上書き (store) 描画 ---
*   X = VRAM offset、 Y = glyph 先頭、 DC_LINECNT = 8、 PARAM+2 = color。
*   各 plane に「選択色なら glyph bit、 でなければ 0」を毎 line ストアする。
*   セル全体を毎回置換するので前の文字/弾の残像は自動で消える (= OR/RMW や
*   別途クリア不要)。 隙間 (g=0) は R/G=0 になり B plane の背景が透ける。
*   color bit0 → R plane、 bit1 → G plane。
glyph_rg_loop:
                lda     ,y+             * g (= この line の glyph bits)
                sta     TMP_MASK
                * --- R plane: color bit0 が立っていれば g、 でなければ 0 ---
                ldb     PARAM+2
                bitb    #$01
                beq     .gc_r0
                lda     TMP_MASK
                bra     .gc_rw
.gc_r0:
                clra
.gc_rw:
                sta     VRAM_R_BASE,x
                * --- G plane: color bit1 が立っていれば g、 でなければ 0 ---
                ldb     PARAM+2
                bitb    #$02
                beq     .gc_g0
                lda     TMP_MASK
                bra     .gc_gw
.gc_g0:
                clra
.gc_gw:
                sta     VRAM_G_BASE,x
                leax    VRAM_LINE_BYTES,x
                dec     DC_LINECNT
                bne     glyph_rg_loop
                clr     CMD_REG
                rts


* ============================================================
* $0A ERASE_BALL — 8x8 領域の R/G を 0 クリアしてボールを消す
*   $D394 = x_byte, $D395 = y_line
* ============================================================
do_erase_ball:
                ldb     PARAM+1
                lda     #VRAM_LINE_BYTES
                mul
                addb    PARAM
                adca    #0
                tfr     d,x
                ldb     #8
.eb_line:
                clr     VRAM_R_BASE,x
                clr     VRAM_G_BASE,x
                leax    VRAM_LINE_BYTES,x
                decb
                bne     .eb_line
                clr     CMD_REG
                rts


* ============================================================
* 共通サブルーチン
* ============================================================

* 丸ボールの 8x8 glyph (= 立った bit を描く。 MSB が左 px)。
BALL_GLYPH:
                fcb     $3C,$7E,$FF,$FF,$FF,$FF,$7E,$3C

* bg_fill_box — U → (x,y)。 32x32 領域の R/G plane を 0 クリアして sprite を
*   消す。 B plane (= 背景タイル) はそのまま残すので、 消した跡は自然に背景
*   タイルが戻る (= 背景の塗り直しも退避バッファも不要)。
bg_fill_box:
                lbsr    calc_vbase_u    * X = VRAM offset (B 基準)
                ldb     #SPRITE_H_LINES
                stb     BG_LINECNT
.fbl:
                clr     VRAM_R_BASE,x
                clr     VRAM_G_BASE,x
                clr     VRAM_R_BASE+1,x
                clr     VRAM_G_BASE+1,x
                clr     VRAM_R_BASE+2,x
                clr     VRAM_G_BASE+2,x
                clr     VRAM_R_BASE+3,x
                clr     VRAM_G_BASE+3,x
                leax    VRAM_LINE_BYTES,x
                dec     BG_LINECNT
                bne     .fbl
                rts

* wait_vblank — $D430 bit7 が 0 になるまで待つ (FM77AV 専用、 timeout 付き)。
*   FM-7 では即抜けるので、 周期安定化は main 側フレームペーシングで行う。
wait_vblank:
                pshs    x
                ldx     #VBLANK_TIMEOUT
.wv:
                lda     SUB_STATUS
                bita    #$80
                beq     .wv_done
                leax    -1,x
                bne     .wv
.wv_done:
                puls    x,pc

* sprite_src — B = sprite_id (0-3) → Y = SPRITE_BASE + id*256
*   1 sprite = R(128)+G(128) = 256 byte。
sprite_src:
                lda     #SPRITE_PLANE   * 128
                mul                     * D = id*128
                lslb
                rola                    * D = id*256
                addd    #SPRITE_BASE
                tfr     d,y
                rts

* calc_vbase_u — U → [x_byte, y_line] から X = y_line*80 + x_byte。
calc_vbase_u:
                ldb     1,u
                lda     #VRAM_LINE_BYTES
                mul
                addb    ,u
                adca    #0
                tfr     d,x
                rts

* mask_blit_2plane — U → (x,y)、 Y → sprite source (R plane 先頭)。
*   32 line × 4 byte/line を R/G 2 plane へ上書き (store) で描く。
mask_blit_2plane:
                lbsr    calc_vbase_u
                ldb     #SPRITE_H_LINES
.mbl_line:
                pshs    b
                lbsr    mask_blit_byte
                lbsr    mask_blit_byte
                lbsr    mask_blit_byte
                lbsr    mask_blit_byte
                leax    VRAM_LINE_BYTES-4,x
                puls    b
                decb
                bne     .mbl_line
                rts

* mask_blit_byte — X=VRAM offset、 Y=sprite R byte。 R/G 2 plane を上書き + X/Y +1。
*   sprite layout [R][G]、 128 byte 離れ。 B plane (背景の青) は触らない。
*   src_R / src_G を素直に store する (= OR/mask 不要):
*     vram_R = src_R / vram_G = src_G
*   透明 (src_R=src_G=0) pixel は R/G=0 になるが、 背景は B plane が保持して
*   いるので透ける (= 重ね合成しないので前景は常に最後に描いたものが残る)。
mask_blit_byte:
                lda     ,y              * src_R
                sta     VRAM_R_BASE,x
                lda     SPRITE_PLANE,y  * src_G
                sta     VRAM_G_BASE,x
                leax    1,x
                leay    1,y
                rts

                end
