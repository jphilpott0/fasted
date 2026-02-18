;
; cell.S - Functions for updating DP cells.
;

bits    64
default rel

global _compute_dp_matrix

%include "arch/x86_64/abi.inc"

%ifndef DEBUG
    %define DEBUG 0
%endif

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
    ; todo: push anything callee-saved!

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

    ; reserve stack.

    mov             r9, rdx                             ; r9 = target string len.
    shl             r9, 7                               ; r9 = target string len * 128 bytes.
    sub             rsp, r9                             ; reserve 128 * target_len bytes.
    mov             r9, rsp                             ; r9 = original stack ptr.

.first_block_init:

    ;
    ; first_block_init - setup 8-wide anti-diagonal wavefront in first column.
    ;
    ; positioning below is (col, row).
    ;
    ; register layout:
    ;
    ; vp: zmm{0, 4, 8, 12, 16, 20, 24, 28}.
    ; vn: zmm{1, 5, 9, 13, 17, 21, 25, 29}.
    ; hp: zmm{2, 6, 10, 14, 18, 22, 26, -}.
    ; hn: zmm{3, 7, 11, 15, 19, 23, 27, -}.
    ;
    ; hp/hn of cell7 use a different layout.
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
    ; see expanded macros: 
    ; ```nasm -DDEBUG=1 -E arch/x86_64/cell.S | grep -v "%line" | cat -s```
    ;

    ; set all vp = -1 and all vn = 0.
    %assign i 0
    %rep 8
        %assign     j (i*4)
        %assign     k (j+1)

        vpternlogd  zmm%+j, zmm%+j, zmm%+j, 0xFF
        vpxord      zmm%+k, zmm%+k, zmm%+k

        %assign     i (i+1)
    %endrep

    ; setup register layout.
    %assign         _tmp0  30
    %assign         _tmp1  31

    ASSIGN_CELLS    cell0,  0,  1,  2,  3
    ASSIGN_CELLS    cell1,  4,  5,  6,  7
    ASSIGN_CELLS    cell2,  8,  9, 10, 11
    ASSIGN_CELLS    cell3, 12, 13, 14, 15
    ASSIGN_CELLS    cell4, 16, 17, 18, 19
    ASSIGN_CELLS    cell5, 20, 21, 22, 23
    ASSIGN_CELLS    cell6, 24, 25, 26, 27
    ASSIGN_CELLS    cell7, 28, 29, 30, 31

    ; basic aliases.
    %define         addr   rax + rbx + (j * 64)

    %xdefine        ztmp0  zmm%[_tmp0]
    %xdefine        ztmp1  zmm%[_tmp1]

    ; perform 8 manual iterations to setup first wavefront.
    %assign i 0
    %rep 8
        ; on iteration `i` we have opened `i+1` cells. so we update `i+1` cells.
        %assign j i
        %rep (i+1)
            %assign prev (j-1)
            %assign k (j*64)

            %if DEBUG
                ; dummy label to help interpret expanded macro.
                first_block_init_iter%[i]_cell%[j]:
            %endif

            ; shorthand for accessing the current zmm registers.
            %xdefine zcell_vp zmm%[cell%[j]_vp]
            %xdefine zcell_vn zmm%[cell%[j]_vn]
            %xdefine zcell_hp zmm%[cell%[j]_hp]
            %xdefine zcell_hn zmm%[cell%[j]_hn]

            ; get next char.
            movzx               rax, byte [rsi + i - j]                     ; get next target char.
            imul                rax, r8                                     ; char * (mmax * 64).

            ; update cell 7.
            %if j = 7
                ; special order here requiring less unique registers.
                ; ends with vp/vn in non-broken layout.

                vmovdqa64       zcell_hn, zmm%[cell6_hn]                    ; pull in hn.
                vmovdqa64       ztmp1, zcell_vn                             ; rename tmp1 = vn.

                vpternlogd      ztmp1, zcell_hn, [rax + rbx + k], 0xFE      ; d0 = eq | vn | hn.
                vpternlogd      zcell_vn, ztmp1, zcell_vp, 0xF7             ; hp = vn | ~(d0 & vp).
                vpandd          zcell_vp, zcell_vp, ztmp1                   ; hn = vp & d0.

                vmovdqa64       [rsp], zcell_vn                             ; spill hp (swapped).
                vmovdqa64       [rsp + 64], zcell_vp                        ; spill hn (swapped).
                vmovdqa64       zcell_vn, zmm%[cell6_hp]                    ; vn = prev hp.
                vmovdqa64       zcell_vp, zcell_hn                          ; rename vp = hn.

                vpternlogd      zcell_vp, ztmp1, zcell_vn, 0xF7             ; vp = hn | ~(d0 & hp).
                vpandd          zcell_vn, zcell_vn, ztmp1                   ; vn = hp & d0.
                add             rsp, 128                                    ; inc stack ptr.
            %endif
            
            ; update cells 1-6.
            %ifn (j = 0 || j = 7)
                vmovdqa64       zcell_hp, zmm%[cell%[prev]_hp]              ; pull in hp
                vmovdqa64       zcell_hn, zmm%[cell%[prev]_hn]              ; pull in hn.
                vmovdqa64       ztmp0, zcell_vn                             ; rename tmp0 = vn.

                vpternlogd      ztmp0, zcell_vn, [rax + rbx + k], 0xFE      ; d0 = eq | vn | hn.
                vpternlogd      zcell_vn, ztmp0, zcell_vp, 0xF7             ; hp = vn | ~(d0 & vp).
                vpternlogd      zcell_hn, ztmp0, zcell_hp, 0xF7             ; vp = hn | ~(d0 & hp).
                vpandd          zcell_vp, zcell_vp, ztmp0                   ; hn = vp & d0.
                vpandd          zcell_vn, zcell_vn, ztmp0                   ; vn = hp & d0.
            ; update cell 0.
            %elif j = 0
                vmovdqa64       ztmp0, zcell_vn                             ; rename tmp0 = vn.

                vpord           zcell_hp, zcell_vn, [rax + rbx + k]         ; vn = d0 = eq | vn.
                vpternlogd      zcell_hn, zcell_hp, zcell_hp, 0x33          ; vp = ~d0.
                vpternlogd      zcell_vn, zcell_vn, zcell_vn, 0xFF          ; hp = -1 by definition.
                vpxord          zcell_vp, zcell_vp, zcell_vp                ; hn = 0 by definition.
            %endif

            ; fix register layout in preprocesser variables.
            %ifn j = 7
                %assign __tmp0      cell%[j]_vp
                %assign __tmp1      cell%[j]_hp
                %assign cell%[j]_vp cell%[j]_hn
                %assign cell%[j]_hn __tmp0
                %assign cell%[j]_hp cell%[j]_vn
                %assign cell%[j]_vn __tmp1
            %endif

            %assign j (j-1) 
        %endrep
        %assign i (i+1)
    %endrep


; these are special cases that will be implmeneted later. just want
; a working general case first.

.small_target:
    ; todo: small target string variant.
    ret

.small_query:
    ; todo: small query string variant.
    ret

.empty:
    ; todo: edit distance is simply length of each query string when empty.
    ret
