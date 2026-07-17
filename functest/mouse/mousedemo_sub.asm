; =============================================================================
; mousedemo_sub.asm — サブCPU側 描画プログラム (画面モード切替ボタン付き)
;
; メインCPUから転送・起動され、以下を行う:
;   1. 現在の画面モードに応じた背景グラデーションを全画面に描画
;   2. 画面最上部にタイトル帯 (行0-9、黒地) とタイトル文字列
;      "7032 - MOUSE TEST" (行1-8、白、CG ROM フォント) を描画
;   3. タイトルの下の段に 4 つのモード切替ボタン (行12-27、ラベルは
;      CG ROM フォント) を描画
;      - 現在モードのボタンは赤枠で強調、非対応モードは暗色 (無効表示)
;   4. ボタン帯の下に現在のマウス方式 (行30) と左右ボタンインジケータ
;      (行41-52、押下中は点灯) を描画
;   5. 共有RAMのメールボックス (座標・ボタン・モード・方式) を監視
;   6. モードが変わったら全再描画、座標が変わったら XOR カーソルを再描画。
;      方式やボタン状態が変わったらステータス表示のみ更新 (変化時のみ)
;   7. 左ボタン押下中は青チャネルのみ反転しカーソル色を変える
;
; 対応モード (mode 0-3):
;   0: 640x200 8色    — 3 プレーン (B/R/G 各 $4000)、80 バイト/ライン
;   1: 320x200 4096色 — 12 サブプレーン (2 ページ x 6、$D430 bit5 で切替)
;   2: 640x400 8色    — 3 プレーン (各 $8000)、$D42F バンク 0/1/2 = B/R/G、
;                       サブ窓 $0000-$7FFF (AV40系のみ)
;   3: 320x200 262144色 — 18 サブプレーン ($D42F バンク 0/1/2 x 各6面)、
;                       バンク0=ビット5/4、1=3/2、2=1/0 (B/R/G 各6ビット)
;                       (AV40系のみ)
;
; 機種レベル (LVL): 0=FM-7 / 1=FM77AV / 2=AV40系
;   メインが FM-7/AV を判別して共有RAMで渡し、サブは $D42F の読み返し
;   (AV40系のみ $FC|バンク が読める。他機種は $FF) で AV40系を判別する。
;
; ビルド: lwasm --6809 --format=raw -o mousedemo_sub.bin mousedemo_sub.asm
; =============================================================================

        org     $C100

; ---- 共有RAM メールボックス (サブ側アドレス) ----
SH_SEQ  equ     $D383           ; 更新カウンタ (メインが更新の度に +1)
SH_XH   equ     $D384           ; カーソルX座標 (16ビット、続けて XL)
SH_YH   equ     $D386           ; カーソルY座標 (16ビット、続けて YL)
SH_BTN  equ     $D388           ; ボタン状態 (bit4=左, bit5=右, 押下=1)
SH_MODE equ     $D389           ; 画面モード (0-3、メインが指示)
SH_AVF  equ     $D38A           ; 機種フラグ (0=FM-7 / 1=AV系、メインが判別)
SH_BG   equ     $D390           ; 背景描画完了マーカー ($A5)
SH_CNT  equ     $D391           ; 描画完了カウンタ
SH_LVL  equ     $D392           ; 機種レベル (0/1/2、サブが確定して報告)
SH_MACK equ     $D393           ; サブが現在表示中のモード (ack)
SH_METH equ     $D39D           ; マウス方式 (0=バス / 1=P1 / 2=P2、メインが書く)
SH_RAW  equ     $D39E           ; 生読み値 12 バイト: BUS[0-3] / P1[4-7] / P2[8-11]
SH_R15P1 equ    $D3AA           ; P1 のストローブ reg15 値
SH_R15P2 equ    $D3AB           ; P2 のストローブ reg15 値

; ---- サブ側 I/O ----
IO_CRT  equ     $D408           ; 読み出しで CRT 表示 ON
IO_VRAM equ     $D409           ; 読み出しで VRAM アクセス許可
IO_BUSY equ     $D40A           ; 読み出しで BUSY フラグ解除
IO_MISC equ     $D430           ; bit7=NMIマスク bit6=表示ページ bit5=アクティブページ
IO_VBNK equ     $D42F           ; AV40系: VRAM バンクセレクト (bit1-0、読み=$FC|バンク)

