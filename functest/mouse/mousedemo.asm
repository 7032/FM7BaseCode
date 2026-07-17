; =============================================================================
; mousedemo.asm — メインCPU側プログラム (画面モード切替ボタン付きマウスデモ)
;
; ディスク直接ブート (F-BASIC 不要):
;   ブートローダはトラック0 サイド0 のセクタ1 (256バイト) を $0100 へ
;   読み込み、$0100 へジャンプする。残りのセクタは IPL 自身が FDC
;   (MB8877 相当、I/O $FD18-$FD1F) を直接操作して読み込む。
;   ブートROM/ブートRAM 内のルーチンに依存しない (版差異に強い)。
;   FM-7 (DOSモード) と FM77AV系のどちらのブート経路でも同じに動く。
;
; 本プログラムの流れ:
;   IPL  : サイド0 セクタ2-16 を $0200-$10FF、サイド1 セクタ1-16 を
;          $1100-$20FF へ読み込む
;   MAIN : 機種判別 (FM-7 / FM77AV系) → デジタルパレット恒等化
;          → AV系ならアナログパレット恒等マップ初期化
;          → サブモニタの正規コマンド ($3F バイトコード) で描画プログラムを
;            サブRAMへ転送・起動 (機種レベルの最終確定はサブ側が行う)
;          → 選択中の方式でマウスをポーリングし座標・ボタン・方式を
;            共有RAM経由でサブへ渡す。方式はキー '0'/'1'/'2' で切替:
;              '0' = バスマウス ($FDE8)
;              '1' = インテリジェントマウス ポート1 (OPN ジョイスティック端子)
;              '2' = インテリジェントマウス ポート2
;            (バスは移動量の符号を反転してラッチする一方、インテリジェントは
;             符号反転なしでラッチするため、方式毎に符号を揃えてから積算する。
;             ボタン極性もバス=正論理／インテリジェント=負論理で逆なので、
;             共通の内部表現 (bit4=左, bit5=右, 押下=1) へ正規化してから渡す)
;            (移動量は 640 幅モードで X 2倍、400 ラインモードで Y 2倍に
;             スケーリングし、全モードで物理的なカーソル速度を一致させる)
;          → キーボードは $FD02←#$01 でメインCPUへ解放し、$FD03 bit0 の
;            ポーリングで受ける (割込みベクタは触らない)
;          → 左クリックで画面上部のモードボタンをヒットテストし、
;            対応モードなら画面モードレジスタを切り替えてサブへ再描画指示
;            (カーソル座標は新旧モードの解像度比で変換して引き継ぐ)
;
; 画面モード (0-3、起動時は全機種とも 0):
;   0: 640x200 8色      $FD12 bit6=0                     (全機種)
;   1: 320x200 4096色   $FD12 bit6=1                     (FM77AV系)
;   2: 640x400 8色      $FD12 bit6=0 + $FD04 bit3=0      (AV40系)
;   3: 320x200 262144色 $FD12 bit6=1 + $FD04 bit4=1      (AV40系)
;   $FD04 (AV40系のみ): bit3=0 で400ライン / bit4=1 かつ bit3=1 で26万色。
;   モード0/1 へ戻すときは $08 (400ライン解除・26万色解除) を書く。
;   FM-7 では $FD12/$FD04/$FD30-$FD34 に書き込まない (判別後に分岐)。
;
; 機種判別:
;   FM-7 / AV系: ブート直後 (640モード) に $FD12 を読む。AV系は bit6=0、
;   FM-7 は未実装でオープンバス ($FF、bit6=1) になることを利用する。
;   AV40系の判別はサブCPU側 ($D42F の読み返し) で行い、共有RAMで受け取る。
;
; ビルド: lwasm --6809 --format=raw -o mousedemo_main.bin mousedemo.asm
; =============================================================================

        org     $0100

; ---- 共有RAM メールボックス (メイン側アドレス、サブ側は $D380- に対応) ----
SH_CMD  equ     $FC82           ; サブモニタコマンドバイト
SH_SEQ  equ     $FC83           ; 更新カウンタ
SH_XH   equ     $FC84           ; カーソルX座標 (16ビット)
SH_YH   equ     $FC86           ; カーソルY座標 (16ビット)
SH_BTN  equ     $FC88           ; ボタン状態
SH_MODE equ     $FC89           ; 画面モード (0-3)
SH_AVF  equ     $FC8A           ; 機種フラグ (0=FM-7 / 1=AV系)
SH_BC   equ     $FC8B           ; バイトコード領域 (転送時のみ使用)
SH_SQV  equ     $FC9B           ; 転送: シーケンス値
SH_ACK  equ     $FC9C           ; 転送: ack セル
SH_METH equ     $FC9D           ; マウス読み取り方式 (0=バス / 1=インテリジェントP1 / 2=P2)
                                ;   (転送バイトコード領域 $FC8B-$FC99 の外に置く)
