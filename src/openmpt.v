module main

import os

// Thin V wrapper over libopenmpt's C API. Owns an opaque `openmpt_module*`.
// Modules are loaded from an in-memory copy of the file (libopenmpt copies what
// it needs during parse). C strings returned by libopenmpt are heap-allocated
// and freed here immediately after copying into V strings.

struct Module {
mut:
	handle voidptr
}

// load_module_from_memory loads a module from raw file bytes. The bytes are not
// retained — the caller may free them after this returns.
fn load_module_from_memory(data []u8) ?Module {
	handle := C.openmpt_module_create_from_memory2(data.data, usize(data.len), unsafe { nil },
		unsafe { nil }, unsafe { nil }, unsafe { nil }, unsafe { nil }, unsafe { nil },
		unsafe { nil })
	if handle == unsafe { nil } {
		return none
	}
	return Module{
		handle: handle
	}
}

// load_module_from_path reads the whole file into memory and loads it.
fn load_module_from_path(path string) ?Module {
	data := os.read_bytes(path) or { return none }
	return load_module_from_memory(data)
}

fn (m Module) destroy() {
	if m.handle != unsafe { nil } {
		C.openmpt_module_destroy(m.handle)
	}
}

// --- Rendering --------------------------------------------------------------

// read_stereo renders up to `count` stereo frames into `interleaved`
// (length >= count*2). Returns the number of frames actually rendered; 0 means
// end of song.
fn (m Module) read_stereo(sample_rate int, count int, interleaved &f32) int {
	return int(C.openmpt_module_read_interleaved_float_stereo(m.handle, sample_rate, usize(count),
		interleaved))
}

// --- Transport / position ---------------------------------------------------

fn (m Module) duration_seconds() f64 {
	return C.openmpt_module_get_duration_seconds(m.handle)
}

fn (m Module) position_seconds() f64 {
	return C.openmpt_module_get_position_seconds(m.handle)
}

fn (m Module) set_position_seconds(seconds f64) {
	C.openmpt_module_set_position_seconds(m.handle, seconds)
}

fn (m Module) set_render_param(param int, value int) {
	C.openmpt_module_set_render_param(m.handle, param, value)
}

// --- Live position state ----------------------------------------------------

fn (m Module) current_order() int {
	return C.openmpt_module_get_current_order(m.handle)
}

fn (m Module) current_pattern() int {
	return C.openmpt_module_get_current_pattern(m.handle)
}

fn (m Module) current_row() int {
	return C.openmpt_module_get_current_row(m.handle)
}

fn (m Module) current_speed() int {
	return C.openmpt_module_get_current_speed(m.handle)
}

fn (m Module) current_tempo() f64 {
	return C.openmpt_module_get_current_tempo2(m.handle)
}

fn (m Module) channel_vu_left(channel int) f32 {
	return C.openmpt_module_get_current_channel_vu_left(m.handle, channel)
}

fn (m Module) channel_vu_right(channel int) f32 {
	return C.openmpt_module_get_current_channel_vu_right(m.handle, channel)
}

// --- Structure --------------------------------------------------------------

fn (m Module) num_channels() int {
	return C.openmpt_module_get_num_channels(m.handle)
}

fn (m Module) num_orders() int {
	return C.openmpt_module_get_num_orders(m.handle)
}

fn (m Module) num_patterns() int {
	return C.openmpt_module_get_num_patterns(m.handle)
}

fn (m Module) num_instruments() int {
	return C.openmpt_module_get_num_instruments(m.handle)
}

fn (m Module) num_samples() int {
	return C.openmpt_module_get_num_samples(m.handle)
}

fn (m Module) pattern_num_rows(pattern int) int {
	return C.openmpt_module_get_pattern_num_rows(m.handle, pattern)
}

// --- Metadata / names (returns owned V strings) -----------------------------

// metadata returns the value for `key` ("title", "type_long", "message",
// "artist", "tracker", ...). Empty string if the key is absent.
fn (m Module) metadata(key string) string {
	raw := C.openmpt_module_get_metadata(m.handle, &char(key.str))
	return dupe_and_free(raw)
}

fn (m Module) sample_name(index int) string {
	raw := C.openmpt_module_get_sample_name(m.handle, index)
	return dupe_and_free(raw)
}

fn (m Module) instrument_name(index int) string {
	raw := C.openmpt_module_get_instrument_name(m.handle, index)
	return dupe_and_free(raw)
}

// format_cell returns the pre-formatted text for one pattern cell
// (e.g. "C-5 01 v32 A20"), copied into an owned V string.
fn (m Module) format_cell(pattern int, row int, channel int) string {
	raw := C.openmpt_module_format_pattern_row_channel(m.handle, pattern, row, channel,
		usize(0), false)
	return dupe_and_free(raw)
}

// cell_command returns the numeric value of a single command for one cell.
fn (m Module) cell_command(pattern int, row int, channel int, command int) int {
	return int(C.openmpt_module_get_pattern_row_channel_command(m.handle, pattern, row,
		channel, command))
}

// dupe_and_free copies a libopenmpt-allocated C string into an owned V string,
// then frees the C original. A null pointer becomes an empty string.
fn dupe_and_free(raw &char) string {
	if raw == unsafe { nil } {
		return ''
	}
	s := unsafe { cstring_to_vstring(raw) }
	C.openmpt_free_string(raw)
	return s
}
