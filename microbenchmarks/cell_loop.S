;
; cell_loop.S - microbenchmarks of cell loop.
;

bits    64
default rel

global  _minimal_rename
global  _extra_rename

global  _minimal_rename_avx2
global  _extra_rename_avx2

;
; Overall Results:
;
; I can't check the exact 512b datapath on my laptop since only desktop Granite
; Ridge Zen5 CPUs have the full 512b datapaths, but my equivalent AVX2 tests
; (which use all the same EUs and should have the exact same constaints), show
; that we achieve a cell update in ~1.75c. The theoretical fastest is 1.25c (since
; Zen5 has 4 EUs capable of 512b logical uop execution, and we have 5 uops to
; execute). After a lot of testing and investigation, it seems that the cell 
; update is bottlenecked by VRF data port limits. Zen5 only has 10 VRF data 
; ports. We are requiring more than 10 most cycles, and this is causing bubbles. 
; A lot of analysis with `perf` has proven nothing else is bottlenecking (no
; frontend issues, no scheduling issues, no retire width issues, and so on).
; You can see its a data port issue simply by changing the `vpandd` 
; instructions in the cell update to equivalent `vpternlogd` ones. Throughput
; drops to 2.0c. We've proven no frontend issues, therefore `vpternlogd` being
; one byte longer than `vpandd` cannot be an issue. The only other differnce
; is that `vpternlogd` has 3 source registers, while `vpandd` only has 2.
; With 3x `vpternlogd` and 2x `vpandd`, we have 3*3 + 2*2 = 13 source registers.
; To do read these in 1.25c, we'd need 10.4 data ports. Hence the issue. And 
; in the synthetic test with 5x `vpternlogd`, we have 15 source registers, and
; would need 12 data ports.
;
; While 10.4 is not much more than 10, remember that the data ports are
; discrete and cannot be fractionalised. If you add 3 + 3 + 3 + 2 = 11,
; then one of those uops cannot execute that cycle, and you only use either
; 8/9 data ports that cycle. Im guessing the scheduler does not take data port
; use into consideration and is just trying to greedily fill EUs with uops.
; Therefore, once a uop is in an EU and there aren't enough data ports left,
; I'm guessing it stalls until the next cycle.
;
; Zen5 can supposedly elide duplicate reads to the VRF and use less data ports.
; However, because we have our 8-wide unroll, we introduce so much opportunity
; for OoO execution, that the scheduler is executing uops that do not share
; inputs from across many different cells. This is optimal to fill EUs, but
; terrible for setting off this CPU hazard. We can't remove or decrease the
; current unroll, because its way worse to need to load and store from L1D
; more often. We already load 128 bytes and store 128 bytes every 8 cells.
; We don't want to make that need to happen more often, since we're already
; nearly at the limit of what the memory subsystem can handle, and that will
; degrade performance way faster than fixing the data port problem might 
; yield improvements. As a brief test: an unroll of 4 led to 2.5c throughput.
; Immediately much worse. An unroll of 2 led to 10c throughput. We'd totally
; have enough ILP at 2-4x unroll, but without the 8x unroll we'd be crushed
; by the memory subsystem's limitations.
;
; There is almost an irony to this. We already have structured the whole system 
; to work in cache because working from DRAM would completely bottleneck us.
; But eventually it became obvious that working solely from cache would also be
; too slow, so we moved to working inside the VRF. And now that's too slow! 
; There is currently about 1 KiB of data in-flight per cycle right now. This is
; the roofline value. I don't think its possible to be faster than this. And
; I've already proven (with some basic information theory) that the 
; implementation of the Levenshtein automata transition function I have is 
; optimal and cannot be improved upon. Therefore, this would seem to be at 
; least the absolute fastest way possible to calculate batched Levenshtein 
; distances on a Zen5 CPU; and since Zen5 beats everything else at 512b SIMD
; by a mile, this might also the fastest possible implementation on a x86-64
; CPU. At 1.75c, we're operating at about 1536 GCUPS per core. That's >100x 
; faster than `edlib`, the field standard. Also at 6 IPC, which is nice.
;

