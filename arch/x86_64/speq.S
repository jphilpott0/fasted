;
; speq.S - Functions for constructing the speq data structure.
;

bits    64
default rel

global _new_speq

%include "arch/x86_64/abi.inc"

;
; _new_speq - Build a new speq in the provided arena.
;
; Calling convention (SysV):
;   rdi = ptr to arena to build in.
;
;   rsi = ptr to input array of fat pointers to strings. each fat pointer is a
;         qword ptr (char*) immediately followed by a qword length (uint64_t).
;
;   rdx = number of fat pointers passed in array.
;
; Return:
;   rax = zero if successful. -1 if failed because string array was empty.
;
align 32
_new_speq:
    test            rdx, rdx                            ; check if input is empty.
    jz              .empty                              ; jump if so.

    push            rbx                                 ; save rbx.
    push            rbp                                 ; save rbp.
    push            r12                                 ; save r12.
    push            r13                                 ; save r13.
    push            r14                                 ; save r14.
    push            r15                                 ; save r15.

    mov             r8,  [rdi + MMAX_OFFSET]            ; r8 = mmax.
    mov             r10, [rdi + SPEQ_PTR_OFFSET]        ; r10 = speq ptr.
    mov             [rdi + BATCH_SIZE_OFFSET], rdx      ; set arena batch size value.
    mov             r15, rdi                            ; save arena ptr to r15.

    lea             r10, [r15 + r10]                    ; calculate actual speq base addr.
    mov             r11, rsi                            ; rename r11 = rsi.
    shl             r8, 6                               ; r8 = mmax * 64.

    xor             r13, r13                            ; zero byte counter.
    mov             r14, rdx                            ; r14 = string count.
    shl             r14, 4                              ; r14 = string count -> total byte count.
    xor             rdx, rdx                            ; zero string counter.

.loop_outer_head:
    mov             rdi, [r11 + r13]                    ; load ptr to next str.
    mov             rsi, [r11 + r13 + 8]                ; load len of next str.

    mov             rcx, rdx                            ; rename rcx = string_counter.
    and             rcx, 0x07                           ; bit_offset = string_counter % 8.

    mov             r12, 0x80                           ; r12 = 0x80.
    shr             r12, cl                             ; rmwmask (r12) = 0x80 >> bit_offset.

    mov             r9, rsi                             ; r9 = chars left.
    shl             r9, 6                               ; r9 = pos offset.

    mov             rbx, rdx                            ; rename rbx = string_counter.
    shr             rbx, 3                              ; byte_offset = string_counter // 8.
    lea             rbx, [r10 + rbx]                    ; combine speq ptr + byte_offset.
    lea             rbx, [rbx + r9 - 64]                ; add pos_offset.


    mov byte [r15 + STORE_MASK_OFFSET + rsi], 0x80      ; mark this length in the storemask.

    test            rsi, rsi                            ; check if empty str.
    jz              .loop_outer_tail                    ; skip inner loop if so.

    ; defo try to scrape back some registers and 2x 
    ; unroll this. extra guaranteed mispredict will
    ; be worth it for 2x throughput.

.loop_inner:
    movzx           rbp, byte [rdi + rsi - 1]           ; get next char.

    mov byte [r15 + ALPHABET_MASK_OFFSET + rbp], 0x80   ; mark this char in alphabetmask.

    imul            rbp, r8                             ; base_addr = char * (mmax * 64).

    ;
    ; check: is this addr off-by-one?
    ;

    mov             rax, r12                            ; rename rax = rmwmask.
    or              al, byte [rbp + rbx]                ; load required byte, OR single bit in.
    mov             byte [rbp + rbx], al                ; write back.

    sub             rbx, 64                             ; offset by 64 bytes.
    dec             rsi                                 ; dec number of chars left.
    jnz             .loop_inner                         ; loop if chars left.

.loop_outer_tail:
    add             r13, 16                             ; add 16 bytes to byte counter.
    inc             rdx                                 ; inc string counter.

    cmp             r13, r14                            ; check if reached end.
    jne             .loop_outer_head                    ; loop if not.