; ---- ワークエリア (サブRAM $CF90-) ----
CURMODE equ     $CF90           ; 現在の画面モード (0-3)
LVL     equ     $CF91           ; 機種レベル (0/1/2)
ENMASK  equ     $CF92           ; 有効モードマスク (bit i = モード i 有効)
NPL     equ     $CF93           ; 現モードのプレーン数
BPL     equ     $CF94           ; 現モードのバイト/ライン
HGT     equ     $CF95           ; 現モードのライン数 (2バイト)
PLPTR   equ     $CF97           ; プレーンテーブル先頭 (2バイト)
MCOLB   equ     $CF99           ; 現モードの色テーブル先頭 (2バイト)
PBASE   equ     $CF9B           ; 現プレーンのベースアドレス (2バイト)
PCHAN   equ     $CF9D           ; 現プレーンのチャネル (0=B 1=R 2=G)
PMASK   equ     $CF9E           ; 現プレーンのチャネル内ビット
PLIDX   equ     $CF9F           ; プレーンループカウンタ
LSEQ    equ     $CFA0           ; 最後に処理した更新カウンタ
DRAWN   equ     $CFA1           ; カーソル描画済みフラグ
NX      equ     $CFA2           ; 新X座標 (2バイト)
NY      equ     $CFA4           ; 新Y座標 (2バイト)
NMASK   equ     $CFA6           ; 新カーソルマスク (0=全プレーン, 非0=Bのみ)
OX      equ     $CFA7           ; 描画済みX座標 (2バイト)
OY      equ     $CFA9           ; 描画済みY座標 (2バイト)
OMASK   equ     $CFAB           ; 描画済みカーソルマスク
CX      equ     $CFAC           ; XOR描画対象X座標 (2バイト)
CY      equ     $CFAE           ; XOR描画対象Y座標 (2バイト)
CMASK   equ     $CFB0           ; XOR描画対象マスク
COL     equ     $CFB1           ; カーソル左端のバイト列
SFT     equ     $CFB2           ; カーソルのビットシフト量 (0-7)
BOFS    equ     $CFB3           ; カーソル基点プレーン内オフセット (2バイト)
OFS     equ     $CFB5           ; 現在行のアドレス (2バイト)
ROWC    equ     $CFB7           ; 行カウンタ
PATH    equ     $CFB8           ; シフト済みパターン上位
PATL    equ     $CFB9           ; シフト済みパターン下位
TMPW    equ     $CFBA           ; 2バイト作業領域
TMP1    equ     $CFBC
COLORP  equ     $CFBD           ; 現在の描画色 (B,R,G 3バイト組) へのポインタ
RCOL    equ     $CFBF           ; 矩形: 左端バイト列
RW      equ     $CFC0           ; 矩形: 幅 (バイト列数)
RROW    equ     $CFC1           ; 矩形: 上端ライン (2バイト)
RNR     equ     $CFC3           ; 矩形: 高さ (ライン数)
TCOL    equ     $CFC4           ; 文字列: 左端バイト列
TROW    equ     $CFC5           ; 文字列: 上端ライン (2バイト)
TSTR    equ     $CFC7           ; 文字列: ポインタ (2バイト)
BIDX    equ     $CFC9           ; ボタン番号
BCOL    equ     $CFCA           ; ボタン左端バイト列
BW      equ     $CFCB           ; ボタン幅
BLCOL   equ     $CFCC           ; ラベル左端バイト列
FILLP   equ     $CFCD           ; ボタン地色ポインタ (2バイト)
BTAB    equ     $CFCF           ; ボタン配置テーブル (2バイト)
LTAB    equ     $CFD1           ; ラベルテーブル (2バイト)
YCNT    equ     $CFD3           ; 背景: Yライン (2バイト、400ライン対応)
BXC     equ     $CFD5           ; 背景: バイト列
BANDC   equ     $CFD6           ; 背景: 縦帯の色番号
; ---- 4096色背景 (BGPASS) 専用ワーク ----
MHI     equ     $CFD8           ; 現パスの上位側ビットマスク (色ニブル内)
MLO     equ     $CFD9           ; 現パスの下位側ビットマスク
BYC     equ     $CFDA           ; BGPASS: Yライン
GHB     equ     $CFDB           ; 緑プレーンバイト (上位ビット面)
GLB     equ     $CFDC           ; 緑プレーンバイト (下位ビット面)
RHB     equ     $CFDD           ; 赤プレーンバイト (上位)
RLB     equ     $CFDE           ; 赤プレーンバイト (下位)
QV      equ     $CFDF           ; (x+y)>>3 の値
FV      equ     $CFE0           ; (x+y)&7
QH      equ     $CFE1           ; 青: 境界前の上位面バイト
QL      equ     $CFE2           ; 青: 境界前の下位面バイト
Q1H     equ     $CFE3           ; 青: 境界後の上位面バイト
Q1L     equ     $CFE4           ; 青: 境界後の下位面バイト
MSKA    equ     $CFE5           ; 境界分割マスク
TINK    equ     $CFE6           ; TEXT: 0=黒文字/地色 (COLORP) / 非0=白系文字 (COLORP)/黒地
CMETH   equ     $CFE7           ; 表示中のマウス方式 (0/1/2)
CBTNS   equ     $CFE8           ; 表示中のボタン状態 (bit4=左, bit5=右, 押下=1)
; ---- 生読み値表示の状態 ----
CRAW    equ     $CFE9           ; 表示中の生読み値 12 バイト ($CFE9-$CFF4)
CR15P1  equ     $CFF5           ; 表示中の P1 reg15
CR15P2  equ     $CFF6           ; 表示中の P2 reg15
CSEL    equ     $CFF7           ; 表示中の選択方式 (0/1/2)
RMETH   equ     $CFF8           ; RAW 行組立: 対象方式
STRBUF  equ     $CE00           ; RAW 行文字列組立バッファ (最大 32 バイト)

CGROM   equ     $D800           ; CG ROM (8x8 フォント、1文字8バイト、ASCII配置)

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
        clr     SH_BG
        clr     SH_CNT
        clr     TINK            ; TEXT は既定で黒文字/地色モード

        ; ---- 機種レベル確定: AVF=0 → FM-7。AV系なら $D42F の読み返しで
        ;      AV40系 (バンク0書込み後 $FC が読める) かを確認する ----
        lda     SH_AVF
        sta     LVL
        beq     LVLOK           ; FM-7: $D42F には触らない
        clr     IO_VBNK         ; バンク0
        lda     IO_VBNK
        cmpa    #$FC            ; AV40系: $FC|バンク / 他: $FF
        bne     LVLOK
        lda     #2
        sta     LVL
LVLOK:  ldx     #MASKTB
        ldb     LVL
        lda     b,x
        sta     ENMASK
        lda     LVL
        sta     SH_LVL

        ; ---- 初期メールボックス取り込み → 全描画 ----
        lda     SH_SEQ
        sta     LSEQ
        ldd     SH_XH
        std     NX
        ldd     SH_YH
        std     NY
        lda     SH_BTN
        anda    #$10
        sta     NMASK
        lda     SH_MODE
        sta     CURMODE
        clr     DRAWN
        jsr     REDRAW
        lda     #$A5
        sta     SH_BG           ; 背景完了マーカー
        bra     MAINLP

MASKTB: fcb     $01,$03,$0F     ; LVL 0/1/2 → 有効モードマスク

