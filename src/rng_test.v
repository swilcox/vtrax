module main

// Starter tests for the xorshift64* PRNG and the Fisher-Yates shuffle.

// Same seed must produce the same sequence (the shuffle relies on this).
fn test_rng_deterministic() {
	mut a := new_rng(12345)
	mut b := new_rng(12345)
	for _ in 0 .. 64 {
		assert a.next() == b.next()
	}
}

// Different seeds should not produce an identical first draw.
fn test_rng_seed_varies() {
	mut a := new_rng(1)
	mut b := new_rng(2)
	assert a.next() != b.next()
}

// below(n) stays in [0, n); non-positive n yields 0.
fn test_rng_below_range() {
	mut r := new_rng(0xdeadbeef)
	for _ in 0 .. 10000 {
		v := r.below(7)
		assert v >= 0 && v < 7
	}
	assert r.below(0) == 0
	assert r.below(-5) == 0
}

// permutation produces a genuine permutation of 0..len, and is deterministic.
fn test_permutation_is_valid() {
	n := 16
	mut out := []int{len: n}
	mut rng := new_rng(99)
	permutation(mut out, mut rng)

	mut seen := []bool{len: n}
	for v in out {
		assert v >= 0 && v < n
		assert !seen[v] // no duplicates
		seen[v] = true
	}
	for s in seen {
		assert s // every index present
	}

	// Same seed -> same permutation.
	mut out2 := []int{len: n}
	mut rng2 := new_rng(99)
	permutation(mut out2, mut rng2)
	assert out == out2
}

// Degenerate sizes must not panic and stay the identity.
fn test_permutation_small() {
	mut empty := []int{}
	mut r0 := new_rng(1)
	permutation(mut empty, mut r0)
	assert empty.len == 0

	mut one := []int{len: 1}
	mut r1 := new_rng(1)
	permutation(mut one, mut r1)
	assert one == [0]
}
