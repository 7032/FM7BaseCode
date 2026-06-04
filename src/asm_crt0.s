* ============================================================
* crt0.s — 本体エントリ ($1000)
*
* トランポリンから JMP $1000 で叩かれる前提。main() は戻って
* こないものとして、jsr ではなく jmp で呼ぶ。
* スタックは本体直下に確保する。
*
* INILIB / _exit:
*   CMOC が生成する start セクションが LBSR INILIB / LBSR _exit
*   を含むため、リンク解決用にダミー実体を置く。本テンプレートは
*   libcmoc 非リンク・大域変数初期化も不要なので、INILIB は即 RTS、
*   _exit は戻る先 (= シェル等) が無い FM-7 環境なので無限ループ。
* ============================================================

                section code
                import  _main
                export  _start
                export  INILIB
                export  _exit

_start:
                orcc    #$50            * IRQ/FIRQ をマスク
                lds     #$FC7F          * boot ROM が設定した位置に揃える
                                        * (= 共有 RAM $FC80-$FCFF の直下)
                jmp     _main           * main は戻ってこない前提

INILIB:
                rts                     * 初期化不要 — ダミー

_exit:
                bra     _exit           * 戻る先が無いので停止

                end
