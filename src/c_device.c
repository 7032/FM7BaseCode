/* ============================================================
 * c_device.c — 機種判別と入力デバイス (FM 音源 / ジョイスティック)
 *
 * FM 音源 (OPN) の I/O は PSG ($FD0D/$FD0E) と同じ BDIR/BC1 プロトコル。
 * ポートだけが $FD15 (コントロール) / $FD16 (データ) に変わる:
 *   $FD15 下位ビット   $03=アドレスラッチ / $00=インアクティブ /
 *                      $02=データ書込み   / $01=データ読出し選択
 *   $FD16              データバス (レジスタ番号も値もここ経由)
 *
 * 機種判別は FM77AV 系だけが備える「サブ CPU の拡張サブシステムバンクへ
 * 切り替えられるか」という能力差を、 サブ CPU の振る舞いの変化として
 * 観測して行う。 詳細は GetMachineType() のコメントを参照。
 * ============================================================ */

#include "c_device.h"
#include "c_subsys.h"

/* ----- FM 音源 (OPN) I/O ポート (メイン側) --------------------- */
#define OPN_CTRL   (*(volatile unsigned char *)0xFD15)   /* BDIR/BC1 */
#define OPN_BUS    (*(volatile unsigned char *)0xFD16)   /* データバス */

/* OPN レジスタ reg に val を書く (アドレスラッチ → データ書込み)。 */
static void opn_write(unsigned char reg, unsigned char val)
{
    OPN_BUS  = reg;     /* データバスにレジスタ番号 */
    OPN_CTRL = 0x03;    /* アドレスラッチ */
    OPN_CTRL = 0x00;    /* インアクティブ */
    OPN_BUS  = val;     /* データバスに値 */
    OPN_CTRL = 0x02;    /* データ書込み */
    OPN_CTRL = 0x00;    /* インアクティブ */
}

/* OPN レジスタ reg を読む (アドレスラッチ → 読出し選択 → 取得)。 */
static unsigned char opn_read(unsigned char reg)
{
    OPN_BUS  = reg;     /* データバスにレジスタ番号 */
    OPN_CTRL = 0x03;    /* アドレスラッチ */
    OPN_CTRL = 0x00;    /* インアクティブ */
    OPN_CTRL = 0x01;    /* データ読出し選択 */
    return OPN_BUS;     /* データバスから取得 */
}


/* ------------------------------------------------------------
 * HasFMSound() — FM 音源 (OPN) の搭載可否
 *
 * OPN の SSG トーンレジスタ (R0) は読み書き可能なので、 2 種類の値を
 * 書いて読み戻し、 両方が保持されていれば OPN 搭載とみなす。 非搭載なら
 * 読み出しは一定値 (0xFF 等) になり保持されない。 元の値は戻しておく。
 * FM77AV 以降は OPN 標準搭載のため、 この判定は必ず成立する。
 * ------------------------------------------------------------ */
unsigned char HasFMSound(void)
{
    unsigned char saved;
    unsigned char t1, t2;

    saved = opn_read(0);

    opn_write(0, 0x55);
    t1 = opn_read(0);
    opn_write(0, 0xAA);
    t2 = opn_read(0);

    opn_write(0, saved);            /* 元に戻す */

    return (t1 == 0x55 && t2 == 0xAA) ? 1 : 0;
}


/* ------------------------------------------------------------
 * JoyStick(nID) — ジョイスティックの状態
 *
 * OPN の I/O ポート経由で読む:
 *   1. ポート B (R15) の上位ニブルで読み出すスティックを選択
 *        nID=0 (1P) → $20 / nID=1 (2P) → $50
 *   2. ポート B を出力 / ポート A を入力に設定 (R7 ミキサ)
 *   3. 読出し対象として ポート A (R14) を選択
 *   4. データバスから状態を読む (アクティブ Low: 0=押下)
 * FM 音源非搭載 (= ポートなし) では 0xFF を返す。
 * ------------------------------------------------------------ */