; =============================================================================
; メインループ: メールボックス監視 → モード切替 / カーソル再描画
; =============================================================================
MAINLP: lda     IO_BUSY         ; 常時レディ通知 (BUSY OFF 維持)
        lda     SH_SEQ
        cmpa    LSEQ
        beq     MAINLP
        sta     LSEQ
        ; 新しい座標・ボタン状態・モードを取り込む
        ldd     SH_XH
        std     NX
        ldd     SH_YH
        std     NY
        lda     SH_BTN
        anda    #$10            ; 左ボタン
        sta     NMASK
        lda     SH_MODE
        cmpa    CURMODE
        beq     CURUPD
        sta     CURMODE         ; モード切替: 全再描画
        jsr     REDRAW
        bra     MAINLP
CURUPD: ; 旧カーソルを先に消去 (XOR は再適用で元に戻る)
        lda     DRAWN
        beq     NOERA
        ldd     OX
        std     CX
        ldd     OY
        std     CY
        lda     OMASK
        sta     CMASK
        jsr     XORCUR
NOERA:  ; ---- 方式表示の更新 (変化時のみ) ----
        lda     SH_METH
        cmpa    CMETH
        beq     SBCHK
        sta     CMETH
        jsr     SMETHD
SBCHK:  ; ---- 左右ボタンインジケータの更新 (変化時のみ) ----
        lda     SH_BTN
        anda    #$30
        cmpa    CBTNS
        beq     RWCHK
        sta     CBTNS
        jsr     SBTND
RWCHK:  ; ---- 生読み値 3 行の更新 (変化時のみ) ----
        jsr     RAWUPD
        ; ---- 新カーソルを最後に描画 (ステータス/生値の上に重ねる) ----
        ldd     NX
        std     CX
        std     OX
        ldd     NY
        std     CY
        std     OY
        lda     NMASK
        sta     CMASK
        sta     OMASK
        jsr     XORCUR
        lda     #1
        sta     DRAWN
        inc     SH_CNT          ; 描画完了通知
        lbra    MAINLP

; =============================================================================
; REDRAW: 現モードの背景 + タイトル + ボタン + カーソルを全描画
; =============================================================================
REDRAW: jsr     MODESET
        ldb     CURMODE
        aslb
        ldx     #BGTAB
        jsr     [b,x]           ; 背景描画
        jsr     TITLE           ; タイトル帯 + タイトル文字列描画
        jsr     BTNDRAW         ; ボタン描画
        lda     SH_METH
        sta     CMETH
        lda     SH_BTN
        anda    #$30
        sta     CBTNS
        jsr     SDRAW           ; 方式表示 + 左右ボタンインジケータ
        jsr     RAWALL          ; 生読み値 3 行 + 操作案内 (帯含む全描画)
        ldd     NX
        std     CX
        std     OX
        ldd     NY
        std     CY
        std     OY
        lda     NMASK
        sta     CMASK
        sta     OMASK
        jsr     XORCUR          ; カーソル描画
        lda     #1
        sta     DRAWN
        lda     CURMODE
        sta     SH_MACK
        inc     SH_CNT
        rts

; -----------------------------------------------------------------------------
; MODESET: モード別パラメータを設定し、ページ/バンクを既定に戻す
; -----------------------------------------------------------------------------
MODESET:
        ldb     CURMODE
        ldx     #NPLTAB
        lda     b,x
        sta     NPL
        ldx     #BPLTAB
        lda     b,x
        sta     BPL
        ldb     CURMODE         ; 2 バイト表は ldd が B を壊すため都度引き直す
        aslb
        ldx     #HGTTAB
        ldd     b,x
        std     HGT
        ldb     CURMODE
        aslb
        ldx     #PLPTRS
        ldd     b,x
        std     PLPTR
        ldb     CURMODE
        aslb
        ldx     #MCOLP
        ldd     b,x
        std     MCOLB
        lda     #$80
        sta     IO_MISC         ; ページ0
        lda     LVL
        cmpa    #2
        bne     MS9
        clr     IO_VBNK         ; AV40系: バンク0 (非搭載機では触らない)
MS9:    rts

; ---- モード別パラメータ表 ----
NPLTAB: fcb     3,12,3,18       ; プレーン数
BPLTAB: fcb     80,40,80,40     ; バイト/ライン
HGTTAB: fdb     200,200,400,200 ; ライン数
PLPTRS: fdb     PT0,PT1,PT2,PT3 ; プレーンテーブル
BGTAB:  fdb     BG0,BG1,BG0,BG3 ; 背景描画ルーチン
MCOLP:  fdb     MCOL0,MCOL1,MCOL2,MCOL3

; ---- モード別色テーブル: 各 (B,R,G) 3バイト x [白地, 暗地, 赤枠] ----
MCOL0:  fcb     1,1,1,1,0,0,0,1,0
MCOL1:  fcb     15,15,15,8,0,0,0,15,0
MCOL2:  fcb     1,1,1,1,0,0,0,1,0
MCOL3:  fcb     63,63,63,32,0,0,0,63,0
BLK3:   fcb     0,0,0           ; 黒 (共通)

; ---- プレーンテーブル: 1 エントリ = [制御値, ベース上位, チャネル, ビット] ----
; 制御値はモード1では $D430 (ページ)、モード2/3では $D42F (バンク) へ書く。
PT0:    fcb     0,$00,0,$01,0,$40,1,$01,0,$80,2,$01
PT1:    fcb     $80,$00,0,$08,$80,$20,0,$04,$80,$40,1,$08,$80,$60,1,$04
        fcb     $80,$80,2,$08,$80,$A0,2,$04
        fcb     $A0,$00,0,$02,$A0,$20,0,$01,$A0,$40,1,$02,$A0,$60,1,$01
        fcb     $A0,$80,2,$02,$A0,$A0,2,$01
PT2:    fcb     0,$00,0,$01,1,$00,1,$01,2,$00,2,$01
PT3:    fcb     0,$00,0,$20,0,$20,0,$10,0,$40,1,$20,0,$60,1,$10
        fcb     0,$80,2,$20,0,$A0,2,$10
        fcb     1,$00,0,$08,1,$20,0,$04,1,$40,1,$08,1,$60,1,$04
        fcb     1,$80,2,$08,1,$A0,2,$04
        fcb     2,$00,0,$02,2,$20,0,$01,2,$40,1,$02,2,$60,1,$01
        fcb     2,$80,2,$02,2,$A0,2,$01

