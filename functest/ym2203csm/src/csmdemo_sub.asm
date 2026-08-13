; =============================================================================
; csmdemo_sub.asm — サブCPU側 描画プログラム (YM2203 CSM 音声デモ)
;
; メインCPUから共有RAM経由で転送・起動され、以下を行う:
;   1. 共有RAMの機種フラグ (SH_AVF) を見て画面レイアウトを決める
;        AV系  : 320x200 4096色 (12 サブプレーン、40 バイト/ライン)
;        FM-7  : 640x200 8色    ( 3 プレーン、80 バイト/ライン)
;   2. 画面全体を黒で塗る (AV系はページ0/1 の 12 面すべて)
;   3. AV系   : 何も描かずメインの指示待ちに入る (画面は主が画像を流し込む)
;      FM-7   : "SORRY! IT'S FOR FM77AV!" を 2倍角・中央寄せで描いて停止する
;   4. 共有RAMのリクエストセルを監視し、メインCPUの指示で
;        1 = "PUSH ANY KEY" を表示
;        3 = 転送されたバイト列を指定プレーンの指定オフセットへ書く (BLIT)
;      を実行して ack を返す
;
; 画像表示 (AV系):
;   320x200 の 64 色画像はメインCPU がディスクから読みながら RLE 展開し、
;   BLIT リクエストで 80 バイト (= 2 ライン) ずつ送ってくる。サブは受け取った
;   バイト列を指定プレーンへ置くだけで、展開もアドレス計算も行わない。
;   ページ0 の 6 面 (B3/B2/R3/R2/G3/G2) だけを使い、ページ1 は 0 のままにする。
;
; "PUSH ANY KEY" は画像の上に重ねて描く:
;   文字色は画像の空きパレットスロットに置いた黄 (添字 = SH_TCOL)。
;   ページ0 の各プレーンについて、そのプレーンが担う添字ビットが
;     1 なら 字形ビットを OR / 0 なら 字形ビットの反転を AND
;   する read-modify-write なので、文字以外のドットは画像のまま残る。
;   消去はサブでは行わない。メインが退避しておいた元の画像を BLIT で
;   書き戻すため、消去後も背景の画像が完全に復元される。
;
; 文字はサブ空間の CG ROM ($D800-、8x8、1文字8バイト、ASCII 配置) を
; 整数倍 (2倍) に拡大して描く。開始桁をバイト境界に揃えるため
; ビットシフトは不要で、1 ドットを N ドットへ展開する表引きだけで済む。
;
; ビルド: lwasm --6809 --format=raw -o csmdemo_sub.bin csmdemo_sub.asm
; =============================================================================

        org     $C100

; ---- 共有RAM メールボックス (サブ側アドレス) ----
SH_SEQ  equ     $D383           ; 更新カウンタ (メインが指示の度に +1)
SH_TCOL equ     $D384           ; 文字色のパレット添字 (0-63、AV系のみ意味を持つ)
SH_IPL  equ     $D385           ; BLIT: 書込み先プレーン番号 (0-5)
SH_IOFS equ     $D386           ; BLIT: プレーン内オフセット (2バイト)
SH_ILEN equ     $D388           ; BLIT: バイト数 (8 の倍数、最大 80)
SH_IERR equ     $D389           ; サブが検出した異常の件数 (0 が正常)
SH_AVF  equ     $D38A           ; 機種フラグ (0=FM-7 / 1=AV系、メインが判別)
SH_ICNT equ     $D38B           ; BLIT で書いた総バイト数 (2バイト、照合用)
SH_REQ  equ     $D39D           ; リクエスト (1=PUSH ANY KEY 表示 / 3=BLIT)
SH_RACK equ     $D39E           ; リクエスト ack (処理した SH_SEQ を返す)
SH_RDY  equ     $D39F           ; 初期描画完了マーカー ($A5)
SH_PAY  equ     $D3A0           ; BLIT ペイロード (最大 80 バイト)

; ---- サブ側 I/O ----
IO_CRT  equ     $D408           ; 読み出しで CRT 表示 ON
IO_VRAM equ     $D409           ; 読み出しで VRAM アクセス許可
IO_BUSY equ     $D40A           ; 読み出しで BUSY フラグ解除
IO_MISC equ     $D430           ; bit7=NMIマスク bit6=表示ページ bit5=アクティブページ