; ---- 生読み値の診断表示セル (毎サンプル更新。ブートスクラッチ $FC8B-$FC99 の外) ----
SH_RAW  equ     $FC9E           ; 生読み値 12 バイト: BUS[0-3] / P1[4-7] / P2[8-11]
SH_R15P1 equ    $FCAA           ; P1 のストローブ reg15 値 ($13)
SH_R15P2 equ    $FCAB           ; P2 のストローブ reg15 値 ($6C)
SH_PAY  equ     $FCA0           ; 転送: ペイロード 96 バイト (ブート時のみ。以後 SH_RAW と共用)
SH_BG   equ     $FC90           ; 背景描画完了マーカー ($A5、サブが書く)
SH_LVL  equ     $FC92           ; 機種レベル (0/1/2、サブが書く)

NCHUNK  equ     32              ; 転送チャンク数 (32 x 96 = 3072 バイト、サブ全体を包含)
ISETTLE equ     $18             ; ストローブ整定待ちのループ回数

; =============================================================================
; IPL: サイド0 セクタ2-16 → $0200-$10FF、サイド1 セクタ1-16 → $1100-$20FF
;
; FDC レジスタ (DP=$FD):
;   $FD18 ステータス(R)/コマンド(W)  $FD19 トラック  $FD1A セクタ
;   $FD1B データ  $FD1C サイド(bit0)  $FD1D ドライブ(bit1-0)+モータ(bit7)
;   $FD1F bit7=DRQ / bit6=IRQ(コマンド完了)
; =============================================================================
IPL:    orcc    #$50
        lds     #$0100          ; スタックはゼロページへ (本体で張り直す)
        lda     #$FD
        tfr     a,dp            ; I/O は DP=$FD の直接アドレシングで参照

        ; ---- ドライブ0 選択 + モータON、サイド0 ----
        lda     #$80
        sta     <$1D            ; モータON, ドライブ0
        clr     <$1C            ; サイド0

        ; ---- RESTORE: ヘッドとトラックレジスタをトラック0 へ ----
        lda     <$18            ; 直前のステータス/IRQ を読み捨て
        lda     #$03            ; RESTORE (ステップレート最遅)
        sta     <$18
IPLRW:  lda     <$1F
        bita    #$40            ; IRQ = コマンド完了
        beq     IPLRW
        lda     <$18            ; 完了ステータス読み出し (IRQ クリア)

        ; ---- サイド0: セクタ2-16 → $0200- ----
        lda     #2              ; セクタ番号
        ldx     #$0200          ; ロード先
IPLLP:  bsr     RDSEC
        bcs     IPLLP           ; エラー時は同一セクタをリトライ
        leax    256,x
        inca
        cmpa    #17
        bne     IPLLP

        ; ---- サイド1: セクタ1-16 → $1100- ----
        lda     #1
        sta     <$1C            ; サイド1
        lda     #1
IPLLP2: bsr     RDSEC
        bcs     IPLLP2
        leax    256,x
        inca
        cmpa    #17
        bne     IPLLP2
        jmp     MAIN

; -----------------------------------------------------------------------------
; RDSEC: セクタ A (256バイト) をアドレス X へ読む。A/X は保存。エラー時 C=1
;   READ SECTOR 発行後、$FD1F の DRQ (bit7) 毎に $FD1B から 1 バイト引き取り、
;   IRQ (bit6) で完了。ステータスの RNF/CRC/LOST DATA をエラーとする。
; -----------------------------------------------------------------------------
RDSEC:  pshs    a,x
        sta     <$1A            ; セクタレジスタ
        lda     #$80            ; READ SECTOR (単レコード)
        sta     <$18
RDLP:   lda     <$1F
        bmi     RDGET           ; bit7=DRQ: データ引き取り
        bita    #$40
        beq     RDLP            ; DRQ も IRQ も無し: 待ち継続
        lda     <$18            ; IRQ: 完了ステータス取得 (IRQ クリア)
        anda    #$1C            ; RNF($10)/CRC($08)/LOST DATA($04)
        beq     RDOK
        puls    a,x
        orcc    #$01            ; C=1: エラー
        rts
RDGET:  lda     <$1B
        sta     ,x+
        bra     RDLP
RDOK:   puls    a,x
        andcc   #$FE            ; C=0: 正常
        rts

        zmb     $0200-*

; =============================================================================
; MAIN: 機種判別・パレット初期化・サブ起動・マウスポーリング・ヒットテスト
; =============================================================================
MAIN:   orcc    #$50
        lds     #$3F00
        lda     #$FD
        tfr     a,dp

        ; ---- 機種判別 (FM-7 / AV系): ブート直後は 640 モードなので
        ;      AV系では $FD12 bit6=0。FM-7 はオープンバス $FF (bit6=1) ----
        clr     MACHAV
        lda     <$12
        bita    #$40
        bne     ISFM7
        lda     #1
        sta     MACHAV
ISFM7:
        ; ---- OPN を初期化 (プリスケーラ + ポート方向) ----
        lbsr    INITOPN

        ; ---- デジタルパレット恒等化 ($FD38-$FD3F ← 0-7、全機種) ----
        ldx     #$FD38
        clrb
DPLP:   stb     ,x+
        incb
        cmpb    #8
        bne     DPLP
        clr     <$37            ; $FD37: マルチページマスク解除

        ; ---- AV系のみ: アナログパレット恒等マップ
        ;      (添字 i → G=(i>>8)&15, R=(i>>4)&15, B=i&15) ----
        tst     MACHAV
        beq     PALSKP
        ldx     #0
