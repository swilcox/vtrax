module main

// Level-meter envelopes. The audio thread publishes raw VU / master-peak
// values; the UI applies a fast-attack, linear-decay envelope with peak-hold
// here. Peak-hold is counted in UI frames (~30 fps, so 45 frames ~= 1.5 s).

const peak_hold_frames = u32(45)
const peak_fall_per_frame = f32(0.02)
const channel_decay = f32(0.10) // ~30 dB/sec at 30 fps
const master_decay = f32(0.06)  // slower -- more like a VU

struct Envelope {
mut:
	smoothed f32
	peak     f32
	hold     u32
}

// step advances one frame toward `v`. `decay` is the linear fall per frame
// while the signal drops; the peak marker holds, then falls once the hold
// lapses.
fn (mut e Envelope) step(v_in f32, decay f32) {
	v := clampf(v_in, 0.0, 1.0)
	e.smoothed = if v >= e.smoothed { v } else { maxf(e.smoothed - decay, v) }
	if e.smoothed >= e.peak {
		e.peak = e.smoothed
		e.hold = peak_hold_frames
	} else if e.hold > 0 {
		e.hold--
	} else {
		e.peak = maxf(e.peak - peak_fall_per_frame, e.smoothed)
	}
}

// Per-channel L/R envelopes, resized to the live channel count.
struct MeterState {
mut:
	left  []Envelope
	right []Envelope
}

fn (mut m MeterState) step(state &SharedState) {
	n := imax(0, state.get_num_channels())
	if m.left.len != n {
		// Channel count only changes on song load; reset to silent.
		m.left = []Envelope{len: n}
		m.right = []Envelope{len: n}
	}
	for ch in 0 .. n {
		l, r := state.vu(ch)
		m.left[ch].step(l, channel_decay)
		m.right[ch].step(r, channel_decay)
	}
}

fn (m &MeterState) left_env(ch int) Envelope {
	return if ch >= 0 && ch < m.left.len { m.left[ch] } else { Envelope{} }
}

fn (m &MeterState) right_env(ch int) Envelope {
	return if ch >= 0 && ch < m.right.len { m.right[ch] } else { Envelope{} }
}

// Master output L/R envelopes.
struct MasterMeterState {
mut:
	left  Envelope
	right Envelope
}

fn (mut m MasterMeterState) step(state &SharedState) {
	pl, pr := state.master_peak()
	m.left.step(pl, master_decay)
	m.right.step(pr, master_decay)
}
