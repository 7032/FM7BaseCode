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

* HALT 要求後、 サブ CPU が次の命令境界で HALT を受理し終えるまでの
* 空転回数。 サブ 1 命令ぶん (= 数サイクル) を余裕をもって跨げればよい。
SUB_HALT_SETTLE equ     32

* CANCEL 発行後、 サブ CPU が割り込みを取り、 サブシステム ROM の
* 割り込みハンドラを実行してコマンド待ちループへ復帰するのを待つ空転回数。
* 割り込み処理はサブの数十命令ぶんかかり得るので HALT より長めに取る。
SUB_CANCEL_WAIT equ     2000

                section code
                export  _subsys_halt
                export  _subsys_release
                export  _sub_cancel

* void subsys_halt(void)
*   サブCPU を HALT させ、共有RAM への安全な書き込みを許す
*
*   $FD05 bit7 は「HALT 受理 OR BUSY」で 1 になる。 HALT 要求は即時
*   ではなく、 サブ CPU が次の命令境界に達した時に受理される。 その
*   ため、 サブが BUSY な状態 (= 起動直後 / BASIC 稼働中 = warm start)
*   で HALT を要求すると、 BUSY 由来の bit7=1 を「HALT 受理」と取り違え、
*   まだ HALT していないのに共有 RAM を触ってしまう (= HALT 中のみ
*   有効という実機仕様により write が破棄され、 chunk 転送が壊れる)。
*
*   対策: HALT 要求 → bit7=1 を確認 → さらに settle で数サイクル空転して
*   「次の命令境界での HALT 受理」を確実に通過させてから戻る。 これで
*   サブが idle でも BUSY でも、 戻った時点で必ず HALT 済みになる。
*   (idle を待つ方式は、 BASIC 稼働中で常時 BUSY な warm start では
*    永久に idle にならず停止し得るので採らない。)
_subsys_halt:
                lda     #$80
                sta     SUB_HALT_REQ
.wait:
                lda     SUB_HALT_REQ
                bita    #$80
                beq     .wait
                ldb     #SUB_HALT_SETTLE
.settle:
                decb                     * サブを 1 命令境界ぶん進めて HALT を確実に受理させる
                bne     .settle
                rts

* void subsys_release(void)
*   サブCPU を再開させ、共有RAMに書いたコマンドを処理させる
_subsys_release:
                clr     SUB_HALT_REQ
                rts

* void sub_cancel(void)
*   サブCPU に CANCEL ($FD05 bit6) を発行し、 実行中の処理を中断させて
*   サブシステム ROM のコマンド待ちループへ戻す。
*
*   warm start 対応:
*     テープ起動 (= BASIC 稼働中に本体へ突入) では、 サブCPU は BASIC の
*     サブシステム処理の途中に居て、 本体の takeover が期待する
*     「コマンド待ちループ」状態ではない。 この状態のまま HALT + 共有RAM
*     コマンドを送っても同期せず、 subprog の転送が成立しない。
*     CANCEL はサブへ割り込みをかけ、 サブシステム ROM の割り込みハンドラ
*     が現コマンドを中止してコマンド待ちループへ復帰させるための仕組み。
*     ディスク起動 (cold start) では既にコマンド待ちなので CANCEL は無害。
*
*   CANCEL は割り込み = サブの命令境界で受理されるため、 発行後に settle
*   してサブが割り込み処理を終えるのを待つ。 2 回発行しているのは、
*   CANCEL 要求がサブ命令境界で確定してから割り込み線が立つ実装に対し、
*   確実に割り込みを通すため (= 1 回目で要求確定、 2 回目で割り込み発火)。
_sub_cancel:
                lda     #$40
                sta     SUB_HALT_REQ     * CANCEL 要求 (bit6=1, bit7=0=run)
                ldb     #SUB_HALT_SETTLE
.c1:
                decb
                bne     .c1
                lda     #$40
                sta     SUB_HALT_REQ     * 再発行で割り込みを確実に立てる
                ldx     #SUB_CANCEL_WAIT
.c2:
                leax    -1,x
                bne     .c2              * サブが割り込み処理を終えコマンド待ちへ戻るのを待つ
                rts

                end