PALLP:  tfr     x,d
        sta     <$30            ; $FD30: パレットアドレス上位
        stb     <$31            ; $FD31: パレットアドレス下位
        stb     <$32            ; $FD32: 青 (下位ニブルのみ有効)
        tfr     b,a
        lsra
        lsra
        lsra
        lsra
        sta     <$33            ; $FD33: 赤
        tfr     x,d
        sta     <$34            ; $FD34: 緑
        leax    1,x
        cmpx    #$1000
        bne     PALLP
PALSKP:

        ; =====================================================================
        ; サブCPUプログラムの転送と起動 — サブモニタの正規コマンド $3F を使う
        ;
        ; サブモニタは共有RAM (メイン $FC80-$FCFF = サブ $D380-$D3FF) の
        ; コマンドバイト (サブ $D382) を監視し、非ゼロなら実行して 0 に戻す。
        ; コマンド $3F はサブ $D38B からのバイトコード列を解釈する:
        ;   $90            : 終了
        ;   $91 src dst len: メモリ転送 (各2バイト、ビッグエンディアン)
        ;   $92 addr       : バイトコード継続位置の変更
        ;   $93 addr       : サブ空間の機械語を JSR で呼び出す
        ; これを使い、サブプログラムを 96 バイト x NCHUNK チャンクで
        ; サブRAM $C100- へ転送し、最後に $93 で起動する。
        ; ROM 版に依存する内部番地 (スタック位置等) を仮定しない。
        ; このコマンド体系は FM-7 と FM77AV系で共通 (サブモニタは同一) 。
        ;
        ; チャンク毎の完了検知は二重化する:
        ;   (1) バイトコード末尾に「シーケンス値セル (サブ $D39B) を
        ;       ack セル (サブ $D39C) へ転送」を足し、$FC9C の一致で確認
        ;   (2) $FC82 が 0 (モニタがコマンドを消費済) に戻るのを確認
        ;
        ; 注意: 共有RAM (メイン $FC80-$FCFF) はデュアルポート調停のため
        ; サブCPUが HALT している間しかメイン側から読み書きできない。
        ; 全アクセスを HALT/RUN で包み、サブに実行時間を与えつつ進める。
        ; =====================================================================

        ; ---- サブモニタがコマンド待ちに入るまで待つ ----
WBUSY:  lda     <$04
        bmi     WBUSY           ; $FD04 bit7=1 の間はビジー

        lda     #1
        sta     CHKN            ; チャンク番号 (= ack 照合値)
        ldx     #$1000          ; 転送元 (メイン側、IPL がロード済)
        ldy     #$C100          ; 転送先 (サブ側)

CHUNK:  lbsr    HALTON
        lda     SH_CMD
        beq     CHGO            ; モニタがアイドルなら送信
        lbsr    HALTOFF         ; まだ前コマンド処理中: 実行時間を与える
        lbsr    DLYS
        lbra    CHUNK
CHGO:   ; ---- (HALT中) ペイロード 96 バイト → $FCA0 (サブ $D3A0) ----
        ldu     #SH_PAY
CPY96:  lda     ,x+
        sta     ,u+
        cmpu    #$FD00
        bne     CPY96
        ; ---- バイトコード組立: [$91 $D3A0 dst 96] [$91 $D39B $D39C 1] [$90] ----
        ldu     #SH_BC
        lda     #$91
        sta     ,u+
        ldd     #$D3A0
        std     ,u++            ; src = ペイロード (サブ側番地)
        sty     ,u++            ; dst
        ldd     #96
        std     ,u++            ; len
        lda     #$91
        sta     ,u+
        ldd     #$D39B
        std     ,u++            ; src = シーケンス値セル
        ldd     #$D39C
        std     ,u++            ; dst = ack セル
        ldd     #1
        std     ,u++            ; len = 1
        lda     #$90
        sta     ,u              ; 終了
        lda     CHKN
        sta     SH_SQV          ; シーケンス値
        clr     SH_ACK          ; ack クリア
        lda     #$3F
        sta     SH_CMD          ; コマンド発行
        lbsr    HALTOFF         ; サブ再開 → モニタがコマンドを実行
WACK:   lbsr    DLYS            ; サブに実行時間を与える
        lbsr    HALTON
        lda     SH_ACK
        cmpa    CHKN
        bne     WNOT            ; ack 未達
        lda     SH_CMD
        bne     WNOT            ; コマンド未消費
        lbsr    HALTOFF         ; チャンク完了
        leay    96,y
        inc     CHKN
        lda     CHKN
        cmpa    #NCHUNK+1
        bne     CHUNK
        lbra    TKDONE
WNOT:   lbsr    HALTOFF
        lbra    WACK

        ; ---- 共有RAM メールボックス初期化 + 起動コマンド (HALT中に書く) ----
