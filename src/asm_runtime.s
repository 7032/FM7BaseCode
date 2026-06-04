* ============================================================
* runtime.s — CMOC が暗黙参照する runtime helper
*
* CMOC は 16-bit 乗算等を内部で `LBSR MUL16` のように呼ぶ。
* libcmoc を使わない本テンプレートでは自前で実装する必要が
* あるので、ここに最小実装を置く。
* ============================================================

                section code
                export  MUL16

* ============================================================
* MUL16 — unsigned 16x16 → 16 multiply
*   In  : X = a (16-bit), D = b (16-bit)
*   Out : D = (a * b) & $FFFF
*   Trash: A, B, X (X is clobbered)
*
* 16-bit 乗算は 6809 の MUL (8x8→16) を 4 回組み合わせて作る:
*   a = a_hi*256 + a_lo
*   b = b_hi*256 + b_lo
*   a*b = a_lo*b_lo + ( (a_hi*b_lo + a_lo*b_hi) << 8 ) (低 16 bit)
*       a_hi*b_hi の項は >>16 で消えるので無視
* ============================================================
MUL16:
                pshs    x,d             * stack: 0=A=b_hi 1=B=b_lo 2=X_hi=a_hi 3=X_lo=a_lo
                lda     3,s             * A = a_lo
                ldb     1,s             * B = b_lo
                mul                     * D = a_lo * b_lo  (= 完全な低部分積)
                pshs    d               * stack: 0=plo_hi 1=plo_lo 2=b_hi 3=b_lo 4=a_hi 5=a_lo
                lda     4,s             * A = a_hi
                ldb     3,s             * B = b_lo
                mul                     * D = a_hi * b_lo (低 8 bit のみ高位に寄与)
                addb    0,s             * B += plo_hi
                stb     0,s             * 高位累積を更新
                lda     5,s             * A = a_lo
                ldb     2,s             * B = b_hi
                mul                     * D = a_lo * b_hi (低 8 bit のみ高位に寄与)
                addb    0,s
                stb     0,s
                puls    d               * D = (plo_hi, plo_lo) = (result_hi, result_lo)
                leas    4,s             * 退避した X, D を捨てる
                rts

                end
