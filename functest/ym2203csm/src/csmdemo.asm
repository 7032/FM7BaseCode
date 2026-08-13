; =============================================================================
; csmdemo.asm — メインCPU側プログラム (YM2203 CSM 音声再生デモ + 全画面画像)
;
; ディスク直接ブート (F-BASIC 不要):
;   ブートローダはシリンダ0 サイド0 のセクタ1 (256バイト) を $0100 へ
;   読み込み、$0100 へジャンプする。残りのセクタは IPL 自身が FDC
;   (MB8877 相当、I/O $FD18-$FD1F) を直接操作して読み込む。
;   ブートROM/ブートRAM 内のルーチンに依存しない (版差異に強い)。
;
; 本プログラムの流れ:
;   IPL  : シリンダ0 サイド0 セクタ2-16 → $0200-$10FF
;          シリンダ0 サイド1 セクタ1-16 → $1100-$20FF
;          シリンダ1 へシーク後 サイド0 セクタ1-12 → $2100-$2CFF
;   MAIN : 機種判別 (FM-7 / FM77AV系)
;          → デジタルパレット恒等化
;          → AV系なら 320x200 4096色へ切替
;            + 画像データ先頭 2 セクタからアナログパレット 64 エントリを設定
;            (FM-7 では画面モードレジスタ/アナログパレットに一切書かない)
;          → サブモニタの正規コマンド ($3F バイトコード) で描画プログラムを
;            サブRAMへ転送・起動
;          → FM-7 の場合はサブが非対応メッセージを出すので、ここで停止する
;          → AV系: 画像データ (RLE) をディスクから読みながら展開し、
;            80 バイト (= 2 ライン) ずつサブへ送って 6 プレーンへ書かせる。
;            同時に "PUSH ANY KEY" が隠す矩形の元データを退避しておく。
;          → AV系の場合は以下を繰り返す:
;              サブへ "PUSH ANY KEY" 表示指示 (画像の上に黄で重ね書き)
;              → キー入力待ち
;              → 退避しておいた画像を書き戻して文字を消去
;              → CSM 音声再生 → 先頭へ戻る
;          → キーボードとメインCPU周期タイマは $FD02←#$05 で許可し、
;            $FD03 のポーリングで受ける (割込みベクタは触らない。CPU の
;            割込みマスクは orcc #$50 のまま)
;
; 画像データの置き場と転送方式:
;   画像は 320x200 の 64 色 (パレット方式)。6 プレーン x 8000 = 48000 バイトを
;   RLE 圧縮した 1 本のストリームで、パレット 320 バイト + 文字色 1 バイトと
;   合わせてディスクのシリンダ2 以降に置いてある。
;   メインRAM には 32KB 超の圧縮データを置く余地が無いため、**1 セクタずつ
;   読みながら逐次 RLE 展開して転送する**方式にした ($8000 以降を RAM に
;   切り替える必要も無く、FM-7 では 1 セクタも読まないので破綻しない)。
;   展開先はサブ空間の VRAM なので、80 バイトのチャンク単位でサブへ渡す。
;
; フレーム同期の時間源:
;   メインCPU が持つ約 2.0345ms 周期のタイマ ($FD02 bit2 で許可、$FD03 bit2 が
;   active-low で立つ) を 5 回数えて 1 フレーム (10.1725ms) とする。
;   FM-7/FM77AV の基本機能なので実装差が出にくい。OPN のステータス
;   (タイマB オーバーフローフラグ) は読まない — フラグを立てるのに許可ビット
;   ($27 の bit3) が要る実装があり、機種によってはフレーム待ちから抜けられ
;   なくなるため。さらに許可ビットを立てるとステータス経由で IRQ 線を上げる
;   実装があるので、$27 のフラグ許可ビット (bit2/bit3) は 0 のままにし、
;   タイマ B 自体を使わない。CSM に必要なのはタイマ A だけ。
;
; 対応機種:
;   FM77AV / FM77AV40 / FM77AV40EX : 320x200 4096色で画像 + 音声デモを実行
;   FM-7                            : 640x200 8色のまま非対応メッセージで停止
;   AV40系専用レジスタ ($FD04 の 400ライン/262144色ビット等) には触らないため、
;   AV40/AV40EX でも FM77AV と全く同じ動作になる。
;
; 機種判別:
;   ブート直後 (640 モード) に $FD12 を読む。AV系は bit6=0、
;   FM-7 は未実装でオープンバス ($FF、bit6=1) になることを利用する。
;
; ビルド: lwasm --6809 --format=raw -I assets -o csmdemo_main.bin csmdemo.asm
; =============================================================================

        org     $0100

; ---- 共有RAM メールボックス (メイン側アドレス、サブ側は $D380- に対応) ----
SH_CMD  equ     $FC82           ; サブモニタコマンドバイト (ブート時のみ)
SH_SEQ  equ     $FC83           ; 更新カウンタ
SH_TCOL equ     $FC84           ; 文字色のパレット添字
SH_IPL  equ     $FC85           ; BLIT: 書込み先プレーン番号 (0-5)
SH_IOFS equ     $FC86           ; BLIT: プレーン内オフセット (2バイト)
SH_ILEN equ     $FC88           ; BLIT: バイト数 (8 の倍数)
SH_IERR equ     $FC89           ; サブが検出した異常の件数 (0 が正常)
SH_AVF  equ     $FC8A           ; 機種フラグ (0=FM-7 / 1=AV系)
SH_ICNT equ     $FC8B           ; サブが BLIT で書いた総バイト数 (2バイト)
SH_BC   equ     $FC8B           ; バイトコード領域 (ブート時のみ使用)
SH_PRB  equ     $FC9A           ; HALT 確認用プローブセル
SH_SQV  equ     $FC9B           ; 転送: シーケンス値 (ブート時のみ)
SH_ACK  equ     $FC9C           ; 転送: ack セル (ブート時のみ)
SH_REQ  equ     $FC9D           ; リクエスト (1=PUSH ANY KEY 表示 / 3=BLIT)
SH_RACK equ     $FC9E           ; リクエスト ack
SH_RDY  equ     $FC9F           ; サブの初期描画完了マーカー ($A5)
SH_PAY  equ     $FCA0           ; ペイロード (ブート時 96 / BLIT 時は最大 80)

SUBIMG  equ     $2100           ; サブプログラムのロード先 (メイン側の一時置場)
NCHUNK  equ     32              ; 転送チャンク数 (32 x 96 = 3072 バイト)

; ---- 画像表示 (AV系のみ) ----
IMGBUF  equ     $2D00           ; ディスク読込バッファ (512 バイト)
SAVBUF  equ     $3000           ; 文字が隠す矩形の元画像 (6面 x 16行 x 24 = 2304)
CHKBUF  equ     $3900           ; 送信チャンク (80 バイト)
IMGCYL0 equ     2               ; 画像データの先頭シリンダ (サイド0 セクタ1 から)
IPALN   equ     64              ; アナログパレットのエントリ数 (1 エントリ 5 バイト)
CHKSZ   equ     80              ; 1 チャンク = 2 ライン (40 x 2)。8 の倍数であること
AVBPL   equ     40              ; AV: バイト/ライン
IPLNSZ  equ     8000            ; 1 プレーン = 40 x 200
KYCOL   equ     4               ; "PUSH ANY KEY" 左端バイト列 (csmdemo_sub.asm と一致)
KYROW   equ     184             ; 上端ライン (偶数であること)
KYNL    equ     16              ; 高さ (2倍角 = 16 ライン)
KYW     equ     24              ; 幅 (12文字 x 2倍角 = 24 バイト列)。8 の倍数であること

; CSMFRAMES / CSMFRSIZE / csmdata は末尾で取り込む csmdata.s が定義する

; =============================================================================
; IPL: シリンダ0 (両サイド) + シリンダ1 サイド0 を読み込む
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

        ; ---- シリンダ0 サイド0: セクタ2-16 → $0200- ----
        lda     #2
        ldx     #$0200
IPLLP:  bsr     RDSEC
        bcs     IPLLP           ; エラー時は同一セクタをリトライ
        leax    256,x
        inca
        cmpa    #17
        bne     IPLLP

        ; ---- シリンダ0 サイド1: セクタ1-16 → $1100- ----
        lda     #1
        sta     <$1C            ; サイド1
        lda     #1
IPLLP2: bsr     RDSEC
        bcs     IPLLP2
        leax    256,x
        inca
        cmpa    #17
        bne     IPLLP2

        ; ---- シリンダ1 へシーク ----
        clr     <$1C            ; サイド0 へ戻す
        lda     #1
        bsr     SEEKT

        ; ---- シリンダ1 サイド0: セクタ1-12 → $2100- ----
        lda     #1
IPLLP3: bsr     RDSEC
        bcs     IPLLP3
        leax    256,x
        inca
        cmpa    #13
        bne     IPLLP3
        jmp     MAIN

; -----------------------------------------------------------------------------
; SEEKT: トラック A へシーク (データレジスタに目標トラックを置いて SEEK)
;   A 破壊。IPL / 画像読込の双方から使う。
; -----------------------------------------------------------------------------
SEEKT:  sta     <$1B            ; データレジスタ = 目標トラック
        lda     #$1B            ; SEEK (ヘッドロード / ベリファイ無し / 最遅)
        sta     <$18
SEEKW:  lda     <$1F
        bita    #$40
        beq     SEEKW
        lda     <$18            ; 完了ステータス読み出し (IRQ クリア)
        rts

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
; MAIN: 機種判別・画面初期化・サブ起動・画像転送・キー待ちと CSM 再生のループ
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
        ; ---- デジタルパレット恒等化 ($FD38-$FD3F ← 0-7、全機種) ----
        ldx     #$FD38
        clrb
DPLP:   stb     ,x+
        incb
        cmpb    #8
        bne     DPLP
        clr     <$37            ; $FD37: マルチページマスク解除

        ; ---- AV系のみ: 320x200 4096色へ切替 + 画像のアナログパレット設定
        ;      (FM-7 では $FD12 / $FD30-$FD34 に一切書き込まない) ----
        tst     MACHAV
        beq     PALSKP
        lda     #$40
        sta     <$12            ; $FD12 bit6=1: 320x200 4096色
        lbsr    IMGINI          ; 画像先頭 2 セクタ → パレット 64 エントリ + 文字色
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
        ; このコマンド体系は FM-7 と FM77AV系で共通 (サブモニタは同一)。
        ;
        ; 注意: 共有RAM はデュアルポート調停のためサブCPUが HALT している間しか
        ; メイン側から読み書きできない。全アクセスを HALT/RUN で包む。
        ; =====================================================================

WBUSY:  lda     <$04
        bmi     WBUSY           ; $FD04 bit7=1 の間はビジー

        lda     #1
        sta     CHKN            ; チャンク番号 (= ack 照合値)
        ldx     #SUBIMG         ; 転送元 (メイン側、IPL がロード済)
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

        ; ---- 共有RAM 初期化 + 起動コマンド (HALT中に書く) ----
TKDONE: lbsr    HALTON
        clr     SH_REQ
        clr     SH_RACK
        clr     SH_RDY
        clr     SH_SEQ
        lda     MACHAV
        sta     SH_AVF          ; 機種フラグをサブへ渡す
        lda     TXTCOL
        sta     SH_TCOL         ; 重ね書き文字の色 (パレット添字) をサブへ渡す
        ; 起動: バイトコード $93 (CALL $C100)。デモは戻らない
        ldu     #SH_BC
        lda     #$93
        sta     ,u+
        ldd     #$C100
        std     ,u
        lda     #$3F
        sta     SH_CMD
        lbsr    HALTOFF         ; サブ再開 → デモ開始

        ; ---- サブの初期描画完了を待つ ----
WRDY:   lbsr    DLYS
        lbsr    HALTON
        lda     SH_RDY
        cmpa    #$A5
        beq     RDYOK
        lbsr    HALTOFF
        bra     WRDY
RDYOK:  lbsr    HALTOFF

        ; ---- FM-7 は非対応。サブが表示したメッセージを残したまま停止する ----
        tst     MACHAV
        bne     AVGO
        clr     <$1D            ; FDD モータ停止
STOP7:  bra     STOP7

        ; ---- AV系: 画像を流し込んでからデモループへ ----
AVGO:   lbsr    IMGXFR          ; 画像 (RLE) を展開しながらサブへ転送
        clr     <$1D            ; FDD モータ停止 (以後ディスクは使わない)
        lda     #$05
        sta     <$02            ; $FD02 bit0=1: キーIRQをメインへ
                                ; $FD02 bit2=1: 周期タイマ (約2.0345ms) を許可
                                ;   CC の割込みマスクは orcc #$50 のままなので
                                ;   ベクタへは飛ばず、$FD03 のポーリングで受ける
        lbsr    OPNINI
        ; 表示指示より前に読み捨てる。表示中に押されたキーは残すこと
        ;      (表示完了を待ってから捨てると、その間の打鍵を取りこぼす)
DEMOLP: lbsr    KEYDRN          ; 再生中に押されていたキーを読み捨てる
        lda     #1
        lbsr    SUBREQ          ; "PUSH ANY KEY" を画像の上へ重ね書き
        lbsr    KEYWT           ; 何かキーが押されるまで待つ
        lbsr    RESTOR          ; 退避しておいた画像を書き戻して文字を消す
        lbsr    CSMPLY          ; 音声再生 (再生中はキーを見ない)
        bra     DEMOLP

; -----------------------------------------------------------------------------
; HALTON/HALTOFF: サブCPUの停止・再開 (A を破壊)
;   HALTON は $FD05 の bit7 を待つだけでなく、共有RAM へ実際に書けることを
;   プローブセルの書込み/読出しで確かめる。デュアルポートの調停が成立する
;   前は書込みが落ちて読出しが $FF になるため、これを確認しないと
;   「書いたつもりで落ちていた」取りこぼしが起こり得る。
; DLYS: 短い待ち (サブへ実行時間を与える)
; DLYI: BLIT の ack 待ち用の短い待ち
; -----------------------------------------------------------------------------
HALTON: lda     #$80
        sta     <$05            ; $FD05 bit7=1: HALT 要求
HLT1:   lda     <$05
        bpl     HLT1            ; HALT 完了 (bit7=1) を待つ
        lda     #$A5
        sta     SH_PRB          ; 共有RAM を掴めたか確認 (書けなければ落ちる)
        lda     SH_PRB
        cmpa    #$A5
        bne     HLT1            ; まだ掴めていない: 待ち直す
        rts
HALTOFF:
        clr     <$05            ; RUN
        rts
DLYS:   pshs    x
        ldx     #300
DLY1:   leax    -1,x
        bne     DLY1
        puls    x,pc
DLYI:   pshs    x           ; 約 0.18ms (サブが 80 バイト書くのに足りる長さ)
        ldx     #40
DLY2:   leax    -1,x
        bne     DLY2
        puls    x,pc

; -----------------------------------------------------------------------------
; SUBREQ: サブへリクエスト A を渡し、ack が返るまで待つ
;   共有RAM アクセスは HALT で包む。更新カウンタ (SH_SEQ) を +1 して知らせ、
;   サブが同じ値を SH_RACK へ書き返したら完了とする。
; -----------------------------------------------------------------------------
SUBREQ: sta     REQV
        bsr     HALTON
        lda     REQV
        sta     SH_REQ
        inc     SEQC
        lda     SEQC
        sta     SH_SEQ
        bsr     HALTOFF
SRW:    bsr     DLYS
        bsr     HALTON
        lda     SH_RACK
        cmpa    SEQC
        beq     SRDONE
        bsr     HALTOFF
        bra     SRW
SRDONE: bsr     HALTOFF
        rts

; =============================================================================
; 画像表示 (AV系のみ)
;
; ディスク上の並び (シリンダ2 サイド0 セクタ1 から連続):
;   +$0000..+$013F  アナログパレット 64 エントリ x 5 バイト
;                   ($FD30,$FD31,$FD32,$FD33,$FD34 の順にそのまま書く)
;   +$0140          重ね書き文字の色 (パレット添字)
;   +$0141..        RLE ストリーム (展開後 6 プレーン x 8000 = 48000 バイト)
;
; RLE 形式:
;   制御バイト C = $00 で終端、bit7=1 なら「次の 1 バイトを (C&$7F) 回」、
;   bit7=0 なら「続く C バイトをそのまま」。トークンはプレーン境界をまたぐ。
;   展開側は出力バイト数を数えて 8000 バイトごとにプレーンを切り替える。
;
; 転送:
;   展開したバイトを CHKBUF に 80 バイト (= 2 ライン) 溜めるたびに、
;   BLIT リクエスト (SH_REQ=3) でサブへ渡す。8000 は 80 で割り切れるので
;   チャンクがプレーン境界をまたぐことはない。
; =============================================================================

; -----------------------------------------------------------------------------
; IMGINI: 画像先頭 2 セクタを読み、アナログパレットと文字色を設定する
;         (残りはそのまま RLE ストリームの先頭として使う)
; -----------------------------------------------------------------------------
IMGINI: lda     #IMGCYL0
        sta     IMGCYL
        clr     IMGSID
        clr     <$1C            ; サイド0
        lda     #IMGCYL0
        lbsr    SEEKT
        clr     IMGIDX
        ldx     #IMGBUF
        bsr     IMGRD           ; 1 セクタ目
        ldx     #IMGBUF+256
        bsr     IMGRD           ; 2 セクタ目
        ; ---- アナログパレット 64 エントリ ----
        ldx     #IMGBUF
        ldb     #IPALN
IPALLP: lda     ,x+
        sta     <$30            ; パレット添字 上位4ビット
        lda     ,x+
        sta     <$31            ; パレット添字 下位8ビット
        lda     ,x+
        sta     <$32            ; 青
        lda     ,x+
        sta     <$33            ; 赤
        lda     ,x+
        sta     <$34            ; 緑
        decb
        bne     IPALLP
        ; ---- 重ね書き文字の色 ----
        lda     ,x+
        sta     TXTCOL
        ; ---- 残りは RLE ストリームの先頭 ----
        stx     IMGPTR
        ldd     #IMGBUF+512
        std     SRCEND
        rts

; -----------------------------------------------------------------------------
; IMGRD: 次の 1 セクタを X へ読み、読み位置を 1 つ進める (X 保存)
;   セクタ番号は ISEQT の順に読む (論理インターリーブ)。1 周したらサイドを
;   反転し、サイド0 へ戻るときは次シリンダへシークする。
;
;   インターリーブについて: FDD は 300rpm (1 周 200ms、1 セクタ枠 12.5ms) で
;   回り続けているので、あるセクタを読み終えてから次を要求するまでに
;   時間がかかると、目的のセクタ枠を通り過ぎて 1 周待たされる。
;   本デモは 1 セクタ読むごとに RLE 展開とサブへの転送 (約 20ms) を行うため、
;   ディスク上の並びを 3 枠 (37.5ms) おきに飛ばして配置してある
;   (scripts/mkd77.mjs が同じ順で書き込む)。
; -----------------------------------------------------------------------------
IMGRD:  ldb     IMGIDX
        ldu     #ISEQT
        lda     b,u             ; 読むべきセクタ番号
IMR1:   lbsr    RDSEC
        bcs     IMR1            ; エラー時は同一セクタをリトライ
        inc     IMGIDX
        lda     IMGIDX
        cmpa    #16
        blo     IMRX
        clr     IMGIDX          ; このトラックを読み切った
        lda     IMGSID
        eora    #1
        sta     IMGSID
        sta     <$1C            ; サイド切替
        bne     IMRX            ; サイド1 へ移った: 同じシリンダのまま
        inc     IMGCYL          ; サイド0 へ戻った: 次のシリンダへ
        lda     IMGCYL
        lbsr    SEEKT
IMRX:   rts

; 1 トラック分の読み出し順 (3 枠おき = インターリーブ 3)
ISEQT:  fcb     1,4,7,10,13,16,3,6,9,12,15,2,5,8,11,14

; -----------------------------------------------------------------------------
; RDFILL: 次の 1 セクタを IMGBUF へ読み込み、X と SRCEND を張り直す
;         (Y = チャンクバッファの書込み位置は保存される)
; -----------------------------------------------------------------------------
RDFILL: ldx     #IMGBUF
        bsr     IMGRD
        ldd     #IMGBUF+256
        std     SRCEND
        ldx     #IMGBUF
        rts

; -----------------------------------------------------------------------------
; GETC1: 圧縮ストリームから 1 バイト取り出す (X を進めて A に返す)
;        バッファを使い切っていたら次のセクタを読む
; -----------------------------------------------------------------------------
GETC1:  stx     TMPW
        ldd     SRCEND
        subd    TMPW
        bne     G1A
        bsr     RDFILL
G1A:    lda     ,x+             ; 最後に A を読むのでフラグは A を反映する
        rts

; -----------------------------------------------------------------------------
; SRCLIM: A (コピーしたいバイト数) をソースバッファの残量で頭打ちにする
;         残量 0 なら次のセクタを読んでから判定する
; -----------------------------------------------------------------------------
SRCLIM: pshs    a
        stx     TMPW
        ldd     SRCEND
        subd    TMPW            ; D = バッファ残量 (0..256)
        bne     SL1
        bsr     RDFILL
        ldd     #256
SL1:    tsta
        bne     SLX             ; 256 バイト残っている: 制限にならない
        cmpb    ,s
        bhs     SLX             ; 残量 >= 要求: 制限にならない
        stb     ,s              ; 残量で頭打ち
SLX:    puls    a,pc

; -----------------------------------------------------------------------------
; IMGXFR: RLE ストリームを展開しながら 80 バイトずつサブへ送る
;
;   X = 圧縮データの読み位置 / Y = チャンクバッファの書込み位置。
;   1 バイトずつ関数呼び出しにすると 1 バイト 80 サイクル近くかかり、
;   1 セクタの処理がディスク 1 回転を跨いでしまうため、
;   「トークン長 / チャンクの残り / バッファの残り」の最小値をまとめて
;   コピーする形にしてある (リテラル 17 サイクル・ラン 11 サイクル / バイト)。
; -----------------------------------------------------------------------------
IMGXFR: clr     PLNIDX
        ldd     #0
        std     PLNOFS
        std     LINEN
        ldy     #CHKBUF
        lda     #CHKSZ
        sta     DSTN
        ldx     IMGPTR          ; IMGINI が設定済み
XFRLP:  lbsr    GETC1
        lbeq    XFRDN           ; $00 = 終端
        bmi     XFRRUN
        sta     LITN            ; リテラル: 続く n バイトをそのまま
XFRLT0: lda     LITN
        cmpa    DSTN
        bls     XFRLT1
        lda     DSTN            ; チャンクの残り容量で頭打ち
XFRLT1: bsr     SRCLIM          ; バッファの残量で頭打ち
        sta     NCP
        ldb     NCP
XFRLTC: lda     ,x+             ; --- リテラルのコピー ---
        sta     ,y+
        decb
        bne     XFRLTC
        lda     LITN
        suba    NCP
        sta     LITN
        lda     DSTN
        suba    NCP
        sta     DSTN
        bne     XFRLT2
        bsr     FLUSH           ; チャンクが満杯: サブへ送る
XFRLT2: tst     LITN
        bne     XFRLT0
        lbra    XFRLP
XFRRUN: anda    #$7F            ; ラン: 次の 1 バイトを n 回
        sta     RUNN
        lbsr    GETC1
        sta     RUNV
XFRRN0: lda     RUNN
        cmpa    DSTN
        bls     XFRRN1
        lda     DSTN            ; チャンクの残り容量で頭打ち
XFRRN1: sta     NCP
        ldb     NCP
        lda     RUNV
XFRRNC: sta     ,y+             ; --- ランの展開 ---
        decb
        bne     XFRRNC
        lda     RUNN
        suba    NCP
        sta     RUNN
        lda     DSTN
        suba    NCP
        sta     DSTN
        bne     XFRRN2
        bsr     FLUSH
XFRRN2: tst     RUNN
        bne     XFRRN0
        lbra    XFRLP
XFRDN:  rts

; -----------------------------------------------------------------------------
; FLUSH: 満杯になったチャンクをサブへ送り、書込み位置を先頭へ戻す (X 保存)
; -----------------------------------------------------------------------------
FLUSH:  pshs    x
        lbsr    SENDCK
        puls    x
        ldy     #CHKBUF
        lda     #CHKSZ
        sta     DSTN
        rts

; -----------------------------------------------------------------------------
; SENDCK: チャンク 1 個 (80 バイト = 2 ライン) をサブへ送り、位置を進める
;   文字が隠す帯にかかるラインは、送る前に SAVBUF へ退避しておく
; -----------------------------------------------------------------------------
SENDCK: bsr     CAPB
        lda     PLNIDX
        sta     BPLN
        ldd     PLNOFS
        std     BOFS
        lda     #CHKSZ
        sta     BLEN
        ldx     #CHKBUF
        stx     BSRC
        lbsr    SENDB
        ldd     LINEN
        addd    #2
        std     LINEN
        ldd     PLNOFS
        addd    #CHKSZ
        std     PLNOFS
        cmpd    #IPLNSZ
        blo     SCK9
        ldd     #0
        std     PLNOFS          ; プレーンを使い切った: 次のプレーンへ
        std     LINEN
        inc     PLNIDX
SCK9:   rts

; -----------------------------------------------------------------------------
; CAPB: いま送ろうとしているチャンク (2 ライン) が "PUSH ANY KEY" の帯に
;       かかるなら、その 24 バイトずつを SAVBUF へ退避する
;       (帯の上端 KYROW は偶数なので、2 ラインは必ず両方入るか両方外れる)
; -----------------------------------------------------------------------------
CAPB:   ldd     LINEN
        subd    #KYROW
        bcs     CAPX            ; 帯より上
        cmpd    #KYNL
        bhs     CAPX            ; 帯より下
        stb     RELLN
        ldb     PLNIDX          ; 退避先 = SAVBUF + プレーン分 + 相対ライン*24
        aslb
        ldx     #PLOFT
        ldd     b,x
        addd    #SAVBUF
        std     TMPW
        ldb     RELLN
        clra
        aslb
        rola
        aslb
        rola
        aslb
        rola                    ; D = 相対ライン * 8
        std     TMPW2
        aslb
        rola                    ; D = 相対ライン * 16
        addd    TMPW2           ; D = 相対ライン * 24
        addd    TMPW
        tfr     d,y
        ldx     #CHKBUF+KYCOL
        ldb     #KYW
CAPL1:  lda     ,x+
        sta     ,y+
        decb
        bne     CAPL1
        ldx     #CHKBUF+AVBPL+KYCOL
        ldb     #KYW
CAPL2:  lda     ,x+
        sta     ,y+
        decb
        bne     CAPL2
CAPX:   rts

; プレーン番号 → SAVBUF 内のオフセット (16 ライン x 24 バイト = 384)
PLOFT:  fdb     0,384,768,1152,1536,1920

; -----------------------------------------------------------------------------
; RESTOR: 退避しておいた画像を書き戻して "PUSH ANY KEY" を消す
;   6 プレーン x 16 ライン = 96 回の BLIT (1 回 24 バイト)。
;   黒で塗り潰すのではなく元データを戻すので、下の画像が完全に復元される。
; -----------------------------------------------------------------------------
RESTOR: clr     RPLN
RSP:    clr     RLIN
RSL:    ldb     RPLN            ; ペイロード元 = SAVBUF + プレーン分 + 行*24
        aslb
        ldx     #PLOFT
        ldd     b,x
        addd    #SAVBUF
        std     TMPW
        ldb     RLIN
        clra
        aslb
        rola
        aslb
        rola
        aslb
        rola
        std     TMPW2
        aslb
        rola
        addd    TMPW2
        addd    TMPW
        std     BSRC
        ldb     RLIN            ; 書込み先 = (KYROW + 行) * 40 + KYCOL
        clra
        addd    #KYROW
        bsr     MUL40
        addd    #KYCOL
        std     BOFS
        lda     RPLN
        sta     BPLN
        lda     #KYW
        sta     BLEN
        lbsr    SENDB
        inc     RLIN
        lda     RLIN
        cmpa    #KYNL
        bne     RSL
        inc     RPLN
        lda     RPLN
        cmpa    #6
        bne     RSP
        rts

; -----------------------------------------------------------------------------
; MUL40: D = D * 40
; -----------------------------------------------------------------------------
MUL40:  aslb
        rola
        aslb
        rola
        aslb
        rola                    ; D = D*8
        std     TMPW2
        aslb
        rola
        aslb
        rola                    ; D = D*32
        addd    TMPW2           ; D = D*40
        rts

; -----------------------------------------------------------------------------
; SENDB: BSRC の BLEN バイトを プレーン BPLN のオフセット BOFS へ送る
;
;   取りこぼしを原理的に起こさないための二重確認:
;     (1) HALTON が共有RAM へ実際に書けることをプローブで確かめてから書く
;     (2) 書いた直後に シーケンス値と長さを読み戻して照合し、
;         食い違ったら同じシーケンス値のまま最初から書き直す
;   さらにサブ側は「前回 +1」以外のシーケンス値を見たら SH_IERR を増やし、
;   受け取った総バイト数を SH_ICNT に積むので、事後照合もできる。
; -----------------------------------------------------------------------------
SENDB:  inc     SEQC
SNDRTY: lbsr    HALTON
        lda     BPLN
        sta     SH_IPL
        ldd     BOFS
        std     SH_IOFS
        lda     BLEN
        sta     SH_ILEN
        lsra
        lsra
        lsra                    ; 8 バイト単位の回数
        sta     CPCNT
        ldx     BSRC
        ldu     #SH_PAY
SNDCP:  ldd     ,x++
        std     ,u++
        ldd     ,x++
        std     ,u++
        ldd     ,x++
        std     ,u++
        ldd     ,x++
        std     ,u++
        dec     CPCNT
        bne     SNDCP
        lda     #3
        sta     SH_REQ
        lda     SEQC
        sta     SH_SEQ
        lda     SH_SEQ          ; 読み戻し確認 (1)
        cmpa    SEQC
        bne     SNDFL
        lda     SH_ILEN         ; 読み戻し確認 (2)
        cmpa    BLEN
        bne     SNDFL
        lbsr    HALTOFF
SNDW:   lbsr    DLYI            ; サブに書込み時間を与える
        lbsr    HALTON
        lda     SH_RACK
        cmpa    SEQC
        beq     SNDOK
        lbsr    HALTOFF
        bra     SNDW
SNDOK:  lbsr    HALTOFF
        rts
SNDFL:  lbsr    HALTOFF         ; 共有RAM を掴めていなかった: 書き直す
        lbsr    DLYI
        lbra    SNDRTY

; -----------------------------------------------------------------------------
; KEYDRN: 溜まっているキーコードを読み捨てる (再生中の打鍵を持ち越さない)
;   "PUSH ANY KEY" の表示指示より前に呼ぶこと。表示完了を待ってから捨てると
;   描画中に押されたキーを取りこぼしてしまう。
; -----------------------------------------------------------------------------
KEYDRN: lda     <$03            ; $FD03: IRQ ステータス (bit0=0 でキーあり)
        bita    #$01
        bne     KDEND           ; 溜まっていない
        lda     <$01            ; 読み捨て (読むとフラグ解除)
        bra     KEYDRN
KDEND:  rts

; -----------------------------------------------------------------------------
; KEYWT: キー押下を待つ ($FD03 bit0 のポーリング)
;   新たに来たコードのうち「メイクコード」だけを押下として扱う。
;   ブレークコード (離鍵) は bit7 が立つので押下と誤認しない。
; -----------------------------------------------------------------------------
KEYWT:  lda     <$03
        bita    #$01
        bne     KEYWT           ; キーなし
        lda     <$01            ; キーコード取得
        bita    #$80
        bne     KEYWT           ; ブレークコード (離鍵) は無視
        tsta
        beq     KEYWT           ; $00 は無視
        rts

; =============================================================================
; OPN (YM2203) アクセス
;
;   $FD15 = コマンドポート (4ビットのバス制御コード)
;     $00=INACTIVE  $02=WRITEDAT  $03=ADDRESS
;   $FD16 = データポート (アドレス / データ)
;
;   レジスタ書込みは ADDRESS でレジスタ番号を選び WRITEDAT で値を書く。
;   各コマンドの後に必ず $00 (INACTIVE) を書いてコマンドラッチを解除し、
;   短い空ループで整定を待つ。ステータス (READSTAT) は一切読まない —
;   読出し手順やビジービットの扱いは実装差が出やすいため、固定待ちだけで
;   完結させる方が機種を問わず確実に通る。
; =============================================================================

OPNSTL  equ     7               ; 整定待ちの反復回数 (1 反復 5 サイクル)

; -----------------------------------------------------------------------------
; OPNW: OPN レジスタ A に値 B を書く (DP=$FD 前提)。A 破壊、B/X/Y 保存
;   DATA←レジスタ番号 → CMD←$03 → CMD←$00 → 整定待ち →
;   DATA←値         → CMD←$02 → CMD←$00 → 整定待ち
;   1 回あたり約 110 サイクル (約 61us @1.794MHz)。1 フレーム 15 回でも
;   約 0.92ms で、フレーム周期 10.1725ms の 1 割に収まる。
; -----------------------------------------------------------------------------
OPNW:   sta     <$16            ; データ = レジスタ番号 (A)
        lda     #$03
        sta     <$15            ; ADDRESS: selreg = A
        clra
        sta     <$15            ; INACTIVE (ラッチ解除)
        lda     #OPNSTL
OPNW1:  deca
        bne     OPNW1           ; 整定待ち
        stb     <$16            ; データ = 値 (B)
        lda     #$02
        sta     <$15            ; WRITEDAT: ここで実際に書き込まれる
        clra
        sta     <$15            ; INACTIVE (ラッチ解除)
        lda     #OPNSTL
OPNW2:  deca
        bne     OPNW2           ; 整定待ち
        rts

; -----------------------------------------------------------------------------
; OPNTBL: [レジスタ, 値] の並びを $FF 終端まで順に書き込む (X = 表の先頭)
; -----------------------------------------------------------------------------
OPNTBL: lda     ,x
        cmpa    #$FF
        beq     OPNTE
        ldb     1,x
        leax    2,x
        bsr     OPNW
        bra     OPNTBL
OPNTE:  rts

; -----------------------------------------------------------------------------
; OPNINI: OPN を CSM 音声再生用に初期化する
;   (1) プリスケーラを $2F → $2D の 2 段書きで 1/6 分周に確定させる
;       (これでタイマ周期が f/72・f/1152 の標準値になる)
;       プリスケーラは 3 本のレジスタ ($2D=1/6 / $2E=1/3 / $2F=1/2) を
;       「アドレスを選ぶだけ」で切り替える特殊な作りで、実装によっては
;       選択ビットを OR で足し込むラッチ構造を模しており、リセット直後の
;       既定値 (1/3) から $2D を 1 回書いただけでは 1/6 に落ちない。
;       先に $2F で 1/2 に落としてから $2D を書けば、どの実装でも確実に
;       1/6 になる。1 段しか書かないとタイマ A の周期も FM の音程も
;       2 倍 (1 オクターブ高) にずれる実装がある。
;   (2) タイマ停止・CSM 解除・タイマフラグクリア
;   (3) Ch3 を「4 オペレータ並列出力 (正弦波 4 本の単純加算)」の音色にする
;       アルゴリズム7 / フィードバック0 / 各スロット DT=0・MUL=2 /
;       AR 最大 (立ち上がり瞬時) / SL=0・DR=0 で減衰は SR に任せ、
;       SR 最速 (数ミリ秒で減衰) / RR 最速。
;       振幅はフレーム毎の TL で与える。
;   Ch3 は CSM モードのキーオンで位相がリセットされ、その繰り返し周期
;   (タイマA) がピッチ、各スロットの周波数がフォルマントになる。
;   MUL=2 は音声パラメータ生成側の周波数換算と対になっているので変えない。
; -----------------------------------------------------------------------------
OPNINI: lda     #$2F
        clrb
        bsr     OPNW            ; プリスケーラ 1/2 (ラッチをいったん落とす)
        lda     #$2D
        clrb
        bsr     OPNW            ; プリスケーラ 1/6 (タイマ周期の基準を確定)
        ldx     #OPNIT
        bsr     OPNTBL
        rts

OPNIT:  fcb     $27,$30         ; タイマ停止 / CSM 解除 / 両フラグクリア
        fcb     $28,$00         ; Ch1 全スロット キーオフ
        fcb     $28,$01         ; Ch2 全スロット キーオフ
        fcb     $28,$02         ; Ch3 全スロット キーオフ
        fcb     $07,$BF         ; SSG: トーン/ノイズ全停止 (ポートB出力・ポートA入力)
        fcb     $08,$00,$09,$00,$0A,$00          ; SSG 音量 0
        fcb     $B2,$07         ; Ch3 フィードバック0 / アルゴリズム7
        fcb     $32,$02,$36,$02,$3A,$02,$3E,$02  ; DT=0 MUL=2
        fcb     $52,$1F,$56,$1F,$5A,$1F,$5E,$1F  ; KS=0 AR=31 (立ち上がり瞬時)
        fcb     $62,$00,$66,$00,$6A,$00,$6E,$00  ; AM=0 DR=0
        fcb     $72,$1F,$76,$1F,$7A,$1F,$7E,$1F  ; SR=31 (最速減衰)
        fcb     $82,$0F,$86,$0F,$8A,$0F,$8E,$0F  ; SL=0 RR=15
        fcb     $92,$00,$96,$00,$9A,$00,$9E,$00  ; SSG-EG 無効
        fcb     $42,$7F,$46,$7F,$4A,$7F,$4E,$7F  ; TL 最小音量 (無音)
        fcb     $FF

; =============================================================================
; CSMPLY: CSM 音声再生
;
;   フレーム同期は「メインCPU の周期タイマ (約 2.0345ms) を 5 回数える」方式。
;   1 フレーム = 5 tick = 10.1725ms。OPN のステータスは読まない。
;   毎フレーム、5 tick 待ってから $27 にフラグクリア値を書き、
;   続けて 14 バイトを OPN へ書き込む。
;
;   1 フレーム 14 バイトの並びと書込み先レジスタ (REGTB と対応):
;     [0][1]   タイマA 上位/下位 ($24/$25) = ピッチ (キーオン繰り返し周期)
;     [2][3]   フォルマント1 F-Number 上位/下位 → Ch3 第1オペレータ ($AD/$A9)
;     [4][5]   フォルマント2                    → Ch3 第2オペレータ ($AC/$A8)
;     [6][7]   フォルマント3                    → Ch3 第3オペレータ ($AE/$AA)
;     [8][9]   フォルマント4                    → Ch3 第4オペレータ ($A6/$A2)
;     [10..13] フォルマント1..4 の TL           → ($42/$46/$4A/$4E)
;   F-Number は上位バイト (ブロック + F-Number 上位3ビット) を先に書いてから
;   下位バイトを書く (下位バイト書込みで値が確定するラッチ構造のため)。
;   各フォルマントの周波数と TL は必ず同じオペレータへ送る (上表の対応)。
;   CSM 中の TL 書込みはラッチされ、次のキーオン (ピッチ周期の頭) で一斉に
;   反映されるため、フレーム途中で書いても波形に段差が出ない。
; =============================================================================
CSMPLY: ; ---- 先頭フレームのピッチをあらかじめ入れておく ----
        ldx     #csmdata
        stx     FPTR
        lda     #$24
        ldb     ,x
        lbsr    OPNW
        ldx     FPTR
        lda     #$25
        ldb     1,x
        lbsr    OPNW
        ; ---- Ch3 を CSM モードにしてタイマA を起動 (初回のみ $81) ----
        ;      $27 の bit7-6 は独立した 2 つの許可ビットではなく、
        ;      Ch3 の動作を選ぶ「2 ビットのモード番号」である:
        ;        00 = 通常モード
        ;        01 = Ch3 特殊モード (3スロット独立 F-Number)
        ;        10 = CSM モード     (特殊モードを含む)
        ;        11 = 未定義 (禁止)
        ;      したがって CSM は 10 ちょうどでなければならない。11 を書くと
        ;      「CSM ではない」と判定してキーオンを一切起こさない実装があり、
        ;      その場合 Ch3 は鳴らないまま TL もラッチされ続けて完全な無音に
        ;      なる。bit6 は立てないこと。10 にすれば 3スロット独立
        ;      F-Number も同時に有効になるので、bit6 を足す必要は無い。
        ;      bit3/bit2 (両タイマのフラグ許可) は CSM に不要。立てると
        ;      ステータス経由で IRQ 線を上げる実装があるので 0 のままにする。
        ;      bit1 (タイマB 有効) も使わないので 0。
        ;      bit0=タイマA 有効 (タイマA の周期が CSM のピッチになる)。
        ;      タイマは「無効→有効」の立ち上がりでのみリロードされる。
        ;      OPNINI で $27←$30 (bit0=0) にしてあるので、ここが 0→1 になる。
        ;      以後のフレーム処理では bit0 を 1 のまま書き続ける。
        lda     #$27
        ldb     #$81
        lbsr    OPNW
        ; ---- フレームループ ----
        clr     TMRBAD          ; 周期タイマの不良判定をリセット
        ldd     #CSMFRAMES
        std     FCNT
CSMFR:  lbsr    WTFR            ; 次フレームまで待つ (周期タイマ 5 tick)
        lda     #$27            ; $B1: bit7-6=10 で CSM モード維持 +
        ldb     #$B1            ;      bit5,bit4=両タイマのフラグクリア +
        lbsr    OPNW            ;      bit0=タイマA 継続 (1→1 なので再ロード
                                ;      は起きず、ピッチの周期は途切れない)
        lbsr    PUTFR           ; 14 バイトを OPN へ
        ldd     FPTR
        addd    #CSMFRSIZE
        std     FPTR
        ldd     FCNT
        subd    #1
        std     FCNT
        bne     CSMFR
        ; ---- 終了: CSM 解除・タイマ停止・キーオフ・音量最小 ----
        ldx     #OPNET
        lbsr    OPNTBL
        rts

OPNET:  fcb     $27,$30         ; CSM 解除 / タイマ停止 / 両フラグクリア
        fcb     $28,$02         ; Ch3 全スロット キーオフ
        fcb     $42,$7F,$46,$7F,$4A,$7F,$4E,$7F  ; TL 最小音量
        fcb     $FF

; -----------------------------------------------------------------------------
; WTFR: 次のフレームまで待つ
;   メインCPU の周期タイマ ($FD03 bit2、active-low = 0 で発生) を FRTICK 回
;   数える。$FD03 の読出しでタイマフラグは落ちるので、1 回読むごとに
;   1 tick を消費したことになる。
;   キーボードのフラグ (bit0) も同じレジスタに出るが、再生中はキーを見ない
;   ので無視してよい ($FD03 の読出しではキーのフラグは落ちない。落とすには
;   $FD01 を読む必要があり、再生後の KEYDRN がまとめて読み捨てる)。
;
;   ウォッチドッグ: 周期タイマが取れない実装でも絶対に固まらないよう、
;   1 tick あたり TMRWDG 回でポーリングを打ち切る (約 39ms 相当 = 1 tick の
;   約 19 倍)。打ち切ったら TMRBAD を立て、以後のフレームは待たずに進める。
;   結果は「少し速く再生される」だけで、再生は必ず有限時間で終わる。
; -----------------------------------------------------------------------------
FRTICK  equ     5               ; 1 フレーム = 5 tick (約 10.1725ms)
TMRWDG  equ     4096            ; 1 tick あたりのポーリング上限

WTFR:   tst     TMRBAD
        bne     WTFRX           ; 周期タイマ不良と判定済み: 待たない
        ldb     #FRTICK
WTFRT:  ldx     #TMRWDG
WTFRP:  lda     <$03            ; $FD03: bit2=0 で周期タイマ発生 (読むとクリア)
        bita    #$04
        beq     WTFRN           ; tick を 1 つ消費した
        leax    -1,x
        bne     WTFRP
        inc     TMRBAD          ; 上限到達: この環境では周期タイマが取れない
        bra     WTFRX
WTFRN:  decb
        bne     WTFRT
WTFRX:  rts

; -----------------------------------------------------------------------------
; PUTFR: FPTR が指す 14 バイトを REGTB の順で OPN へ書き込む
; -----------------------------------------------------------------------------
PUTFR:  ldy     #REGTB
        ldx     FPTR
        lda     #CSMFRSIZE
        sta     PCNT
PFLP:   lda     ,y+
        ldb     ,x+
        lbsr    OPNW
        dec     PCNT
        bne     PFLP
        rts

REGTB:  fcb     $24,$25         ; タイマA 上位/下位 (ピッチ)
        fcb     $AD,$A9         ; フォルマント1: 第1オペレータ F-Number 上位/下位
        fcb     $AC,$A8         ; フォルマント2: 第2オペレータ
        fcb     $AE,$AA         ; フォルマント3: 第3オペレータ
        fcb     $A6,$A2         ; フォルマント4: 第4オペレータ
        fcb     $42,$46,$4A,$4E ; フォルマント1..4 の TL

; ---- ワークエリア ----
MACHAV: fcb     0               ; 0=FM-7 / 1=AV系
CHKN:   fcb     0               ; 転送チャンク番号
SEQC:   fcb     0               ; リクエストの更新カウンタ
REQV:   fcb     0               ; リクエストコードの一時退避
TMRBAD: fcb     0               ; 0=周期タイマ正常 / 非0=取得できず待たない
PCNT:   fcb     0               ; フレーム内バイトカウンタ
FPTR:   fdb     0               ; 再生中フレームへのポインタ
FCNT:   fdb     0               ; 残りフレーム数
TXTCOL: fcb     0               ; 重ね書き文字の色 (パレット添字)
IMGCYL: fcb     0               ; 画像読込: シリンダ
IMGSID: fcb     0               ; 画像読込: サイド
IMGIDX: fcb     0               ; 画像読込: トラック内の読み出し順 (0-15)
IMGPTR: fdb     0               ; 画像読込: バッファ内の次バイト
SRCEND: fdb     0               ; 画像読込: バッファの終端
DSTN:   fcb     0               ; チャンクバッファの残り容量
NCP:    fcb     0               ; 一度にコピーするバイト数
PLNIDX: fcb     0               ; 転送中のプレーン番号 (0-5)
PLNOFS: fdb     0               ; 転送中のプレーン内オフセット
LINEN:  fdb     0               ; 転送中のライン番号 (プレーン内)
LITN:   fcb     0               ; RLE: リテラルの残り
RUNN:   fcb     0               ; RLE: ランの残り
RUNV:   fcb     0               ; RLE: ランの値
RELLN:  fcb     0               ; 帯内の相対ライン
RPLN:   fcb     0               ; 復元: プレーン番号
RLIN:   fcb     0               ; 復元: 行番号
BPLN:   fcb     0               ; BLIT: プレーン番号
BOFS:   fdb     0               ; BLIT: オフセット
BLEN:   fcb     0               ; BLIT: バイト数
BSRC:   fdb     0               ; BLIT: 転送元
CPCNT:  fcb     0               ; BLIT: 8 バイト単位のコピー回数
TMPW:   fdb     0               ; 作業用
TMPW2:  fdb     0               ; 作業用

; =============================================================================
; CSM 音声データ (別ツールが WAV から生成する)
;   CSMFRAMES = フレーム数 / csmdata = データ先頭
; =============================================================================
        include "csmdata.s"

        end