TKDONE: lbsr    READALL         ; 初期生値を読む (メインI/Oのみ。HALT不要)
        lbsr    HALTON
        ldd     #320
        std     SH_XH           ; X 座標初期値 (モード0 の中央)
        ldd     #100
        std     SH_YH           ; Y 座標初期値
        clr     SH_BTN          ; ボタン状態
        clr     SH_MODE         ; モード0 (640x200 8色) で開始
        clr     SH_METH         ; 方式0 (バスマウス) で開始
        ; ---- 初期生値を共有RAMへ + LRAW を初期化 (起動直後の空送信を防ぐ) ----
        ldx     #RAWBUS
        ldy     #SH_RAW
        ldb     #12
TKRAW:  lda     ,x+
        sta     ,y+
        decb
        bne     TKRAW
        lda     #$13
        sta     SH_R15P1
        lda     #$6C
        sta     SH_R15P2
        ldx     #RAWBUS
        ldy     #LRAW
        ldb     #12
TKRAW2: lda     ,x+
        sta     ,y+
        decb
        bne     TKRAW2
        lda     MACHAV
        sta     SH_AVF          ; 機種フラグをサブへ渡す
        lda     #1
        sta     SH_SEQ          ; 更新カウンタ
        ; 起動: バイトコード $93 (CALL $C100)。デモは戻らない
        ldu     #SH_BC
        lda     #$93
        sta     ,u+
        ldd     #$C100
        std     ,u
        lda     #$3F
        sta     SH_CMD
        lbsr    HALTOFF         ; サブ再開 → デモ開始

        ; ---- サブの初期描画完了を待ち、機種レベル (0/1/2) を受け取る ----
WLVL:   lbsr    DLYS
        lbsr    HALTON
        lda     SH_BG
        cmpa    #$A5
        beq     GOTLVL
        lbsr    HALTOFF
        bra     WLVL
GOTLVL: lda     SH_LVL          ; (HALT中に取得)
        lbsr    HALTOFF
        ldx     #MASKTB
        tfr     a,b
        lda     b,x
        sta     ENMASK
        ; ---- キーボードをメインCPUへ解放 (以後 $FD03 bit0 でポーリング) ----
        lda     #$01
        sta     <$02            ; $FD02 bit0=1: キーIRQをメインへ (ベクタは使わない)
        lbra    MOUSLP

MASKTB: fcb     $01,$03,$0F     ; 機種レベル 0/1/2 → 有効モードマスク

; -----------------------------------------------------------------------------
; HALTON/HALTOFF: サブCPUの停止・再開 (A を破壊)
; DLYS: 短い待ち (サブへ実行時間を与える)
; -----------------------------------------------------------------------------
HALTON: lda     #$80
        sta     <$05            ; $FD05 bit7=1: HALT 要求
HLT1:   lda     <$05
        bpl     HLT1            ; HALT 完了 (bit7=1) を待つ
        rts
HALTOFF:
        clr     <$05            ; RUN
        rts
DLYS:   pshs    x
        ldx     #300
DLY1:   leax    -1,x
        bne     DLY1
        puls    x,pc

; =============================================================================
; マウスポーリングループ (方式切替対応)
;
; 各ポーリングで以下を行う:
;   1. キーボードを $FD03 bit0 でポーリングし、'0'/'1'/'2' で方式 (MMODE) を切替
;   2. 選択中の方式でマウスを読み、DXV/DYV (右・下が正)、BTNNEW (bit4=左,
;      bit5=右, 押下=1) を得る
;   3. 移動量を積算・クランプ、左押下エッジでモードボタンをヒットテスト
;   4. 座標/ボタン/モード/方式が変化したらサブへ送る
;
; バスマウス ($FDE8) の読み値の形式: bit7=1 (接続), bit6=0, bit5=右, bit4=左
;   (押下=1), bit3-0=移動量ニブル。下位2ビット非ゼロの書込みでラッチし、以後
;   4 回の読みで X下位/X上位/Y下位/Y上位 の順 (右・下が正、2の補数)。
;   I/F 非搭載機では bit6=1 になるためそのポーリングを捨てる。
;
; インテリジェントマウス (OPN ジョイスティック端子) の読み出しは IEDGE/RDINTEL
; 参照。バスと違い移動量は符号反転なしでラッチされ、ボタンは負論理のため、
; 読んだ後に符号とボタン極性を揃えて共通表現へ正規化する。
;
; 移動量スケーリング: 640 幅モード (0/2) は横のピクセル密度が 320 幅の
; 2 倍、400 ラインモード (2) は縦の密度が 200 ラインの 2 倍のため、
; 1 カウント=1 ピクセルの等倍加算では見かけの移動速度が半分になる。
; XSCL/YSCL (モード切替時に更新) が立っていれば移動量を 2 倍して積算し、
; 全モードで画面上の物理的な移動速度を一致させる (320x200 系が基準)。
; =============================================================================
MOUSLP: ldx     #200            ; 約1ms の待ち
DLY:    leax    -1,x
        bne     DLY

        ; ---- キーボードポーリング: '0'/'1'/'2' で方式切替 ----
        lda     <$03            ; $FD03: IRQ ステータス (bit0=0 でキーあり)
        bita    #$01
        bne     NOKEY           ; bit0=1: キーなし
        lda     <$01            ; $FD01: キーコード取得 (読むとフラグ解除)
        suba    #$30            ; '0'..'2' → 0..2
        bmi     NOKEY           ; '0' 未満
        cmpa    #2
        bhi     NOKEY           ; '2' 超
        cmpa    MMODE
        beq     NOKEY           ; 同一方式なら何もしない
        sta     MMODE           ; 方式切替 (キー操作のみで変わる)
        lda     #1
        sta     METHCHG         ; 変化を強制送信 (画面の方式表示を更新させる)