CGROM   equ     $D800           ; CG ROM (8x8 フォント、1文字8バイト、ASCII配置)

; ---- ワークエリア (サブRAM $CF90-) ----
NPL     equ     $CF90           ; プレーン数 (消去対象、AV=12 / FM-7=3)
BPL     equ     $CF91           ; バイト/ライン (40 or 80)
PLPTR   equ     $CF92           ; プレーンテーブル先頭 (2バイト)
PBASE   equ     $CF94           ; 現プレーンのベースアドレス (2バイト)
PLIDX   equ     $CF96           ; プレーンループカウンタ
AVF     equ     $CF97           ; 機種フラグ (0=FM-7 / 1=AV系)
TCOL    equ     $CF98           ; 文字列: 左端バイト列
TSCL    equ     $CF99           ; 文字列: 拡大率 (1/2/4)
TROW    equ     $CF9A           ; 文字列: 上端ライン (2バイト)
TSTR    equ     $CF9C           ; 文字列: ポインタ (2バイト)
OFS     equ     $CF9E           ; 現在の描画アドレス (2バイト)
ROWC    equ     $CFA0           ; 字形の行カウンタ (0-7)
VREP    equ     $CFA1           ; 縦方向の繰り返しカウンタ
GPTR    equ     $CFA2           ; 字形先頭アドレス (2バイト)
EXPB    equ     $CFA4           ; 展開済みバイト列 (最大4バイト)
DLT     equ     $CFA8           ; 次ラインまでの増分 (BPL - TSCL)
LSEQ    equ     $CFAF           ; 最後に処理した更新カウンタ
TMPW    equ     $CFB0           ; 2バイト作業領域
VSIZE   equ     $CFB2           ; 1プレーンの使用バイト数 (2バイト)
NPLD    equ     $CFB4           ; 文字描画の対象プレーン数 (AV=6 / FM-7=3)
TXCOL   equ     $CFB5           ; 文字色のパレット添字
MSKV    equ     $CFB6           ; 現プレーンの色マスク ($FF=立てる / $00=落とす)
BCNT    equ     $CFB7           ; BLIT の 8 バイト単位カウンタ

; =============================================================================
; エントリポイント (サブモニタのコマンド $3F バイトコード $93 で呼び出される。
;   制御は返さず、以後サブCPUはこのプログラムが専有する)
; =============================================================================
ENTRY:  orcc    #$50            ; IRQ/FIRQ 禁止
        lds     #$CF80          ; 独自スタック
        lda     IO_BUSY         ; BUSY 解除 (読み出しで OFF)
        lda     #$80
        sta     IO_MISC         ; NMI マスク + 表示/アクティブページ0
        lda     IO_VRAM         ; VRAM アクセス許可
        lda     IO_CRT          ; CRT 表示 ON
        clr     SH_RDY
        clr     LSEQ
        clr     SH_RACK
        clr     SH_IERR
        clr     SH_ICNT
        clr     SH_ICNT+1
        lda     SH_TCOL
        sta     TXCOL

        ; ---- 機種フラグに応じた画面パラメータ ----
        lda     SH_AVF
        sta     AVF
        beq     SETUP7
        ; AV系: 320x200 4096色 = 12 サブプレーン x 40 バイト/ライン
        ;       画像はページ0 の 6 面だけを使うので、文字描画も 6 面のみ
        lda     #12
        sta     NPL
        lda     #6
        sta     NPLD
        lda     #40
        sta     BPL
        ldx     #PTAV
        stx     PLPTR
        ldd     #8000           ; 40 x 200
        std     VSIZE
        bra     SETUPD
SETUP7: ; FM-7: 640x200 8色 = 3 プレーン x 80 バイト/ライン
        lda     #3
        sta     NPL
        sta     NPLD
        lda     #80
        sta     BPL
        ldx     #PT7
        stx     PLPTR
        ldd     #16000          ; 80 x 200
        std     VSIZE
SETUPD:
        jsr     CLS             ; 全面黒 (AV系はページ1 も 0 にしておく)

        tst     AVF
        lbeq    DRAW7

        ; ---- AV系: ここでは何も描かない。
        ;      画像はメインが BLIT で流し込み、"PUSH ANY KEY" はその上に重ねる
        lda     #$A5
        sta     SH_RDY