unsigned char JoyStick(int nID)
{
    unsigned char sel;

    if (!HasFMSound()) {
        return 0xFF;                /* OPN なし → 入力なし */
    }

    sel = (nID == 0) ? 0x20 : 0x50; /* ポート B 上位ニブルでスティック選択 */

    /* R7 ミキサ: ポート B = 出力 (bit7=1) / ポート A = 入力 (bit6=0)、
     * トーン/ノイズは全 OFF (下位 6 bit = 1)。 */
    opn_write(0x07, 0xBF);

    /* ポート B (R15) にセレクタを書く。 */
    opn_write(0x0F, sel);

    /* 読出し対象を ポート A (R14) に選択。 */
    OPN_BUS  = 0x0E;
    OPN_CTRL = 0x03;                /* アドレスラッチ (R14 選択) */
    OPN_CTRL = 0x00;                /* インアクティブ */

    /* ジョイスティック読出しモードでデータ取得。 */
    OPN_CTRL = 0x09;                /* ジョイスティック読出し */
    return OPN_BUS;                 /* アクティブ Low: 0=押下 */
}


/* ------------------------------------------------------------
 * GetMachineType() — 機種判別
 *
 * 【判別原理】
 * FM77AV 系はサブ CPU の動作プログラム (サブシステム) を複数バンクから
 * 選べる。 バンク選択レジスタ $FD13 への「書き込み」でサブ CPU がリセット
 * され、 選んだバンクで起動し直す。 バンク 0 は FM-7 互換 (Type-C)、
 * バンク 1 以降は FM77AV 専用の拡張サブシステムである。 素の FM-7 には
 * $FD13 が無く、 書き込んでも何も起こらない (= サブ CPU は常に FM-7
 * 互換サブシステムのまま)。
 *
 * 起動直後は FM-7・FM77AV とも FM-7 互換サブシステムが応答する。 そこで
 * 「拡張バンクへ切り替えられるか」を、 サブ CPU の振る舞いの変化として
 * 観測する:
 *
 *   1. まず FM-7 互換サブシステムが正常に応答することを確認する
 *      (= 共有 RAM のコマンド byte $FC82 にコマンドを書くと、 サブが
 *        拾って $FC82 を 0 に戻す。 これを上限付きで待つ)。
 *   2. $FD13 に 1 を書いて拡張バンクへの切替を試みる。
 *   3. 再び同じコマンドを送り、 サブが拾うか上限付きで待つ。
 *        - FM-7  : $FD13 は無効。 FM-7 互換サブシステムが応答し続ける
 *                  → コマンドが拾われる → FM-7。
 *        - FM77AV: 拡張バンクが起動し、 サブはもう FM-7 互換の
 *                  コマンド byte 規約 ($FC82) を読まない → コマンドが
 *                  拾われずタイムアウト → FM77AV。
 *   4. $FD13 に 0 を書いて FM-7 互換バンク (Type-C) へ必ず復元する。
 *      FM77AV ではこの書き込みでサブ CPU が再リセットされ、 FM-7 互換
 *      サブシステムで再稼働する。 FM-7 では無害。
 *
 * 観測信号は「FM-7 互換のコマンド byte がサブに拾われる/拾われない」と
 * いう、 共有 RAM 上で確実に読める値の変化のみに依存する (= $FD13 の
 * 読み戻しのような書込専用レジスタの読みには一切依存しない)。
 *
 * 【復元の確実性】
 * 判定の最後で必ず $FD13=0 (Type-C) へ戻し、 共有 RAM のコマンド byte も
 * クリアする。 これにより本関数の呼び出し後、 FM-7 互換サブシステムが
 * コマンド待ち状態で再稼働し、 通常のサブシステム呼び出し (描画等) が
 * そのまま使える。 切替/復元時のサブ CPU リセットは $FD13 書込で行われる
 * ため、 サブを HALT しない状態で書き込んで即時に効かせる。
 *
 * ※ AV40 / AV40EX の細分類は本テンプレでは行わない (予約)。
 * ------------------------------------------------------------ */

/* サブ ROM バンク選択レジスタ (FM77AV 系のみ実装。 書込専用)。 */
#define SUB_BANK_REG    (*(volatile unsigned char *)0xFD13)
#define SUB_BANK_TYPE_C 0x00    /* FM-7 互換サブシステム (全機種) */
#define SUB_BANK_TYPE_A 0x01    /* FM77AV 拡張サブシステム */

/* 共有 RAM (main 側 $FC80-$FC8E) の FM-7 互換サブシステム規約レイアウト。
 *   $FC80 = ATN / 応答 bit、 $FC81 = 応答コード、
 *   $FC82 = main→sub コマンド byte (0=コマンドなし)。 */
#define SHARED_BASE     ((volatile unsigned char *)0xFC80)
#define SHARED_COMMAND  2       /* $FC82 = コマンド byte */

