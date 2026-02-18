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
sits around 50 billion cell updates per second per core.

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
implementation can maintain a working set in `O(m)` space, `fasted` requires
`O(n * w)`, which is probably much larger. As the mainloop is extremely fast, we
must load data from the working set rapidly. There is a register tiling system
used to ameliorate this; however, we still require very high memory bandwidths,
so high that the entire working set must ideally reside in L1/L2. The moment it
spills to shared L3/DRAM (L3 only in the case when there are multiple cores
running the mainloop concurrently), the algorithm becomes strongly cache/memory
bound and performance drops sharply. Hence again why this approach is well
suited for short to medium strings that require only a small working set. For a
1 MiB L2, the approximate maximum tolerated string size is around 4096
characters. Beyond that, performance will suffer. Fortunately, this is still
sufficient for many cases in bioinformatics.

## Cell Transition Optimisation:

The configuration that computes the Levenshtein automaton in the fewest number 
of `vpternlogd` instructions utilises five such instructions. It is in fact
impossible to represent the update in any fewer, as can be shown via information
theory.

Consider the automaton cell transition: we input 18 states and output 9. This is
a transition from `log2(18) = 4.17` bits of information to `log2(9) = 3.17` 
bits. Notice that this transition is lossy and therefore that any past input 
or intermediate state from the computations of previous cells is fundamentally 
less informative in total to the current transition than the input we have to
the current cell. This point is minor, and possibly obvious, but simply proves
that the only state we should consider when trying to evaluate the automaton
transition optimally is the state input to the current cell alone.

Next, observe that `vpternlogd` accepts 3 bits of information and outputs 1 bit.
We can immediately see that a single `vpternlogd` could not accept the 4.17 bits
of information required to evaluate the cell. Furthermore, note that a minimum
of four bit-vectors are required to hold the 3.17 bits of output state from the
cell. As `vpternlogd` outputs only a single value, with 1 bit capacity, we can
set a lower bound that at least four `vpternlogd` instructions are required to 
calculate the cell transition.

Now, consider the actual cell transition logic:

```
Given: eq, hp, hn, vp, vn.

hp_out = vn | ~(eq | hn | vp)
hn_out = vp & (eq | hn)

vp_out = hn | ~(eq | vn | hp)
vn_out = hp & (eq | vn)

Return: hp_out, hn_out, vp_out, vn_out.
```

Both `hp_out` and `vp_out` are functions of four values and require 3.58 bits of
information to compute (hp/hn and vp/vn are mutually exclusive and therefore
each pair has 1.58 bits of entropy, not 2 bits). This exceeds what a single
`vpternlogd` can ever compute and therefore said instruction cannot calculate 
either `hp_out` or `vp_out` from the initial cell state and must require some 
intermediate value that condenses some of the information. Note, however, that
such an intermediate itself would require a `vpternlogd` instruction to 
compute. Therefore, in any system of four `vpternlogd` instructions capable of
computing the cell transition, such an intermediate would have to be the value
`hn_out` for `hp_out` and `vn_out` for `vp_out`. This is because the 
intermediate for `hp_out` in tandem with `hp_out` itself, must contain 1.58 bits
of information towards representing the collective state of `hp_out` and 
`hn_out`. Of course, the only intermediate value capable of doing this is 
`hn_out` itself. This logic applies equivalently to `vp_out` and `vn_out`. 
However, observe the value of `hn_out` when vp is equal to zero:

```
When vp = 0:

hn_out = 0 & (eq | hn)
       = 0 & (...)
       = 0.
```

In the case when vp is equal to zero, the information from both eq and hn is
lost, and `hn_out` becomes no more informative than vp alone. Therefore, in this
worst-case scenario, `hn_out` is a function that maps 1 bit of information to 1
bit of information, and therefore cannot be our intermediate to calculate
`hp_out` because it does not condense any more useful information than already
available into the intermediate when `vp = 0`. Therefore, if `hn_out` is the 
only possible intermediate that would also emit all required output state from
the cell, but cannot possibly be used as an intermediate to calculate `hp_out`,
then there exists no possible intermediate that satisfies both conditions.
Equivalent logic applies perfectly for the `vp_out`/`vn_out` case. Hence there
exists no possible four `vpternlogd` instruction system that can calculate the
cell transition. Proof by contradiction, Q.E.D.

We can immediately prove the existence of a 5 `vpternlogd` instruction system 
with a working example:

```
Given: eq, hp, hn, vp, vn.

d0 = eq | hn | vn

hp_out = vn | ~(d0 | vp)
hn_out = vp & d0

vp_out = hn | ~(d0 | hp)
vn_out = hp & d0

Return: hp_out, hn_out, vp_out, vn_out.
```

We use the common intermediate d0 to calculate each output bit-vector as a 
function of three or less bits per `vpternlogd`. This implementation is valid.
Note the trick used in calculating d0: as vp/vn and hp/hn are mutually
exclusive, the relevant hn/vn will perfectly cancel out in the equation it is
not meant to be in and has no effect on the cell output, while allowing the
calculation of a single shared intermediate. One technical note: both `hn_out`
and `vn_out` should be calculated with `vpandd` instead of `vpternlogd` because
they only require two input operands, and a Zen5 core only has 10 data ports,
which we would exceed with 5x `vpternlogd`. Finally, as Ukkonen has already
proven the Levenshtein automaton as optimal, and no four `vpternlogd` system
exists, it follows that this cell transition kernel is also proven optimal.

## Preliminary Benchmarks:

