* ============================================================
* asm_test.s — main から「TEST コマンド」 経由でサブ
*                  CPU にプログラム転送 + 実行する API
*
* TEST cmd は サブシステム ROM の 拡張コマンド領域の CMD $3F
* にある TEST/DEBUG 機能。 共有 RAM にキーワード列とサブコマンド
* ($91 MOVE / $93 CALL / $90 END) を並べて発火すると、 sub の
* workspace 上で memory copy や任意番地 JSR を実行してくれる。
*
* 本テンプレでは:
*   - 自前の sub プログラム (= asm_subprog.s) を sub の $C300 に転送
*   - sprite データを sub の $C500 に転送
*   - sub_call($C300) で sub プログラムを 1 回起動 (= 共有 RAM の cmd
*     を見て 1 つ処理して RTS)
* という用途で使う。
*
* 共有 RAM レイアウト (main 側):
*   $FC80    : $00          ; 未使用
*   $FC81    : $00          ; 未使用
*   $FC82    : $3F          ; TEST コマンド
*   $FC83-$FC8A: 8B 0       ; キーワード (FM-7 では照合しないが配置必須)
*   $FC8B    : サブコマンド ; $91=MOVE / $93=CALL / $90=END
*   $FC8C+   : サブコマンド パラメータ
*     MOVE   : src(2) + dst(2) + len(2) + END
*     CALL   : addr(2) + END
*
* HALT プロトコル:
*   1. HALT 要求 ($FD05=$80)
*   2. wait BUSY ($FD05 bit7=1) ← 省略不可 (省くと write 反映されない)
*   3. 共有 RAM に TEST cmd 列を書込
*   4. RELEASE ($FD05=$00) で sub 実行開始
*
* 詳細 + 罠集は docs/SUBPROGRAM.md。
* ============================================================

IO_SUBCTRL      equ     $FD05
SHARED_RAM      equ     $FC80
SHARED_SUB      equ     $D3A0           * sub 側から見た $FCA0 (= 共有 RAM 後半)

                section code

                export  _sub_wait_ready
                export  _sub_halt
                export  _sub_release
                export  _sub_call
                export  _sub_takeover


* void sub_wait_ready(void) — $FD05 bit7=0 まで待つ
*
* 注意: これは「sub が HALT 中でも BUSY 中でもない (= 動いてる)」
* 状態を待つだけで、 「cmd handler が完了した」 ことの保証ではない。
* 実機準拠仕様: $FD05 = (_subHalted || _subBusy) ? $FE : $7E
* sub が一旦動き始めれば即抜けるので、 cmd 実行中でも main は次へ進む。
_sub_wait_ready:
                lda     IO_SUBCTRL
                bmi     _sub_wait_ready
                rts

* void sub_halt(void) — HALT 要求 → BUSY=1 待ち (= HALT 完了確認)
*   wait READY (= 旧 bmi loop) は省略。 実機 HALT は要求即発行で安全、
*   かつ実機準拠エミュの _subBusy=true 残留と race して永久
*   hang する事象を避けるため。
_sub_halt:
                lda     #$80
                sta     IO_SUBCTRL
.bw:            lda     IO_SUBCTRL
                bpl     .bw
                rts

* void sub_release(void) — HALT 解除
_sub_release:
                clr     IO_SUBCTRL
                rts


* ---- TEST cmd ヘッダを $FC80 に書き、 X = $FC8B (subcmd 先) を返す
.build_header:
                ldx     #SHARED_RAM
                clr     ,x+             * $FC80
                clr     ,x+             * $FC81
                lda     #$3F
                sta     ,x+             * $FC82 TEST
                clr     ,x+             * $FC83-$FC8A (= 8 byte zero)
                clr     ,x+
                clr     ,x+
                clr     ,x+
                clr     ,x+
                clr     ,x+
                clr     ,x+
                clr     ,x+
                rts                     * X = $FC8B


* void sub_call(unsigned addr)
*   addr に JSR 相当で飛ぶ (= sub_call は RTS まで待つ)
*   stack: [ret:2] [addr:2]
_sub_call:
                pshs    u
