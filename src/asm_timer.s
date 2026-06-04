* ============================================================
* asm_timer.s — メイン CPU の周期タイマ IRQ (約2ms) を数える
*               「経過 tick カウンタ」フレームペーシング (deadline 方式)
*
* 【設計】 deadline 方式:
*   - FM-7 メイン 6809 には約 2ms 周期 (≈491Hz) のタイマ IRQ がある
*     (要因フラグ $FD03 bit2、 許可は $FD02 bit2)。 これを IRQ ハンドラ
*     _irq_isr で数え、 16-bit カウンタ frame_tick を ++ する (= 自走する
*     経過 tick カウンタ。 1 tick ≈ 2ms)。
*   - メインループは「timer_start() で frame_tick を 0 に戻し、 timer_get()
*     が FRAME_TARGET に達するまでロック」 するだけ。 処理が重くても軽くても
*     1 フレームの実時間が FRAME_TARGET × 2ms に揃う (= IRQ は処理中も数え
*     続けるので、 ポーリングのような取りこぼしが無い)。
*
* 【なぜ IRQ か (FIRQ でなく)】
*   $FD04 bit1 の BREAK は FIRQ 要因。 前にアテンションを FIRQ で数えようと
*   して FIRQ を許可したら、 BREAK 押下中ずっと FIRQ が再発火してメインループ
*   が餓死した。 メインタイマは IRQ 要因 ($FD02/$FD03 bit2) なので、 IRQ だけ
*   許可し FIRQ はマスクのままにすれば、 BREAK と干渉しない (BREAK は従来どおり
*   break_check() が $FD04 bit1 をポーリング)。
*
* C API (c_subprog.h):
*   void     timer_init(void)   起動時 1 回。 IRQ ベクタ設置 + タイマ IRQ 許可。
*   void     timer_start(void)  経過カウンタ frame_tick を 0 に戻す。
*   unsigned timer_get(void)    timer_start() からの経過 tick (16-bit、 1≈2ms)。
* ペーシングはメインループ先頭で
*     while (timer_get() < FRAME_TARGET) {}   timer_start();
* と書く (= c_main 側。 ハング防止の安全キャップ付き)。
*
* ※ 機種依存 (実機/エミュで要検証):
*   ・IRQ ベクタ $FFF8 は IPL が RAM モード ($FD0F write) にして以降 RAM。
*   ・タイマ IRQ フラグ $FD03 bit2 は active-low (0=発生)。 $FD03 read で
*     ack される前提 (= クリアされないと IRQ が再発火し続ける)。
*   ・キーボード IRQ ($FD02 bit0) は使わず無効化する (= キー入力はポーリング)。
*   詳細は docs/TIMER.md。
* ============================================================

IO_IRQFLAG      equ     $FD03           * R: IRQ 要因 (active-low。 bit2=タイマ, bit0=キーボード)
IO_IRQMASK      equ     $FD02           * W: IRQ 許可 (bit2=タイマ, bit0=キーボード)
IO_KEYDATA      equ     $FD01           * R: キーコード (= read でキーボード IRQ を ack)
TIMER_BIT       equ     $04             * $FD03/$FD02 bit2 = タイマ
KBD_BIT         equ     $01             * $FD03/$FD02 bit0 = キーボード
IRQ_VECTOR      equ     $FFF8           * 6809 IRQ ベクタ (RAM モードで RAM)

                section code

                export  _timer_init
                export  _timer_start
                export  _timer_get
                import  _kbd_buf        * asm_kbd.s 側の bss (IRQ ハンドラが書く)


* void timer_init(void) — IRQ ベクタを設置し、 タイマ IRQ を許可する (起動時 1 回)。
*   キーボード IRQ (bit0) は立てない (= キー入力はポーリングのため)。
_timer_init:
                ldd     #_irq_isr
                std     IRQ_VECTOR      * $FFF8/$FFF9 に handler 番地
                lda     #TIMER_BIT+KBD_BIT  * bit2=タイマ + bit0=キーボード IRQ 許可
                sta     IO_IRQMASK
                andcc   #$EF            * I フラグ解除 = IRQ 許可 (F は立てたまま)
                rts


* void timer_start(void) — 経過 tick カウンタを 0 に戻す。
_timer_start:
                clr     frame_tick
                clr     frame_tick+1
                rts


* unsigned timer_get(void) — 経過 tick (16-bit) を D で返す。
*   IRQ が ++ 途中に割込む torn read はペーシングでは実害小なので許容。
_timer_get:
                ldd     frame_tick
                rts


* --- メイン IRQ ハンドラ (タイマ + キーボード) ---
*   IRQ は全レジスタを自動 push する (E=1) ので、 A/B/CC を自由に使って RTI で
*   復帰できる。 $FD03 を 1 回読み (= タイマ ack)、 タイマ(bit2)なら frame_tick++、
*   キーボード(bit0)なら $FD01 を読んで (= キーボード ack) _kbd_buf に格納する。
_irq_isr:
                lda     IO_IRQFLAG      * $FD03 read (= 要因判別 + タイマ ack)
                bita    #TIMER_BIT
                bne     .chk_kbd        * bit2=1 → タイマでない
                inc     frame_tick+1    * 16-bit ++ (下位)
                bne     .chk_kbd
                inc     frame_tick      * 桁上げ (上位)
.chk_kbd:
                bita    #KBD_BIT        * A はまだ $FD03 の値 (inc は A を壊さない)
                bne     .ii_done        * bit0=1 → キーボードでない
                ldb     IO_KEYDATA      * $FD01 read (= キーボード ack、 B=キーコード)
                cmpb    #$FF
                beq     .ii_done        * バス浮き ($FF) は無視
                stb     _kbd_buf        * 直近キーを格納 (key_check が取り出す)
.ii_done:
                rti


                section bss
frame_tick      rmb     2               * 16-bit 経過 tick (IRQ が ++、 1≈2ms)

                end