align 32
_minimal_rename:
    mov             rdi, 64

    mov             r10, rsp

    sub             rsp, 1024
    and             rsp, -64

    mov             byte [rsp + 128], 0x45

    ; record cycle count.

    ; i don't think this is working correctly. using perf instead.

    rdtscp
    shl             rdx, 32
    or              rax, rdx
    mov             r8, rax

    mov             rcx, 1_000_000_000                    ; 1 billion iterations.

align 16
.loop:
    ; this loop doesn't compute an actual useful cell update. it just
    ; contains the same instructions to work as a benchmark.

    ; unroll 8x.
    %assign i 7
    %rep 8
        %ifn i = 7
            %assign         vp (4*i+0)
            %assign         vn (4*i+1)
            %assign         hp (4*i+2)
            %assign         hn (4*i+3)
        %else
            %assign         vp (4*i+0)
            %assign         vn (4*i+1)
            %assign         hp 2
            %assign         hn 3
        %endif
            
        movzx           rax, byte [rsp + 128]               ; load any byte from stack.
        imul            rax, rdi

        %if i = 0
            ; this will technically allow store forwarding that is not present
            ; in the real loop, but latency is never an issue here anyway.

            vmovdqa64   zmm2, [rsp + 512]                   ; load any zmmword from stack.
            vmovdqa64   zmm3, [rsp + 512 + 64]              ; load any zmmword from stack.
        %endif


        vmovdqa64       zmm31, zmm%+vn

        vpternlogd      zmm31, zmm%+hn, [rsp + rax], 0xFE
        vpternlogd      zmm%+vn, zmm31, zmm%+vp, 0xF7
        vpternlogd      zmm%+hn, zmm31, zmm%+hp, 0xF7
        vpandd          zmm%+vp, zmm%+vp, zmm31
        vpandd          zmm%+hp, zmm%+hp, zmm31

        %ifn i = 0
            %assign i (i-1)
        %endif
    %endrep

    vmovdqa64           [rsp], zmm2
    vmovdqa64           [rsp + 64], zmm3
    add                 r9, 128

    sub             rcx, 8

    ; use cmp flags instead of sub to mimic real loop.
    cmp             rcx, 0
    jnz             .loop

.epilogue:
    ; get final time and difference.

    rdtscp
    shl             rdx, 32
    or              rax, rdx
    sub             rax, r8

    mov             rsp, r10

    ; return cycles spent.

    ret

align 32
_extra_rename:
    mov             rdi, 1

    mov             r10, rsp

    sub             rsp, 256
    and             rsp, -64

    mov             byte [rsp + 128], 0x41

    ; record cycle count.

    rdtscp
    shl             rdx, 32
    or              rax, rdx
    mov             r8, rax

    mov             rcx, 100_000_000                    ; 100 million iterations.

align 16
.loop:
    ; this loop doesn't compute an actual useful cell update. it just
    ; contains the same instructions to work as a benchmark.

    ; unroll 8x.
    %assign i 7
    %rep 8
        %ifn i = 7
            %assign         vp (4*i+0)
            %assign         vn (4*i+1)
            %assign         hp (4*i+2)
            %assign         hn (4*i+3)
        %else
            %assign         vp (4*i+0)
            %assign         vn (4*i+1)
            %assign         hp 2
            %assign         hn 3
        %endif

        movzx           rax, byte [rsp + 128]           ; load any byte from stack.
        imul            rax, rdi

        ; add extra renames to see if they affect performance.
        %ifn i = 0
            %assign         hp_prev (4*(i-1)+2)
            %assign         hn_prev (4*(i-1)+3)

            ; this will technically allow store forwarding that is not present
            ; in the real loop, but latency is never an issue here anyway.

            vmovdqa64       zmm%+hp, zmm%+hp_prev
            vmovdqa64       zmm%+hn, zmm%+hn_prev
        %else
            vmovdqa64       zmm%+hp, [rsp]              ; load any zmmword from stack.
            vmovdqa64       zmm%+hn, [rsp + 64]         ; load any zmmword from stack.
        %endif

        vmovdqa64       zmm31, zmm%+vn

        vpternlogd      zmm31, zmm%+hn, [rsp + rax], 0xFE
        vpternlogd      zmm%+vn, zmm31, zmm%+vp, 0xF7
        vpternlogd      zmm%+hn, zmm31, zmm%+hp, 0xF7
        vpandd          zmm%+vp, zmm%+vp, zmm31
        vpandd          zmm%+hp, zmm%+hp, zmm31

        %ifn i = 0
            %assign i (i-1)
        %endif
    %endrep

    vmovdqa64           [rsp], zmm2
    vmovdqa64           [rsp + 64], zmm3
    add                 r9, 128

    sub             rcx, 8

    ; use cmp flags instead of sub to mimic real loop.
    cmp             rcx, 0
    jnz             .loop