; -----------------------------------------------------------------------------
; PLGET: PLIDX 番目のプレーンを選択 (ページ/バンク切替 + PBASE/PCHAN/PMASK 設定)
; -----------------------------------------------------------------------------
PLGET:  lda     PLIDX
        ldb     #4
        mul
        ldx     PLPTR
        leax    d,x
        lda     ,x              ; 制御値
        ldb     CURMODE
        cmpb    #1
        bne     PG2
        sta     IO_MISC         ; モード1: アクティブページ切替
        bra     PG9
PG2:    cmpb    #2
        blo     PG9             ; モード0: 制御なし
        sta     IO_VBNK         ; モード2/3: VRAM バンク切替
PG9:    lda     1,x
        sta     PBASE
        clr     PBASE+1
        lda     2,x
        sta     PCHAN
        lda     3,x
        sta     PMASK
        rts

; -----------------------------------------------------------------------------
; FVAL: A = 現プレーンにおける COLORP 色の塗りバイト ($FF / $00)
; -----------------------------------------------------------------------------
FVAL:   pshs    x
        ldx     COLORP
        ldb     PCHAN
        lda     b,x
        anda    PMASK
        beq     FV0
        lda     #$FF
        puls    x,pc
FV0:    clra
        puls    x,pc

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
; RECTF: 全プレーンへ矩形塗り (RCOL/RW/RROW/RNR、色は COLORP)
; -----------------------------------------------------------------------------
RECTF:  clr     PLIDX
RFPL:   jsr     PLGET
        jsr     FVAL
        sta     TMP1
        ldd     RROW
        jsr     MULBPL
        addd    PBASE
        addb    RCOL
        adca    #0
        std     OFS
        lda     RNR
        sta     ROWC
RFROW:  ldx     OFS
        ldb     RW
        lda     TMP1
RFB:    sta     ,x+
        decb
        bne     RFB
        ldd     OFS
        addb    BPL
        adca    #0
        std     OFS
        dec     ROWC
        bne     RFROW
        inc     PLIDX
        lda     PLIDX
        cmpa    NPL
        bne     RFPL
        rts

; -----------------------------------------------------------------------------
; TEXT: 全プレーンへ文字列描画 (TCOL/TROW/TSTR)
;   TINK=0: 地色 COLORP に黒文字 (ボタンラベル用)
;   TINK=1: 黒地に COLORP 色の文字 (タイトル用、字形ビットをそのまま置く)
;   CG ROM (サブ $D800-、8x8、1文字8バイト、ASCII配置) から字形を読む
; -----------------------------------------------------------------------------
TEXT:   clr     PLIDX
TXPL:   jsr     PLGET
        jsr     FVAL
        sta     TMP1            ; 地色バイト ($FF/$00)
        ldd     TROW
        jsr     MULBPL
        addd    PBASE
        addb    TCOL
        adca    #0
        std     OFS
        ldy     TSTR
TXCH:   lda     ,y+
        lbeq    TXPLN           ; NUL 終端 → 次のプレーン
        tfr     a,b
        clra
        aslb
        rola
        aslb
        rola
        aslb
        rola                    ; D = 文字コード*8
        addd    #CGROM
        tfr     d,u
        ldx     OFS
        lda     #8
        sta     ROWC
TXROW:  lda     ,u+
        tst     TINK
        beq     TXNRM           ; 通常: 地色に黒文字
        tst     TMP1            ; 白系文字: 文字色ビットの立つプレーンのみ字形
        bne     TXR1            ;   そのまま (立たないプレーンは黒 = 0)
        bra     TXR0
TXNRM:  tst     TMP1
        beq     TXR0
        coma                    ; 地=1: 字形の補数 (黒文字)
        bra     TXR1
TXR0:   clra                    ; 地=0: そのまま黒
TXR1:   sta     ,x
        pshs    a
        tfr     x,d
        addb    BPL
        adca    #0
        tfr     d,x
        puls    a
        dec     ROWC
        bne     TXROW
        ldd     OFS
        addd    #1
        std     OFS
        bra     TXCH
TXPLN:  inc     PLIDX
        lda     PLIDX
        cmpa    NPL
        lbne    TXPL
        rts

; =============================================================================
; TITLE: 画面最上部にタイトル帯 (行0-9、黒地) とタイトル文字列
;   "7032 - MOUSE TEST" (行1-8、白、中央寄せ) を描画する
;   文字は TEXT の白系文字モード (TINK=1、黒地に COLORP 色) で描く
; =============================================================================
TITLE:  ; ---- 帯: 全幅 x 行0-9 を黒で塗る ----
        ldd     #BLK3
        std     COLORP
        clr     RCOL
        lda     BPL
        sta     RW              ; 全幅 (80 or 40 バイト列)
        ldd     #0
        std     RROW
        lda     #10
        sta     RNR
        jsr     RECTF
        ; ---- タイトル文字列 (行1-8、白、中央寄せ) ----
        lda     #1
        sta     TINK            ; 白系文字モード
        ldd     MCOLB
        std     COLORP          ; 白 (モード別の白地色を流用)
        lda     #31             ; 640 幅: (80-17)/2 = 31
        ldb     BPL
        cmpb    #80
        beq     TT1
        lda     #11             ; 320 幅: (40-17)/2 = 11
TT1:    sta     TCOL
        ldd     #1
        std     TROW
        ldx     #TSTITL
        stx     TSTR
        jsr     TEXT
        clr     TINK            ; 黒文字/地色モードへ戻す
        rts
TSTITL: fcc     "7032 - MOUSE TEST"
        fcb     0