; =============================================================================
; メインループ: 共有RAMのリクエストを処理する
;   1 = "PUSH ANY KEY" を画像の上へ重ね書き
;   3 = BLIT (受け取ったバイト列を VRAM へ置く。画像本体と文字消去の両方に使う)
;
; 取りこぼし防止の二重確認:
;   - メインは更新カウンタ SH_SEQ を 1 ずつ増やす。サブは「前回 +1」以外の
;     値を見たら SH_IERR を増やす (メインは転送後にこれを確認できる)。
;   - サブは処理を終えてから SH_RACK に同じ値を書く。メインは ack が一致
;     するまで次のリクエストを出さないので、ペイロードが上書きされることは
;     原理的に起きない (共有RAM はメインが HALT 中しか書けず、HALT の解除は
;     メインしか行わないため)。
; =============================================================================
MAINLP: lda     IO_BUSY         ; 常時レディ通知 (BUSY OFF 維持)
        lda     SH_SEQ
        cmpa    LSEQ
        beq     MAINLP
        pshs    a
        lda     LSEQ
        inca
        cmpa    ,s              ; 期待は「前回 +1」
        beq     MLSEQ
        inc     SH_IERR         ; 飛び (取りこぼし) を検出
MLSEQ:  puls    a
        sta     LSEQ
        lda     SH_REQ
        cmpa    #1
        bne     MLP3
        jsr     SHOWKY
        bra     MLPACK
MLP3:   cmpa    #3
        bne     MLPACK
        jsr     DOBLIT
MLPACK: lda     LSEQ
        sta     SH_RACK
        bra     MAINLP

        ; ---- FM-7: 非対応メッセージを出して停止する ----
        ;      (画面モードは切り替えない = ブート直後の 640x200 8色のまま)
DRAW7:  lda     #S7COL
        sta     TCOL
        lda     #2
        sta     TSCL
        ldd     #S7ROW
        std     TROW
        ldx     #SSORRY
        stx     TSTR
        jsr     DSTR
        lda     #$A5
        sta     SH_RDY
STOP7:  lda     IO_BUSY         ; BUSY OFF を維持しつつ停止
        bra     STOP7

; -----------------------------------------------------------------------------
; SHOWKY: "PUSH ANY KEY" を画像の上へ重ね書きする
; -----------------------------------------------------------------------------
SHOWKY: lda     #KYCOL
        sta     TCOL
        lda     #2
        sta     TSCL
        ldd     #KYROW
        std     TROW
        ldx     #SPUSH
        stx     TSTR
        jmp     DSTR

; -----------------------------------------------------------------------------
; DOBLIT: SH_PAY の SH_ILEN バイトを プレーン SH_IPL のオフセット SH_IOFS へ置く
;   SH_ILEN は 8 の倍数 (メイン側が 80 または 24 で送る)。
;   ページ0 の 6 面以外を指定されたら書かずに異常として数える。
; -----------------------------------------------------------------------------
DOBLIT: lda     SH_IPL
        cmpa    #6
        bhs     DBERR
        sta     PLIDX
        jsr     PLGET           ; ページ選択 + PBASE
        ldd     SH_IOFS
        addd    PBASE
        tfr     d,y             ; Y = 書込み先
        lda     SH_ILEN
        beq     DBX
        lsra
        lsra
        lsra                    ; 8 バイト単位の回数
        sta     BCNT
        ldu     #SH_PAY
DBLP:   ldd     ,u++
        std     ,y++
        ldd     ,u++
        std     ,y++
        ldd     ,u++
        std     ,y++
        ldd     ,u++
        std     ,y++
        dec     BCNT
        bne     DBLP
        ldd     SH_ICNT         ; 受け取った総バイト数 (メイン側の照合用)
        addb    SH_ILEN
        adca    #0
        std     SH_ICNT
DBX:    rts
DBERR:  inc     SH_IERR
        rts

