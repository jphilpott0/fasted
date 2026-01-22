;
; cell.S - Functions for updating DP cells.
;

bits    64
default rel

global _compute_dp_matrix

%include "arch/x86_64/abi.inc"

%macro SET_ONES 1
    ; Inputs:
    ; %1 = zmm to set to all ones.

    ; Outputs:
    ; %1 = -1.

    vpternlogd      %1, %1, %1, 0xFF
%endmacro

%macro NEXT_CHAR 3
    ; Inputs:
    ; %1 = mmax * 64.
    ; %2 = target char output.
    ; %3 = [char addr].

    ; Outputs:
    ; %2 = target char output.

    movzx           %2, byte %3                         ; get next target char.
    imul            %2, %1                              ; base_addr = char * (mmax * 64).

%endmacro

%macro NEXT_CELLS 6
    ; Inputs:
    ; %1 = vp.
    ; %2 = vn.
    ; %3 = hp.
    ; %4 = hn.
    ; %5 = tmp0.
    ; %6 = [eq addr].

    ; Outputs:
    ; %1 = hn.
    ; %2 = hp.
    ; %3 = vn.
    ; %4 = vp.

    ; %5 can again be used as a tmp register in next update. overall, the
    ; register layout reverses. this layout is confusing but important. we can
    ; execute 4 bitwise AVX-512 logic uops per cycle on a Zen5 Granite Ridge
    ; core. that means this macro can execute in 1.25c. if we overload it with
    ; renames, we will bottleneck on frontend pressure and not reach backend
    ; compute bound.

    vmovdqa64       %5, %2                              ; rename tmp0 = vn.

    vpternlogd      %5, %4, %6, 0xFE                    ; d0 = eq | vn | hn.
    vpternlogd      %2, %5, %1, 0xF7                    ; hp = vn | ~(d0 & vp).
    vpternlogd      %4, %5, %3, 0xF7                    ; vp = hn | ~(d0 & hp).
    vpandd          %1, %1, %5                          ; hn = vp & d0.
    vpandd          %3, %3, %5                          ; vn = hp & d0.

%endmacro

%macro NEXT_CELLS_INIT 5
    ; Inputs:
    ; %1 = vp.
    ; %2 = vn.
    ; %3 = tmp0.
    ; %4 = tmp1.
    ; %5 = [eq addr].

    ; Outputs:
    ; %1 = hn.
    ; %2 = hp.
    ; %3 = vn.
    ; %4 = vp.

    ; special variant of NEXT_CELLS for the first column where hp = -1 and 
    ; hn = 0 by definition. this gives the simplified logic implemented below.

    vmovdqa64       %3, %2                              ; rename tmp0 = vn.

    vpord           %3, %2, %5                          ; vn = d0 = eq | vn.
    vpternlogd      %2, %2, %1, 0xF7                    ; hp = vn | ~(d0 & vp).
    vpandd          %1, %1, %3                          ; hn = vp & d0.
    vpternlogd      %4, %3, %3, 0x33                    ; vp = ~d0.

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

    cmp             rdx, 8                              ; check if small target variant needed.
    jbe             .small_target                       ; jump if so.

    xor             rcx, rcx                            ; zero target char counter.
    mov             r8, [rdi + MMAX_OFFSET]             ; load mmax.

    cmp             r8, 8                               ; check if small query variant needed.
    jbe             .small_query                        ; jump if so.

.setup:
    shl             r8, 6                               ; r8 = mmax * 64.

    mov             rbx, [rdi + SPEQ_PTR_OFFSET]        ; get speq ptr from arena.
    lea             rbx, [rdi + rbx]                    ; calculate speq base.

    vzeroall                                            ; reset all vector registers.

    ; set starting conditions for vp = -1.

    SET_ONES        zmm0
    SET_ONES        zmm6
    SET_ONES        zmm10
    SET_ONES        zmm14
    SET_ONES        zmm18
    SET_ONES        zmm22
    SET_ONES        zmm26
    SET_ONES        zmm28

    ; reserve stack.

    mov             r9, rdx                             ; r9 = target string len.
    shl             r9, 7                               ; r9 = target string len * 128 bytes.
    sub             rsp, r9                             ; reserve 128 * target_len bytes.