* wait_ready は省略 (= sub_halt が内包する BUSY 待ちで HALT 完了確認できる)。
* main 側 caller が release 直後 sub_call を呼ぶケースでは _subBusy=true
* が残ってて wait_ready が永久 hang する (= 実機準拠エミュ)。
                lbsr    _sub_halt
                lbsr    .build_header   * X = $FC8B
                lda     #$93
                sta     ,x+             * CALL
                ldd     4,s
                std     ,x++            * addr
                lda     #$90
                sta     ,x              * END
                lbsr    _sub_release
                lbsr    _sub_wait_ready * sub の RTS 完了を待つ
                puls    u,pc


* void sub_takeover(const void *code, unsigned len, unsigned dst, unsigned exec)
*   main RAM 上の code[] を sub の dst へ len byte 転送、 終わったら
*   sub_call(exec) で実行開始。 共有 RAM 後半 $FCA0+ を chunk バッファ
*   (= 最大 64 byte / chunk) として使う。
*   stack: [ret:2] [code:2] [len:2] [dst:2] [exec:2]
_sub_takeover:
                pshs    u,y
                leas    -5,s
* 最終 stack (pshs u,y → leas -5,s 後):
*   0,s  = chunk (1B)
*   1,s  = w_dst (2B)
*   3,s  = w_remain (2B)
*   5,s  = saved Y (2B)
*   7,s  = saved U (2B)
*   9,s  = ret addr (2B)
*  11,s  = arg code (2B)
*  13,s  = arg len  (2B)
*  15,s  = arg dst  (2B)
*  17,s  = arg exec (2B)
                ldd     13,s            * len
                std     3,s             * w_remain = len
                ldd     15,s            * dst
                std     1,s             * w_dst = dst
                ldx     11,s            * code → keep in X across loop

.loop:
                ldd     3,s             * remain
                beq     .done
                cmpd    #64
                bls     .szok
                ldd     #64
.szok:
                stb     ,s              * chunk (1B、 最大 64 なので B のみで OK)

                lbsr    _sub_halt
* 1) chunk byte を $FCA0+ にコピー
                ldy     #SHARED_RAM+$20 * = $FCA0
                ldb     ,s
.cp:
                lda     ,x+
                sta     ,y+
                decb
                bne     .cp
* 2) TEST MOVE cmd 構築 (X は保持したいので別レジスタで一旦受け)
                stx     5,s             * save X = next src ptr
                lbsr    .build_header   * X = $FC8B
                lda     #$91
                sta     ,x+             * MOVE
                ldd     #SHARED_SUB     * src (sub から見た $D3A0)
                std     ,x++
                ldd     1,s             * w_dst
                std     ,x++
                clra
                ldb     ,s              * chunk
                std     ,x++            * len
                lda     #$90
                sta     ,x              * END
                lbsr    _sub_release
                lbsr    _sub_wait_ready
                ldx     5,s             * restore code ptr

* 3) w_dst += chunk, w_remain -= chunk
*
*   16-bit 加算は「ldd → addb → adca #0 → std」 の素朴な形で書く
*   こと (= 途中で clra を挟むと HI byte を消す罠あり)。
                ldd     1,s             * D = w_dst (16-bit)
                addb    ,s              * B += chunk (lo)
                adca    #0              * A += carry (hi)
                std     1,s             * w_dst += chunk
*
*   w_remain -= chunk: chunk を 16-bit に符号拡張 (= sex で A = $FF
*   全 byte に伸ばす) して 16-bit 加算で減算する。 chunk は 1-64 の
*   範囲なので negb で 2's complement の負数にしてから sex で OK。
                ldd     3,s
                clra
                ldb     ,s
                negb
                sex                     * D = -chunk (16-bit 符号拡張)
                addd    3,s
                std     3,s
                bra     .loop

.done:
                leas    5,s
                ldd     12,s            * exec (= 0 なら CALL skip = 転送のみ)
                beq     .skip
                pshs    b,a
                lbsr    _sub_call
                leas    2,s
.skip:
                puls    u,y,pc

                end
