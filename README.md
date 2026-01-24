# fasted

fasted ("**fast** **e**dit **d**istance") is a WIP edit distance library written
in x86-64 Assembly and Rust optimised for processing batches of short to medium
length strings in parallel.

This is in active development and will continue to be updated over the coming 
weeks. Presently, the preprocessing stage and allocator have been written. The 
remaining components have been designed and will be implemented soon.

## Basic Overview:

Bit-parallelism can substantially accelerate string matching and edit distance
calculations by packing more computation into each instruction. The classic
approach for this is from Myers (1999) which achieves an `O(n * ceil(m / w))`
implementation, where `n` and `m` are string lengths, and `w` is the bit-width
of the word used. The algorithm for this is roughly:

```c
// Algorithm: Bit-parallel Levenshtein distance.
// Input: text t[1..n], pattern p[1..m].
// Output: score = edit_distance(t, p).
//
// Requires that m < word_size.
// This can be resolved with the "blocked" variant of the algorithm. This is
// just showing the basic variant for simplicity.

peq[256] = {0}

// Build pattern equality vector.
for i = 1..m do
{
    peq[p[i]] |= (1 << i)
}

// Starting conditions.
vp = (1 << m) - 1
vn = 0
score = m

for j = 1..n do 
{
    eq = peq[t[j]]
    d0 = (((eq & vp) + vp) ^ vp) | eq | vn

    hp = vn | ~(d0 | vp)
    hn = vp & d0

    if hp & (1 << m) then
        score += 1
    else if hn & (1 << m) then
        score -= 1

    hp = (hp << 1) | 1
    hn = hn << 1

    vp = hn | ~(d0 | hp)
    vn = hp & d0
}

return score
```

This makes for a very fast algorithm. However, there are two notable areas for
improvement. Firstly, if `m < w`, then there is no speedup if `m` becomes
smaller. This means that small strings (often very important in bioinformatics)
are no faster than a `w`-char string. Secondly, the addition and shift 
operations complicate a SIMD implementation. A SIMD approach is desirable, since
this would allow a much larger `w` and hence more computation. However, these
operations require a single `w`-bit integer, not many smaller packed integers
within a `w`-bit register. Instructions for these operations do not natively
exist. While this logic can be fairly easily emulated, it has nonetheless
complicated existing implementations enough such that SIMD has been largely 
avoided. Furthermore, because both the emulated addition and shift steps would 
require expensive operations between SIMD lanes, this adds a substantial latency 
penalty compared to the rest of the loop (and this code is typically latency 
bound).

`fasted`'s approach differs by instead of processing `w` bits of a column from 
a single string, it tackles the case where you have `w` different strings that 
you want to compare to one or more strings all together, and hence computes `1`
bit from each column across `w` different string comparisons at once. This leads
to a substantially simpler mainloop that is roughly:

```c
// Algorithm: update the cells as part of the mainloop.
// Input: vp, vn, hp, hn, eq.
// Output: vp_new, vn_new, hp_new, hn_new.
//
// This forms the entire body of the mainloop. The actual looping logic, 
// starting conditions, score counting and peq construction are omitted for 
// simplicity.

d0 = eq | vn | hn

hp_new = vn | ~(d0 & vp)
hn_new = vp & d0

vp_new = hn | ~(d0 & hp)
vn_new = hp & d0

return vp_new, vn_new, hp_new, hn_new
```

This is a much faster implementation that requires no addition or shifting,
making it far more SIMD-friendly. A few components of the algorithm are omitted
above, but this is the actual consequential code that runs in the mainloop, and
it is clear that far fewer instructions are needed here than in the original.
In fact, the above sequence requires only 3 `vpternlog` and 2 `vpand` 
instructions. It also is very amenable to unrolling (whereas the standard case
isn't as much), and therefore extra latency can be effectively hidden. On a Zen5
core, this can run at a theoretical maximum of one loop every 1.25 cycles with
AVX-512 (only with Granite Ridge; Strix Point is still double-pumping 256-bit
uops) for a throughput of 409.6 cell updates per cycle. Assuming a 5 GHz clock
(and otherwise optimal conditions), this is 2048 billion cell updates per second
per core. The fastest AVX-512 implementation of the original Myers formulation 
sits around 50 billion cell updates per second per core. `fasted` has been 
designed to approach this theoretical roofline as closely as possible. It is 
still WIP, but hopefully soon will show whether this target is reached. 

This approach also has an asymptotic improvement, achieving 
`O(m * n * ceil(k / w))`, where you have a batch of `k` strings to compare and
`w`-bit words. Therefore, in this special case of batched string comparisons,
the limitation of `m < w` having no effect on complexity is removed. For 
reference, comparing `k` strings with the original approach has complexity
`O(k * n * ceil(m / w))`. In many cases, particularly in bioinformatics, it
may be much easier to obtain large `k` than large `m`. When `k >> w`, the
complexity reduces to `O(k * m * n / w)`.

This method only attempts to solve the multiple comparison case and is 
particularly well suited for small to medium length strings. However, for a 
single long pairwise string comparison, `fasted` is extremely slow, as this 
effectively means that `k = 1` and we hence achieve complexity `O(m * n)`,
completely eliminating the benefit of bit-parallelism. Furthermore, the biggest
limiter here is the worse space complexity. While the standard Myers 
implementation can maintain a working set in `O(m / w)` space, `fasted` requires
`O(n * w)`, which is much larger. As the mainloop is extremely fast, we must 
load data from the working set rapidly. There is a complex register blocking 
system used to ameliorate this; however, we still require very high memory 
bandwidths, so high that the entire working set must ideally reside in L1/L2.
The moment it spills to shared L3/DRAM (L3 only in the case when there are 
multiple cores running the mainloop concurrently), the algorithm becomes 
strongly cache/memory bound and performance drops sharply. Hence again why this 
approach is well suited for short to medium strings that require only a small 
working set. For a 1 MiB L2, the approximate maximum tolerated string size is 
around 4096 characters. Beyond that, performance will suffer. Fortunately,
this is still sufficient for many cases in bioinformatics.

```
References:

G. Myers, A fast bit-vector algorithm for approximate string matching based on 
dynamic programming, J. ACM 46 (3) (1999) 395–415.
```

#### Development Timeline:

Hopefully to be finished over the next few weeks, as I find time outside of work
to complete this. I have spent a couple of months designing all algorithms in
advance, so its now just implementation.
