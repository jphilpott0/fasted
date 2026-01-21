;
; cell.S - Functions for updating DP cells.
;

bits    64
default rel

global _compute_dp_matrix

%include "arch/x86_64/abi.inc"

%macro UPDATE_CELLS 6
    ; Inputs:
    ; %1 = vp.
    ; %2 = vn.
    ; %3 = hp.
    ; %4 = hn.
    ; %5 = tmp0.
    ; %6 = [eq addr]

    ; Outputs:
    ; %1 = hn.
    ; %2 = hp.
    ; %3 = vn.
    ; %4 = vp.
    ;
    ; %5 can again be used as a tmp register in next update. overall, the
    ; register layout reverses. this layout is confusing but important. we can
    ; execute 4 bitwise AVX-512 logic uops per cycle on a Zen5 Granite Ridge
    ; core. that means this macro can execute in 1.25c. if we overload it with
    ; renames, we will bottleneck with frontend pressure and not reach backend
    ; compute bound.

    vmovdqa64       %5, %2                              ; rename tmp0 = vn.
    vpternlogd      %5, %4, %6, 0xFE                    ; d0 = eq | vn | hn.
    vpternlogd      %2, %5, %1, 0xF7                    ; hp = vn | ~(d0 & vp).
    vpternlogd      %4, %5, %3, 0xF7                    ; vp = hn | ~(d0 & hp).
    vpandd          %1, %1, %5                          ; hn = vp & d0.
    vpandd          %3, %3, %5                          ; vn = hp & d0.
%endmacro

;
; _compute_dp_matrix - Evaluate the full DP matrix.
;
; Calling convention (SysV):
;   rdi = ptr to arena.
;
;   rsi = ptr to target string.
;
;   rdx = target string length.
;
; Return:
;   rax = zero if successful. -1 if failed.
;
; Notes:
;   Writes output column to arena.
;
align 32
_compute_dp_matrix:
    test            rdx, rdx                            ; test if input target string is empty.
    jz              .empty                              ; jump if so.

    cmp             rdx, 8                              ; check if small variant needed.
    jbe             .small                              ; jump if so.

    ; todo: nested loops. register layout.

.small:
    ; todo: small string variant.
    ret

.empty:
    ; todo: edit distance is simply length of each query string.
    ret
