module main

// Starter tests for the bounded single-producer/single-consumer ring buffer.
// These run single-threaded; they exercise the FIFO contract, not concurrency.

fn test_spsc_empty() {
	mut r := new_spsc[int](4)
	assert r.is_empty()
	if _ := r.pop() {
		assert false // pop on empty must return none
	}
}

fn test_spsc_fifo_order() {
	mut r := new_spsc[int](4)
	assert r.push(10)
	assert r.push(20)
	assert r.push(30)
	assert !r.is_empty()
	assert r.pop()? == 10
	assert r.pop()? == 20
	assert r.pop()? == 30
	assert r.is_empty()
}

fn test_spsc_full_drops() {
	mut r := new_spsc[int](2)
	assert r.push(1)
	assert r.push(2)
	assert !r.push(3) // ring full -> dropped
	assert r.pop()? == 1
	assert r.push(3) // space freed -> accepted
	assert r.pop()? == 2
	assert r.pop()? == 3
	assert r.is_empty()
}

// Interleaved push/pop past the capacity exercises the modulo index wrap.
fn test_spsc_wraparound() {
	mut r := new_spsc[int](3)
	for round in 0 .. 100 {
		assert r.push(round)
		assert r.push(round + 1000)
		assert r.pop()? == round
		assert r.pop()? == round + 1000
		assert r.is_empty()
	}
}