; =============================================================================
; BTNDRAW: モード切替ボタン 4 個を描画 (タイトルの下、行 12-27 の帯)
;   有効ボタン: 白地 + 黒ラベル / 無効ボタン: 暗地 + 黒ラベル
;   現在モードのボタン: 赤枠 / その他: 黒枠
; =============================================================================
BTNDRAW:
        ldx     #BTABW          ; 640 幅レイアウト (モード0/2)
        ldu     #LTABW
        lda     CURMODE
        anda    #1
        beq     BD0
        ldx     #BTABN          ; 320 幅レイアウト (モード1/3)
        ldu     #LTABN
BD0:    stx     BTAB
        stu     LTAB
        clr     BIDX
BDLP:   lda     BIDX
        ldb     #3
        mul
        ldx     BTAB
        leax    d,x
        lda     ,x
        sta     BCOL
        ldb     1,x
        stb     BW
        lda     2,x
        sta     BLCOL
        ; ---- 地色: 有効なら白地、無効なら暗地 ----
        ldb     BIDX
        lda     #1
BDSH:   tstb
        beq     BDSH2
        asla
        decb
        bra     BDSH
BDSH2:  anda    ENMASK          ; (ldd はフラグを壊すため分岐を先に済ませる)
        beq     BDDK
        ldd     MCOLB           ; 白地
        bra     BDEN
BDDK:   ldd     MCOLB
        addd    #3              ; 暗地
BDEN:   std     FILLP
        std     COLORP
        ; ---- ボタン全体を地色で塗る ----
        lda     BCOL
        sta     RCOL
        lda     BW
        sta     RW
        ldd     #12
        std     RROW
        lda     #16
        sta     RNR
        jsr     RECTF
        ; ---- 枠色: 現在モードなら赤、他は黒 ----
        lda     BIDX
        cmpa    CURMODE
        bne     BDBLK
        ldd     MCOLB
        addd    #6              ; 赤
        bra     BDFR
BDBLK:  ldd     #BLK3
BDFR:   std     COLORP
        ; 上枠 (行12-13)
        lda     BCOL
        sta     RCOL
        lda     BW
        sta     RW
        ldd     #12
        std     RROW
        lda     #2
        sta     RNR
        jsr     RECTF
        ; 下枠 (行26-27)
        lda     BCOL
        sta     RCOL
        lda     BW
        sta     RW
        ldd     #26
        std     RROW
        lda     #2
        sta     RNR
        jsr     RECTF
        ; 左枠 (1バイト列)
        lda     BCOL
        sta     RCOL
        lda     #1
        sta     RW
        ldd     #12
        std     RROW
        lda     #16
        sta     RNR
        jsr     RECTF
        ; 右枠 (1バイト列)
        lda     BCOL
        adda    BW
        deca
        sta     RCOL
        lda     #1
        sta     RW
        ldd     #12
        std     RROW
        lda     #16
        sta     RNR
        jsr     RECTF
        ; ---- ラベル (行17-24、地色 = ボタン地色) ----
        ldd     FILLP
        std     COLORP
        lda     BLCOL
        sta     TCOL
        ldd     #17
        std     TROW
        lda     BIDX
        asla
        ldx     LTAB
        pshs    a
        puls    b
        ldd     b,x
        std     TSTR
        jsr     TEXT
        inc     BIDX
        lda     BIDX
        cmpa    #4
        lbne    BDLP
        rts

; ---- ボタン配置表: 1 ボタン = [左端バイト列, 幅, ラベル左端バイト列] ----
BTABW:  fcb     1,18,6,21,18,24,41,18,46,61,18,64
BTABN:  fcb     0,9,2,10,9,11,20,9,21,30,9,32
LTABW:  fdb     LW0,LW1,LW2,LW3
LTABN:  fdb     LN0,LN1,LN2,LN3
LW0:    fcc     "640x200 8"
        fcb     0
LW1:    fcc     "320x200 4096"
        fcb     0
LW2:    fcc     "640x400 8"
        fcb     0
LW3:    fcc     "320x200 262K"
        fcb     0
LN0:    fcc     "640x8"
        fcb     0
LN1:    fcc     "320x4K"
        fcb     0
LN2:    fcc     "640x400"
        fcb     0
LN3:    fcc     "262K"
        fcb     0

; =============================================================================
; SDRAW: ステータス表示 (現在の方式 + 左右ボタンインジケータ) の全描画
;   ボタン帯 (行12-27) の下の空きに配置し、全モード共通のバイト列を使う。
;   入力: CMETH (方式 0/1/2), CBTNS (bit4=左, bit5=右, 押下=1)
; =============================================================================
SDRAW:  jsr     SMETHD          ; 方式表示
        jsr     SBTND           ; 左右ボタンインジケータ
        rts

; -----------------------------------------------------------------------------
; SMETHD: 方式表示 (行29-38 を黒帯で塗り、行30 に方式名を白で描く)
; -----------------------------------------------------------------------------
SMETHD: ; ---- 黒帯 (行29-38、全幅) で旧表示を消す ----
        ldd     #BLK3
        std     COLORP
        clr     RCOL
        lda     BPL
        sta     RW
        ldd     #29
        std     RROW
        lda     #10
        sta     RNR
        jsr     RECTF
        ; ---- 方式名 (行30、白、TINK=1 黒地に白文字) ----
        lda     #1
        sta     TINK
        ldd     MCOLB
        std     COLORP          ; 白 (モード別の白地色を流用)
        lda     #1
        sta     TCOL
        ldd     #30
        std     TROW
        ldb     CMETH
        aslb
        ldx     #METHTAB
        ldd     b,x
        std     TSTR
        jsr     TEXT
        clr     TINK
        rts

METHTAB: fdb    MSTR0,MSTR1,MSTR2
MSTR0:  fcc     "MOUSE: BUS"
        fcb     0
MSTR1:  fcc     "MOUSE: INTELLIGENT P1"
        fcb     0
MSTR2:  fcc     "MOUSE: INTELLIGENT P2"
        fcb     0