.epilogue:
    ; get final time and difference.

    rdtscp
    shl             rdx, 32
    or              rax, rdx
    sub             rax, r8

    mov             rsp, r10

    ; return cycles spent.

    ret

; use avx2 as well because I'm testing on my Strix Point laptop that doesn't
; have full 512b datapaths and is just double pumping 256-bit uops. this means
; the extra renames might just spread out across the extra cycles.

align 32
_minimal_rename_avx2:
    mov             rdi, 64

    mov             r10, rsp

    sub             rsp, 1024
    and             rsp, -64

    mov             byte [rsp + 128], 0x45
    mov             r11, 0

    ; record cycle count.

    rdtscp
    shl             rdx, 32
    or              rax, rdx
    mov             r8, rax

    mov             rcx, 1_000_000_000                  ; 1 billion iterations.

align 16
.loop:
    ; this loop doesn't compute an actual useful cell update. it just
    ; contains the same instructions to work as a benchmark.

    ; unroll 8x.
    %assign i 7
    %rep 8
        %ifn i = 7
            %assign         vp (4*i+0)
            %assign         vn (4*i+1)
            %assign         hp (4*i+2)
            %assign         hn (4*i+3)
        %else
            %assign         vp (4*i+0)
            %assign         vn (4*i+1)
            %assign         hp 2
            %assign         hn 3
        %endif

        movzx           rax, byte [rsp + 128]               ; load any byte from stack.
        imul            rax, rdi

        %if i = 0
            ; this will technically allow store forwarding that is not present
            ; in the real loop, but latency is never an issue here anyway.

            vmovdqa64   ymm2, [rsp + 512]                         ; load any ymmword from stack.
            vmovdqa64   ymm3, [rsp + 512 + 64]                    ; load any ymmword from stack.
        %endif
        ;
        ;
        vmovdqa64       ymm31, ymm%+vn

        ; results: so removing a vpandd doesn't change much. but removing
        ; a vpternlogd does. im guessing this is a data port + VRF bandwidth
        ; issue, since that's the only thing that should differ between
        ; these instructions. they have basically the same dependencies,
        ; and in a steady-state it shouldn't matter as much. my guess is that
        ; the scheduler, while it can optimise for maximal EU usage, does not
        ; consider whether the data ports will fill and this is causing bubbles.
        ; the more OoO execution there is here, the more different inputs are used,
        ; and the less duplicated inputs can be elided and use the same data port.
        ; but we need the large unroll to reduce the need to spill to cache. the
        ; latter is far more detrimental. so this is probably just a fundamental
        ; limitation that cannot be removed. lol unless i fill the scheduler up
        ; with nops to keep my unroll but reduce OoO execution? nops will kill
        ; decode, but the loop operates out of the uop cache most of the time.
        ;
        ; unless its just an instruction alignment issue? and removing different
        ; instructions changes the alignment and uop cache fetches etc.? nope, removing
        ; the vpternlog and putting in a 7-byte nop gives the same performance as just
        ; removing the vpternlog.

        ; vmovdqa64       ymm30, [rsp + rax]

        vpternlogd      ymm31, ymm%+hn, [rsp + rax], 0xFE
        ; vpxord          ymm31, ymm31, ymm31       ; break dependency.
        ; vpternlogd      ymm31, ymm%+hn, ymm30, 0xFE
        ; nop             dword [eax + eax*1 + 00000000H] ; 8-byte nop.
        vpternlogd      ymm%+vn, ymm31, ymm%+vp, 0xF7
        ; nop             dword [eax + 00000000H]         ; 7-byte nop.
        vpternlogd      ymm%+hn, ymm31, ymm%+hp, 0xF7
        vpandd          ymm%+vp, ymm%+vp, ymm31
        ; vpternlogd      ymm%+vp, ymm%+vp, ymm31, 0x88
        ; db 0x66, 0x0F, 0x1F, 0x44, 0x00, 0x00               ; 6-byte nop.
        vpandd          ymm%+hp, ymm%+hp, ymm31
        ; vpternlogd      ymm%+hp, ymm%+hp, ymm31, 0x88

        ; add rsp, r11

        ; %if i % 1 = 0
        ;     ; add r11, r10
        ;     ; mov r11, r12
        ;     ; mov r12, r11
        ; %endif

        %ifn i = 0
            %assign i (i-1)
        %endif
    %endrep

    vmovdqa64           [rsp], ymm2
    vmovdqa64           [rsp + 64], ymm3
    add                 r9, 128

    sub             rcx, 8

    ; use cmp flags instead of sub to mimic real loop.
    cmp             rcx, 0
    jnz             .loop

