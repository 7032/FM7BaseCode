; =============================================================================
; psgvoice_sub.asm — サブCPU側 文字表示プログラム (PSG 音声再生デモ)
;
; メインCPUから共有RAM経由で転送・起動され、以下を行う:
;   1. 画面全体 (640x200 8色、3 プレーン) を黒で塗る
;   2. "HIT SPACE KEY" を 2倍角・中央寄せ・白で描く
;   3. 共有RAMのリクエストセルを監視し、メインCPUの指示で
;        1 = 文字帯を消して "HIT SPACE KEY" を描く
;        2 = 文字帯を消して "FM-7 PSG!" を描く
;      を実行して ack を返す
;
; 背景は無地 (黒) なので、消去は文字帯 (16 ライン x 80 バイト x 3 プレーン)
; の黒塗りで行う。
;
; 文字はサブ空間の CG ROM ($D800-、8x8、1文字8バイト、ASCII 配置) を
; 2 倍に拡大して描く。開始桁をバイト境界に揃えるためビットシフトは不要で、
; 1 ドットを 2 ドットへ展開するニブル表引きだけで済む。
;
; ビルド: lwasm --6809 --format=raw -o psgvoice_sub.bin psgvoice_sub.asm
; =============================================================================

        org     $C100

; ---- 共有RAM 受け渡し領域 (サブ側アドレス) ----
SH_SEQ  equ     $D383           ; 更新カウンタ (メインが指示の度に +1)
SH_REQ  equ     $D39D           ; リクエスト (1=HIT SPACE KEY / 2=FM-7 PSG!)
SH_RACK equ     $D39E           ; リクエスト ack (処理した SH_SEQ を返す)
SH_RDY  equ     $D39F           ; 初期描画完了マーカー ($A5)

; ---- サブ側 I/O ----
IO_CRT  equ     $D408           ; 読み出しで CRT 表示 ON
IO_VRAM equ     $D409           ; 読み出しで VRAM アクセス許可
IO_BUSY equ     $D40A           ; 読み出しで BUSY フラグ解除

CGROM   equ     $D800           ; CG ROM (8x8 フォント、1文字8バイト、ASCII配置)

; ---- 画面レイアウト (640x200 8色 = 3 プレーン x 80 バイト/ライン) ----
BPL     equ     80              ; バイト/ライン
TXROW   equ     92              ; 文字帯の上端ライン
TXNL    equ     16              ; 文字帯の高さ (2倍角 = 16 ライン)
TXOFS   equ     TXROW*BPL       ; 文字帯のプレーン内オフセット (= 7360)
; "HIT SPACE KEY" 13文字 x 2倍角 = 26 バイト列 → 左端 (80-26)/2 = 27
HITCOL  equ     27
; "FM-7 PSG!"      9文字 x 2倍角 = 18 バイト列 → 左端 (80-18)/2 = 31
PSGCOL  equ     31

; ---- ワークエリア (サブRAM $CF90-) ----
PBASE   equ     $CF90           ; 現プレーンのベースアドレス (2バイト)
PLIDX   equ     $CF92           ; プレーンループカウンタ
TCOL    equ     $CF93           ; 文字列: 左端バイト列
TSTR    equ     $CF94           ; 文字列: ポインタ (2バイト)
OFS     equ     $CF96           ; 現在の描画アドレス (2バイト)
ROWC    equ     $CF98           ; 字形の行カウンタ (0-7)
GPTR    equ     $CF99           ; 字形先頭アドレス (2バイト)
LSEQ    equ     $CF9B           ; 最後に処理した更新カウンタ

; =============================================================================
; エントリポイント (サブモニタのコマンド $3F バイトコード $93 で呼び出される。
;   制御は返さず、以後サブCPUはこのプログラムが専有する)
; =============================================================================
ENTRY:  orcc    #$50            ; IRQ/FIRQ 禁止
        lds     #$CF80          ; 独自スタック
        lda     IO_BUSY         ; BUSY 解除 (読み出しで OFF)
        lda     IO_VRAM         ; VRAM アクセス許可
        lda     IO_CRT          ; CRT 表示 ON
        clr     SH_RDY
        clr     LSEQ
        clr     SH_RACK

        jsr     CLS             ; 全面黒
        jsr     SHOWHIT         ; "HIT SPACE KEY"
        lda     #$A5
        sta     SH_RDY          ; 初期描画完了をメインへ知らせる

; =============================================================================
; メインループ: 共有RAMのリクエストを処理する
;   メインは更新カウンタ SH_SEQ を +1 して指示を出す。サブは処理を終えて
;   から SH_RACK に同じ値を書く。メインは ack が一致するまで次のリクエスト
;   を出さない。
; =============================================================================
MAINLP: lda     IO_BUSY         ; 常時レディ通知 (BUSY OFF 維持)
        lda     SH_SEQ
        cmpa    LSEQ
        beq     MAINLP
        sta     LSEQ
        lda     SH_REQ
        cmpa    #1
        bne     MLP2
        jsr     SHOWHIT
        bra     MLPACK
