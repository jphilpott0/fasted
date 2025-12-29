;
; arena.S - Arena-based allocator optimised for fast speq allocation and reuse.
;
; Speq construction is very fast. So fast that the time to allocate the backing
; memory can noticeably affect throughput. We want to minimise page faults and
; maximise dirty page re-use. There are two important notes about the speq 
; structure that underpin the allocator's implementation: 
;
;	1. We need mostly zeroed memory when constructing a new speq.
;
;	2. We must allocate assuming that alphabet_size = 256, but in practice it
;	   is typically much much smaller.
;
; A minor page fault taking ~1000 cycles is roughly equivalent to the execution 
; time of building 2 characters across 512 different strings into the speq. And 
; we may spread data across many pages, incurring multiple faults. Since in
; practice alphabet_size << 256, using mmap's MAP_POPULATE would be wasteful,
; because we often won't write to most pages. We rely on MAP_ANONYMOUS and 
; defer the fault until we write to a page. This does stall the hot loop and 
; flush all OoO execution, but pre-faulting is still not worthwhile when it 
; would touch and zero far more pages than we actually need.
;
; After we've consumed a speq, the backing memory remains. Since we will be
; taking a new batch of w strings from the same original set of strings as the 
; previous batch took from, with Levenshtein/Damerau distance, it makes sense
; that the new string lengths would remain similar. Thus, we probably can use 
; the original allocation to build the new speq, especially if we slightly
; overallocate in the first instance, and zero any dirty pages before re-use. 
; Doing this all manually avoids a new mmap syscall and minimises, if not 
; eliminates, new page faults.

bits	64
default rel

global	_arena_alloc
global	_arena_free

;
; Arena Layout:
;
; Format here is: REGION_OFFSET	| OFFSET | REGION_SIZE.
; + in the offset means "added to previous offset".
;
%define	SIZE_OFFSET				0						; qword integer.
%define	MMAX_OFFSET				8						; qword integer.
%define	BATCH_SIZE_OFFSET		16						; qword integer.
%define BLOCKMAP_PTR_OFFSET		24						; qword ptr.
%define BLOCKSPILL_PTR_OFFSET	32						; qword ptr.
%define	SPEQ_PTR_OFFSET			40						; qword ptr.
%define OUTPUT_STORE_PTR_OFFSET	48						; qword ptr + 8B padding.
%define	ALPHABET_MASK_OFFSET	64						; 256 byte mask.
%define	STORE_MASK_OFFSET		320						; mmax bytes.
;		BLOCKMAP_OFFSET			+ mmax + pad.			; 64B aligned. (mmax + 1) >> 3 bytes.
;		BLOCKSPILL_OFFSET		+ (mmax + 1 >> 3) + pad.; 64B aligned. mmax << 7 bytes.
;		SPEQ_OFFSET				+ mmax << 7.			; 64B aligned. mmax << 14 bytes.
;		OUTPUT_STORE_OFFSET		+ mmax << 14 + pad.		; 4 KiB page aligned. 4096 bytes.
;		END_OFFSET				+ 4096.					; end of arena.
;

%define MAP_PRIVATE				0x0002
%define MAP_ANONYMOUS			0x0020
%define PROT_READ				0x0001
%define	PROT_WRITE				0x0002

section .rodata

;
; Export ABI offsets so Rust uses them directly, ensuring the ABI cannot drift.
;

global _SIZE_OFFSET
global _MMAX_OFFSET
global _BATCH_SIZE_OFFSET
global _BLOCKMAP_PTR_OFFSET
global _BLOCKSPILL_PTR_OFFSET
global _SPEQ_PTR_OFFSET
global _OUTPUT_STORE_PTR_OFFSET
global _ALPHABET_MASK_OFFSET
global _STORE_MASK_OFFSET

_SIZE_OFFSET:					dq SIZE_OFFSET
_MMAX_OFFSET:					dq MMAX_OFFSET
_BATCH_SIZE_OFFSET:				dq BATCH_SIZE_OFFSET
_BLOCKMAP_PTR_OFFSET:			dq BLOCKMAP_PTR_OFFSET
_BLOCKSPILL_PTR_OFFSET:			dq BLOCKSPILL_PTR_OFFSET
_SPEQ_PTR_OFFSET:				dq SPEQ_PTR_OFFSET
_OUTPUT_STORE_PTR_OFFSET:		dq OUTPUT_STORE_PTR_OFFSET
_ALPHABET_MASK_OFFSET:			dq ALPHABET_MASK_OFFSET
_STORE_MASK_OFFSET:				dq STORE_MASK_OFFSET

