;
; ============================================================================
; FM-7 multi-chunk LOADM trampoline templates (6809 ASM, lwasm syntax)
;
; Companion source for d77_to_t77_chunks.py. Five variants, each shipped as
; a small .bin (48-65 B) with sentinel placeholders that the Python tool
; patches per chunk at T77 build time.
;
; Memory layout (assumed by every template):
;   CLEAR ,&H13FF leaves $1400-$7FFF free; we use $1400-$5FFF.
;     $1400-$1419   Stage 1                    (always 26 B)
;     $141A-$143x   Stage 2 source             (22 / 23 / 39 B)
;     $143x-$1FFF   zero padding
;     $2000-$5FFF   LOADM buffer               (16 KiB; the chunk lands here)
;
; Stage 1 (identical shape in every variant; only CMPX operand changes):
;   ORCC #$50        ; mask FIRQ/IRQ (BASIC IRQ handler is in the ROM overlay)
;   LDA  #$00
;   STA  $FD0F       ; write -> ROM overlay OFF; $8000-$FBFF = URA RAM
;   LDX  #$141A      ; Stage 2 source = $1400 + 26
;   LDY  #$D000      ; Stage 2 lives here (URA RAM; survives chunk overwrite)
; .l LDA ,X+ : STA ,Y+
;   CMPX #$143x      ; one past Stage 2 source — depends on Stage 2 size
;   BNE  .l
;   JMP  $D000
;
; Stage 2 forms (one of):
;   forward single move + intermediate tail   (fwd_int.bin,  S2 = 22 B)
;   reverse single move + intermediate tail   (rev_int.bin,  S2 = 22 B)
;   forward single move + last tail           (fwd_last.bin, S2 = 23 B)
;   reverse single move + last tail           (rev_last.bin, S2 = 23 B)
;   2-move relocator + last tail              (relocate2.bin, S2 = 39 B)
;
; Sentinels (Python patches each exactly once):
;   $DEAD  TARGET (single-move) or M1_DST_END (relocate2)
;          single-move fwd: patched with TARGET
;          single-move rev: patched with TARGET + $4000 (LDY = end-exclusive)
;          relocate2      : patched with TARGET1 + $4000
;   $BEEF  START (single-move last tail) or M2_SRC (relocate2)
;          single-move    : patched with the entry address
;          relocate2      : patched with the stash address
;   $CAFE  M2_DST (relocate2)        — patched with TARGET0
;   $FACE  M2_SRC_END (relocate2)    — patched with stash + $4000
;   $D00D  ENTRY (relocate2)         — patched with the entry address
; ============================================================================

STAGER_LOAD     equ     $1400
STAGE2_SRC_BASE equ     $141A           ; STAGER_LOAD + 26
BUFFER          equ     $2000
BUFFER_END      equ     $6000
STAGE2          equ     $D000
ENTRY_STACK     equ     $FBFF
ROM_PORT        equ     $FD0F

PLACEHOLDER_TGT equ     $DEAD
PLACEHOLDER_ST  equ     $BEEF
PLACEHOLDER_M2D equ     $CAFE
PLACEHOLDER_M2E equ     $FACE
PLACEHOLDER_EN  equ     $D00D


; ============================================================================
; Variant 1: trampoline_fwd_int.bin   (forward single move, intermediate)
; ============================================================================

                org     STAGER_LOAD
s1_fwd_int      orcc    #$50
                lda     #$00
                sta     ROM_PORT
                ldx     #s2_fwd_int
                ldy     #STAGE2
.l              lda     ,x+
                sta     ,y+
                cmpx    #s2_fwd_int_end
                bne     .l
                jmp     STAGE2
s2_fwd_int      ldx     #BUFFER
                ldy     #PLACEHOLDER_TGT        ; <-- TARGET (fwd)
.l              lda     ,x+
                sta     ,y+
                cmpx    #BUFFER_END
                bne     .l
                lda     ROM_PORT                ; read = ROM ON
                andcc   #$AF
                rts
s2_fwd_int_end


; ============================================================================
; Variant 2: trampoline_rev_int.bin   (reverse single move, intermediate)
; ============================================================================

                org     STAGER_LOAD