.epilogue:
    ; get final time and difference.

    rdtscp
    shl             rdx, 32
    or              rax, rdx
    sub             rax, r8

    mov             rsp, r10

    ; return cycles spent.

    ret

align 32
_extra_rename_avx2:
    mov             rdi, 64

    mov             r10, rsp

    sub             rsp, 1024
    and             rsp, -64

    mov             byte [rsp + 128], 0x44

    ; record cycle count.

    rdtscp
    shl             rdx, 32
    or              rax, rdx
    mov             r8, rax

    mov             rcx, 1_000_000_000                  ; 10 billion iterations.

align 16
.loop:
    ; this loop doesn't compute an actual useful cell update. it just
    ; contains the same instructions to work as a benchmark.

    ; unroll 8x.
    %assign i 7
    %rep 8
        %ifn i = 7
            %assign         vp (4*i+0)
            %assign         vn (4*i+1)
            %assign         hp (4*i+2)
            %assign         hn (4*i+3)
        %else
            %assign         vp (4*i+0)
            %assign         vn (4*i+1)
            %assign         hp 2
            %assign         hn 3
        %endif

        movzx           rax, byte [rsp + 128]           ; load any byte from stack.
        imul            rax, rdi

        ; add extra renames to see if they affect performance.
        %ifn i = 0
            %assign         vp_prev (4*(i-1)+0)
            %assign         vn_prev (4*(i-1)+1)
            %assign         hp_prev (4*(i-1)+2)
            %assign         hn_prev (4*(i-1)+3)

            ; this will technically allow store forwarding that is not present
            ; in the real loop, but latency is never an issue here anyway.

            vmovdqa64       ymm%+hp, ymm%+hp_prev
            vmovdqa64       ymm%+hn, ymm%+hn_prev

            ; vmovdqa64       ymm%+vp, ymm%+vp_prev
            ; vmovdqa64       ymm%+vn, ymm%+vn_prev

            ; vmovdqa64       ymm30, ymm31
            ; vmovdqa64       ymm0, ymm29
        %else
            vmovdqa64       ymm%+hp, [rsp + 512]              ; load any ymmword from stack.
            vmovdqa64       ymm%+hn, [rsp + 512 + 64]         ; load any ymmword from stack.
        %endif

        vmovdqa64       ymm31, ymm%+vn

        vpternlogd      ymm31, ymm%+hn, [rsp + rax], 0xFE
        vpternlogd      ymm%+vn, ymm31, ymm%+vp, 0xF7
        vpternlogd      ymm%+hn, ymm31, ymm%+hp, 0xF7
        vpandd          ymm%+vp, ymm%+vp, ymm31
        vpandd          ymm%+hp, ymm%+hp, ymm31

        %ifn i = 0
            %assign i (i-1)
        %endif
    %endrep

    vmovdqa64           [rsp], ymm2
    vmovdqa64           [rsp + 64], ymm3
    add                 r9, 128

    sub             rcx, 8

    ; use cmp flags instead of sub to mimic real loop.
    cmp             rcx, 0
    jnz             .loop

.epilogue:
    ; get final time and difference.

    rdtscp
    shl             rdx, 32
    or              rax, rdx
    sub             rax, r8

    mov             rsp, r10

    ; return cycles spent.

    ret
