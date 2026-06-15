/* ============================================================
 * c_main.c — Phase B エントリ (= 雛形のゲーム本体)
 *
 * 動作:
 *   assets/character.png から取り込んだ 32x32 sprite (= 赤/シアン/白のキャラ)
 *   を画面に描画し、 テンキー 8/2/4/6 で上下左右に連続移動する。
 *
 *   キー入力仕様 (= 「最後押下キー保持」 方式):
 *     - 方向キー (8/2/4/6) を押した → その方向へ動き続ける
 *     - 別の方向キーを押した → 新しい方向へ切替 + sprite も向き変更
 *     - 方向キー以外のキー (例: スペース) を押した → 停止
 *     - キー入力なし (= key_check() が 0) → 現在の方向を保持
 *     - 画面端で動けない時 → sprite だけ向きを反映、 方向は保持
 *     - BREAK キー → キャラが向いている方向へシアンのボールを投げる
 *       (= 最大 3 個まで同時に飛ぶ = 3 連射。 画面端に達したら消える。
 *        横方向はキャラ移動の倍速)
 *
 * 描画は サブシステム ROM の PRINT 経由ではなく、 main から sub の
 * RAM ($C300) に転送した自前プログラムが VRAM を直書きする方式
 * (= 任意座標に pixel 単位で 32x32 sprite を描ける)。
 *
 *   詳細は:
 *     docs/GAMEMAIN.md   — このファイルのゲームロジック解説
 *     docs/SUBPROGRAM.md — sub-side 描画の全貌
 *     docs/SPRITE.md     — sprite データ形式
 *
 * 起動シーケンスの順序は厳守 (= 後述コメント参照)。 とくに subsys_call
 * と subprog_init の間に必ず delay を挟むこと。
 * ============================================================ */

#include "c_subsys.h"
#include "c_subprog.h"
#include "c_sound.h"


/* 雑な busy-wait delay。 1.78 MHz の 6809 で 1 unit ≒ 数 ms 目安。
 * volatile は CMOC の最適化で消されないため必須 (= 入れないと「無限
 * ループの中身が無くて even loop すら最適化で消える」 ことがある)。 */
static void delay_loop(unsigned int units)
{
    volatile unsigned int i;
    volatile unsigned char j;
    for (i = 0; i < units; i++) {
        for (j = 0; j < 200; j++) { /* spin */ }
    }
}


/* sprite の左上位置として許容できる範囲。 32×32 px sprite を 80×200
 * 画面に収めるための上限。 横は byte 単位 (= 1 byte = 8 px) なので
 *   max_x_byte = 80 - 4 = 76 (= 76*8 + 32 = 640 px ぴったり)
 * 縦は line 単位なので
 *   max_y_line = 200 - 32 = 168 */
#define SCREEN_W_BYTES_MAX  (SCREEN_W_BYTES - SPRITE_W_BYTES)
#define SCREEN_H_LINES_MAX  (SCREEN_H_LINES - SPRITE_PX_H)

/* 1 step で動く量。 横は byte 単位 (= 8 px 刻み) なので 1。
 * 縦は line 単位なので 4 (= 4 px の細かい動き)。 */
#define STEP_X_BYTES        1
#define STEP_Y_LINES        4

/* テンキー ASCII (= サブシステム ROM がキーボード scan の結果を ASCII で
 * 共有 RAM に流す。 '8' = $38 等)。 */
#define KEY_UP              '8'
#define KEY_DOWN            '2'
#define KEY_LEFT            '4'
#define KEY_RIGHT           '6'


/* 歩行アニメの速度: 何回移動するごとに frame を 1 つ進めるか。
 * 1 = 毎フレーム切替 (= 一番パタパタ速い)、 大きいほどゆっくり。 */
#define ANIM_PERIOD         1