; -----------------------------------------------------------------------------
; SBTND: 左右ボタンインジケータ (行41-52 の 2 箱)。押下中は白 (点灯)、
;   非押下は暗色 (消灯)。ラベルは黒文字 (TINK=0)。
; -----------------------------------------------------------------------------
SBTND:  clr     TINK
        ; ---- 左ボタン箱 (バイト列 1-8) ----
        lda     CBTNS
        bita    #$10
        beq     SBLD            ; 非押下 → 暗色
        ldd     MCOLB           ; 押下 → 白 (点灯)
        bra     SBLF
SBLD:   ldd     MCOLB
        addd    #3              ; 暗色 (消灯)
SBLF:   std     COLORP
        std     FILLP
        lda     #1
        sta     RCOL
        lda     #8
        sta     RW
        ldd     #41
        std     RROW
        lda     #12
        sta     RNR
        jsr     RECTF
        ldd     FILLP
        std     COLORP
        lda     #2
        sta     TCOL
        ldd     #44
        std     TROW
        ldx     #LBLLEFT
        stx     TSTR
        jsr     TEXT
        ; ---- 右ボタン箱 (バイト列 10-18) ----
        lda     CBTNS
        bita    #$20
        beq     SBRD
        ldd     MCOLB
        bra     SBRF
SBRD:   ldd     MCOLB
        addd    #3
SBRF:   std     COLORP
        std     FILLP
        lda     #10
        sta     RCOL
        lda     #9
        sta     RW
        ldd     #41
        std     RROW
        lda     #12
        sta     RNR
        jsr     RECTF
        ldd     FILLP
        std     COLORP
        lda     #11
        sta     TCOL
        ldd     #44
        std     TROW
        ldx     #LBLRIGHT
        stx     TSTR
        jsr     TEXT
        rts

LBLLEFT:  fcc   "LEFT"
          fcb   0
LBLRIGHT: fcc   "RIGHT"
          fcb   0

; =============================================================================
; 生読み値の 3 行同時表示 (BUS / P1 / P2) + 操作案内
;   実機/検証機で BUS・P1・P2 の生バイトを見比べ、どの系統がどう返っているか
;   (例: P1 はボタンビットだけ来て X/Y ニブルがずれる、P2 は全 FF 等) を
;   一目で読み取れるようにする診断表示。選択中の方式は行頭 '>' で強調する。
;
;   レイアウト (行 = ピクセルライン、CG ROM 8x8 フォント):
;     行53-92 : 黒帯 (全幅)
;     行54    : ">BUS xx xx xx xx"        (選択中は '>' / 他は ' ')
;     行63    : " P1  xx xx xx xx R15:13"
;     行72    : " P2  xx xx xx xx R15:6C"
;     行84    : "KEY 0:BUS 1:INT-P1 2:INT-P2" (操作案内)
;   320幅 (40バイト/行) でも最長 23 文字で収まる。
; =============================================================================
; RAWALL: 帯 + 操作案内 + 3 行を全描画し、表示中値を控える (REDRAW から)
RAWALL: ; ---- 黒帯 (行53-92 全幅) ----
        ldd     #BLK3
        std     COLORP
        clr     RCOL
        lda     BPL
        sta     RW
        ldd     #53
        std     RROW
        lda     #40
        sta     RNR
        jsr     RECTF
        ; ---- 操作案内 (行84、白、TINK=1) ----
        lda     #1
        sta     TINK
        ldd     MCOLB
        std     COLORP
        clr     TCOL
        ldd     #84
        std     TROW
        ldx     #GUIDES
        stx     TSTR
        jsr     TEXT
        clr     TINK
        ; ---- 3 行の生読み値 ----
        jsr     RAWROWS
        jsr     RAWSAV
        rts

; RAWUPD: 共有RAMの生値/選択が変わっていれば 3 行を再描画 (固定幅で上書き)
RAWUPD: lda     SH_METH
        cmpa    CSEL
        bne     RUDO
        lda     SH_R15P1
        cmpa    CR15P1
        bne     RUDO
        lda     SH_R15P2
        cmpa    CR15P2
        bne     RUDO
        ldx     #SH_RAW
        ldy     #CRAW
        ldb     #12
RUCK:   lda     ,x+
        cmpa    ,y+
        bne     RUDO
        decb
        bne     RUCK
        rts                     ; 変化なし
RUDO:   jsr     RAWROWS
        jsr     RAWSAV
        rts

; RAWSAV: 現在の共有RAM生値/選択を表示中値 (CRAW/CR15/CSEL) へ控える
RAWSAV: ldx     #SH_RAW
        ldy     #CRAW
        ldb     #12
RSAV1:  lda     ,x+
        sta     ,y+
        decb
        bne     RSAV1
        lda     SH_R15P1
        sta     CR15P1
        lda     SH_R15P2
        sta     CR15P2
        lda     SH_METH
        sta     CSEL
        rts

; RAWROWS: 3 行 (BUS/P1/P2) を描画。各行は STRBUF に組み立てて TEXT で描く
RAWROWS: clrb
RRLP:   stb     RMETH
        jsr     ROWBLD          ; STRBUF に方式 RMETH の行文字列を組む
        lda     #1
        sta     TINK
        ldd     MCOLB
        std     COLORP          ; 白 (モード別白地色を流用)
        clr     TCOL
        ldb     RMETH
        aslb
        ldx     #ROWLNT
        ldd     b,x
        std     TROW
        ldx     #STRBUF
        stx     TSTR
        jsr     TEXT
        clr     TINK
        ldb     RMETH
        incb
        cmpb    #3
        bne     RRLP
        rts
ROWLNT: fdb     54,63,72        ; BUS / P1 / P2 の行 (ピクセルライン)

; ROWBLD: RMETH (0/1/2) の行文字列を STRBUF へ NUL 終端で組み立てる
;   ">"/" " + ラベル(4) + "xx xx xx xx" [+ " R15:xx" (P1/P2)]
ROWBLD: ldy     #STRBUF
        ; --- 選択マーカー ---
        lda     #' '
        ldb     RMETH
        cmpb    SH_METH
        bne     RBM
        lda     #'>'
