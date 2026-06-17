module main

// Audio thread. Owns the openmpt Module and the miniaudio playback device.
//
// The miniaudio data callback (real-time critical, runs as the V function
// `vtrax_fill`):
//  - decodes interleaved f32 stereo straight into the output buffer,
//  - pushes a downsampled mono copy into the FFT ring,
//  - reads per-channel VU from libopenmpt into shared atomics,
//  - updates order/row/BPM/speed atomics,
//  - maintains sticky per-channel instrument state.
//
// Commands (Load/Play/Pause/Stop/Seek/Volume) arrive over a lock-free SPSC ring
// drained at the top of each buffer. The old module from a Load is handed back
// over the drop ring and destroyed on the UI thread -- the callback never
// frees. Inside the callback: no allocation, no locks, no logging.

// Mono samples pushed into the FFT ring per second (after downsampling).
const fft_ring_rate_hz = u32(12000)
// FFT ring capacity (mono f32 samples).
const fft_ring_capacity = 8192

enum CommandKind {
	load
	play
	pause
	stop
	seek_relative
	volume_millibel
}

struct Command {
	kind     CommandKind
	module_  Module
	seek     f32
	millibel int
}

// All state the callback owns and mutates. Heap-allocated so its address is
// stable for the lifetime of the miniaudio stream (passed as `pUserData`).
@[heap]
struct Callback {
mut:
	state                 &SharedState
	commands              &Spsc[Command]
	drops                 &Spsc[Module]
	fft                   &Spsc[f32]
	sample_rate           u32
	has_module            bool
	module_               Module
	downsample_accum      u32
	last_snapshot_row     int = -1
	last_snapshot_pattern int = -1
}

// vtrax_fill is the miniaudio data callback, invoked from miniaudio's audio
// thread. It must not allocate, lock, or log.
@[export: 'vtrax_fill']
fn vtrax_fill(userdata voidptr, output &f32, frames u32, sample_rate u32) {
	mut cb := unsafe { &Callback(userdata) }
	cb.fill(output, int(frames))
}

fn (mut cb Callback) fill(output &f32, frames int) {
	for {
		cmd := cb.commands.pop() or { break }
		cb.apply_command(cmd)
	}

	unsafe {
		for i in 0 .. frames * 2 {
			output[i] = 0
		}
	}

	if !cb.has_module {
		return
	}
	if !cb.state.get_playing() {
		return
	}

	rendered := cb.module_.read_stereo(int(cb.sample_rate), frames, output)
	if rendered == 0 {
		cb.state.set_eof(true)
		cb.state.set_playing(false)
		return
	}

	cb.publish_master_peak(output, rendered)
	cb.push_to_fft(output, rendered)
	cb.publish_state()
	cb.publish_last_instruments()
}

fn (mut cb Callback) apply_command(cmd Command) {
	match cmd.kind {
		.load {
			old_has := cb.has_module
			old := cb.module_
			cb.module_ = cmd.module_
			cb.has_module = true
			cb.state.set_playing(true)
			cb.state.set_stopped(false)
			cb.state.set_eof(false)
			if old_has {
				cb.drops.push(old)
			}
			cb.state.clear_last_instruments()
			cb.last_snapshot_row = -1
			cb.last_snapshot_pattern = -1
		}
		.play {
			if cb.has_module {
				cb.state.set_playing(true)
				cb.state.set_stopped(false)
			}
		}
		.pause {
			cb.state.set_playing(false)
		}
		.stop {
			cb.state.set_playing(false)
			cb.state.set_stopped(true)
			if cb.has_module {
				cb.module_.set_position_seconds(0.0)
			}
			for ch in 0 .. max_channels {
				cb.state.set_vu(ch, 0, 0)
			}
			cb.state.set_master_peak(0, 0)
			cb.state.clear_last_instruments()
		}
		.seek_relative {
			if cb.has_module {
				now := cb.module_.position_seconds()
				next := if now + f64(cmd.seek) > 0.0 { now + f64(cmd.seek) } else { 0.0 }
				cb.module_.set_position_seconds(next)
			}
		}
		.volume_millibel {
			if cb.has_module {
				cb.module_.set_render_param(openmpt_render_mastergain_millibel, cmd.millibel)
			}
			cb.state.set_master_gain_millibel(cmd.millibel)
		}
	}
}

fn (mut cb Callback) publish_master_peak(stereo &f32, frames int) {
	mut peak_l := f32(0)
	mut peak_r := f32(0)
	unsafe {
		for i in 0 .. frames {
			l := absf(stereo[i * 2])
			r := absf(stereo[i * 2 + 1])
			if l > peak_l {
				peak_l = l
			}
			if r > peak_r {
				peak_r = r
			}
		}
	}
	cb.state.set_master_peak(minf(peak_l, 1.0), minf(peak_r, 1.0))
}

