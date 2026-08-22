; =============================================================================
; psgdata.asm — PSG 音声データを単体のバイナリにするためのラッパ
;   実体は assets/psgdata.s (wav2psg.py が生成)。
;   IPL がディスクから $1100 へ読み込む (psgvoice.asm の PSGDAT と一致)。
;
; ビルド: lwasm --6809 --format=raw -I assets -o psgdata.bin psgdata.asm
; =============================================================================

        org     $1100

        include "psgdata.s"

        end