NOKEY:
        ; ---- 3 系統 (バス/P1/P2) を各 1 サンプル読み、生バイトを保存 ----
        ;      (画面には 3 系統を常時表示。カーソル駆動は選択中方式のみ)
        lbsr    READALL

        ; ---- 選択方式 (MMODE) の生バイトを復号して DXV/DYV/BTNNEW を得る ----
        lda     MMODE
        beq     DECBUS
        cmpa    #1
        beq     DECP1
        ldx     #RAWP2          ; 方式2: P2 の生バイト
        bra     DECINT
DECP1:  ldx     #RAWP1          ; 方式1: P1 の生バイト
        bra     DECINT

        ; ---- 方式0: バスマウス生バイト (RAWBUS) を復号 ----
DECBUS: lda     RAWBUS          ; フェーズ0: X下位ニブル + ボタン (bit4/5)
        bita    #$40            ; bit6=1: マウス I/F 無し (実装外の読み値)
        bne     MSKIP           ;   → 移動量無視。方式変化のみ送信し得る
        sta     TMPB
        anda    #$0F
        sta     TMPN
        lda     RAWBUS+1        ; フェーズ1: X上位ニブル
        asla
        asla
        asla
        asla
        ora     TMPN
        sta     DXV             ; 右方向が正のまま積算に使う
        lda     RAWBUS+2        ; フェーズ2: Y下位ニブル
        anda    #$0F
        sta     TMPN
        lda     RAWBUS+3        ; フェーズ3: Y上位ニブル
        asla
        asla
        asla
        asla
        ora     TMPN
        sta     DYV             ; 下方向が正のまま積算に使う
        lda     TMPB
        anda    #$30            ; バス: ボタンは正論理 (押下=1)
        sta     BTNNEW
        lbra    MACCUM

        ; ---- バスマウス I/F 非搭載: 移動なし・ボタン据置。方式変化のみ拾う ----
MSKIP:  clr     DXV
        clr     DYV
        lda     BTN
        sta     BTNNEW
        lbra    MACCUM

        ; ---- インテリジェント生バイト (X=RAWP1/RAWP2) を復号 ----
        ;   並び [0]=X上位 [1]=X下位 [2]=Y上位 [3]=Y下位、ボタンは [3]。
        ;   符号反転なしでラッチされるため nega で右・下を正へ揃える。
        ;   4 読みとも $FF なら無応答 (移動0・ボタン解放)。
DECINT: lda     ,x
        anda    1,x
        anda    2,x
        anda    3,x
        cmpa    #$FF
        beq     DINONE
        lda     ,x              ; X上位
        asla
        asla
        asla
        asla
        anda    #$F0
        sta     TMPN
        lda     1,x             ; X下位
        anda    #$0F
        ora     TMPN
        nega
        sta     DXV
        lda     2,x             ; Y上位
        asla
        asla
        asla
        asla
        anda    #$F0
        sta     TMPN
        lda     3,x             ; Y下位
        anda    #$0F
        ora     TMPN
        nega
        sta     DYV
        lda     3,x             ; ボタン (負論理 → 反転して押下=1)
        coma
        anda    #$30
        sta     BTNNEW
        lbra    MACCUM
DINONE: clr     DXV
        clr     DYV
        clr     BTNNEW
        lbra    MACCUM

        ; =====================================================================
        ; MACCUM: 共通の積算・ヒットテスト・送信 (DXV/DYV/BTNNEW を入力とする)
        ; =====================================================================
MACCUM:
        ; ---- X 積算 + クランプ (0..MAXX)。640 幅モードでは移動量 2 倍 ----
        ldb     DXV
        beq     NOX
        sex
        tst     XSCL
        beq     XADD
        aslb                    ; D = 移動量 x2 (符号付き 16 ビット)
        rola
XADD:   addd    POSX
        bpl     XCLP
        ldd     #0
        bra     XSTO
XCLP:   cmpd    MAXX
        ble     XSTO
        ldd     MAXX
XSTO:   std     POSX
NOX:    ; ---- Y 積算 + クランプ (0..MAXY)。400 ラインモードでは移動量 2 倍 ----
        ldb     DYV
        beq     NOY
        sex
        tst     YSCL
        beq     YADD
        aslb                    ; D = 移動量 x2 (符号付き 16 ビット)
        rola
YADD:   addd    POSY
        bpl     YCLP
        ldd     #0
        bra     YSTO
YCLP:   cmpd    MAXY
        ble     YSTO
        ldd     MAXY
YSTO:   std     POSY
NOY:    ; ---- 左ボタン押下エッジならモードボタンのヒットテスト ----
        lda     BTNNEW
        bita    #$10
        beq     NOHIT
        lda     BTN
        bita    #$10
        lbeq    HITTST          ; 新規押下 → ヒットテストへ
