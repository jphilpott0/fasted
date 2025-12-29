//! `fasted` ("**Fast** **e**dit **d**istance") is an edit distance library written
//! in Rust and x86-64 assembly optimised for processing batches of short to medium
//! length strings in parallel.
//!
//! # Target and Platform Requirements:
//!
//! `fasted` currently only supports `x86_64` targets with `SystemV` calling
//! conventions. ARM and Windows may be supported in the future.
//!
//! We additionally require the following CPU features:
//! - `sse`,
//! - `avx2`,
//! - `avx512f`,
//! - `avx512vl`.
//!
//! Pure SSE and AVX2 versions may be supported in the future.
//!
//! ## Safety:
//!
//! `fasted` does not expose safe functions that do not internally check whether
//! required CPU features or architectures are available (panicking / returning
//! `Err` if unavailable). However, for the many `unsafe` functions in this crate,
//! calling a function that has specific machine requirements that are unmet is
//! considered undefined behaviour.

#![allow(unsafe_op_in_unsafe_fn)]
#![cfg(all(target_arch = "x86_64", target_pointer_width = "64"))]
#![feature(slice_as_array)]

pub mod arena;
pub mod speq;

pub(crate) mod len;

pub type Ed1D<T> = Vec<T>;
pub type Ed2D<T> = Vec<Vec<T>>;

// pub fn ld_1d<S1, S2, AL>(x: S1, y: &[S2]) -> Ed1D<usize>
// where
//     S1: AsRef<[u8]> + Sync,
//     S2: AsRef<[u8]> + Sync,
//     AL: AsRef<[u8]> + Sync,
// {
//     todo!()
// }
//
// pub fn ld_2d<S1, S2, AL>(x: &[S1], y: &[S2]) -> Ed2D<usize>
// where
//     S1: AsRef<[u8]> + Sync,
//     S2: AsRef<[u8]> + Sync,
//     AL: AsRef<[u8]> + Sync,
// {
//     todo!()
// }
//
// pub fn ld_1d_within_k<S1, S2, AL>(x: S1, y: &[S2], k: usize) -> Ed1D<bool>
// where
//     S1: AsRef<[u8]> + Sync,
//     S2: AsRef<[u8]> + Sync,
//     AL: AsRef<[u8]> + Sync,
// {
//     todo!()
// }
//
// pub fn ld_2d_within_k<S1, S2, AL>(x: &[S1], y: &[S2], k: usize) -> Ed2D<bool>
// where
//     S1: AsRef<[u8]> + Sync,
//     S2: AsRef<[u8]> + Sync,
//     AL: AsRef<[u8]> + Sync,
// {
//     todo!()
// }