; ---- 画面レイアウト定数 ----
;   AV系 (320x200 = 40 バイト/ライン):
;     "PUSH ANY KEY" 12文字 x 2倍角 = 24 バイト列 (192px)。
;     画面下端の暗い帯 (画像の見どころを隠さない位置) に置く:
;     左端 4 バイト列 (x=32-223)、上端 184 ライン (y=184-199)。
;     文字色は画像データ側の空きパレットスロット (IMGTXTCOL = 黄) を使う。
;   FM-7 (640x200 = 80 バイト/ライン):
;     "SORRY! IT'S FOR FM77AV!" 23文字 x 2倍角 = 46 バイト列 (368px)
;                                            → 左端 (80-46)/2 = 17
KYCOL   equ     4
KYROW   equ     184
S7COL   equ     17
S7ROW   equ     92

SPUSH:  fcc     "PUSH ANY KEY"
        fcb     0
SSORRY: fcc     "SORRY! IT'S FOR FM77AV!"
        fcb     0

; ---- プレーンテーブル: 1 エントリ = [$D430 制御値, ベース上位バイト] ----
;   AV系 320x200 4096色: ページ0/1 ($D430 bit5) x 各6面 = 12 サブプレーン
;   ページ0 の並びは B3 / B2 / R3 / R2 / G3 / G2 (画像データの並びと同じ)
PTAV:   fcb     $80,$00,$80,$20,$80,$40,$80,$60,$80,$80,$80,$A0
        fcb     $A0,$00,$A0,$20,$A0,$40,$A0,$60,$A0,$80,$A0,$A0
;   FM-7 640x200 8色: B=$0000 R=$4000 G=$8000 (ページ切替は無い)
PT7:    fcb     $80,$00,$80,$40,$80,$80

;   ページ0 の各プレーンが担うパレット添字 n のビット位置
;     0:B3=bit1  1:B2=bit0  2:R3=bit3  3:R2=bit2  4:G3=bit5  5:G2=bit4
PLNBIT: fcb     1,0,3,2,5,4

; -----------------------------------------------------------------------------
; PLGET: PLIDX 番目のプレーンを選択 (ページ切替 + PBASE 設定)
; -----------------------------------------------------------------------------
PLGET:  ldb     PLIDX
        aslb
        clra
        ldx     PLPTR
        leax    d,x
        lda     ,x
        sta     IO_MISC         ; ページ選択 (FM-7 では bit7 のみ意味を持つ)
        lda     1,x
        sta     PBASE
        clr     PBASE+1
        rts

; -----------------------------------------------------------------------------
; MULBPL: D = D * BPL (BPL は 40 または 80)
; -----------------------------------------------------------------------------
MULBPL: aslb
        rola
        aslb
        rola
        aslb
        rola                    ; D = 行*8
        std     TMPW
        aslb
        rola
        aslb
        rola                    ; D = 行*32
        addd    TMPW            ; D = 行*40
        std     TMPW
        lda     BPL
        cmpa    #80
        bne     MB1
        ldd     TMPW
        aslb
        rola                    ; D = 行*80
        std     TMPW
MB1:    ldd     TMPW
        rts

; -----------------------------------------------------------------------------
; CLS: 全プレーンを黒 (0) で塗る (AV系はページ1 の 6 面も 0 にする)
; -----------------------------------------------------------------------------
CLS:    clr     PLIDX
CLSPL:  jsr     PLGET
        ldx     PBASE
        ldy     VSIZE
        clra
CLSLP:  sta     ,x+
        leay    -1,y
        bne     CLSLP
        inc     PLIDX
        lda     PLIDX
        cmpa    NPL
        bne     CLSPL
        rts

; =============================================================================
; DSTR: 文字列を描く (TCOL/TROW/TSTR/TSCL)
;   TSCL = 1/2/4 の整数倍角。開始桁はバイト境界なのでビットシフトは不要。
;
;   プレーン毎に色マスク MSKV を決め、字形ビット g に対し
;     MSKV=$FF : 新 = 旧 OR g        (そのプレーンのビットを立てる)
;     MSKV=$00 : 新 = 旧 AND (NOT g) (そのプレーンのビットを落とす)
;   とする read-modify-write なので、字形以外のドットは元のまま残る
;   (= 画像の上に重ねて描ける)。
;
;   AV系: 色は SH_TCOL のパレット添字。プレーン i が担う添字ビットは PLNBIT[i]。
;   FM-7: 全プレーン $FF = 白 (地は黒で塗ってあるので従来と同じ結果になる)。
; =============================================================================
DSTR:   ; ---- 次ラインまでの増分 (BPL - TSCL) を先に求める ----
        lda     BPL
        suba    TSCL
        sta     DLT
        clr     PLIDX
