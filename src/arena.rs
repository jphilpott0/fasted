use std::ffi::c_void;
use std::fmt::Debug;

use crate::len::_len_calculate_mmax;
use crate::speq::SliceStr;

unsafe extern "C" {

    unsafe static _SIZE_OFFSET: usize;
    unsafe static _MMAX_OFFSET: usize;
    unsafe static _BATCH_SIZE_OFFSET: usize;
    unsafe static _BLOCKMAP_PTR_OFFSET: usize;
    unsafe static _BLOCKSPILL_PTR_OFFSET: usize;
    unsafe static _SPEQ_PTR_OFFSET: usize;
    unsafe static _OUTPUT_STORE_PTR_OFFSET: usize;
    unsafe static _ALPHABET_MASK_OFFSET: usize;
    unsafe static _STORE_MASK_OFFSET: usize;

    pub(crate) unsafe fn _arena_alloc(mmax: usize, batch_size: usize) -> *mut c_void;

    pub(crate) unsafe fn _arena_free(ptr: *mut c_void) -> isize;
}

pub struct Arena {
    ptr: *mut c_void,
}

impl Arena {
    unsafe fn new(ptr: *mut c_void) -> Self {
        Arena { ptr }
    }

    pub(crate) unsafe fn new_from<'a, T>(s: T) -> Self
    where
        T: AsRef<[&'a [u8]]>,
    {
        let slice_strs: Vec<SliceStr> = s.as_ref().iter().map(SliceStr::from).collect();

        assert!(
            !slice_strs.is_empty(),
            "You should not create an empty arena ..."
        );

        assert!(
            slice_strs.len() <= 512,
            "You cannot create an arena for more than 512 strings ..."
        );

        // Safety:
        //
        // Provided ptr is non-null and is valid. Provided length is correct.
        // Caller guarantees all machine requirements.
        let mmax = unsafe { _len_calculate_mmax(slice_strs.as_ptr(), slice_strs.len()) };
        let batch_size = slice_strs.len();

        // Safety:
        let ptr = unsafe { _arena_alloc(mmax, batch_size) };

        if ptr.addr().cast_signed().is_negative() {
            panic!("Failed to allocate arena: {} ...", ptr.addr());
        }

        Arena::new(ptr)
    }

    pub(crate) unsafe fn read<U>(&self, offset: usize) -> U {
        self.ptr.byte_add(offset).cast::<U>().read()
    }

    pub(crate) unsafe fn read_usize(&self, offset: usize) -> usize {
        self.read::<usize>(offset)
    }

    pub(crate) unsafe fn size_of(&self) -> usize {
        self.read_usize(_SIZE_OFFSET)
    }
}

impl Debug for Arena {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Safety:
        //
        // A properly instantiated `Arena` will follow the ABI used below, so reads are safe.
        unsafe {
            // I'm interpreting the "pointers" here as integers because they are not real
            // pointers, they are virtual-ish pointers within my Arena space. Technically
            // better to call them offsets, but then I have my ABI detailing offsets to stored
            // offsets and that's far too confusing.
            f.debug_struct("Arena")
                .field(".SIZE", &self.size_of())
                .field(".MMAX", &self.read_usize(_MMAX_OFFSET))
                .field(".BATCH_SIZE", &self.read_usize(_BATCH_SIZE_OFFSET))
                .field(".BLOCKMAP_PTR", &self.read_usize(_BLOCKMAP_PTR_OFFSET))
                .field(".BLOCKSPILL_PTR", &self.read_usize(_BLOCKSPILL_PTR_OFFSET))
                .field(".SPEQ_PTR", &self.read_usize(_SPEQ_PTR_OFFSET))
                .field(
                    ".OUTPUT_STORE_PTR",
                    &self.read_usize(_OUTPUT_STORE_PTR_OFFSET),
                )
                .finish()
        }
    }
}

impl Drop for Arena {
    fn drop(&mut self) {
        let status = unsafe { _arena_free(self.ptr) };

        debug_assert!(status == 0, "Failed to free arena: {} ...", status);
    }
}

#[cfg(test)]
mod tests {
    use std::iter::repeat_n;

    use super::*;

    #[test]
    fn test_arena_alloc() {
        let strings: Vec<Vec<u8>> = (0..512)
            .map(|x| repeat_n(b'a', x + 1).collect::<Vec<u8>>())
            .collect();

        let arena = unsafe {
            Arena::new_from(strings.iter().map(|x| x.as_slice()).collect::<Vec<&[u8]>>())
        };

        assert_eq!(unsafe { arena.size_of() }, 8462336);
    }
}