NOHIT:

        ; ---- 変化がなければ送信しない (方式変化は毎回送る) ----
        lda     METHCHG
        bne     SEND
        lda     BTNNEW
        cmpa    BTN
        bne     SEND
        ldd     POSX
        cmpd    LASTX
        bne     SEND
        ldd     POSY
        cmpd    LASTY
        bne     SEND
        ; ---- 生読み値が変わっていれば診断表示のため送信 ----
        ;      (座標が動かなくても実機の生値変化を画面へ反映させる = 診断の要) ----
        ldx     #RAWBUS
        ldy     #LRAW
        ldb     #12
RCHK:   lda     ,x+
        cmpa    ,y+
        lbne    SEND
        decb
        bne     RCHK
        lbra    MOUSLP

SEND:   ; ---- サブCPUを停止して座標・モード・方式を渡す (アトミック性確保) ----
        lbsr    HALTON
        ldd     POSX
        std     SH_XH
        ldd     POSY
        std     SH_YH
        lda     BTNNEW
        sta     SH_BTN
        lda     CURMODE
        sta     SH_MODE
        lda     MMODE
        sta     SH_METH         ; 現在の方式コード
        clr     METHCHG
        ; ---- 生読み値 (12バイト) + ストローブ reg15 値を共有RAMへ ----
        ldx     #RAWBUS
        ldy     #SH_RAW
        ldb     #12
SNRAW:  lda     ,x+
        sta     ,y+
        decb
        bne     SNRAW
        lda     #$13
        sta     SH_R15P1
        lda     #$6C
        sta     SH_R15P2
        inc     SEQC
        lda     SEQC
        sta     SH_SEQ          ; 更新カウンタは最後に書く
        lbsr    HALTOFF         ; サブCPU再開
        ; ---- 送った生値を LRAW へ控える (次サンプルの変化検知用) ----
        ldx     #RAWBUS
        ldy     #LRAW
        ldb     #12
SNRAW2: lda     ,x+
        sta     ,y+
        decb
        bne     SNRAW2
        ldd     POSX
        std     LASTX
        ldd     POSY
        std     LASTY
        lda     BTNNEW
        sta     BTN
        lbra    MOUSLP

; =============================================================================
; READALL: バス/P1/P2 の 3 系統を各 1 サンプル (4 リード) 読み、生バイトを
;   RAWBUS/RAWP1/RAWP2 へ格納する (BUS/P1/P2 の 3 行同時表示による診断用)。
;   カーソル駆動には選択中方式の生バイトだけを別途復号して使う。
;
;   バス   : $FDE8 へラッチ書込み後 4 リード (X下位/X上位/Y下位/Y上位 + ボタン)。
;            I/F 非搭載機では bit6=1、非接続時は bit7 のみ ($80) が返る。
;   P1/P2  : OPN ジョイスティック端子経由。$FD15/$FD16 の OPN コマンドで
;            reg15 (ポートB出力) にポート選択+ストローブ+トリガを書き、
;            reg14 (ポートA入力) を JOYSTICK コマンドで 4 フェーズ読む (IEDGE)。
;            P1 = 選択00+トリガ11+ストローブ bit4、
;            P2 = 選択01($40)+トリガ11+ストローブ bit5。
;            非接続/無応答時は 4 読みとも $FF になる。
;
;   3 系統を毎サンプル読むが、選択外ポートのストローブ/ラッチ書込みは移動量
;   アキュムレータを消費しないため、選択中方式のカーソル挙動は影響を受けない。
; =============================================================================
READALL:
        ; ---- バス: ラッチ + 4 リード → RAWBUS ----
        lda     #$03
        sta     <$E8            ; 下位2ビット非ゼロの書込み = ラッチ
        ldx     #RAWBUS
        ldb     #4
RALB:   lda     <$E8
        sta     ,x+
        decb
        bne     RALB
        ; ---- P1: 選択00+トリガ11, ストローブ bit4 → RAWP1 ----
        lda     #$03
        sta     IMBASE
        lda     #$10
        sta     IMSTRB
        ldx     #RAWP1
        lbsr    RDEDGES
        ; ---- P2: 選択01($40)+トリガ11, ストローブ bit5 → RAWP2 ----
        lda     #$4C
        sta     IMBASE
        lda     #$20
        sta     IMSTRB
        ldx     #RAWP2
        lbsr    RDEDGES
        rts

; -----------------------------------------------------------------------------
; RDEDGES: IMBASE/IMSTRB を用い 4 エッジ読みを X[0..3] へ格納
;   ([0]=X上位 [1]=X下位 [2]=Y上位 [3]=Y下位 のフェーズ順、bit4/5=ボタン)。
;   ストローブ線を 立て→伏せ を 2 周させ各エッジ後に reg14 を読む。
; -----------------------------------------------------------------------------
RDEDGES:
        lda     IMBASE
        ora     IMSTRB
        lbsr    IEDGE
        sta     ,x
        lda     IMBASE
        lbsr    IEDGE
        sta     1,x
        lda     IMBASE
        ora     IMSTRB
        lbsr    IEDGE
        sta     2,x
        lda     IMBASE
        lbsr    IEDGE
        sta     3,x
        rts

