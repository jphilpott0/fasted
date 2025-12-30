;
; Arena Layout:
;
; Format here is: REGION_OFFSET | OFFSET | REGION_SIZE.
; + in the offset means "added to previous offset".
;
%define SIZE_OFFSET             0                       ; qword integer.
%define MMAX_OFFSET             8                       ; qword integer.
%define BATCH_SIZE_OFFSET       16                      ; qword integer.
%define BLOCKMAP_PTR_OFFSET     24                      ; qword ptr.
%define BLOCKSPILL_PTR_OFFSET   32                      ; qword ptr.
%define SPEQ_PTR_OFFSET         40                      ; qword ptr.
%define OUTPUT_STORE_PTR_OFFSET 48                      ; qword ptr + 8B padding.
%define ALPHABET_MASK_OFFSET    64                      ; 256 byte mask.
%define STORE_MASK_OFFSET       320                     ; mmax bytes.
;       BLOCKMAP_OFFSET         + mmax + pad.           ; 64B aligned. (mmax + 1) >> 3 bytes.
;       BLOCKSPILL_OFFSET       + (mmax + 1 >> 3) + pad.; 64B aligned. mmax << 7 bytes.
;       SPEQ_OFFSET             + mmax << 7.            ; 64B aligned. mmax << 14 bytes.
;       OUTPUT_STORE_OFFSET     + mmax << 14 + pad.     ; 4 KiB page aligned. 4096 bytes.
;       END_OFFSET              + 4096.                 ; end of arena.
;
