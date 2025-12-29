//! Operations for processing the lengths of strings in `fasted`.

use crate::speq::SliceStr;

unsafe extern "C" {
    /// Calculate the length of the longest string (`mmax`) of the 512 strings given.
    ///
    /// # Safety:
    /// - `arr` must be non-null and point to a valid array of `SliceStr` types.
    /// - `len` must be the correct length of `arr`.
    /// - Refer to the [crate-level documentation](crate#target-and-platform-requirements)
    ///   for machine requirements.
    pub(crate) unsafe fn _len_calculate_mmax(arr: *const SliceStr, len: usize) -> usize;
}

#[cfg(test)]
mod tests {
    use std::iter::repeat_n;

    use crate::len::_len_calculate_mmax;

    use super::*;

    #[test]
    fn test_speq_calculate_mmax_0() {
        let data = Vec::new();
        let mmax = unsafe { _len_calculate_mmax(data.as_ptr(), data.len()) };

        assert_eq!(mmax, 0);
    }

    #[test]
    fn test_speq_calculate_mmax_1_1025() {
        let strings: Vec<Vec<u8>> = (0..1024)
            .map(|x| repeat_n(b'a', x).collect::<Vec<u8>>())
            .collect();

        let slices: Vec<SliceStr> = strings.iter().map(SliceStr::from).collect();

        for m in 1..1025 {
            let d = &slices[0..m];

            let mmax = unsafe { _len_calculate_mmax(d.as_ptr(), d.len()) };

            let n = d
                .iter()
                .max_by_key(|x| x.len())
                .expect("Could not get max")
                .len();

            assert_eq!(mmax, n);
        }
    }
}