RBM:    sta     ,y+
        ; --- ラベル 4 バイト (LABTAB[RMETH]) ---
        ldb     RMETH
        lslb
        ldx     #LABTAB
        ldx     b,x
        lda     ,x+
        sta     ,y+
        lda     ,x+
        sta     ,y+
        lda     ,x+
        sta     ,y+
        lda     ,x+
        sta     ,y+
        ; --- 生バイト 4 個 "xx xx xx xx" (SH_RAW[RMETH*4..]) ---
        ldb     RMETH
        lslb
        lslb
        ldx     #SH_RAW
        leax    b,x
        lda     ,x+
        bsr     PUTHEX
        lda     #' '
        sta     ,y+
        lda     ,x+
        bsr     PUTHEX
        lda     #' '
        sta     ,y+
        lda     ,x+
        bsr     PUTHEX
        lda     #' '
        sta     ,y+
        lda     ,x+
        bsr     PUTHEX
        ; --- R15 値 (P1/P2 のみ) " R15:xx" ---
        ldb     RMETH
        beq     RBEND
        ldx     #TXTR15
        lda     ,x+
        sta     ,y+
        lda     ,x+
        sta     ,y+
        lda     ,x+
        sta     ,y+
        lda     ,x+
        sta     ,y+
        lda     ,x+
        sta     ,y+
        ldb     RMETH
        cmpb    #1
        bne     RBP2
        lda     SH_R15P1
        bra     RBPV
RBP2:   lda     SH_R15P2
RBPV:   bsr     PUTHEX
RBEND:  clr     ,y+             ; NUL 終端
        rts
TXTR15: fcc     " R15:"

; PUTHEX: A の 1 バイトを 16 進 2 桁で ,Y+ へ書き込む (Y 前進)
PUTHEX: pshs    a
        lsra
        lsra
        lsra
        lsra
        bsr     HEXNIB
        sta     ,y+
        puls    a
        anda    #$0F
        bsr     HEXNIB
        sta     ,y+
        rts
; HEXNIB: A 下位ニブル (0-15) → ASCII '0'-'9'/'A'-'F'
HEXNIB: anda    #$0F
        cmpa    #10
        blo     HNL
        adda    #7              ; 'A' = '9'+1+7
HNL:    adda    #'0'
        rts

LABTAB: fdb     LBUS,LP1,LP2
LBUS:   fcc     "BUS "
LP1:    fcc     "P1  "
LP2:    fcc     "P2  "
GUIDES: fcc     "KEY 0:BUS 1:INT-P1 2:INT-P2"
        fcb     0

; =============================================================================
; BG0: 640 幅 8色モードの背景 (モード0/2 共用): 8 色の縦帯 (各 80px)
;   帯色 c = バイト列/10 (0-7)。プレーンのチャネル c ビットで $FF/$00
; =============================================================================
BG0:    clr     PLIDX
B0PL:   jsr     PLGET
        ldx     PBASE
        ldd     HGT
        std     YCNT
B0ROW:  clr     BANDC
B0BAND: lda     BANDC
        ldb     PCHAN
B0SH:   tstb
        beq     B0SH2
        lsra
        decb
        bra     B0SH
B0SH2:  bita    #1
        beq     B0Z
        lda     #$FF
        bra     B0F0
B0Z:    clra
B0F0:   ldb     #10
B0F:    sta     ,x+
        decb
        bne     B0F
        inc     BANDC
        ldb     BANDC
        cmpb    #8
        bne     B0BAND
        ldd     YCNT
        subd    #1
        std     YCNT
        lbne    B0ROW
        inc     PLIDX
        lda     PLIDX
        cmpa    NPL
        lbne    B0PL
        rts

; =============================================================================
; BG3: 320x200 262144色モードの背景 (18 サブプレーン、バイト粒度)
;   B = バイト列 + (y>>3) (0-63) / R = バイト列 (0-39) / G = y>>2 (0-49)
; =============================================================================
BG3:    clr     PLIDX
B3PL:   jsr     PLGET
        ldx     PBASE
        clr     YCNT+1          ; y (0-199、下位バイトのみ使用)
B3ROW:  clr     BXC
B3B:    lda     PCHAN
        beq     B3B0
        cmpa    #2
        beq     B3G
        lda     BXC             ; R: バイト列
        bra     B3V
B3G:    lda     YCNT+1
        lsra
        lsra                    ; G: y>>2
        bra     B3V
B3B0:   lda     YCNT+1
        lsra
        lsra
        lsra
        adda    BXC             ; B: バイト列 + (y>>3)
B3V:    anda    PMASK
        beq     B3Z
        lda     #$FF
        bra     B3S
B3Z:    clra
B3S:    sta     ,x+
        inc     BXC
        lda     BXC
        cmpa    #40
        bne     B3B
        inc     YCNT+1
        lda     YCNT+1
        cmpa    #200
        lbne    B3ROW
        inc     PLIDX
        lda     PLIDX
        cmpa    NPL
        lbne    B3PL
        rts

; =============================================================================
; BG1: 320x200 4096色モードの背景 (12 サブプレーンを 2 パスで描画)
;   色設計: 赤 = X方向 (16px毎) / 緑 = Y方向 (8ライン毎) / 青 = 斜め ((x+y)/8)
; =============================================================================
BG1:    lda     #$80
        sta     IO_MISC         ; アクティブページ0
        lda     #$08
        ldb     #$04
        jsr     BGPASS
        lda     #$A0
        sta     IO_MISC         ; アクティブページ1
        lda     #$02
        ldb     #$01
        jsr     BGPASS
        lda     #$80
        sta     IO_MISC
        rts

