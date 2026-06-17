module main

// Lock-free state shared between the audio callback and the UI thread.
//
// Discipline (ported from ztrax/rtrax): the audio callback only *writes* these
// atomics; the UI only *reads* them. Every field is a plain integer accessed
// through the C atomic helpers; float/int/bool values are bit-cast through the
// integer slots. Module metadata and the pattern cache are NOT here — they are
// owned by the UI thread and never touched by the audio callback.

// Cap on how many per-channel meter slots we publish.
const max_channels = 128

@[heap]
struct SharedState {
mut:
	playing u32 // bool (0/1)
	stopped u32 // bool (0/1), starts true
	eof     u32 // bool (0/1)

	sample_rate          u32
	master_gain_millibel u32 // i32 bits

	num_channels            u32 // i32 bits
	num_orders              u32 // i32 bits
	current_order           u32 // i32 bits
	current_pattern         u32 // i32 bits
	current_row             u32 // i32 bits
	current_rows_in_pattern u32 // i32 bits
	current_speed           u32 // i32 bits
	current_tempo_bits      u32 // f32 bits

	position_secs_bits u64 // f64 bits
	duration_secs_bits u64 // f64 bits

	// Per-channel VU. Slots 2*i / 2*i+1 are left/right for channel i (f32 bits).
	vu_bits [256]u32 // max_channels * 2

	master_peak_l_bits u32 // f32 bits in [0,1]
	master_peak_r_bits u32 // f32 bits in [0,1]

	// Most-recent non-empty instrument number seen per channel (1-based; 0 =
	// unseen). Sticky across rows.
	last_instrument [128]u32 // i32 bits

	// Incremented every time the audio thread moves to a new row/pattern.
	row_generation u64
}

fn new_shared_state() &SharedState {
	s := &SharedState{
		stopped:     1
		sample_rate: 48000
	}
	return s
}

// --- bit-cast helpers -------------------------------------------------------

fn f32_to_bits(f f32) u32 {
	return unsafe { *(&u32(&f)) }
}

fn bits_to_f32(b u32) f32 {
	mut v := b
	return unsafe { *(&f32(&v)) }
}

fn f64_to_bits(f f64) u64 {
	return unsafe { *(&u64(&f)) }
}

fn bits_to_f64(b u64) f64 {
	mut v := b
	return unsafe { *(&f64(&v)) }
}

// --- typed atomic field accessors -------------------------------------------

fn (s &SharedState) get_playing() bool {
	return C.vtx_load_u32(&s.playing) != 0
}

fn (mut s SharedState) set_playing(v bool) {
	C.vtx_store_u32(&s.playing, if v { u32(1) } else { u32(0) })
}

fn (s &SharedState) get_stopped() bool {
	return C.vtx_load_u32(&s.stopped) != 0
}

fn (mut s SharedState) set_stopped(v bool) {
	C.vtx_store_u32(&s.stopped, if v { u32(1) } else { u32(0) })
}

fn (s &SharedState) get_eof() bool {
	return C.vtx_load_u32(&s.eof) != 0
}

fn (mut s SharedState) set_eof(v bool) {
	C.vtx_store_u32(&s.eof, if v { u32(1) } else { u32(0) })
}

// swap_eof atomically reads eof and clears it; returns the old value.
fn (mut s SharedState) swap_eof(v bool) bool {
	old := C.vtx_swap_u32(&s.eof, if v { u32(1) } else { u32(0) })
	return old != 0
}

fn (s &SharedState) get_sample_rate() u32 {
	return C.vtx_load_u32(&s.sample_rate)
}

fn (mut s SharedState) set_sample_rate(v u32) {
	C.vtx_store_u32(&s.sample_rate, v)
}

fn (s &SharedState) get_master_gain_millibel() int {
	return int(C.vtx_load_u32(&s.master_gain_millibel))
}

fn (mut s SharedState) set_master_gain_millibel(v int) {
	C.vtx_store_u32(&s.master_gain_millibel, u32(v))
}

fn (s &SharedState) get_num_channels() int {
	return int(C.vtx_load_u32(&s.num_channels))
}

fn (mut s SharedState) set_num_channels(v int) {
	C.vtx_store_u32(&s.num_channels, u32(v))
}

fn (s &SharedState) get_num_orders() int {
	return int(C.vtx_load_u32(&s.num_orders))
}

fn (mut s SharedState) set_num_orders(v int) {
	C.vtx_store_u32(&s.num_orders, u32(v))
}