section .text

;
; _arena_alloc - Allocate a new arena.
;
; Calling convention (SysV):
;	rdi = mmax (length of longest string in batch of BATCH_SIZE strings).
;
;	rsi = BATCH_SIZE.
;
; Return:
;	rax = ptr to new arena. if allocation errors, returns the mmap error code.
;
; Notes:
;	Allocates enough space for 512 strings to be processed, even if there
;	aren't actually that many to process.
;
align 32
_arena_alloc:
	mov				rax, STORE_MASK_OFFSET				; set offset counter to first DST offset.
	sub				rsp, 72								; reserve 64B of stack + pre-align for mmap.

	mov qword [rsp + MMAX_OFFSET], rdi					; save mmax. (first 8B are for arena size).
	mov qword [rsp + BATCH_SIZE_OFFSET], rsi			; save BATCH_SIZE.
	mov qword [rsp + OUTPUT_STORE_PTR_OFFSET + 8], 0x0	; zero qword used for padding.

	; BLOCKMAP_OFFSET.

	add				rax, rdi							; add mmax.
	add				rax, 63								; setup padding.
	and				rax, -64							; pad to next 64B.

	mov qword [rsp + BLOCKMAP_PTR_OFFSET], rax			; save BLOCKMAP_OFFSET.

	; BLOCKSPILL_OFFSET.

	mov				rdx, rdi							; rename mmax into rdx.
	add				rdx, 8								; add 8 (1 extra + 7 padding calc).
	shr				rdx, 3								; divide by 8.

	add				rax, 63								; prep padding calc.
	add				rax, rdx							; add to counter.
	and				rax, -64							; pad to next 64B.

	mov qword [rsp + BLOCKSPILL_PTR_OFFSET], rax		; save BLOCKMAP_OFFSET.

	; SPEQ_OFFSET.

	mov				rcx, rdi							; rename mmax into rcx.
	shl				rcx, 7								; mmax << 7.
	add				rax, rcx							; add to prev offset. already 64B aligned.

	mov qword [rsp + SPEQ_PTR_OFFSET], rax				; save SPEQ_OFFSET.
	
	; OUTPUT_STORE_OFFSET.

	mov				r8, rdi								; rename mmax into r8.
	shl				r8, 14								; mmax << 14.
	add				rax, r8								; add to prev offset. already 64B aligned.

	mov qword [rsp + OUTPUT_STORE_PTR_OFFSET], rax		; save OUTPUT_STORE_OFFSET.

	; END_OFFSET (i.e. arena size).

	add				rax, 8191							; final size. 4096+4095=8191.
	and				rax, -4096							; align to page.

	mov	qword [rsp + SIZE_OFFSET], rax					; save final size.

	; mmap.

	xor				rdi, rdi							; addr = null (return any ptr).
	mov				rsi, rax							; set mapping length.
	mov				rdx, PROT_READ | PROT_WRITE			; mapping protection.
	mov				r10, MAP_PRIVATE | MAP_ANONYMOUS	; flags.
	mov				r8, -1								; fd = -1 (required by MAP_ANONYMOUS).
	xor				r9, r9								; offset = 0.
	mov				rax, 9								; mmap syscall number.

	syscall												; allocate memory.

	test			rax, rax							; test if error.
	js				.mmap_error							; jump if negative (err is negative).

	; add metadata to arena.

	vmovdqu64		zmm0, [rsp]							; load 64B from stack.
	vmovdqa64		[rax], zmm0							; write metadata to arena.

	add				rsp, 72								; un-reserve stack space.

	ret

.mmap_error:
	add				rsp, 72								; restore stack.
	ret

;
; _arena_free - De-allocate backing memory of an arena.
;
; Calling convention (SysV):
;	rdi = ptr to arena.
;
; Return:
;	rax = zero if successful. negative indicates failure, and is a munmap error code.
;
align 32
_arena_free:	
	mov				rax, 11								; munmap syscall code.
	mov				rsi, qword [rdi + SIZE_OFFSET]		; get arena size. (addr already in rdi).

	syscall												; free arena.

	ret													; pass exit code to caller.