s1_rev_int      orcc    #$50
                lda     #$00
                sta     ROM_PORT
                ldx     #s2_rev_int
                ldy     #STAGE2
.l              lda     ,x+
                sta     ,y+
                cmpx    #s2_rev_int_end
                bne     .l
                jmp     STAGE2
s2_rev_int      ldx     #BUFFER_END
                ldy     #PLACEHOLDER_TGT        ; <-- TARGET + $4000 (rev)
.l              lda     ,-x
                sta     ,-y
                cmpx    #BUFFER
                bne     .l
                lda     ROM_PORT
                andcc   #$AF
                rts
s2_rev_int_end


; ============================================================================
; Variant 3: trampoline_fwd_last.bin   (forward single move, last)
; ============================================================================

                org     STAGER_LOAD
s1_fwd_last     orcc    #$50
                lda     #$00
                sta     ROM_PORT
                ldx     #s2_fwd_last
                ldy     #STAGE2
.l              lda     ,x+
                sta     ,y+
                cmpx    #s2_fwd_last_end
                bne     .l
                jmp     STAGE2
s2_fwd_last     ldx     #BUFFER
                ldy     #PLACEHOLDER_TGT        ; <-- TARGET (fwd)
.l              lda     ,x+
                sta     ,y+
                cmpx    #BUFFER_END
                bne     .l
                lds     #ENTRY_STACK
                jmp     PLACEHOLDER_ST          ; <-- START (entry)
s2_fwd_last_end


; ============================================================================
; Variant 4: trampoline_rev_last.bin   (reverse single move, last)
; ============================================================================

                org     STAGER_LOAD
s1_rev_last     orcc    #$50
                lda     #$00
                sta     ROM_PORT
                ldx     #s2_rev_last
                ldy     #STAGE2
.l              lda     ,x+
                sta     ,y+
                cmpx    #s2_rev_last_end
                bne     .l
                jmp     STAGE2
s2_rev_last     ldx     #BUFFER_END
                ldy     #PLACEHOLDER_TGT        ; <-- TARGET + $4000 (rev)
.l              lda     ,-x
                sta     ,-y
                cmpx    #BUFFER
                bne     .l
                lds     #ENTRY_STACK
                jmp     PLACEHOLDER_ST          ; <-- START (entry)
s2_rev_last_end


; ============================================================================
; Variant 5: trampoline_relocate2.bin
;   2-move relocator: M1 reverse-copy from the buffer to chunk N-1's final,
;   M2 forward-copy from the URA RAM stash to chunk 0's final. Used as the
;   FINAL pass when the entry address is so low that chunk 1's final
;   overlaps with the LOADM block range ($1400-$5FFF), forcing the
;   article's "stash first, relocate in the final pass" pattern.
; ============================================================================

                org     STAGER_LOAD
s1_relo         orcc    #$50
                lda     #$00
                sta     ROM_PORT
                ldx     #s2_relo
                ldy     #STAGE2
.l              lda     ,x+
                sta     ,y+
                cmpx    #s2_relo_end            ; Stage 2 is 39 B, so this
                bne     .l                      ;   resolves to $1441
                jmp     STAGE2

s2_relo                                         ; Move 1 (reverse): buffer -> target1
                ldx     #BUFFER_END
                ldy     #PLACEHOLDER_TGT        ; <-- M1_DST_END = TARGET1 + $4000
.m1             lda     ,-x
                sta     ,-y
                cmpx    #BUFFER
                bne     .m1
                                                ; Move 2 (forward): stash -> target0
                ldx     #PLACEHOLDER_ST         ; <-- M2_SRC = stash address
                ldy     #PLACEHOLDER_M2D        ; <-- M2_DST = TARGET0
.m2             lda     ,x+
                sta     ,y+
                cmpx    #PLACEHOLDER_M2E        ; <-- M2_SRC_END = stash + $4000
                bne     .m2
                lds     #ENTRY_STACK
                jmp     PLACEHOLDER_EN          ; <-- ENTRY (start address)
s2_relo_end

                end