; -----------------------------------------------------------------------------
; BGPASS: 背景グラデーション 1パス分 (6サブプレーン)
;   入力: A = 上位側ビット選択マスク / B = 下位側ビット選択マスク
;   サブプレーン配置 (アクティブページ内):
;     $0000=青上位 $2000=青下位 $4000=赤上位 $6000=赤下位 $8000=緑上位 $A000=緑下位
; -----------------------------------------------------------------------------
BGPASS: sta     MHI
        stb     MLO
        ldx     #0              ; X = プレーン内オフセット (0-7999)
        clr     BYC
BGYLP:  ; 緑ニブル = (y>>3) & 15 → ライン内で一定
        lda     BYC
        lsra
        lsra
        lsra
        anda    #$0F
        jsr     MK2
        sta     GHB
        stb     GLB
        clr     BXC
BGXLP:  ; 赤ニブル = (bx>>1) & 15 → バイト列 2 個 (16px) 毎に変化
        lda     BXC
        lsra
        anda    #$0F
        jsr     MK2
        sta     RHB
        stb     RLB
        ; 青ニブル = ((x+y)>>3) & 15 → バイト内で高々 1 回変化する
        ; v = bx*8 + y (9ビット)
        ldb     BXC
        clra
        aslb
        rola
        aslb
        rola
        aslb
        rola
        addb    BYC
        adca    #0
        std     TMPW
        ldb     TMPW+1
        andb    #$07
        stb     FV              ; f = v & 7
        ldd     TMPW
        lsra
        rorb
        lsra
        rorb
        lsra
        rorb
        stb     QV              ; q = v >> 3
        ; 境界前 (q) / 境界後 (q+1) の青バイトを作る
        lda     QV
        anda    #$0F
        jsr     MK2
        sta     QH
        stb     QL
        lda     QV
        inca
        anda    #$0F
        jsr     MK2
        sta     Q1H
        stb     Q1L
        ; 分割マスク: 先頭 (8-f) ピクセルが q、残りが q+1
        ldu     #MSKT
        ldb     FV
        lda     b,u
        sta     MSKA
        ; 青上位面バイト
        anda    QH
        sta     TMP1
        lda     MSKA
        coma
        anda    Q1H
        ora     TMP1
        pshs    a               ; = BHB
        ; 青下位面バイト
        lda     MSKA
        anda    QL
        sta     TMP1
        lda     MSKA
        coma
        anda    Q1L
        ora     TMP1
        pshs    a               ; = BLB
        ; 6 プレーンへ格納
        puls    b               ; BLB
        puls    a               ; BHB
        sta     ,x
        stb     $2000,x
        lda     RHB
        sta     $4000,x
        lda     RLB
        sta     $6000,x
        lda     GHB
        sta     $8000,x
        lda     GLB
        sta     $A000,x
        leax    1,x
        inc     BXC
        lda     BXC
        cmpa    #40
        lbne    BGXLP
        inc     BYC
        lda     BYC
        cmpa    #200
        lbne    BGYLP
        rts

; -----------------------------------------------------------------------------
; MK2: 色ニブル値からプレーンバイトを作る
;   入力: A = ニブル値 (0-15)
;   出力: A = 上位側ビット面バイト ($FF/$00), B = 下位側ビット面バイト
; -----------------------------------------------------------------------------
MK2:    tfr     a,b
        anda    MHI
        beq     MK2A
        lda     #$FF
        bra     MK2B
MK2A:   clra
MK2B:   andb    MLO
        beq     MK2C
        ldb     #$FF
        rts
MK2C:   clrb
        rts

; 分割マスク表: f=0..7 → 先頭 (8-f) ビットが 1
MSKT:   fcb     $FF,$FE,$FC,$F8,$F0,$E0,$C0,$80

; =============================================================================
; XORCUR: カーソルを全対象プレーンへ XOR 描画/消去
;   入力: CX/CY = 座標 (クランプ済み), CMASK = 0:全プレーン / 非0:青チャネルのみ
;   モード毎の BPL・プレーン集合・高さクリップに追従する
; =============================================================================
XORCUR: ldd     CX
        lsra
        rorb
        lsra
        rorb
        lsra
        rorb
        stb     COL             ; COL = CX>>3
        lda     CX+1
        anda    #$07
        sta     SFT
        ldd     CY
        jsr     MULBPL
        addb    COL
        adca    #0
        std     BOFS            ; プレーン内オフセット
        clr     PLIDX
XCPL:   jsr     PLGET
        lda     CMASK
        beq     XC1
        lda     PCHAN
        bne     XCNXT           ; 押下中は青チャネル (PCHAN=0) のみ
XC1:    ldd     PBASE
        addd    BOFS
        std     OFS
        clr     ROWC
XCROW:  ldb     ROWC
        cmpb    #12
        bhs     XCNXT
        ldd     CY
        addb    ROWC
        adca    #0
        cmpd    HGT
        bhs     XCNXT           ; 画面下端でクリップ
        ; 行パターンを SFT ビット右シフトして 2 バイトに展開
        ldu     #SHAPE
        ldb     ROWC
        lda     b,u
        sta     PATH
        clr     PATL
        lda     SFT
        beq     XCS0
XCSH:   lsr     PATH
        ror     PATL
        deca
        bne     XCSH
XCS0:   ldx     OFS
        lda     ,x
        eora    PATH
        sta     ,x
        ; 右バイト (画面右端でクリップ)
        lda     COL
        inca
        cmpa    BPL
        bhs     XCNX2
        lda     PATL
        beq     XCNX2
        eora    1,x
        sta     1,x
XCNX2:  ldd     OFS
        addb    BPL
        adca    #0
        std     OFS
        inc     ROWC
        bra     XCROW
XCNXT:  inc     PLIDX
        lda     PLIDX
        cmpa    NPL
        lbne    XCPL
        rts

; 矢印カーソル形状 (8x12)
SHAPE:  fcb     %10000000
        fcb     %11000000
        fcb     %11100000
        fcb     %11110000
        fcb     %11111000
        fcb     %11111100
        fcb     %11111110
        fcb     %11111000
        fcb     %11011000
        fcb     %10001100
        fcb     %00001100
        fcb     %00000110

        end
