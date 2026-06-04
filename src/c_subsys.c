/* ============================================================
 * c_subsys.c — FM-7 サブシステム呼び出しの実装
 *
 * 実機 サブシステム ROM (= サブ CPU 側で動いている標準サブシステム
 * ROM) のコマンドプロトコル:
 *
 *   $D380 (= main $FC80) : ATN bit7 (sub↔main の attention)
 *   $D381 (= main $FC81) : sub→main 応答コード
 *   $D382 (= main $FC82) : ★ main→sub コマンドコード (0=idle)
 *   $D383-$D38E          : コマンドパラメータ (12 byte)
 *
 * 共有 RAM アクセスは「サブ HALT」 が必須:
 *   実機 (および実機準拠エミュレータ) では、 主 CPU の共有 RAM
 *   ($FC80-$FCFF) アクセスはサブ CPU を HALT している間のみ有効。
 *   サブ稼働中の write は破棄、 read は $FF を返す。 従って毎回
 *   [HALT → R/W → RELEASE] を行う。
 *
 * 完了検出の注意:
 *   sub はコマンドを受け付けると、 受付処理の初期で $D382 を
 *   即クリアする。 つまり $D382 == 0 は「sub が拾った」サインに
 *   過ぎず、 ハンドラの完了サインではない。 そこで PRINT
 *   (CMD $03) では $D383 (= 残文字数) を見る: sub が 1 char
 *   消費ごとに DEC $D383 するので、 $D383 == 0 が「全文字描画
 *   完了」 のサインになる。 その他のコマンドは「sub が拾った
 *   ($D382 == 0)」 + 短 spin で済ませる。
 * ============================================================ */

#include "c_subsys.h"

#define SHARED_RAM      ((volatile unsigned char *)0xFC80)

#define SH_ATN           0
#define SH_RESPONSE      1
#define SH_COMMAND       2
#define SH_PARAM_BASE    3      /* $D383 = params[0] */


/* halt → read offset → release → return byte */
static unsigned char shared_peek(unsigned char off)
{
    unsigned char v;
    subsys_halt();
    v = SHARED_RAM[off];
    subsys_release();
    return v;
}


unsigned char subsys_call(unsigned char cmd,
                          const unsigned char *params,
                          unsigned char param_len)
{
    unsigned char i;
    unsigned char resp;

    if (param_len > SUBSYS_MAX_PARAMS) {
        return 0xFF;
    }

    /* 1. sub HALT → params + cmd 書込 → sub RELEASE で起動 */
    subsys_halt();
    for (i = 0; i < param_len; i++) {
        SHARED_RAM[SH_PARAM_BASE + i] = params[i];
    }
    SHARED_RAM[SH_COMMAND] = cmd;
    subsys_release();

    /* 2. sub が拾うまで待つ ( で $D382 = 0 になる)。
     *    共有 RAM 読みは HALT 必須なので poll loop も毎回 HALT。 */
    while (shared_peek(SH_COMMAND) != 0) { /* spin */ }

    /* 3. PRINT (= cmd $03) は $D383 が 0 になるまで待つ。
     *    sub が 1 char 消費ごとに $D383 を DEC する。 */
    if (cmd == 0x03) {
        while (shared_peek(SH_PARAM_BASE) != 0) { /* spin */ }
    }

    /* 4. ハンドラ末尾の cleanup とサブのメインループ復帰を待つ短 spin。 */
    {
        volatile unsigned int spin;
        for (spin = 0; spin < 200; spin++) { /* short delay */ }
    }

    /* 5. 応答コード ($D381) を読んで返す。 */
    resp = shared_peek(SH_RESPONSE);
    return resp;
}