; -----------------------------------------------------------------------------
; OPNW: OPN レジスタ A に値 B を書く (DP=$FD 前提)。
;   ADDRESS でレジスタ番号を選び、WRITEDAT で値を書く。各コマンドの後に
;   $00 (INACTIVE) を書いてコマンドラッチを解除する。A は破壊、B は保持。
; -----------------------------------------------------------------------------
OPNW:   sta     <$16            ; データ = レジスタ番号 (A)
        lda     #$03
        sta     <$15            ; ADDRESS: selreg = A
        clra
        sta     <$15            ; INACTIVE (ラッチ解除)
        stb     <$16            ; データ = 値 (B)
        lda     #$02
        sta     <$15            ; WRITEDAT
        clra
        sta     <$15            ; INACTIVE
        rts

; -----------------------------------------------------------------------------
; IEDGE: reg15 に A を書いてストローブを 1 エッジ進め、整定待ちの後 reg14 を
;   読んで A に返す (DP=$FD 前提)。ストローブ書込みの後、ポートA のデータが
;   確定するまで整定時間 (ISETTLE) を置いてから読む。
; -----------------------------------------------------------------------------
IEDGE:  tfr     a,b             ; B = reg15 書込み値
        lda     #15
        bsr     OPNW            ; reg15 ← B (ストローブ 1 エッジ, INACTIVE 込み)
        lda     #ISETTLE        ; ---- ストローブ整定待ち ----
IEDLY:  deca
        bne     IEDLY
        lda     #14
        sta     <$16            ; データ = 14
        lda     #$03
        sta     <$15            ; ADDRESS: selreg = 14
        clra
        sta     <$15            ; INACTIVE
        lda     #$09
        sta     <$15            ; JOYSTICK
        lda     <$16            ; ポートA読み = ニブル+ボタン
        pshs    a               ; 読み値を退避して INACTIVE
        clra
        sta     <$15            ; INACTIVE
        puls    a
        rts

; -----------------------------------------------------------------------------
; INITOPN: OPN (YM2203) をマウス読み出し可能な状態へ初期化する (DP=$FD 前提)。
;   (1) プリスケーラ ($2D/$2E) を設定し SSG 部のクロックを確定する。
;   (2) reg15 に待機値 $3F を置く ($3F: ポート1選択・両ストローブ高・トリガ)。
;   (3) reg7 で ポートB (reg15) を出力・ポートA (reg14) を入力に設定する
;       (内蔵音源は全チャネル停止)。
; -----------------------------------------------------------------------------
INITOPN:
        ; ---- プリスケーラ設定 ($2D→$2E: SSG クロック確定、ポートI/O の前提) ----
        lda     #$2D
        clrb
        bsr     OPNW            ; reg $2D (プリスケーラ)
        lda     #$2E
        clrb
        bsr     OPNW            ; reg $2E (プリスケーラ)
        ; ---- reg15 待機値 $3F → reg7 方向 $BF ----
        lda     #15
        ldb     #$3F
        bsr     OPNW            ; reg15 = $3F (待機値)
        lda     #7
        ldb     #$BF            ; bit7=ポートB出力,bit6=0 ポートA入力,音源停止
        bsr     OPNW            ; reg7 = $BF
        rts

; =============================================================================
; HITTST: 左クリック位置がモードボタン上かを判定し、対応モードなら切り替える
;   ボタン帯はライン 12-27 (最上部のタイトル帯の下)。
;   X 範囲はレイアウト (640幅/320幅) 毎の表で判定。
; =============================================================================
HITTST: ; ---- Y がボタン帯 (12..27) か ----
        ldd     POSY
        cmpd    #12
        lblt    HITEND
        cmpd    #27
        lbgt    HITEND
        ; ---- レイアウト表選択 (モード1/3 = 320幅) ----
        ldx     #HITW
        lda     CURMODE
        anda    #1
        beq     HT0
        ldx     #HITN
HT0:    clr     BIDX
HTLP:   ldd     POSX
        cmpd    ,x
        blt     HTNX
        cmpd    2,x
        ble     HTHIT
HTNX:   leax    4,x
        inc     BIDX
        lda     BIDX
        cmpa    #4
        bne     HTLP
        lbra    HITEND
HTHIT:  ; ---- 押されたボタン = BIDX。現在モードと同じなら何もしない ----
        lda     BIDX
        cmpa    CURMODE
        lbeq    HITEND
        ; ---- 対応機種か (無効ボタンはクリックしても何も起きない) ----
        ldb     BIDX
        lda     #1
HTSH:   tstb
        beq     HTSH2
        asla
        decb
        bra     HTSH
HTSH2:  anda    ENMASK
        lbeq    HITEND
        ; ---- モード切替: 画面レジスタ → 座標系引継ぎ → サブへ指示 ----
        lda     CURMODE
        sta     OLDMD           ; 座標引継ぎ変換用に旧モードを保存
        lda     BIDX
        sta     CURMODE
        tst     MACHAV
        beq     HWSKP           ; FM-7 では画面レジスタに触らない (到達しない筈)
        ldb     CURMODE
        ldx     #FD12T
        lda     b,x
        sta     <$12            ; 320/640 切替
        lda     ENMASK
        bita    #$08
        beq     HWSKP           ; AV40系でなければ $FD04 は触らない
        ldx     #FD04T
        lda     b,x
        sta     <$04            ; 400ライン/26万色切替