/* ボール (= BREAK キーで発射) の設定。
 *   色はシアン (= 2。 前景 color bit1=G)。 1 フレームの移動量は横 2 byte
 *   (= 16px = キャラ横移動の倍速) / 縦 8 line。 横を倍にしているのは、
 *   キャラと同じ 1 byte だと弾とキャラの速さが揃って見づらいため。
 *   8x8 ボールなので画面内に置ける上限は:
 *     bx: 0..79 (= 80 - 1 byte)、  by: 0..192 (= 200 - 8 line) */
#define BALL_COLOR          2
#define BALL_STEP_X         2
#define BALL_STEP_Y         8
#define BALL_MAX_X          (SCREEN_W_BYTES - 1)
#define BALL_MAX_Y          (SCREEN_H_LINES - 8)

/* 同時に飛ばせるボールの最大数 (= 3 連射)。 */
#define BALL_MAX            3

/* フレームペーシング (= deadline 方式)。 メイン CPU の周期タイマ IRQ (約2ms、
 * $FD02/$FD03 bit2) を IRQ ハンドラで数える経過 tick カウンタ
 * (timer_init/timer_start/timer_get、 src/asm_timer.s) を使う。 メインループ
 * 先頭で「timer_get() が FRAME_TARGET に達するまでロック → timer_start() で 0
 * に戻す」 ことで、 処理の重い/軽いに関わらず 1 フレームを FRAME_TARGET × 2ms に
 * 揃える。 1 tick ≈ 2ms なので FRAME_TARGET=16 で約 32ms/フレーム (≈30fps)。
 * 大きいほど全体がゆっくり。 IRQ は処理中も数えるのでフレーム揺れが出ない
 * (= ステータスフラグのポーリングでは処理中に過ぎた tick を取りこぼし deadline が
 * 組めないが、 IRQ なら処理中も数え続けられる)。
 * PACE_SAFETY_CAP はタイマ IRQ が来ない環境でのハング防止上限 (= フォール
 * バック。 timer が効けば達する前にロックを抜ける)。 詳細は docs/TIMER.md。 */
#define FRAME_TARGET        16
#define PACE_SAFETY_CAP     8000u

/* 押下方向キー → dir index (= sprite_data の dir-major 並びの方向番号)。
 * c_subprog.h で DIR_DOWN=0, UP=1, RIGHT=2, LEFT=3 と定義しており、
 * sprite_data.s も同じ順序で並ぶ。 */
static unsigned char key_to_dir_index(unsigned char k)
{
    switch (k) {
        case KEY_DOWN:  return DIR_DOWN;
        case KEY_UP:    return DIR_UP;
        case KEY_RIGHT: return DIR_RIGHT;
        case KEY_LEFT:  return DIR_LEFT;
    }
    return DIR_DOWN;
}