DSPL:   jsr     PLGET
        ; ---- このプレーンの色マスクを決める ----
        lda     #$FF
        tst     AVF
        beq     DSMSK           ; FM-7 は白
        ldb     PLIDX
        ldx     #PLNBIT
        ldb     b,x             ; 担当する添字ビット位置
        lda     TXCOL
DSMS1:  tstb
        beq     DSMS2
        lsra
        decb
        bra     DSMS1
DSMS2:  anda    #1
        beq     DSMS3
        lda     #$FF
        bra     DSMSK
DSMS3:  clra
DSMSK:  sta     MSKV
        ldd     TROW
        jsr     MULBPL
        addd    PBASE
        addb    TCOL
        adca    #0
        std     OFS
        ldy     TSTR
DSCH:   lda     ,y+
        lbeq    DSNXP           ; NUL 終端 → 次のプレーンへ
        ; ---- 字形先頭 = CGROM + 文字コード*8 ----
        tfr     a,b
        clra
        aslb
        rola
        aslb
        rola
        aslb
        rola
        addd    #CGROM
        std     GPTR
        ldx     OFS
        clr     ROWC
DSROW:  ldu     GPTR
        ldb     ROWC
        lda     b,u             ; 字形 1 行分
        pshs    x               ; EXPAND は X を壊すので退避
        lbsr    EXPAND          ; → EXPB[0..TSCL-1]
        puls    x
        lda     TSCL
        sta     VREP
DSVR:   ldu     #EXPB
        ldb     TSCL
DSWB:   lda     ,u+             ; 拡大後の字形バイト g
        tst     MSKV
        bne     DSWSET
        coma                    ; 色ビット 0: 旧 AND (NOT g)
        anda    ,x
        bra     DSWST
DSWSET: ora     ,x              ; 色ビット 1: 旧 OR g
DSWST:  sta     ,x+
        decb
        bne     DSWB
        tfr     x,d             ; 次ラインの同じ桁へ
        addb    DLT
        adca    #0
        tfr     d,x
        dec     VREP
        bne     DSVR
        inc     ROWC
        lda     ROWC
        cmpa    #8
        bne     DSROW
        ldd     OFS             ; 次の文字へ (TSCL バイト列進む)
        addb    TSCL
        adca    #0
        std     OFS
        bra     DSCH
DSNXP:  inc     PLIDX
        lda     PLIDX
        cmpa    NPLD
        lbne    DSPL
        rts

; -----------------------------------------------------------------------------
; EXPAND: 字形 1 バイト (A) を TSCL 倍に横拡大して EXPB へ格納する
;   TSCL=1: そのまま / TSCL=2: ニブル表引き / TSCL=4: 2ビット表引き
; -----------------------------------------------------------------------------
EXPAND: ldb     TSCL
        cmpb    #2
        beq     EXP2
        cmpb    #4
        beq     EXP4
        sta     EXPB
        rts
EXP2:   pshs    a
        lsra
        lsra
        lsra
        lsra
        tfr     a,b
        ldx     #EXP2T
        lda     b,x
        sta     EXPB
        puls    a
        anda    #$0F
        tfr     a,b
        ldx     #EXP2T
        lda     b,x
        sta     EXPB+1
        rts
EXP4:   ldu     #EXPB
        ldb     #4
EXP4LP: pshs    b
        tfr     a,b
        lsrb
        lsrb
        lsrb
        lsrb
        lsrb
        lsrb                    ; B = 上位2ビット
        pshs    a
        ldx     #EXP4T
        lda     b,x
        sta     ,u+
        puls    a
        asla
        asla
        puls    b
        decb
        bne     EXP4LP
        rts

; ---- 横拡大表 ----
;   EXP2T: ニブル b3b2b1b0 → b3b3 b2b2 b1b1 b0b0
EXP2T:  fcb     $00,$03,$0C,$0F,$30,$33,$3C,$3F
        fcb     $C0,$C3,$CC,$CF,$F0,$F3,$FC,$FF
;   EXP4T: 2ビット b1b0 → b1b1b1b1 b0b0b0b0
EXP4T:  fcb     $00,$0F,$F0,$FF

        end