/* 判別用の無害なコマンド: カーソル ON/OFF ($0C)。 サブが拾うこと自体が
 * 観測対象で、 副作用 (カーソル状態) は判定後の復元と本体初期化で
 * 上書きされる。 */
#define PROBE_CMD       0x0C

/* コマンドが拾われるのを待つ上限ループ回数 (= タイムアウト)。 FM-7 互換
 * サブシステムは数命令でコマンド byte をクリアするので、 これに達する
 * 前に必ず拾われる。 拡張バンクは規約が異なり永久に拾わないので、 上限に
 * 達した時点で「拾われなかった」 と判定できる。 */
#define PROBE_TIMEOUT   2000u

/* 共有 RAM は サブ CPU を HALT している間だけ main から R/W 有効
 * (実機準拠)。 1 byte 読み書きごとに HALT→操作→RELEASE する。 */

static void shared_write(unsigned char off, unsigned char val)
{
    subsys_halt();
    SHARED_BASE[off] = val;
    subsys_release();
}

static unsigned char shared_read(unsigned char off)
{
    unsigned char v;
    subsys_halt();
    v = SHARED_BASE[off];
    subsys_release();
    return v;
}

/* FM-7 互換サブシステムにコマンドを 1 つ送り、 サブがそれを拾って
 * コマンド byte をクリアするか上限付きで待つ。
 *   戻り値 1 = 拾われた (= FM-7 互換サブシステムが応答している)
 *          0 = 上限に達しても拾われなかった (= タイムアウト) */
static unsigned char probe_typec_responds(void)
{
    unsigned int guard;

    shared_write(SHARED_COMMAND, PROBE_CMD);

    for (guard = 0; guard < PROBE_TIMEOUT; guard++) {
        if (shared_read(SHARED_COMMAND) == 0) {
            return 1;               /* サブが拾った = 応答あり */
        }
    }
    return 0;                       /* タイムアウト = 応答なし */
}

static unsigned char fm77av_present(void)
{
    unsigned char before;
    unsigned char after;

    /* (1) 起動直後の FM-7 互換サブシステムが応答するか。 FM-7・FM77AV
     *     とも応答するはず。 万一応答しなければ判定不能なので FM-7 扱い。 */
    before = probe_typec_responds();
    if (!before) {
        return 0;
    }

    /* (2) 拡張サブシステムバンクへの切替を試みる ($FD13=1)。 FM77AV では
     *     サブ CPU がリセットされ拡張サブシステムで起動し直す。 FM-7 では
     *     $FD13 が無く無効。 HALT していない状態で書き、 即時に効かせる。 */
    SUB_BANK_REG = SUB_BANK_TYPE_A;

    /* (3) 再びコマンドを送って応答を観測する。 */
    after = probe_typec_responds();

    /* (4) FM-7 互換バンク (Type-C) へ必ず復元する。 FM77AV ではサブ CPU が
     *     再リセットされ FM-7 互換サブシステムで再稼働。 FM-7 では無害。 */
    SUB_BANK_REG = SUB_BANK_TYPE_C;
    shared_write(SHARED_COMMAND, 0x00);   /* コマンド byte を空に戻す */

    /* 切替後に応答が消えた (タイムアウト) → 拡張へ切り替わった = FM77AV。
     * 応答が続いた → 切替が効かなかった = FM-7。 */
    return after ? 0 : 1;
}

unsigned char GetMachineType(void)
{
    unsigned char feat = 0;

    /* FEAT_FMSOUND: OPN (FM 音源) の搭載可否。 FM-7 のカードでも
     * FM77AV の内蔵でも立つ。 */
    if (HasFMSound()) {
        feat |= FEAT_FMSOUND;
    }

    /* FEAT_AV: FM77AV 系か。 拡張サブシステムバンクへの切替可否で判別。 */
    if (fm77av_present()) {
        feat |= FEAT_AV;
    }

    /* 0x02 / 0x04 (周辺オプション枠) と上位 4 bit (AV 世代細分類) は
     * 本テンプレでは検出せず常に 0 (予約)。 */

    return feat;
}


/* ------------------------------------------------------------
 * GetMachineName() — 機種名の文字列
 *
 * FEAT_AV が立っていれば FM77AV 系、 否なら FM-7。 AV のサブ機種
 * (AV20 / AV40 等) は本テンプレでは区別しないため一律 "FM77AV"。
 * ------------------------------------------------------------ */
const char *GetMachineName(void)
{
    if (GetMachineType() & FEAT_AV) {
        return "FM77AV";
    }
    return "FM-7";
}