MLP2:   cmpa    #2
        bne     MLPACK
        jsr     SHOWPSG
MLPACK: lda     LSEQ
        sta     SH_RACK
        bra     MAINLP

; -----------------------------------------------------------------------------
; SHOWHIT / SHOWPSG: 文字帯を消してから文字列を描く
; -----------------------------------------------------------------------------
SHOWHIT:
        bsr     ERASE
        lda     #HITCOL
        sta     TCOL
        ldx     #SHIT
        stx     TSTR
        bra     DSTR
SHOWPSG:
        bsr     ERASE
        lda     #PSGCOL
        sta     TCOL
        ldx     #SPSG
        stx     TSTR
        bra     DSTR

SHIT:   fcc     "HIT SPACE KEY"
        fcb     0
SPSG:   fcc     "FM-7 PSG!"
        fcb     0

; ---- プレーンベースアドレス (B / R / G) ----
PTBL:   fdb     $0000,$4000,$8000

; -----------------------------------------------------------------------------
; ERASE: 文字帯 (TXROW から 16 ライン、全幅) を 3 プレーンとも黒で塗る
; -----------------------------------------------------------------------------
ERASE:  ldx     #$0000+TXOFS
        bsr     ERB
        ldx     #$4000+TXOFS
        bsr     ERB
        ldx     #$8000+TXOFS
ERB:    ldy     #TXNL*BPL
        clra
ERBL:   sta     ,x+
        leay    -1,y
        bne     ERBL
        rts

; -----------------------------------------------------------------------------
; CLS: 3 プレーンを黒 (0) で塗る
; -----------------------------------------------------------------------------
CLS:    clr     PLIDX
CLSPL:  bsr     PLGET
        ldx     PBASE
        ldy     #BPL*200
        clra
CLSLP:  sta     ,x+
        leay    -1,y
        bne     CLSLP
        inc     PLIDX
        lda     PLIDX
        cmpa    #3
        bne     CLSPL
        rts

; -----------------------------------------------------------------------------
; PLGET: PLIDX 番目のプレーンのベースアドレスを PBASE へ
; -----------------------------------------------------------------------------
PLGET:  ldb     PLIDX
        aslb
        clra
        ldx     #PTBL
        ldd     d,x
        std     PBASE
        rts

; =============================================================================
; DSTR: 文字列を 2 倍角・白で描く (TCOL / TSTR)
;   上端ラインは TXROW 固定。文字帯は ERASE 済みなので上書きで良い。
;   白 = 3 プレーンすべてに同じ字形を書く。
; =============================================================================
DSTR:   clr     PLIDX
DSPL:   bsr     PLGET
        ldd     #TXOFS
        addd    PBASE
        addb    TCOL
        adca    #0
        std     OFS
        ldy     TSTR
DSCH:   lda     ,y+
        beq     DSNXP           ; NUL 終端 → 次のプレーンへ
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
        pshs    x               ; EXP2 は X を壊すので退避
        bsr     EXP2            ; D = 横 2 倍に拡大した 2 バイト
        puls    x
        std     ,x              ; 1 ライン目
        pshs    d
        tfr     x,d
        addd    #BPL
        tfr     d,x
        puls    d
        std     ,x              ; 2 ライン目 (縦 2 倍)
        pshs    d
        tfr     x,d
        addd    #BPL
        tfr     d,x
        puls    d
        inc     ROWC
        lda     ROWC
        cmpa    #8
        bne     DSROW
        ldd     OFS             ; 次の文字へ (2 バイト列進む)
        addd    #2
        std     OFS
        bra     DSCH
DSNXP:  inc     PLIDX
        lda     PLIDX
        cmpa    #3
        bne     DSPL
        rts

; -----------------------------------------------------------------------------
; EXP2: 字形 1 バイト (A) を横 2 倍に拡大して D (A=左, B=右) に返す
;   ニブル b3b2b1b0 → b3b3 b2b2 b1b1 b0b0 の表引き
; -----------------------------------------------------------------------------
EXP2:   pshs    a
        lsra
        lsra
        lsra
        lsra
        ldx     #EXP2T
        tfr     a,b
        abx
        lda     ,x              ; 左バイト = 上位ニブルの拡大
        puls    b
        pshs    a
        andb    #$0F
        ldx     #EXP2T
        abx
        ldb     ,x              ; 右バイト = 下位ニブルの拡大
        puls    a
        rts

; ---- 横拡大表: ニブル b3b2b1b0 → b3b3 b2b2 b1b1 b0b0 ----
EXP2T:  fcb     $00,$03,$0C,$0F,$30,$33,$3C,$3F
        fcb     $C0,$C3,$CC,$CF,$F0,$F3,$FC,$FF

        end