// push_to_fft pushes a downsampled mono copy into the FFT ring via a
// phase-accumulator decimator from the audio rate to fft_ring_rate_hz.
fn (mut cb Callback) push_to_fft(stereo &f32, frames int) {
	unsafe {
		for i in 0 .. frames {
			cb.downsample_accum += fft_ring_rate_hz // wraps on overflow, like ztrax's +%=
			if cb.downsample_accum >= cb.sample_rate {
				cb.downsample_accum -= cb.sample_rate
				mono := (stereo[i * 2] + stereo[i * 2 + 1]) * 0.5
				if !cb.fft.push(mono) {
					return
				}
			}
		}
	}
}

fn (mut cb Callback) publish_state() {
	m := cb.module_
	order := m.current_order()
	pat := m.current_pattern()
	row := m.current_row()

	prev_row := cb.state.get_current_row()
	prev_pat := cb.state.get_current_pattern()
	if row != prev_row || pat != prev_pat {
		cb.state.inc_row_generation()
	}

	cb.state.set_current_order(order)
	cb.state.set_current_pattern(pat)
	cb.state.set_current_row(row)
	cb.state.set_current_speed(m.current_speed())
	cb.state.set_tempo(f32(m.current_tempo()))
	cb.state.set_position_secs(m.position_seconds())
	cb.state.set_duration_secs(m.duration_seconds())

	nch := imax(0, m.num_channels())
	cb.state.set_num_channels(nch)
	mut ch := 0
	for ch < imin(nch, max_channels) {
		l := m.channel_vu_left(ch)
		r := m.channel_vu_right(ch)
		cb.state.set_vu(ch, l, r)
		ch++
	}
	for ch < max_channels {
		cb.state.set_vu(ch, 0, 0)
		ch++
	}

	cb.state.set_num_orders(m.num_orders())
}

fn (mut cb Callback) publish_last_instruments() {
	m := cb.module_
	pat := m.current_pattern()
	row := m.current_row()
	if pat == cb.last_snapshot_pattern && row == cb.last_snapshot_row {
		return
	}
	pattern_changed := pat != cb.last_snapshot_pattern
	cb.last_snapshot_pattern = pat
	cb.last_snapshot_row = row

	num_channels := m.num_channels()
	num_rows := m.pattern_num_rows(pat)
	cb.state.set_current_rows_in_pattern(num_rows)

	// First time we see this pattern: walk every row up to the current one to
	// reconstruct each channel's last-seen instrument.
	if pattern_changed && num_rows > 0 {
		upto := imin(row, num_rows - 1)
		mut r := 0
		for r <= upto {
			cb.snapshot_row(m, pat, r, num_channels)
			r++
		}
	}
	cb.snapshot_row(m, pat, row, num_channels)
}

fn (mut cb Callback) snapshot_row(m Module, pat int, row int, num_channels int) {
	for ch in 0 .. num_channels {
		inst := m.cell_command(pat, row, ch, openmpt_command_instrument)
		if inst > 0 {
			cb.state.set_last_instrument(ch, inst)
		}
	}
}

// Handle to the running playback device.
@[heap]
struct Engine {
mut:
	cb     &Callback
	device voidptr
}

fn new_engine(state &SharedState) ?&Engine {
	mut cb := &Callback{
		state:       state
		commands:    new_spsc[Command](64)
		drops:       new_spsc[Module](64)
		fft:         new_spsc[f32](fft_ring_capacity)
		sample_rate: 48000
	}
	mut rate := u32(0)
	device := C.vtrax_device_create(cb, &rate)
	if device == unsafe { nil } {
		return none
	}
	// miniaudio fills in the negotiated rate; read it back for the decoder.
	cb.sample_rate = rate
	C.vtx_store_u32(&state.sample_rate, rate)
	return &Engine{
		cb:     cb
		device: device
	}
}

fn (mut e Engine) deinit() {
	// Stops the device and joins its backend thread, so no callback can run
	// after this returns.
	C.vtrax_device_destroy(e.device)
	if e.cb.has_module {
		e.cb.module_.destroy()
	}
	for {
		m := e.cb.drops.pop() or { break }
		m.destroy()
	}
}

// send delivers a command to the audio thread (non-blocking; dropped if the
// ring is full, which never happens in practice given the command cadence).
fn (mut e Engine) send(cmd Command) {
	e.cb.commands.push(cmd)
}

// drain_drops destroys any old modules the audio thread handed back. Called
// from the UI thread each frame, keeping frees off the callback.
fn (mut e Engine) drain_drops() {
	for {
		m := e.cb.drops.pop() or { break }
		m.destroy()
	}
}

fn (mut e Engine) fft_ring() &Spsc[f32] {
	return e.cb.fft
}
