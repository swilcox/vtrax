module main

// A bounded, lock-free single-producer/single-consumer ring buffer.
//
// Used for the three audio<->UI hand-offs that must never block the audio
// callback: command delivery (UI->audio), old-module drops (audio->UI, so the
// callback never frees), and decimated mono samples for the FFT (audio->UI).
//
// `head`/`tail` are monotonically increasing indices (they never wrap in any
// realistic runtime), so emptiness is `head == tail` and fullness is
// `tail - head == capacity`.

@[heap]
struct Spsc[T] {
mut:
	buf  []T
	cap  u64
	head u64 // next index the consumer reads
	tail u64 // next index the producer writes
}

fn new_spsc[T](capacity int) &Spsc[T] {
	return &Spsc[T]{
		buf: []T{len: capacity}
		cap: u64(capacity)
	}
}

// push is the producer side. Returns false if the ring is full (item dropped).
fn (mut r Spsc[T]) push(item T) bool {
	tail := C.vtx_load_u64(&r.tail)
	head := C.vtx_load_u64_acq(&r.head)
	if tail - head >= r.cap {
		return false
	}
	r.buf[int(tail % r.cap)] = item
	C.vtx_store_u64_rel(&r.tail, tail + 1)
	return true
}

// pop is the consumer side. Returns none if the ring is empty.
fn (mut r Spsc[T]) pop() ?T {
	head := C.vtx_load_u64(&r.head)
	tail := C.vtx_load_u64_acq(&r.tail)
	if head == tail {
		return none
	}
	item := r.buf[int(head % r.cap)]
	C.vtx_store_u64_rel(&r.head, head + 1)
	return item
}

fn (mut r Spsc[T]) is_empty() bool {
	return C.vtx_load_u64_acq(&r.head) == C.vtx_load_u64_acq(&r.tail)
}
