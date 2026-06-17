module main

import time

// Tiny non-cryptographic PRNG (xorshift64*) used only to shuffle play order.
// Shuffle quality here is cosmetic, not security-sensitive.

struct Rng {
mut:
	state u64
}

fn new_rng(seed u64) Rng {
	// xorshift's state must be non-zero.
	return Rng{
		state: seed ^ u64(0x9e3779b97f4a7c15)
	}
}

// rng_from_entropy seeds from the clock mixed with a stack address (varies per
// run thanks to ASLR). Good enough for a cosmetic shuffle.
fn rng_from_entropy() Rng {
	mut x := u64(0)
	addr := u64(voidptr(&x))
	t := u64(time.sys_mono_now())
	return new_rng(addr ^ (t * u64(0x9e3779b97f4a7c15)))
}

fn (mut r Rng) next() u64 {
	mut x := r.state
	x ^= x >> 12
	x ^= x << 25
	x ^= x >> 27
	r.state = x
	return x * u64(0x2545f4914f6cdd1d)
}

// below returns a uniform-ish integer in 0..n (returns 0 when n == 0). Modulo
// bias is irrelevant here.
fn (mut r Rng) below(n int) int {
	if n <= 0 {
		return 0
	}
	return int(r.next() % u64(n))
}

// permutation writes a Fisher-Yates shuffle of 0..out.len into `out`.
fn permutation(mut out []int, mut rng Rng) {
	for i in 0 .. out.len {
		out[i] = i
	}
	if out.len < 2 {
		return
	}
	mut i := out.len - 1
	for i >= 1 {
		j := rng.below(i + 1)
		out[i], out[j] = out[j], out[i]
		i--
	}
}
