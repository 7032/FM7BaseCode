/* ============================================================
 * c_subsys.h — メインCPU から FM-7 サブシステム (= 実機
 *              サブシステム ROM が走っている前提) を呼ぶ API
 *
 * 共有 RAM ($FC80-$FCFF) の サブシステム ROM 規約上のレイアウト:
 *   main side  sub side  役割
 *   $FC80      $D380     ATN フラグ (sub→main 応答 bit7)
 *   $FC81      $D381     sub→main 応答コード
 *   $FC82      $D382     ★ main→sub コマンドコード (= 0 で「コマンドなし」)
 *   $FC83-$FC8E $D383-$D38E コマンドパラメータ
 *
 * sub はメインループで $D382 を polling し、非0 を見たら
 * コマンド表でハンドラを実行する。 subsys_call() は params 配置 +
 * cmd 書き込み + 完了待ち を 1 発で行う。
 *
 * 完了検出: sub は コマンド処理 直後の  で $D382 を即クリアする。
 *   従って $D382 == 0 は「拾った」サインに過ぎず完了ではない。
 *   PRINT (CMD $03) は $D383 (= 残り文字数) を fetch ごとに DEC する
 *   ので $D383 == 0 を完了サインにする。 詳細は c_subsys.c 参照。
 *
 * サブシステム ROM コマンド表 (= 内蔵 ANK font 含む描画コマンド):
 *   $01  画面モード初期化  ($D384=幅, $D385=高)
 *   $02  画面クリア (CLS)
 *   $03  ★ PRINT (params[0]=N, params[1..N]=ASCII/制御文字)
 *   $0A-$0D, $15-$20, $29-$2C, $3D-$3F  (色 / 矩形 / ライン / カーソル等)
 *   $0C  text mode flag set ($D021)
 * ============================================================ */

#ifndef C_SUBSYS_H
#define C_SUBSYS_H

/* サブシステム ROM コマンドコード (本テンプレで使う分のみ定数化) */
#define SCMD_INIT_SCREEN  0x01
#define SCMD_CLS          0x02
#define SCMD_PRINT        0x03    /* params[0]=N, params[1..N]=ASCII/制御 */
#define SCMD_CURSOR       0x0C    /* params[0]=テキストモードフラグ
                                   *   bit0: cursor ON/OFF
                                   *   bit1: PRINT 内で制御文字解釈
                                   *   bit5: 行末オートラップ等
                                   *   ※ boot 時の既定は $23。 */

/* CMD $03 PRINT のバイト列中で sub が解釈する制御文字 (要 $D021 bit1) */
#define SUBC_LF      0x0A   /* LF: Y++ (X 維持) */
#define SUBC_COLOR   0x11   /* COLOR: 後ろに 1 byte (= 色) */
#define SUBC_LOCATE  0x12   /* LOCATE: 後ろに col, row */
#define SUBC_REPEAT  0x13   /* REPEAT: 後ろに count, char */

/* params (= $D383+) に乗せられる最大 byte 数 = 12 ($D383-$D38E) */
#define SUBSYS_MAX_PARAMS  12

/* 低レベル (asm_subsys.s) — main から sub を HALT/RELEASE する
 * 本テンプレの通常 API では使わないが、 直接共有 RAM を読み書きしたい
 * ような特殊用途用に export してある。 */
void subsys_halt(void);
void subsys_release(void);

/* サブCPU に CANCEL を発行し、 実行中の処理を中断してサブシステム ROM の
 * コマンド待ちループへ戻す。 テープ起動 (= warm start) で本体へ突入した
 * 際、 サブを takeover 可能なクリーン状態に揃えるために起動時 1 回呼ぶ。
 * ディスク起動 (cold start) では無害。 */
void sub_cancel(void);

/* ------------------------------------------------------------
 * subsys_call(cmd, params, param_len)
 *   サブシステム ROM の標準コマンドを 1 発で発行する。 詳細は c_subsys.c。
 *
 *   引数:
 *     cmd       : サブシステム ROM コマンドコード (SCMD_* 定数)
 *     params    : $D383 から書き込むパラメータ (NULL なら書き込まない)
 *     param_len : params の長さ (0 〜 SUBSYS_MAX_PARAMS)
 *
 *   戻り値: sub からの応答コード ($D381 の値)
 * ------------------------------------------------------------ */
unsigned char subsys_call(unsigned char cmd,
                          const unsigned char *params,
                          unsigned char param_len);

#endif
