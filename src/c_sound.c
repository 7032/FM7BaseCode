/* ============================================================
 * c_sound.c — PSG (AY-3-8910) サウンド実装
 *
 * 低レベル: PSG レジスタ書込みは BDIR/BC1 プロトコルで行う。
 *   $FD0D : BDIR/BC1 制御 (下位 2 bit でモード。 $03=アドレスラッチ /
 *           $02=データ書込み / $00=インアクティブ)
 *   $FD0E : データバス (レジスタ番号も値もここ経由)
 *
 * レジスタ (AY-3-8910):
 *   R0/R1   ch A tone period (fine/coarse)   ※本テンプレでは未使用
 *   R2/R3   ch B tone period (fine/coarse)   歩行音
 *   R4/R5   ch C tone period (fine/coarse)   BGM
 *   R6      ノイズ周期 (5bit)                ボール発射音
 *   R7      mixer (0=有効。 bit0-2=tone A/B/C, bit3-5=noise A/B/C)
 *   R8/R9/R10 ch A/B/C 音量 (0-15。 bit4=エンベロープ)
 *
 * 周波数 = PSGクロック / (16 × period)。 period = クロック / (16 × freq)。
 * (本テンプレの音程 period 値は下表に直書き。 実機/エミュのクロック差で
 *  音高がずれる場合は値を調整する。 詳細は docs/SOUND.md。)
 * ============================================================ */

#include "c_sound.h"

/* ----- PSG I/O ポート (メイン側) ------------------------------- */
#define PSG_CTRL   (*(volatile unsigned char *)0xFD0D)   /* BDIR/BC1 */
#define PSG_BUS    (*(volatile unsigned char *)0xFD0E)   /* データバス */

/* PSG レジスタ reg に val を書く (= アドレスラッチ → データ書込み)。 */
static void psg_write(unsigned char reg, unsigned char val)
{
    PSG_BUS  = reg;     /* データバスにレジスタ番号 */
    PSG_CTRL = 0x03;    /* アドレスラッチ (BDIR=1, BC1=1) */
    PSG_CTRL = 0x00;    /* インアクティブ (ラッチ確定) */
    PSG_BUS  = val;     /* データバスに値 */
    PSG_CTRL = 0x02;    /* データ書込み (BDIR=1, BC1=0) */
    PSG_CTRL = 0x00;    /* インアクティブ (書込み確定) */
}

/* ----- 設定値 -------------------------------------------------- */
/* mixer R7: tone A off / tone B,C on / noise A on / noise B,C off /
 * I/O ポートは入力。 = 0b00110001。 各音の ON/OFF は音量で制御する。 */
#define MIX_R7              0x31

#define BALL_NOISE_PERIOD   0x0F    /* R6: ボール発射音のノイズ周期 */
#define WALK_PERIOD_LO      0x58    /* R2: 歩行音 (= 低い矩形波、 period 600) */
#define WALK_PERIOD_HI      0x02    /* R3 */
#define WALK_VOL            10      /* 歩行音の音量 */
#define BGM_VOL             11      /* BGM の音量 */

#define SFX_BALL_FRAMES     6       /* ボール発射音の長さ (フレーム) */
#define SFX_WALK_FRAMES     2       /* 歩行音の長さ (フレーム) */

/* ボール発射音の音量減衰テーブル (= 残りフレーム数で引く。 0 で消音)。 */
static const unsigned char ball_vol[SFX_BALL_FRAMES + 1] = {
    0, 3, 6, 9, 12, 14, 15
};

/* ----- BGM (= ch C 単音メロディ) ------------------------------- */
/* 音程 period (= PSGクロック 1.2288MHz、 period = 76800 / 周波数[Hz])。
 * 0 は休符 (= 音量 0)。 実機/エミュで音高がずれたら値を調整する。 */
#define N_REST  0
#define N_C4    294
#define N_D4    262
#define N_E4    233
#define N_F4    220
#define N_G4    196
#define N_A4    175
#define N_B4    156
#define N_C5    147

/* 単調に繰り返す短いメロディ。 period と長さ (フレーム) の並走 2 配列。 */
static const unsigned int  bgm_period[] = {
    N_C4, N_E4, N_G4, N_E4, N_C4, N_E4, N_G4, N_REST,
    N_D4, N_F4, N_A4, N_F4, N_D4, N_F4, N_A4, N_REST
};
static const unsigned char bgm_frames[] = {
    10, 10, 10, 10, 10, 10, 10, 6,
    10, 10, 10, 10, 10, 10, 10, 6
};
#define BGM_LEN  (sizeof(bgm_frames) / sizeof(bgm_frames[0]))

/* ----- 状態 (= sound_init で初期化) ---------------------------- */
static unsigned char bgm_idx;       /* 次に鳴らす音符の index */
static unsigned char bgm_timer;     /* 現在の音符の残りフレーム */
static unsigned char sfxA_timer;    /* ボール発射音の残りフレーム (= ch A) */
static unsigned char sfxB_timer;    /* 歩行音の残りフレーム (= ch B) */


void sound_init(void)
{
    /* 全 ch 消音 → mixer 設定 → ノイズ周期 → 状態初期化。 */
    psg_write(8, 0);                    /* ch A 音量 0 */
    psg_write(9, 0);                    /* ch B 音量 0 */
    psg_write(10, 0);                   /* ch C 音量 0 */
    psg_write(7, MIX_R7);               /* mixer */
    psg_write(6, BALL_NOISE_PERIOD);    /* ノイズ周期 (ch A 用) */

    bgm_idx    = 0;
    bgm_timer  = 0;                     /* 0 = 次の tick で先頭音符をロード */
    sfxA_timer = 0;
    sfxB_timer = 0;
}


void sound_tick(void)
{
    /* --- BGM (ch C): 音長が尽きたら次の音符へ。 末尾でループ。 --- */
    if (bgm_timer == 0) {
        unsigned int p = bgm_period[bgm_idx];
        if (p == 0) {
            psg_write(10, 0);                   /* 休符 = 消音 */
        } else {
            psg_write(4, (unsigned char)(p & 0xFF));        /* period fine */
            psg_write(5, (unsigned char)((p >> 8) & 0x0F)); /* period coarse */
            psg_write(10, BGM_VOL);             /* ch C 発音 */
        }
        bgm_timer = bgm_frames[bgm_idx];
        bgm_idx++;
        if (bgm_idx >= BGM_LEN) bgm_idx = 0;
    }
    bgm_timer--;

    /* --- SE ch A (ボール発射音): ノイズを毎フレーム減衰させる。 --- */
    if (sfxA_timer != 0) {
        sfxA_timer--;
        psg_write(8, ball_vol[sfxA_timer]);     /* 残り 0 で音量 0 = 自動リリース */
    }

    /* --- SE ch B (歩行音): 短いブリップを鳴らしてリリース。 --- */
    if (sfxB_timer != 0) {
        sfxB_timer--;
        if (sfxB_timer == 0) psg_write(9, 0);
    }
}


void sfx_ball(void)
{
    /* ch A のノイズを最大音量でトリガ (= sound_tick が減衰させる)。 */
    psg_write(6, BALL_NOISE_PERIOD);
    sfxA_timer = SFX_BALL_FRAMES;
    psg_write(8, ball_vol[SFX_BALL_FRAMES]);
}


void sfx_walk(void)
{
    /* ch B に短い低音ブリップをセット。 */
    psg_write(2, WALK_PERIOD_LO);
    psg_write(3, WALK_PERIOD_HI);
    psg_write(9, WALK_VOL);
    sfxB_timer = SFX_WALK_FRAMES;
}
