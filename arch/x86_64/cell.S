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

%macro ASSIGN_CELLS 5
    ; Inputs:
    ; %1 = cell index.
    ; %2 = vp.
    ; %3 = vn.
    ; %4 = hp.
    ; %5 = hn.

    %assign %1_vp %2
    %assign %1_vn %3
    %assign %1_hp %4
    %assign %1_hn %5
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
    SET_ONES        zmm4
    SET_ONES        zmm8
    SET_ONES        zmm12
    SET_ONES        zmm16
    SET_ONES        zmm20
    SET_ONES        zmm24
    SET_ONES        zmm28

    ; reserve stack.

    mov             r9, rdx                             ; r9 = target string len.
    shl             r9, 7                               ; r9 = target string len * 128 bytes.
    sub             rsp, r9                             ; reserve 128 * target_len bytes.

.first_block_init0:

    ;
    ; first_block_init - setup 8-wide anti-diagonal wavefront in first column.
    ;
    ; positioning below is (col, row).
    ;
    ; format is:
    ;
    ; NEXT_CHAR     r8, rax, [rsi + rcx + row].
    ; NEXT_CELLS    vp_prev, vn_prev, hp_prev, hn_prev, [rax + rbx + 64 * col].
    ;
    ; NEXT_CELLS_INIT is used for (0, row) where hp = -1 and hn = 0 by 
    ; definition.
    ;
    ; register layout:
    ;
    ; vp: zmm{0, 4, 8, 12, 16, 20, 24, 28}.
    ; vn: zmm{1, 5, 9, 13, 17, 21, 25, 29}.
    ; hp: zmm{2, 6, 10, 14, 18, 22, 26, 29}.
    ; hn: zmm{3, 7, 11, 15, 19, 23, 27, 28}.
    ;
    ; we need to hold 8 live vp and vn values, hence why each gets 8 registers.
    ; but hp and hn are different since once we write a block's hp and hn to
    ; the stack, we can use those registers again, hence we only need 7 unique
    ; ones for hp and hn.
    ;
    ; note that NEXT_CELLS(_INIT) flips the register order. another NEXT_CELLS
    ; will unflip the order.
    ;
    ; note: harcoding the layout may be fastest for backend, but will it 
    ; overload the frontend? will be fine in loop when uops are cached, but
    ; this startup phase might be limited by decode throughput. none of the
    ; instructions are over 10 bytes, so all 4 decoder slots will work (this
    ; doesn't use SMT so cannot use second decoder).
    ;
    ; actually this is definitely frontend bound right now. we try 8 
    ; instructions every 1.25c. that's 6.4 instructions per cycle, which
    ; the 4 decoder slots cannot do.
    ;
    ; again, will be fine in the mainloop when the uop cache is used instead,
    ; but technically slightly slower on block initialisation.
    ;
    ; possible algorithm for doing this as macro: cell (x, y) has same layout
    ; as (x-1, y-1), and (i, 0) and (0, j) have calculable layouts. so either
    ; can do this recursively (in a nasm macro though?) or maybe this has closed
    ; form solution. check later.
    ;

    ; cell (0, 0).

    NEXT_CHAR       r8, rax, [rsi + 0]
    NEXT_CELLS_INIT zmm0, zmm1, zmm2, zmm3, [rax + rbx + 0]

.first_block_init1:

    ; cell (1, 0).

    NEXT_CHAR       r8, rax, [rsi + 0]
    NEXT_CELLS      zmm4, zmm5, zmm1, zmm0, zmm31, [rax + rbx + 64]

    ; cell (0, 1).

    NEXT_CHAR       r8, rax, [rsi + 1]
    NEXT_CELLS_INIT zmm3, zmm2, zmm6, zmm7, [rax + rbx + 0]

.first_block_init2:

    ; cell (2, 0).

    NEXT_CHAR       r8, rax, [rsi + 0]
    NEXT_CELLS      zmm8, zmm9, zmm5, zmm4, zmm31, [rax + rbx + 128]

    ; cell (1, 1).

    NEXT_CHAR       r8, rax, [rsi + 1]
    NEXT_CELLS      zmm0, zmm1, zmm2, zmm3, zmm31, [rax + rbx + 64]

    ; cell (0, 2).

    NEXT_CHAR       r8, rax, [rsi + 2]
    NEXT_CELLS_INIT zmm7, zmm6, zmm10, zmm11, [rax + rbx + 0]

.first_block_init3:

    ; cell (3, 0).

    NEXT_CHAR       r8, rax, [rsi + 0]
    NEXT_CELLS      zmm12, zmm13, zmm9, zmm8, zmm31, [rax + rbx + 192]

    ; cell (2, 1).

    NEXT_CHAR       r8, rax, [rsi + 1]
    NEXT_CELLS      zmm4, zmm5, zmm1, zmm0, zmm31, [rax + rbx + 128]

    ; cell (1, 2).

    NEXT_CHAR       r8, rax, [rsi + 2]
    NEXT_CELLS      zmm3, zmm2, zmm6, zmm7, zmm31, [rax + rbx + 64]

    ; cell (0, 3).

    NEXT_CHAR       r8, rax, [rsi + 3]
    NEXT_CELLS_INIT zmm11, zmm10, zmm14, zmm15, [rax + rbx + 0]

.first_block_init4:

    ; cell (4, 0).

    NEXT_CHAR       r8, rax, [rsi + 0]
    NEXT_CELLS      zmm16, zmm17, zmm13, zmm12, zmm31, [rax + rbx + 256]

    ; cell (3, 1).

    NEXT_CHAR       r8, rax, [rsi + 1]
    NEXT_CELLS      zmm8, zmm9, zmm5, zmm4, zmm31, [rax + rbx + 192]

    ; cell (2, 2).

    NEXT_CHAR       r8, rax, [rsi + 2]
    NEXT_CELLS      zmm0, zmm1, zmm2, zmm3, zmm31, [rax + rbx + 128]

    ; cell (1, 3).

    NEXT_CHAR       r8, rax, [rsi + 3]
    NEXT_CELLS      zmm7, zmm6, zmm10, zmm11, zmm31, [rax + rbx + 64]

    ; cell (0, 4).

    NEXT_CHAR       r8, rax, [rsi + 4]
    NEXT_CELLS_INIT zmm15, zmm14, zmm18, zmm19, [rax + rbx + 0]

.first_block_init5:

    ; cell (5, 0).

    NEXT_CHAR       r8, rax, [rsi + 0]
    NEXT_CELLS      zmm20, zmm21, zmm17, zmm16, zmm31, [rax + rbx + 320]

    ; cell (4, 1).

    NEXT_CHAR       r8, rax, [rsi + 1]
    NEXT_CELLS      zmm12, zmm13, zmm9, zmm8, zmm31, [rax + rbx + 256]

    ; cell (3, 2).

    NEXT_CHAR       r8, rax, [rsi + 2]
    NEXT_CELLS      zmm4, zmm5, zmm1, zmm0, zmm31, [rax + rbx + 192]

    ; cell (2, 3).

    NEXT_CHAR       r8, rax, [rsi + 3]
    NEXT_CELLS      zmm3, zmm2, zmm6, zmm7, zmm31, [rax + rbx + 128]

    ; cell (1, 4).

    NEXT_CHAR       r8, rax, [rsi + 4]
    NEXT_CELLS      zmm11, zmm10, zmm14, zmm15, zmm31, [rax + rbx + 64]

    ; cell (0, 5).

    NEXT_CHAR       r8, rax, [rsi + 5]
    NEXT_CELLS_INIT zmm19, zmm18, zmm22, zmm23, [rax + rbx + 0]

.first_block_init6:

    ; cell (6, 0).

    NEXT_CHAR       r8, rax, [rsi + 0]
    NEXT_CELLS      zmm24, zmm25, zmm21, zmm20, zmm31, [rax + rbx + 384]

    ; cell (5, 1).

    NEXT_CHAR       r8, rax, [rsi + 1]
    NEXT_CELLS      zmm16, zmm17, zmm13, zmm12, zmm31, [rax + rbx + 320]

    ; cell (4, 2).

    NEXT_CHAR       r8, rax, [rsi + 2]
    NEXT_CELLS      zmm8, zmm9, zmm5, zmm4, zmm31, [rax + rbx + 256]

    ; cell (3, 3).

    NEXT_CHAR       r8, rax, [rsi + 3]
    NEXT_CELLS      zmm0, zmm1, zmm2, zmm3, zmm31, [rax + rbx + 192]

    ; cell (2, 4).

    NEXT_CHAR       r8, rax, [rsi + 4]
    NEXT_CELLS      zmm7, zmm6, zmm10, zmm11, zmm31, [rax + rbx + 128]

    ; cell (1, 5).

    NEXT_CHAR       r8, rax, [rsi + 5]
    NEXT_CELLS      zmm15, zmm14, zmm18, zmm19, zmm31, [rax + rbx + 64]

    ; cell (0, 6).

    NEXT_CHAR       r8, rax, [rsi + 6]
    NEXT_CELLS_INIT zmm23, zmm22, zmm26, zmm27, [rax + rbx + 0]

.first_block_init7:

    ; cell (7, 0).

    NEXT_CHAR       r8, rax, [rsi + 0]
    NEXT_CELLS      zmm28, zmm29, zmm25, zmm24, zmm31, [rax + rbx + 448]

    vmovdqa64       [rsp], zmm29                        ; push block overflow hp to stack.
    vmovdqa64       [rsp + 64], zmm28                   ; push block overflow hn to stack.

    add             rsp, 128                            ; inc stack ptr by 128 bytes.

    ; cell (6, 1).

    NEXT_CHAR       r8, rax, [rsi + 1]
    NEXT_CELLS      zmm20, zmm21, zmm17, zmm16, zmm31, [rax + rbx + 384]

    ; cell (5, 2).

    NEXT_CHAR       r8, rax, [rsi + 2]
    NEXT_CELLS      zmm12, zmm13, zmm9, zmm8, zmm31, [rax + rbx + 320]

    ; cell (4, 3).

    NEXT_CHAR       r8, rax, [rsi + 3]
    NEXT_CELLS      zmm4, zmm5, zmm1, zmm0, zmm31, [rax + rbx + 256]

    ; cell (3, 4).

    NEXT_CHAR       r8, rax, [rsi + 4]
    NEXT_CELLS      zmm3, zmm2, zmm6, zmm7, zmm31, [rax + rbx + 192]

    ; cell (2, 5).

    NEXT_CHAR       r8, rax, [rsi + 5]
    NEXT_CELLS      zmm11, zmm10, zmm14, zmm15, zmm31, [rax + rbx + 128]

    ; cell (1, 6).

    NEXT_CHAR       r8, rax, [rsi + 6]
    NEXT_CELLS      zmm19, zmm18, zmm22, zmm23, zmm31, [rax + rbx + 64]
    
    ; cell (0, 7).

    ; NEXT_CELLS_INIT clobbers zmm28 and zmm29 but we have written the relevant
    ; data to stack so don't need to keep it in registers anymore.

    NEXT_CHAR       r8, rax, [rsi + 7]
    NEXT_CELLS_INIT zmm27, zmm26, zmm29, zmm28, [rax + rbx + 0]

    mov             rcx, 9                              ; target char counter = 9.

    cmp             rcx, rdx                            ; check if more chars.
    je              .first_block_changeover             ; skip to changeover if finished.

.first_block_main:

    ;
    ; first_block_main - advance the wavefront.
    ;
    ; we need 16 manually unrolled iterations of the loop in order to return
    ; to the original register layout, at which point we can loop as normal.
    ;

    ; define starting register layout. the register layout has been 
    ; manually fixed.

    %assign         _tmp0    30
    %assign         _tmp1    31

    ; setup preprocessor variables with register layout.
    ASSIGN_CELLS    cell7, 24, 25, 29, 28
    ASSIGN_CELLS    cell6, 16, 17, 21, 20
    ASSIGN_CELLS    cell5,  8,  9, 13, 12
    ASSIGN_CELLS    cell4,  0,  1,  5,  4
    ASSIGN_CELLS    cell3,  7,  6,  2,  3
    ASSIGN_CELLS    cell2, 15, 14, 10, 11
    ASSIGN_CELLS    cell1, 23, 22, 18, 19
    ASSIGN_CELLS    cell0, 28, 29, 26, 27

    ; query addr shorthand.
    %define         addr     rax + rbx + (j * 64)

    ; compute 16 iterations of the mainloop.
    %assign i 0
    %rep 16
        ; compute each of the 8 cells per outer iteration.
        %assign j 7
        %rep 8
            ; define useless label just so that macro expansion is more legible.
            .first_block_main_iter%[i]_cell%[j]:

                ; shorthand for accessing the current zmm registers.
                %xdefine zcell_vp zmm%[cell%[j]_vp]
                %xdefine zcell_vn zmm%[cell%[j]_vn]
                %xdefine zcell_hp zmm%[cell%[j]_hp]
                %xdefine zcell_hn zmm%[cell%[j]_hn]
                %xdefine ztmp0    zmm%[_tmp0]
                %xdefine ztmp1    zmm%[_tmp1]

                ; get next target char for this cell.
                NEXT_CHAR r8, rax, [rsi + rcx - (j+1)]

                ; update cells.
                %if j = 0
                    ; cycle unneeded hp/hn registers from cell 7.
                    %assign cell0_hp cell7_hp
                    %assign cell0_hn cell7_hn
                    NEXT_CELLS_INIT zcell_vp, zcell_vn, zcell_hp, zcell_hn, [addr]
                %else
                    ; use hp and hn from cell j-1.
                    %assign prev (j-1)
                    %assign cell%[j]_hp cell%[prev]_hp
                    %assign cell%[j]_hn cell%[prev]_hn
                    NEXT_CELLS zcell_vp, zcell_vn, zcell_hp, zcell_hn, ztmp0, [addr]
                %endif

                ; fix the broken register layout. only in the preprocessor's 
                ; variables, the actual registers are still swapped weirdly.
                ; this just allows simpler macro programming.
                %assign __tmp0      cell%[j]_vp
                %assign __tmp1      cell%[j]_hp
                %assign cell%[j]_vp cell%[j]_hn
                %assign cell%[j]_hn __tmp0
                %assign cell%[j]_hp cell%[j]_vn
                %assign cell%[j]_vn __tmp1

                ; if last cell of block, spill hp/hn to stack.
                %if j = 7
                    vmovdqa64   [rsp],      zcell_hp
                    vmovdqa64   [rsp + 64], zcell_hn
                    add         rsp, 128
                %endif

                ; don't cause underflow.
                %ifn j = 0
                    %assign j (j-1)
                %endif
        %endrep
        %assign i (i+1)

        inc     rcx
        cmp     rcx, rdx
        je      .first_block_changeover
    %endrep

.first_block_changeover:
    ; todo: write changeover.

.small_target:
    ; todo: small target string variant.
    ret

.small_query:
    ; todo: small query string variant.
    ret

.empty:
    ; todo: edit distance is simply length of each query string when empty.
    ret
