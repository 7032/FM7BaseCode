* ============================================================
* bootrom.s — 自前 512 byte ブート ROM ($FE00-$FFFF)
*
* FM-7 内蔵ブート ROM が行う「ディスクからの IPL 起動」を
* オリジナル実装で書き起こした最小ブート ROM。実機の内蔵ブート
* ROM (通常は BASIC モードの BASIC モードのブート ROM) と同じ規約で動作する:
*   1. DP / SP セットアップ
*   2. FDC を叩いて track 0 / side 0 / sector 1 (= IPL) を $0100
*      に読み込む (= BASIC モード標準。 DOS モードなら $0300)
*   3. DP=$00 にして JMP $0100 で IPL に制御を渡す
*
* 用途:
*   - 実機ブート ROM (= 著作物) を入手できない環境で
*     代わりに使う ($FE00-$FFFF にロードできるエミュレータ等)
*   - 実機の内蔵ブート ROM が壊れた / 自前ハードを起こした
*     場合の参考実装
*   実機 FM-7 / FM77AV を持っていてビルド成果物 (D77) を
*   実機ドライブで使うだけの場合は、内蔵ブート ROM (通常
*   BASIC モードのブート ROM) がディスクから起動するので本 ROM は不要。
*
* メモリ配置:
*   $FE00 : 本コード
*   $FFFE : reset vector → $FE00
* ============================================================

* ── MB8877 FDC レジスタ (DP=$FD 経由で <$18 形式) ──
FDC_CMD         equ     $18             * W: Command / R: Status
FDC_TRK         equ     $19             * Track
FDC_SEC         equ     $1A             * Sector
FDC_DATA        equ     $1B             * Data
FDC_DRVSEL      equ     $1D             * Drive / Side / Motor

ST_BUSY         equ     $01
ST_DRQ          equ     $02
CMD_READ        equ     $80             * Read Sector (single)

IPL_LOAD        equ     $0100           * BASIC モード標準 (DOS なら $0300)

                org     $FE00

start:
                orcc    #$50            * IRQ/FIRQ マスク
                lda     #$FD
                tfr     a,dp            * DP=$FD (I/O 短縮アドレス用)
                lds     #$FC7F          * SP は共有 RAM 直下

                clra
                sta     <FDC_DRVSEL     * drive 0 / side 0
                clr     <FDC_TRK        * track 0

                ldx     #IPL_LOAD       * 転送先 $0100 (BASIC モード)
                lda     #$01
                sta     <FDC_SEC        * sector 1
                lda     #CMD_READ
                sta     <FDC_CMD

wait_drq:
                lda     <FDC_CMD        * status
                bita    #ST_DRQ
                bne     got_byte
                bita    #ST_BUSY
                bne     wait_drq
                bra     done            * idle → 終了

got_byte:
                lda     <FDC_DATA
                sta     ,x+
                bra     wait_drq

done:
                clra
                tfr     a,dp            * IPL 入口は DP=$00 (実機ブート ROM 準拠)
                jmp     IPL_LOAD

* 512 byte への padding と $FFFE 配置の reset vector は
* tools/pad_bootrom.py が後段で行う (lwasm --raw は `org $FFFE`
* で自動 pad しないため)

                end     start
