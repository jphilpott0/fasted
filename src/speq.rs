//! Module for constructing the speq data structure.

use std::borrow::Borrow;
use std::marker::PhantomData;

use crate::arena::Arena;

pub struct Speq;

impl Speq {
    #[allow(unused_variables)]
    pub(crate) unsafe fn new_in(arena: &mut Arena, data: &[SliceStr]) {
        todo!();
    }
}

#[repr(C)]
pub(crate) struct SliceStr<'a> {
    ptr: *const u8,
    len: usize,
    marker: PhantomData<&'a [u8]>,
}

impl<'a, T> From<&'a T> for SliceStr<'a>
where
    T: Borrow<[u8]> + ?Sized,
{
    // This may be zero cost. Hopefully LLVM will recognise that this is
    // extracting and repackaging the data in the exact same layout 99% of the
    // time and will optimise this away. We still need it because Rust slices
    // are not FFI safe, so we need to pass something with a guaranteed ABI.
    // 99% of the time, this fatptr layout is what is used, hence why it is
    // normally zero-cost to do this transform.
    fn from(value: &'a T) -> Self {
        let slice: &[u8] = value.borrow();

        // Safety: borrowck already guarantees that T lives for 'a and slice is
        // borrowed from &'a T therefore slice cannot outlive T.
        unsafe { SliceStr::new(slice.as_ptr(), slice.len()) }
    }
}

impl<'a> SliceStr<'a> {
    /// Creates a new [`SliceStr`].
    ///
    /// # Safety:
    /// - `ptr` must be non-null and point to a valid array of fat pointers
    ///   (qword ptr + qword len).
    /// - `len` must be the correct length of the array `ptr` points to.
    pub(crate) unsafe fn new(ptr: *const u8, len: usize) -> Self {
        SliceStr {
            ptr,
            len,
            marker: PhantomData,
        }
    }

    pub(crate) fn as_ptr(&self) -> *const u8 {
        self.ptr
    }

    pub(crate) fn len(&self) -> usize {
        self.len
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_slice_str() {
        #[allow(clippy::byte_char_slices)]
        let s = [b'f', b'o', b'o'];

        let slice_str0 = SliceStr::from(&s);

        assert_eq!(s.len(), slice_str0.len);

        let v = vec![b'b', b'a', b'r'];

        let slice_str1 = SliceStr::from(&v);

        assert_eq!(slice_str1.len, 3);

        let string = String::from("baz");

        let slice_str2 = SliceStr::from(string.as_bytes());

        assert_eq!(slice_str2.len, 3);
    }
}
