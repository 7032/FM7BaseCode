* ============================================================
* subsys.s — メインCPUからサブシステム(サブCPU)を呼ぶヘルパ
*
* FM-7 では VRAM はサブCPUのアドレス空間にマップされており、
* メインCPU からは直接触れない。描画はサブCPU側のサブシステム
* プログラムにコマンドを送って行う。
*
* 基本シーケンス:
*   1. メインCPU が SUB_HALT_REQ (=$FD05 bit7) を立てる
*   2. サブCPU が HALT したことを SUB_HALT_REQ の読み出しで確認
*   3. 共有RAM ($FC80-$FCFF) にコマンドコードとパラメータを書く
*   4. SUB_HALT_REQ を 0 に戻してサブCPU を再開
*   5. サブCPU 側のサブシステムプログラムがコマンドを処理
*
* 共有RAMの中身 (コマンドコード、パラメータ並び) は実機/利用する
* サブシステムプログラムの仕様に従う。
* ============================================================

SUB_HALT_REQ    equ     $FD05

                section code
                export  _subsys_halt
                export  _subsys_release

* void subsys_halt(void)
*   サブCPU を HALT させ、共有RAM への安全な書き込みを許す
_subsys_halt:
                lda     #$80
                sta     SUB_HALT_REQ
.wait:
                lda     SUB_HALT_REQ
                bita    #$80
                beq     .wait
                rts

* void subsys_release(void)
*   サブCPU を再開させ、共有RAMに書いたコマンドを処理させる
_subsys_release:
                clr     SUB_HALT_REQ
                rts

                end