fn (s &SharedState) get_current_order() int {
	return int(C.vtx_load_u32(&s.current_order))
}

fn (mut s SharedState) set_current_order(v int) {
	C.vtx_store_u32(&s.current_order, u32(v))
}

fn (s &SharedState) get_current_pattern() int {
	return int(C.vtx_load_u32(&s.current_pattern))
}

fn (mut s SharedState) set_current_pattern(v int) {
	C.vtx_store_u32(&s.current_pattern, u32(v))
}

fn (s &SharedState) get_current_row() int {
	return int(C.vtx_load_u32(&s.current_row))
}

fn (mut s SharedState) set_current_row(v int) {
	C.vtx_store_u32(&s.current_row, u32(v))
}

fn (s &SharedState) get_current_rows_in_pattern() int {
	return int(C.vtx_load_u32(&s.current_rows_in_pattern))
}

fn (mut s SharedState) set_current_rows_in_pattern(v int) {
	C.vtx_store_u32(&s.current_rows_in_pattern, u32(v))
}

fn (s &SharedState) get_current_speed() int {
	return int(C.vtx_load_u32(&s.current_speed))
}

fn (mut s SharedState) set_current_speed(v int) {
	C.vtx_store_u32(&s.current_speed, u32(v))
}

fn (s &SharedState) get_tempo() f32 {
	return bits_to_f32(C.vtx_load_u32(&s.current_tempo_bits))
}

fn (mut s SharedState) set_tempo(bpm f32) {
	C.vtx_store_u32(&s.current_tempo_bits, f32_to_bits(bpm))
}

fn (s &SharedState) get_position_secs() f64 {
	return bits_to_f64(C.vtx_load_u64(&s.position_secs_bits))
}

fn (mut s SharedState) set_position_secs(v f64) {
	C.vtx_store_u64(&s.position_secs_bits, f64_to_bits(v))
}

fn (s &SharedState) get_duration_secs() f64 {
	return bits_to_f64(C.vtx_load_u64(&s.duration_secs_bits))
}

fn (mut s SharedState) set_duration_secs(v f64) {
	C.vtx_store_u64(&s.duration_secs_bits, f64_to_bits(v))
}

// --- VU ---------------------------------------------------------------------

fn (mut s SharedState) set_vu(channel int, left f32, right f32) {
	if channel < 0 || channel >= max_channels {
		return
	}
	C.vtx_store_u32(&s.vu_bits[channel * 2], f32_to_bits(left))
	C.vtx_store_u32(&s.vu_bits[channel * 2 + 1], f32_to_bits(right))
}

fn (s &SharedState) vu(channel int) (f32, f32) {
	if channel < 0 || channel >= max_channels {
		return 0, 0
	}
	l := bits_to_f32(C.vtx_load_u32(&s.vu_bits[channel * 2]))
	r := bits_to_f32(C.vtx_load_u32(&s.vu_bits[channel * 2 + 1]))
	return l, r
}

fn (mut s SharedState) set_master_peak(left f32, right f32) {
	C.vtx_store_u32(&s.master_peak_l_bits, f32_to_bits(left))
	C.vtx_store_u32(&s.master_peak_r_bits, f32_to_bits(right))
}

fn (s &SharedState) master_peak() (f32, f32) {
	l := bits_to_f32(C.vtx_load_u32(&s.master_peak_l_bits))
	r := bits_to_f32(C.vtx_load_u32(&s.master_peak_r_bits))
	return l, r
}

// --- sticky instruments -----------------------------------------------------

fn (mut s SharedState) set_last_instrument(channel int, instrument int) {
	if channel >= 0 && channel < max_channels {
		C.vtx_store_u32(&s.last_instrument[channel], u32(instrument))
	}
}

fn (s &SharedState) last_instrument(channel int) int {
	if channel >= 0 && channel < max_channels {
		return int(C.vtx_load_u32(&s.last_instrument[channel]))
	}
	return 0
}

fn (mut s SharedState) clear_last_instruments() {
	for i in 0 .. max_channels {
		C.vtx_store_u32(&s.last_instrument[i], 0)
	}
}

// --- row generation ---------------------------------------------------------

fn (mut s SharedState) inc_row_generation() {
	C.vtx_add_u64(&s.row_generation, 1)
}

fn (s &SharedState) get_row_generation() u64 {
	return C.vtx_load_u64(&s.row_generation)
}