While the theoretical limit for a Zen5 Granite Ridge CPU might be 512 cell 
updates every 1.25c (assuming that all FP0123 pipes are filled with bitwise
logical uops every cycle), it appears this is not possible due to Zen5's data
port limitation. Zen5 has 10 data ports that supply EUs with register values
from the VRF, and hence can supply 10 unique 512b values per cycle. Notably,
uops in the EUs on the same cycle requiring the same register value can elide
duplicate reads to the VRF and use a single data port.

A mainloop block consists of 3x `vpternlogd` and 2x `vpandd` instructions, the
former taking 3 inputs and the latter taking 2. This is 13 VRF reads per block
update, and executed every 1.25c, that is on average 10.4 reads per cycle. Of
course, this exceeds the available number of VRF reads the 10 data ports can
supply. Furthermore, the number of VRF reads possible is integer, and if a uop
cannot obtain enough data ports to make all its required VRF reads, it
(I believe) stalls in the EU for a cycle, wasting the EU slot and leaving some
data ports unused. Therefore, even though 10.4 is only slightly over 10, the
real disruption to uop execution is actually much greater. Now, within a block
update, some inputs are re-used multiple times, possibly allowing eliding
duplicate reads. However, because we maintain our register tiling setup, and
each of the 8x unrolled blocks have independent inputs and execution, the
schedulers appear to be drawing uops at random from all 8 available blocks
(i.e. OoO execution), rather than evaluating each block in order. Therefore, it
is increasingly unlikely that two uops from the same block which share the same
inputs that could elide a VRF read are executed at the same time. This
scrambling of uops worsens the larger our unroll in the register tiling system
is, because there is more independent work to draw from at random.

Of course, the tiling system is imperative to reduce L1D cache accesses which
would otherwise bottleneck throughput; if each block were to load its five input
bit-vectors from L1D, then we'd need to load 320 bytes and store 256 bytes back
every block (in practice you could maintain a vp/vn or hp/hn pair in registers
since, depending on the order of matrix evaluation, one pair is immediately used
in the calculation of the next block). Even if forcing uops from the same block
to be evaluated simultaneously this way theoretically could yield a 1.25c
throughput, you of course cannot read 320 bytes from and write 256 bytes to L1D
every 1.25c! You would be completely bottlenecked by FP45 throughput (per cycle:
128B read / 64B read, 64B store). Furthermore, if the working set exceeded L1D
and spilled into L2, which is likely at all but the smallest target strings
(approximately when `n > 96-128`), then you would become even further
bottlenecked by the 64B datapath between L1 and L2. Lion Cove has slightly more
throughput here, but it still is far too slow (and not that AVX-512 on Lion Cove
is even available until Diamond Rapids anyway).

Overall, it remains fastest to keep the 8x block unroll to combat cache
throughput limitations and accept the VRF data port issue as a final unavoidable 
bottleneck. My measurements show a block update completing in ~1.75c on average.
This is still extremely fast: 293 cell updates per cycle, or with a 5 GHz clock,
about 1463 GCUPS per core. This is still two orders-of-magnitude times faster
than `edlib`, the field standard, but slower than the predicted 2048 GCUPS per 
core theoretical maximum.

The only feasible way I can see getting around this is to controllably neuter
OoO execution just enough to encourage uops from the same block to execute
simultaneously, but not enough to butcher ILP. All without actually reducing the
unroll size and leaving the register tile system intact. Adding false 
dependencies between blocks kills performance, even between every other block or
every four. The mainloop runs out of the uop cache, meaning decode pressure is a
non-issue, so I tried adding NOPs to attempt to fill up the schedulers and
inhibit OoO execution somewhat (by shrinking the pool of ready macro-ops; this
is a trick AMD recommended for benchmarking the true 1c latency of SIMD
instructions on Zen5 cores as it prevents a CPU hazard; I figured the same
principle could work here). Interestingly, adding a few NOPs did not degrade
performance, albeit it did not improve it. Adding more noticeably worsened
throughput. The vector NSQ probably complicates this since macro-ops can be
drawn from that roughly at random into the renamers, scrambling the desired
execution order. Adding junk register moves to bottleneck vector rename slots
only degraded performance, probably because it prevented moving proper logical
macro-ops to the schedulers from the NSQ (the IPC is high enough that we are 
nearly filling all 6 rename slots natively anyway). Adding junk integer domain
instructions to take dispatch slots (and thereby prevent issuing vector
macro-ops to the NSQ) was only detrimental to performance. Overall, right now I
cannot see a way to remedy the VRF data port issue and unlock the theoretical 
1.25c throughput. If it is possible, it could improve performance by up to 40%.

In terms of general benchmarked statistics, the mainloop is currently reaching
6 IPC, there is negligible frontend pressure (decode and dispatch are all good),
the schedulers are always full (since we run out of the uop cache this is 
unsurprising), and we're within retire width. The one nice thing about not 
de-duplicating VRF reads is that it means there is more unique data in-flight
at any given time. In fact, there is just about 1 KiB of new data in-flight
between the EUs and the VRF / integer PRF every cycle, which is pretty
incredible.

```
References:
AMD, Software Optimization Guide for the AMD Zen 5 Microarchitecture,
(2024). https://docs.amd.com/v/u/en-US/58455_1.00.

G. Myers, A fast bit-vector algorithm for approximate string matching based on 
dynamic programming, J. ACM 46 (3) (1999) 395–415.

Ukkonen. E, Finding approximate patterns in strings, Journal of Algorithms, 
6(1) (1985) 132–137.
```

#### Development Timeline:

Hopefully to be finished over the next few weeks, as I find time outside of work
to complete this. I have spent a couple of months designing all algorithms in
advance, so its now just implementation.