HWSKP:  ; ---- クランプ範囲を新モードへ (ldd が B を壊すため都度引き直す) ----
        ldb     CURMODE
        aslb
        ldx     #MAXXT
        ldd     b,x
        std     MAXX
        ldb     CURMODE
        aslb
        ldx     #MAXYT
        ldd     b,x
        std     MAXY
        ; ---- X 座標の引継ぎ: 幅クラス (640/320) が変われば 2倍/半分 ----
        ;      画面上の物理位置を維持する (例: 320 幅の X=160 → 640 幅の X=320)
        lda     OLDMD
        eora    CURMODE
        anda    #1              ; bit0=1 が 320 幅モード
        beq     XCNVD           ; 幅クラス同一: 変換不要
        lda     CURMODE
        anda    #1
        bne     XHALF
        asl     POSX+1          ; 320 幅 → 640 幅: X を 2 倍
        rol     POSX
        bra     XCNVD
XHALF:  lsr     POSX            ; 640 幅 → 320 幅: X を 1/2
        ror     POSX+1
XCNVD:
        ; ---- Y 座標の引継ぎ: ラインクラス (200/400) が変われば 2倍/半分 ----
        ldx     #YSCLT          ; YSCLT は「400 ラインモードか」の表を兼ねる
        ldb     OLDMD
        lda     b,x
        ldb     CURMODE
        eora    b,x
        beq     YCNVD           ; ラインクラス同一: 変換不要
        lda     b,x             ; B=CURMODE のまま: 新モードのクラス
        bne     YDBL
        lsr     POSY            ; 400 ライン → 200 ライン: Y を 1/2
        ror     POSY+1
        bra     YCNVD
YDBL:   asl     POSY+1          ; 200 ライン → 400 ライン: Y を 2 倍
        rol     POSY
YCNVD:
        ; ---- 移動量スケールを新モードへ更新 ----
        ldb     CURMODE
        ldx     #XSCLT
        lda     b,x
        sta     XSCL
        ldx     #YSCLT
        lda     b,x
        sta     YSCL
        lbra    SEND            ; モードを含めて即送信 (サブが全再描画)
HITEND: lbra    NOHIT

; ---- モード別レジスタ値・座標系テーブル ----
FD12T:  fcb     $00,$40,$00,$40 ; $FD12 (bit6 = 320 モード)
FD04T:  fcb     $08,$08,$00,$18 ; $FD04 (AV40系: bit3=0 → 400ライン, bit4=1 → 26万色)
MAXXT:  fdb     639,319,639,319
MAXYT:  fdb     199,199,399,199
XSCLT:  fcb     1,0,1,0         ; X 移動量 2倍フラグ (1 = 640 幅モード)
YSCLT:  fcb     0,0,1,0         ; Y 移動量 2倍フラグ (1 = 400 ラインモード)

; ---- ヒットテスト表: ボタン毎の X 範囲 [x0,x1] (ピクセル) ----
HITW:   fdb     8,151,168,311,328,471,488,631     ; 640 幅レイアウト
HITN:   fdb     0,71,80,151,160,231,240,311       ; 320 幅レイアウト

; ---- ワークエリア ----
POSX:   fdb     320
POSY:   fdb     100
LASTX:  fdb     320
LASTY:  fdb     100
MAXX:   fdb     639
MAXY:   fdb     199
BTN:    fcb     0
BTNNEW: fcb     0
DXV:    fcb     0
DYV:    fcb     0
TMPB:   fcb     0
TMPN:   fcb     0
SEQC:   fcb     1
CHKN:   fcb     0
MMODE:  fcb     0               ; マウス方式 (0=バス / 1=インテリジェントP1 / 2=P2)
METHCHG: fcb    0               ; 方式変化フラグ (次回送信を強制)
IMBASE: fcb     0               ; インテリジェント: reg15 基準値
IMSTRB: fcb     0               ; インテリジェント: ストローブビット
RAWBUS: fcb     0,0,0,0         ; バス 4 生バイト (フェーズ順)
RAWP1:  fcb     0,0,0,0         ; P1  4 生バイト
RAWP2:  fcb     0,0,0,0         ; P2  4 生バイト
LRAW:   fcb     0,0,0,0,0,0,0,0,0,0,0,0  ; 最後に送った 12 生バイト (変化検知用)
MACHAV: fcb     0               ; 0=FM-7 / 1=AV系
CURMODE: fcb    0               ; 現在の画面モード (0-3)
ENMASK: fcb     $01             ; 有効モードマスク (サブの機種レベルから設定)
BIDX:   fcb     0
OLDMD:  fcb     0               ; モード切替時の旧モード (座標引継ぎ変換用)
XSCL:   fcb     1               ; X 移動量 2倍フラグ (初期モード0 = 640 幅)
YSCL:   fcb     0               ; Y 移動量 2倍フラグ (初期モード0 = 200 ライン)

        end
