;
; len.S - Operations for processing the lengths of strings in fasted.
;

bits    64
default rel

global  _len_calculate_mmax

%macro ZERO_MMAX_ACC 1
    ; %1 = number of accumulators to use.
    %assign i   0

    %rep %1
        vpxorq      zmm%+i, zmm%+i                      ; zero accumulator i.
        %assign i   (i+1)
    %endrep
%endmacro

%macro MAX_FATPTR 4
    ; %1 = register containing ptr to start of array.
    ; %2 = register containing start of next block in array.
    ; %3 = number of accumulators there are.
    ; %4 = stride.
    %assign i   0
    %assign off 0

    %rep %3
        vpmaxuq     zmm%+i, zmm%+i, [%1 + %2 + off]     ; max(acc_i, fatptr_i).

        %assign i   (i+1)
        %assign off (off+%4)
    %endrep
%endmacro

section .text

; 
; _len_calculate_mmax - Calculates the length of the longest given string.
;
; Calling convention (SysV):
;
;   rdi = ptr to input array of fat pointers to strings. each fat pointer is a
;         qword ptr (char*) immediately followed by a qword length (uint64_t).
;
;   rsi = number of fat pointers passed in array.
;
; Return:
;   rax = 64-bit integer containing mmax.
;
align 32
_len_calculate_mmax:
    ZERO_MMAX_ACC   4                                   ; zero 4x mmax accumulators.
    xor             rax, rax                            ; zero scalar acc.
    xor             rcx, rcx                            ; zero loop counter.

    cmp             rsi, 16                             ; check if 16 or more fat ptrs to process.
    jae             .loop_big                           ; go to big loop if so.

    cmp             rsi, 0                              ; check if no strings.
    jz              .empty                              ; skip to degenerate case.

    ; fallthrough to small loop instead of big loop 
    ; because a mispredict in jcc above is better 
    ; amortised by the big loop than the small loop.

.loop_small:
    mov             rdx, qword [rdi + rcx + 8]          ; get next len.

    cmp             rdx, rax                            ; compare current len to max.
    cmova           rax, rdx                            ; acc = current len if bigger.

    add             rcx, 16                             ; inc 16 B to current count.
    dec             rsi                                 ; dec fat ptr count.
    jnz             .loop_small                         ; loop if remaining count not zero.

    jmp             .reduce                             ; once finish go to reduction.

.loop_big:
    MAX_FATPTR      rdi, rcx, 4, 64                     ; 4x unroll of max(acc_i, load(fatptr_i)).
    add             rcx, 256                            ; inc 256 B to current count (4x64B).
    sub             rsi, 16                             ; dec fat ptr count by 16.

    cmp             rsi, 16                             ; check if 16 or more fat ptrs left.
    jae             .loop_big                           ; loop if so.

    cmp             rsi, 0                              ; check if finished.
    jz              .reduce                             ; go to reduction if done.

    jmp             .loop_small                         ; go to small loop to finish up tail.

.reduce:
    vpmaxuq         zmm0, zmm0, zmm1                    ; reduce acc 0 and 1.
    vpmaxuq         zmm2, zmm2, zmm3                    ; reduce acc 2 and 3.

    vpmaxuq         zmm0, zmm0, zmm2                    ; reduce acc [0,1] and [2,3].

    vextracti64x4   ymm1, zmm0, 1                       ; upper lanes into ymm1. (lower in ymm0).
    vpunpckhqdq     ymm0, ymm0, ymm1                    ; unpack just lengths from ptrs + lengths.
    vperm2i128      ymm1, ymm0, ymm0, 1                 ; shuffle [a, b, c, d] to [c, d, a, b].

    vpmaxuq         ymm0, ymm0, ymm1                    ; [max(a,c), max(b,d), max(c,a), max(d,b)].
    vpshufd         xmm1, xmm0, 0x4E                    ; shuffle to [max(b,d), max(a,c)].
    vpmaxuq         xmm0, xmm0, xmm1                    ; [max(a,b,c,d), max(a,b,c,d)].

    movq            rdx, xmm0                           ; move mmax into rdx.

    cmp             rdx, rax                            ; compare max vector to max scalar.
    cmova           rax, rdx                            ; rax = max vector if bigger.

    ret

.empty:
    ret                                                 ; rax is already 0.