int main(void)
{
    /* sprite の左上 (x_byte, y_line)。 byte 単位 / line 単位。 */
    unsigned char x       = 30;
    unsigned char y       = 80;
    /* dir = 0 は「まだ何も押されてない / 停止中」。 動き始めると
     * KEY_UP/DOWN/LEFT/RIGHT のいずれかが入る。 */
    unsigned char dir     = 0;
    /* 現在の向き index (= 0..3、 sub に常駐させてる 4 frame の方向)。 */
    unsigned char dir_idx = DIR_DOWN;
    /* 歩行アニメの現在 frame (= 0..3、 sub 常駐 4 frame の中の index)。 */
    unsigned char frame   = 0;
    /* frame を進めるカウンタ (= ANIM_PERIOD 回移動ごとに frame++)。 */
    unsigned char anim_cnt = 0;

    /* ボール状態 (= 最大 BALL_MAX 個まで同時に飛ばせる = 3 連射)。
     * 各スロット i について:
     *   ball_on[i]  : 0 = 空き、 1 = 飛行中
     *   ball_x/y[i] : ボール左上 (byte 単位 / line 単位)
     *   ball_d[i]   : 飛んでいる方向 (= 発射時のキャラの向き DIR_*)
     * brk_prev は前フレームの BREAK 状態 (= 立ち上がり検出用)。 */
    unsigned char ball_on[BALL_MAX];
    unsigned char ball_x[BALL_MAX];
    unsigned char ball_y[BALL_MAX];
    unsigned char ball_d[BALL_MAX];
    unsigned char brk_prev = 0;
    unsigned char bi;                 /* ボールスロット走査用 */

    for (bi = 0; bi < BALL_MAX; bi++) ball_on[bi] = 0;

    /* ============================================================
     * 起動シーケンス (= この順序を変えると動かなくなる)
     * ============================================================ */

    /* (0) サブCPU を CANCEL でコマンド待ちループへ戻す (= warm start 対策)。
     *
     *   テープ起動 (= BASIC 稼働中に LOADM,,R で本体へ突入) では、 サブCPU
     *   は BASIC のサブシステム処理の途中に居て、 本体の takeover が期待する
     *   「コマンド待ちループ」 状態ではない。 そのまま HALT + 共有RAM コマンド
     *   を送っても同期せず、 subprog (= 描画コード) の転送が成立せず画面が
     *   出ない。 起動時に一度 CANCEL を送ってサブを既知のコマンド待ち状態へ
     *   揃えてから takeover を始める。 ディスク起動 (cold start) では既に
     *   コマンド待ちなので無害。 詳細は docs/CMT.md「warm start 対応」。 */
    sub_cancel();

    /* (1) サブシステム ROM のカーソル blink を OFF にする。
     *
     *   起動直後は サブシステム ROM が VRAM の $0000- 起点に「カーソル
     *   blink」 を継続的に書込んでいて、 これを止めないと自前描画と
     *   重なって画面の左上に余計な点が出続ける。
     *
     *   SCMD_CURSOR の bit0 = 0 で cursor OFF、 bit1 = 0 で PRINT 内
     *   制御文字解釈も OFF (= 雛形では使わない)。 */
    {
        unsigned char p = 0x00;
        subsys_call(SCMD_CURSOR, &p, 1);
    }

    /* (2) sub が cmd を完全に処理し終えるのを待つ ← 重要 ← 重要 ← 重要
     *
     *   subsys_call は cmd コマンド処理 が「cmd を拾った」 ($D382 = 0)
     *   ことを確認するだけで戻ってくる。 cmd handler 本体の完了は
     *   待っていない (= 完了検出が サブシステム ROM 仕様上厄介)。
     *
     *   このまま続けて subprog_init を呼ぶと、 sub_takeover の最初の
     *   sub_halt が「sub が忙しい (BUSY=1) のを HALT 完了と誤判定」
     *   して即抜け → 共有 RAM への main write が反映されない (= 実機
     *   準拠仕様) → 初回 chunk (= 先頭 64 byte) が転送失敗 → subprog
     *   コードが壊れて起動しない。
     *
     *   雛形は雑に delay_loop で吸収。 ちゃんとした実装にするなら
     *   subsys_call の完了検出を cmd 別に実装する必要がある (= PRINT
     *   は $D383 残文字数を見る等)。 */
    delay_loop(500);

    /* (3) subprog 本体 (= asm_subprog.s) を sub の $C300 に転送 + 起動。
     *
     *   起動時は CMD_REG = NOP なので entry → done → rts で何もしない。
     *   この呼び出しの目的は subprog コードを sub にロードすること。 */
    subprog_init();

    /* (4) 初期方向 (DOWN) の 4 frame を sub の $C700 に動的ロード。
     *
     *   16 sprite 全部 (= 4096 byte) は console RAM (4KB) に載らないので、
     *   「今向いてる方向の 4 frame」 (= 1024 byte) だけ常駐させ、 方向が
     *   変わった時に load し直す。 配置先 $C700 は subprog コード末尾
     *   (≒$C46A) より後ろ (= 衝突回避。 docs/SUBPROGRAM.md §3)。 */
    sub_load_dir_frames(dir_idx);

    /* (4.5) パレット設定。 色1=青(背景)、 2/3=赤、 4/5=シアン、 6/7=白。
     *   背景を B plane 単体、 前景を R/G plane だけで描く方式の要。
     *   背景を塗る前に設定しておく。 */
    palette_init();

    /* (4.7) 背景タイル (64x64 モノクロ) を sub に転送してから背景を描く。 */
    sub_load_bgtile();

    /* (5) 背景を 64x64 タイル模様で敷く。 B plane にタイル (青/黒)、 R/G は 0。
     *   sprite はこの上を R/G plane だけで描き、 R=G=0 の部分が自然に背景
     *   模様として透ける (= マスク不要)。 */
    sub_draw_bg();

    /* (6) キーボード入力を有効化 ($FD02 bit0 セット = キーボード IRQ ON)。 */
    kb_init();

    /* (6.5) フレームペーシング用タイマ起動: メイン CPU の周期タイマ IRQ (約2ms)
     *   を許可し、 IRQ ハンドラで経過 tick を数える (= deadline 方式)。 timer_init()
     *   が IRQ ベクタ $FFF8 設置 + $FD02 bit2 でタイマ IRQ 許可 + I フラグ解除を行う
     *   (FIRQ はマスクのまま = BREAK と干渉しない)。 ここで $FD02 は bit2 のみに
     *   なるので kb_init() のキーボード IRQ は無効化される (= キー入力はポーリング)。
     *   timer_start() で経過カウンタを 0 に初期化。 */
    timer_init();
    timer_start();

    /* (6.6) PSG サウンドを初期化して BGM を開始 (= メイン側 I/O。 サブ系統とは
     *   独立)。 以後メインループで毎フレーム sound_tick() を呼んで進める。 */
    sound_init();

    /* (7) 初期 sprite を描画 (= DOWN 向き frame 0 を (30, 80) に)。 */
    sub_blit_sprite(frame, x, y);

    /* (8) テキスト表示のデモ: 画面上部に SCORE をシアン文字で初期表示。
     *   col=2 (= 左から 16px)、 row=4 (= line 4)、 color=2 (= シアン)。
     *   前景 color は bit0=R, bit1=G なので 2 (= G のみ) = シアン。
     *   ※ メインループ先頭で毎フレーム上書き描画し直すので (= spin 値の
     *      デバッグ表示)、 キャラ移動でこの欄が欠けても次フレームで復帰する。 */
    sub_draw_text(2, 4, "SCORE 0000", 2);


    /* ============================================================
     * メインループ — 「最後押下方向キー保持」 連続移動 + 歩行アニメ
     * ============================================================ */
    for (;;) {
        unsigned char k;
        unsigned char nx, ny;
        unsigned spin, g;
        unsigned char d4, d3, d2, d1;
        char buf[12];

        /* フレームペーシング (deadline): 前フレーム開始 (= 前回 timer_start) からの
         * 経過 tick が FRAME_TARGET に達するまでロックしてから timer_start() で 0 に
         * 戻す。 経過 tick はタイマ IRQ (約2ms) が処理中も数えるので、 処理の重い/
         * 軽いに関わらず 1 フレームが FRAME_TARGET × 2ms に揃う。 ロック + リセットは
         * ループ先頭に置く (= 内部に continue があるので全周回を均一にペーシング)。
         * spin はロック中のスピン回数 (= デバッグ表示用)。 PACE_SAFETY_CAP は
         * タイマ IRQ 未発火時のハング防止。 */
        {
            unsigned guard = 0;
            while (timer_get() < FRAME_TARGET && guard < PACE_SAFETY_CAP) {
                guard++;
            }
            timer_start();
            spin = guard;
        }

        /* デバッグ HUD: spin (= ロック中の待ちスピン回数) を 5 桁 10 進で "SCORE"
         * 欄に表示。 安定した値ならタイマ IRQ 順調、 PACE_SAFETY_CAP(=8000) 付近に
         * 張り付くならタイマ IRQ が来ていない (= $FD03 bit2 / $FFF8 ベクタを疑う)、
         * 0 付近なら処理が FRAME_TARGET×2ms を超えている。 描画は上書き (store) なので
         * 前フレームの数字は自動で消える。 桁分解は CMOC の DIV16 ランタイム (未リンク)
         * を避けるため減算ループで行う。 */
        g = spin;
        d4 = 0; while (g >= 10000) { g -= 10000; d4++; }
        d3 = 0; while (g >= 1000)  { g -= 1000;  d3++; }
        d2 = 0; while (g >= 100)   { g -= 100;   d2++; }
        d1 = 0; while (g >= 10)    { g -= 10;    d1++; }
        buf[0] = 'S'; buf[1] = 'C'; buf[2] = 'O'; buf[3] = 'R'; buf[4] = 'E';
        buf[5] = ' ';
        buf[6] = (char)('0' + d4);
        buf[7] = (char)('0' + d3);
        buf[8] = (char)('0' + d2);
        buf[9] = (char)('0' + d1);
        buf[10] = (char)('0' + (unsigned char)g);
        buf[11] = 0;
        sub_draw_text(2, 4, buf, 2);

        /* サウンドを 1 フレーム進める (= BGM 音長カウント + SE 減衰/リリース)。
         * フレームペーシング (timer 待ち) の直後・全 continue の前に置き、 毎フレーム呼ぶ。 */
        sound_tick();

        k = key_check();

        /* キー入力の解釈:
         *   k == 方向キー  → dir 更新 (+ 方向が変わったら 4 frame load)
         *   k != 0 で他のキー → 停止 (= dir = 0)
         *   k == 0 (= 入力なし) → 何もしない (= dir 保持して移動続行) */
        if (k == KEY_UP || k == KEY_DOWN || k == KEY_LEFT || k == KEY_RIGHT) {
            if (k != dir) {
                unsigned char new_idx = key_to_dir_index(k);
                dir = k;
                /* 方向 (= 4 frame セット) が変わった時だけ sub に load
                 * し直す (= 1024 byte 転送、 方向変更時のみで移動中は不要)。 */
                if (new_idx != dir_idx) {
                    dir_idx = new_idx;
                    sub_load_dir_frames(dir_idx);
                    frame    = 0;
                    anim_cnt = 0;
                }
            }
        } else if (k != 0) {
            dir = 0;
        }

        /* --- BREAK キーでボール発射 (立ち上がりエッジで 1 発) ---
         *
         * BREAK は通常キー ($FD01) には流れず $FD04 bit1 に出る。
         * break_check() を毎フレーム読み、 「前回 0・今回 1」 の瞬間だけ
         * 発射する (= 押しっぱなしで連射されないように)。 空きスロットが
         * あれば撃てるので、 最大 BALL_MAX 個 (= 3 連射) まで同時に飛ぶ。 */
        {
            unsigned char brk_now = break_check();
            if (brk_now && !brk_prev) {
                /* 空きスロットを 1 つ探す (= 無ければ撃たない)。 */
                for (bi = 0; bi < BALL_MAX; bi++) {
                    if (!ball_on[bi]) break;
                }
                if (bi < BALL_MAX) {
                    unsigned char nbx, nby;
                    /* キャラ (32x32) の向いている辺からボールを出す。 */
                    switch (dir_idx) {
                        case DIR_UP:    nbx = x + 2; nby = (y >= 8) ? (y - 8) : 0; break;
                        case DIR_DOWN:  nbx = x + 2; nby = y + SPRITE_PX_H;        break;
                        case DIR_RIGHT: nbx = x + SPRITE_W_BYTES; nby = y + 12;    break;
                        default:        nbx = (x >= 1) ? (x - 1) : 0; nby = y + 12; break; /* LEFT */
                    }
                    if (nbx > BALL_MAX_X) nbx = BALL_MAX_X;   /* 画面内にクランプ */
                    if (nby > BALL_MAX_Y) nby = BALL_MAX_Y;
                    ball_on[bi] = 1;
                    ball_x[bi]  = nbx;
                    ball_y[bi]  = nby;
                    ball_d[bi]  = dir_idx;   /* 今キャラが向いている方向へ投げる */
                    sub_draw_ball(nbx, nby, BALL_COLOR);
                    sfx_ball();              /* 発射音 (ch A ノイズ) */
                }
            }
            brk_prev = brk_now;
        }

        /* --- 全ボールの飛翔更新 (毎フレーム、 キャラ静止中も動かす) --- */
        for (bi = 0; bi < BALL_MAX; bi++) {
            unsigned char obx, oby, gone;
            if (!ball_on[bi]) continue;
            obx = ball_x[bi];
            oby = ball_y[bi];
            gone = 0;
            switch (ball_d[bi]) {
                case DIR_UP:
                    if (ball_y[bi] >= BALL_STEP_Y) ball_y[bi] -= BALL_STEP_Y; else gone = 1;
                    break;
                case DIR_DOWN:
                    if (ball_y[bi] + BALL_STEP_Y <= BALL_MAX_Y) ball_y[bi] += BALL_STEP_Y; else gone = 1;
                    break;
                case DIR_RIGHT:
                    if (ball_x[bi] + BALL_STEP_X <= BALL_MAX_X) ball_x[bi] += BALL_STEP_X; else gone = 1;
                    break;
                default: /* LEFT */
                    if (ball_x[bi] >= BALL_STEP_X) ball_x[bi] -= BALL_STEP_X; else gone = 1;
                    break;
            }
            sub_erase_ball(obx, oby);          /* 旧位置の R/G をクリアして消す (背景タイルは B plane に残る) */
            if (gone) {
                ball_on[bi] = 0;               /* 画面端に達した → 消滅 */
            } else {
                sub_draw_ball(ball_x[bi], ball_y[bi], BALL_COLOR);
            }
        }

        /* 停止中 (= 起動直後の dir=0 か、 方向キー以外で停止された) は
         * (ボール更新は上で済ませたので) ここでループ先頭に戻る。 */
        if (dir == 0) continue;

        /* 次の位置 (nx, ny) を計算。 画面端で外に出る場合は据え置き
         * (= nx == x, ny == y)。 */
        nx = x;
        ny = y;
        switch (dir) {
            case KEY_UP:
                if (y >= STEP_Y_LINES) ny = y - STEP_Y_LINES;
                break;
            case KEY_DOWN:
                if (y + STEP_Y_LINES <= SCREEN_H_LINES_MAX) ny = y + STEP_Y_LINES;
                break;
            case KEY_LEFT:
                if (x >= STEP_X_BYTES) nx = x - STEP_X_BYTES;
                break;
            case KEY_RIGHT:
                if (x + STEP_X_BYTES <= SCREEN_W_BYTES_MAX) nx = x + STEP_X_BYTES;
                break;
        }

        /* 端で動けない時 (= 壁): 何もしない。
         *
         * 描画 (= 消去→再描画) は「実際に位置が変わる時」 だけ行う。
         * 動けないのに毎ループ消去→描画を繰り返すのは無駄で、 不要な
         * ちらつきの元にもなる。 向きを変えても、 実際に動き出すまで
         * 画面の sprite は据え置き (= 動いた瞬間に新しい向きで描かれる)。 */
        if (nx == x && ny == y) {
            continue;
        }

        /* 歩行アニメ: ANIM_PERIOD 回移動するごとに frame を 1 つ進める
         * (= 0→1→2→3→0...)。 sub には現在方向の 4 frame が常駐してるので
         * frame index をそのまま sprite_id として渡せる。 */
        anim_cnt++;
        if (anim_cnt >= ANIM_PERIOD) {
            anim_cnt = 0;
            frame = (frame + 1) & 3;        /* 0..3 を循環 */
            sfx_walk();                     /* 歩行音 (ch B) を 1 歩ぶん */
        }

        /* 旧位置 erase + 新位置 blit を atomic move で 1 回にまとめる
         * (= sub 側で連続実行)。 */
        sub_move_sprite(frame, x, y, nx, ny);
        x = nx;
        y = ny;
    }

    return 0;   /* ここには到達しない */
}