.block_init0:

    ;
    ; block_init - setup 8-wide anti-diagonal wavefront block.
    ;
    ; positioning below is (col, row).
    ;
    ; format is:
    ;
    ; NEXT_CHAR     r8, r10, [rsi + rcx + row].
    ; NEXT_CELLS    vp_prev, vn_prev, hp_prev, hn_prev, [r10 + rbx + 64 * col].
    ;
    ; NEXT_CELLS_INIT is used for (0, row) where hp = -1 and hn = 0 by 
    ; definition.
    ;

    ; todo: harcoding the layout may be fastest for backend, but will it 
    ; overload the frontend? will be fine in loop when uops are cached, but
    ; this startup phase might be limited by decode throughput. none of the
    ; instructions are over 10 bytes, so all 4 decoder slots will work (this
    ; doesn't use SMT so cannot use second decoder).
    ;
    ; actually this is definitely frontend bound right now. we try 7 
    ; instructions every 1.25c. that's 5.6 instructions per cycle, which
    ; the 4 decoder slots cannot do.
    ;
    ; again, will be fine in the mainloop when the uop cache is used instead,
    ; but technically slightly slower on block initialisation.

    ; cell (0, 0).

    NEXT_CHAR       r8, r10, [rsi + rcx + 0]
    NEXT_CELLS_INIT zmm0, zmm1, zmm2, zmm3, [r10 + rbx + 0]

.block_init1:

    ; cell (0, 1).

    NEXT_CHAR       r8, r10, [rsi + rcx + 1]
    NEXT_CELLS_INIT zmm3, zmm2, zmm4, zmm5, [r10 + rbx + 0]

    ; cell (1, 0).

    NEXT_CHAR       r8, r10, [rsi + rcx + 0]
    NEXT_CELLS      zmm6, zmm7, zmm1, zmm0, zmm31, [r10 + rbx + 64]

.block_init2:
    
    ; cell (0, 2).

    NEXT_CHAR       r8, r10, [rsi + rcx + 2]
    NEXT_CELLS_INIT zmm5, zmm4, zmm8, zmm9, [r10 + rbx + 0]

    ; cell (1, 1).

    NEXT_CHAR       r8, r10, [rsi + rcx + 1]
    NEXT_CELLS      zmm0, zmm1, zmm2, zmm3, zmm31, [r10 + rbx + 64]

    ; cell (2, 0).

    NEXT_CHAR       r8, r10, [rsi + rcx + 0]
    NEXT_CELLS      zmm10, zmm11, zmm7, zmm6, zmm31, [r10 + rbx + 128]

.block_init3:

    ; cell (0, 3).

    NEXT_CHAR       r8, r10, [rsi + rcx + 3]
    NEXT_CELLS_INIT zmm9, zmm8, zmm12, zmm13, [r10 + rbx + 0]

    ; cell (1, 2).

    NEXT_CHAR       r8, r10, [rsi + rcx + 2]
    NEXT_CELLS      zmm3, zmm2, zmm4, zmm5, zmm31, [r10 + rbx + 64]

    ; cell (2, 1).

    NEXT_CHAR       r8, r10, [rsi + rcx + 1]
    NEXT_CELLS      zmm6, zmm7, zmm1, zmm0, zmm31, [r10 + rbx + 128]

    ; cell (3, 0).

    NEXT_CHAR       r8, r10, [rsi + rcx + 0]
    NEXT_CELLS      zmm14, zmm15, zmm11, zmm10, zmm31, [r10 + rbx + 192]

.block_init4:

    ; cell (0, 4).

    NEXT_CHAR       r8, r10, [rsi + rcx + 4]
    NEXT_CELLS_INIT zmm13, zmm12, zmm16, zmm17, [r10 + rbx + 0]

    ; cell (1, 3).

    NEXT_CHAR       r8, r10, [rsi + rcx + 3]
    NEXT_CELLS      zmm5, zmm4, zmm8, zmm9, zmm31, [r10 + rbx + 64]

    ; cell (2, 2).

    NEXT_CHAR       r8, r10, [rsi + rcx + 2]
    NEXT_CELLS      zmm0, zmm1, zmm2, zmm3, zmm31, [r10 + rbx + 128]

    ; cell (3, 1).

    NEXT_CHAR       r8, r10, [rsi + rcx + 1]
    NEXT_CELLS      zmm10, zmm11, zmm7, zmm6, zmm31, [r10 + rbx + 192]

    ; cell (4, 0).

    NEXT_CHAR       r8, r10, [rsi + rcx + 0]
    NEXT_CELLS      zmm18, zmm19, zmm15, zmm14, zmm31, [r10 + rbx + 256]

.block_init5:

    ; cell (0, 5).

    NEXT_CHAR       r8, r10, [rsi + rcx + 5]
    NEXT_CELLS_INIT zmm17, zmm16, zmm20, zmm21, [r10 + rbx + 0]

    ; cell (1, 4).

    NEXT_CHAR       r8, r10, [rsi + rcx + 4]
    NEXT_CELLS      zmm9, zmm8, zmm12, zmm13, zmm31, [r10 + rbx + 64]

    ; cell (2, 3).

    NEXT_CHAR       r8, r10, [rsi + rcx + 3]
    NEXT_CELLS      zmm3, zmm2, zmm4, zmm5, zmm31, [r10 + rbx + 128]

    ; cell (3, 2).

    NEXT_CHAR       r8, r10, [rsi + rcx + 2]
    NEXT_CELLS      zmm6, zmm7, zmm1, zmm0, zmm31, [r10 + rbx + 192]

    ; cell (4, 1).

    NEXT_CHAR       r8, r10, [rsi + rcx + 1]
    NEXT_CELLS      zmm14, zmm15, zmm11, zmm10, zmm31, [r10 + rbx + 256]

    ; cell (5, 0).

    NEXT_CHAR       r8, r10, [rsi + rcx + 0]
    NEXT_CELLS      zmm22, zmm23, zmm19, zmm18, zmm31, [r10 + rbx + 320]

.block_init6:

    ; cell (0, 6).

    NEXT_CHAR       r8, r10, [rsi + rcx + 6]
    NEXT_CELLS_INIT zmm21, zmm20, zmm24, zmm25, [r10 + rbx + 0]

    ; cell (1, 5).

    NEXT_CHAR       r8, r10, [rsi + rcx + 5]
    NEXT_CELLS      zmm13, zmm12, zmm16, zmm17, zmm31, [r10 + rbx + 64]

    ; cell (2, 4).

    NEXT_CHAR       r8, r10, [rsi + rcx + 4]
    NEXT_CELLS      zmm5, zmm4, zmm8, zmm9, zmm31, [r10 + rbx + 128]

    ; cell (3, 3).

    NEXT_CHAR       r8, r10, [rsi + rcx + 3]
    NEXT_CELLS      zmm0, zmm1, zmm2, zmm3, zmm31, [r10 + rbx + 192]

    ; cell (4, 2).

    NEXT_CHAR       r8, r10, [rsi + rcx + 2]
    NEXT_CELLS      zmm10, zmm11, zmm7, zmm6, zmm31, [r10 + rbx + 256]

    ; cell (5, 1).

    NEXT_CHAR       r8, r10, [rsi + rcx + 1]
    NEXT_CELLS      zmm18, zmm19, zmm15, zmm14, zmm31, [r10 + rbx + 320]

    ; cell (6, 0).

    NEXT_CHAR       r8, r10, [rsi + rcx + 0]
    NEXT_CELLS      zmm26, zmm27, zmm23, zmm22, zmm31, [r10 + rbx + 384]

.block_init7:

    ; reverse order here because we need to do (7, 0) before (0, 7) to make the
    ; registers available.

    ; cell (7, 0).

    NEXT_CHAR       r8, r10, [rsi + rcx + 0]
    NEXT_CELLS      zmm28, zmm29, zmm27, zmm26, zmm31, [r10 + rbx + 448]

    vmovdqa64       [rsp + 0], zmm29                        ; push hp to stack.
    vmovdqa64       [rsp + 64], zmm28                       ; push hn to stack.

    add             rsp, 128                                ; inc stack ptr by 128 bytes.

    ; cell (6, 1).

    NEXT_CHAR       r8, r10, [rsi + rcx + 1]
    NEXT_CELLS      zmm22, zmm23, zmm27, zmm26, zmm31, [r10 + rbx + 384]

    ; cell (5, 2).

    NEXT_CHAR       r8, r10, [rsi + rcx + 2]
    NEXT_CELLS      zmm14, zmm15, zmm11, zmm10, zmm31, [r10 + rbx + 320]

    ; cell (4, 3).

    NEXT_CHAR       r8, r10, [rsi + rcx + 3]
    NEXT_CELLS      zmm6, zmm7, zmm1, zmm0, zmm31, [r10 + rbx + 256]

    ; cell (3, 4).

    NEXT_CHAR       r8, r10, [rsi + rcx + 4]
    NEXT_CELLS      zmm3, zmm2, zmm4, zmm5, zmm31, [r10 + rbx + 192]

    ; cell (2, 5).

    NEXT_CHAR       r8, r10, [rsi + rcx + 5]
    NEXT_CELLS      zmm9, zmm8, zmm12, zmm13, zmm31, [r10 + rbx + 128]

    ; cell (1, 6).

    NEXT_CHAR       r8, r10, [rsi + rcx + 6]
    NEXT_CELLS      zmm17, zmm16, zmm20, zmm21, zmm31, [r10 + rbx + 64]

    ; cell (0, 7).

    ; NEXT_CELLS_INIT clobbers zmm28 and zmm29 but we have written the relevant
    ; data to stack so don't need to keep it in registers anymore.

    NEXT_CHAR       r8, r10, [rsi + rcx + 7]
    NEXT_CELLS_INIT zmm25, zmm24, zmm28, zmm29, [r10 + rbx + 0]
    

.small_target:
    ; todo: small target string variant.
    ret

.small_query:
    ; todo: small query string variant.
    ret

.empty:
    ; todo: edit distance is simply length of each query string.
    ret
