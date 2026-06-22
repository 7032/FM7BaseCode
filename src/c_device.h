/* ============================================================
 * c_device.h — 機種判別と入力デバイス (FM 音源 / ジョイスティック) API
 *
 * 提供する関数:
 *   GetMachineType()  動作中の機種・機能を判別し FEAT_* のビットマスクを返す
 *   GetMachineName()  機種名の文字列を返す (例 "FM-7")
 *   HasFMSound()      FM 音源 (OPN) の搭載可否 (1=あり / 0=なし)
 *   JoyStick(nID)     ジョイスティックの状態を読む (nID=0:1P / 1:2P)
 *
 * 設計メモ:
 *   - FM 音源 (OPN) は メイン側 I/O $FD15 (コントロール) / $FD16 (データ) に
 *     位置し、 PSG ($FD0D/$FD0E) と同じ BDIR/BC1 プロトコルでアクセスする。
 *   - FM-7 では FM 音源は拡張カードのため、 レジスタ書込み→読み戻しで
 *     搭載可否を判定する。 FM77AV 以降は標準搭載。
 *   - ジョイスティックは FM 音源 (OPN) の I/O ポート経由で読む。 従って
 *     FM 音源を搭載しない素の FM-7 では読み出せない (= 0xFF を返す)。
 * ============================================================ */

#ifndef C_DEVICE_H
#define C_DEVICE_H

/* ----- GetMachineType() の戻り値 (機能ビットマスク) ----------------
 *   GetMachineType() は検出した機能ビット (FEAT_*) の OR を返す。
 *   「FM77AV 以降か?」は (GetMachineType() & FEAT_AV) で判定する。
 *
 *   本テンプレが実機判別を実装するのは FEAT_FMSOUND と FEAT_AV のみ。
 *   `0x02` / `0x04` は将来の周辺オプション用、 上位 4 bit は AV 世代の
 *   細分類用の予約で、 本テンプレでは検出せず常に 0 を返す。 */
#define FEAT_FMSOUND  0x01   /* FM 音源 (OPN) が使える (FM-7=カード / AV=内蔵) */
/* 0x02 / 0x04 は将来の周辺オプション用に予約 (未使用) */
#define FEAT_AV       0x08   /* FM77AV 系 (アナログ表示 / ALU / ジョイスティック / OPN 内蔵) */
#define FEAT_2DD      0x10   /* 2DD 世代 (AV20 / AV40 以降)   ← 予約 (未実装=0) */
#define FEAT_400LINE  0x20   /* 400 ライン (AV40 系 / 77L4)    ← 予約 (未実装=0) */
#define FEAT_DMAC     0x40   /* DMAC (AV20EX / 40EX / 40SX)   ← 予約 (未実装=0) */
#define FEAT_26MAN    0x80   /* 26 万色 (AV40EX / 40SX 級)     ← 予約 (未実装=0) */

/* 互換用: FM-7 (= 機能ビットが何も立たない素の機種) を表す 0x00。
 * 基本は FEAT_* と (GetMachineType() & FEAT_AV) で扱う。 */
#define MACHINE_FM7   0x00

/* ----- JoyStick() の戻り値ビット --------------------------------
 *   アクティブ Low: 0 = 押下 / 1 = 非押下。 未接続・未搭載は 0xFF。
 *   判定例:  if ((JoyStick(0) & JOY_UP) == 0) { 上が押されている } */
#define JOY_UP     0x01
#define JOY_DOWN   0x02
#define JOY_LEFT   0x04
#define JOY_RIGHT  0x08
#define JOY_TRIG_A 0x10   /* トリガ 1 (A ボタン) */
#define JOY_TRIG_B 0x20   /* トリガ 2 (B ボタン) */

/* 動作中の機種・機能を判別し、 検出した FEAT_* ビットの OR を返す。 */
unsigned char GetMachineType(void);

/* 機種名の文字列を返す (FEAT_AV が立てば "FM77AV"、 否なら "FM-7")。 */
const char *GetMachineName(void);

/* FM 音源 (OPN) を搭載していれば 1、 していなければ 0 を返す。
 * FM77AV 以降は標準搭載のため常に 1。 */
unsigned char HasFMSound(void);

/* ジョイスティックの状態を読む。 nID=0 で 1P、 nID=1 で 2P。
 * 戻り値は JOY_* ビット (アクティブ Low)。 FM 音源非搭載なら 0xFF。 */
unsigned char JoyStick(int nID);

#endif