.blockmap:
    mov             r9,  [r15 + BLOCKMAP_PTR_OFFSET]    ; r9 = blockmap ptr.
    lea             r9,  [r15 + r9]                     ; calculate actual blockmap base addr.

    shr             r8, 6                               ; r8 = (mmax * 64) >> 6.
    inc             r8                                  ; r8 = mmax + 1.
    xor             rbx, rbx                            ; zero counter.
    lea             rdi, [r15 + STORE_MASK_OFFSET]      ; calculate store mask ptr.

    ; could vectorise this later, but small string 
    ; perf may suffer from extra mispredict.

.blockmap_loop:
    mov             rcx, rbx                            ; copy rcx = rbx.
    and             rcx, 0x07                           ; rcx = rbx % 8.

    mov             al, byte [rdi + rbx]                ; rax = either 0x00 or 0x80.

    shr             rax, cl                             ; rax >>= rcx.
    mov             rsi, rbx                            ; copy rsi = rbx.
    shr             rsi, 3                              ; rsi = rbx // 8.

    or              al, byte [r9 + rsi]                 ; OR bit into bitmask.
    mov             byte [r9 + rsi], al                 ; write back.
    inc             rbx                                 ; inc counter.

    cmp             rbx, r8                             ; see if finished.
    jne             .blockmap_loop                      ; loop if not.
    
.done:
    pop             r15                                 ; restore callee-saved registers.
    pop             r14
    pop             r13
    pop             r12
    pop             rbp
    pop             rbx

    mov             rax, 0                              ; set return code.
    ret

.empty:
    mov             rax, -1                             ; set error code.
    ret


; 
; Notes on bitmask generation:
;
; could avoid rmw pattern by doing fire-and-forget style byte stores and then
; using vpmovb2m + kmov or something to condense into bitmask. but this adds 8x
; the page faults and if speq spills out of L2 then we're attempting 144
; bytes/cycle/core from L3/DRAM which is awful. could be best to include both
; methods and route depending on mmax and number of speq re-uses expected. 
;
; actually, can this better. instead of this, start with our strings, and place
; the first, say, eight chars into a 4 KiB reusable scratch space. this is only
; a single page fault. and also small enough to reside entirely in L1 and skip
; shared L3/DRAM bandwidth issues. iterate over first eight chars of each string
; and write back in AoSoA layout with much simpler, entirely AGU-based,
; addressing. we can do this at 2 chars/cycle. we also need to maintain an
; alphabet bitmask. we can't seem to do this at 2 chars/cycle with a 256-bit
; mask (fastest way i can think for two chars is 2 shuffle + 2 shift + 1
; vpternlog, but that's 5 uops per cycle on average, which even zen4/5 can't
; do). so we'd need to decide to limit alphabet_size to 128, not 256 and use
; 2x pslldq + 1x vpternlog with xmms (3 uops per cycle on average, works for 
; even pre-lion cove intel and totally fine for zen4/5). does require AVX512VL
; for vpternlog though. having 128 different chars to work with is enough. if
; it weren't then chances are you need so many more that even 256 wouldn't be
; enough. the only case is when you wanted to input UTF-8 that hasn't been
; confirmed to entirely use standard 7-bit ASCII. we already can't support
; unicode, so not supporting extended-ASCII isn't outrageous. if someone truly
; does want to use extended-ASCII, they can just manually preprocess their data
; to map those chars to the weird control chars that exist in 7-bit ASCII. will
; work fine here. if we do that, we can transform all strings from AoS to AoSoA
; layout in 4 KiB blocks, eliminating the memory bandwidth + page fault issues,
; all while updating an alphabet bitmask at 2 chars per cycle. then, for each
; symbol in the final alphabet mask, avx512 compare 64 bytes with said symbol
; for equality. kmov the resulting mask to the correct position in the speq.
; this is O(alphabet_size * m / 64). the current method is O(m), but has much
; slower loop. so provided alphabet_size is small, which it normally is, then
; this is mcuh much faster. right now we're at 0.1 chars/cycle. this can get us
; up to the maximum of 2 chars/cycle minus time to do the post-processing
; (64 * alphabet_size * (vpcmp + kmov) => when pipelined, around 
; 64 * alphabet_size cycles). so for each of the 4096 chars processed, this is
; alphabet_size/64 extra cycles of time. so basically we maintain the perfect
; 2 chars/cycle rate. so this is 20x faster than what i currently have. defo
; worthwhile to try this out in the future.
;
