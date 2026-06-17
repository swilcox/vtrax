module main

// Single C surface for the whole program: libopenmpt (module decoding) and
// miniaudio (audio output, vendored). Build flags, includes, and every `C.`
// declaration live here so the wiring is compiled once.

#pkgconfig --cflags --libs libopenmpt

#flag -I@VMODROOT/vendor
#flag @VMODROOT/vendor/ma.c
#flag @VMODROOT/vendor/atomics.c

// Homebrew installs the Boehm GC (libgc, which V links by default) under
// /opt/homebrew/lib, which isn't on clang's default library search path.
#flag darwin -L/opt/homebrew/lib

// CoreAudio family backs miniaudio's default playback backend on macOS.
#flag darwin -framework CoreFoundation
#flag darwin -framework CoreAudio
#flag darwin -framework AudioToolbox
// On Linux miniaudio dlopen's the ALSA/PulseAudio/JACK backends at runtime.
#flag linux -lpthread -lm -ldl

#include "libopenmpt/libopenmpt.h"
#include "miniaudio.h"
#include "vtrax.h"

// --- libopenmpt render-param + command constants ---------------------------

const openmpt_render_mastergain_millibel = C.OPENMPT_MODULE_RENDER_MASTERGAIN_MILLIBEL
const openmpt_command_note = C.OPENMPT_MODULE_COMMAND_NOTE
const openmpt_command_instrument = C.OPENMPT_MODULE_COMMAND_INSTRUMENT
const openmpt_command_volumeeffect = C.OPENMPT_MODULE_COMMAND_VOLUMEEFFECT
const openmpt_command_effect = C.OPENMPT_MODULE_COMMAND_EFFECT
const openmpt_command_volume = C.OPENMPT_MODULE_COMMAND_VOLUME
const openmpt_command_parameter = C.OPENMPT_MODULE_COMMAND_PARAMETER

// --- libopenmpt: load / lifetime -------------------------------------------

fn C.openmpt_module_create_from_memory2(filedata voidptr, filesize usize, logfunc voidptr, loguser voidptr, errfunc voidptr, erruser voidptr, error voidptr, error_message voidptr, ctls voidptr) voidptr
fn C.openmpt_module_destroy(handle voidptr)
fn C.openmpt_free_string(str &char)

// --- libopenmpt: rendering --------------------------------------------------

fn C.openmpt_module_read_interleaved_float_stereo(handle voidptr, samplerate int, count usize, interleaved_stereo &f32) usize

// --- libopenmpt: transport / position --------------------------------------

fn C.openmpt_module_get_duration_seconds(handle voidptr) f64
fn C.openmpt_module_get_position_seconds(handle voidptr) f64
fn C.openmpt_module_set_position_seconds(handle voidptr, seconds f64) f64
fn C.openmpt_module_set_render_param(handle voidptr, param int, value int) int

fn C.openmpt_module_get_current_order(handle voidptr) int
fn C.openmpt_module_get_current_pattern(handle voidptr) int
fn C.openmpt_module_get_current_row(handle voidptr) int
fn C.openmpt_module_get_current_speed(handle voidptr) int
fn C.openmpt_module_get_current_tempo2(handle voidptr) f64

fn C.openmpt_module_get_current_channel_vu_left(handle voidptr, channel int) f32
fn C.openmpt_module_get_current_channel_vu_right(handle voidptr, channel int) f32

// --- libopenmpt: structure --------------------------------------------------

fn C.openmpt_module_get_num_channels(handle voidptr) int
fn C.openmpt_module_get_num_orders(handle voidptr) int
fn C.openmpt_module_get_num_patterns(handle voidptr) int
fn C.openmpt_module_get_num_instruments(handle voidptr) int
fn C.openmpt_module_get_num_samples(handle voidptr) int
fn C.openmpt_module_get_pattern_num_rows(handle voidptr, pattern int) int

// --- libopenmpt: metadata / names (returns heap C strings) ------------------

fn C.openmpt_module_get_metadata(handle voidptr, key &char) &char
fn C.openmpt_module_get_sample_name(handle voidptr, index int) &char
fn C.openmpt_module_get_instrument_name(handle voidptr, index int) &char
fn C.openmpt_module_format_pattern_row_channel(handle voidptr, pattern int, row int, channel int, width usize, pad bool) &char
fn C.openmpt_module_get_pattern_row_channel_command(handle voidptr, pattern int, row int, channel int, command int) u8

// --- miniaudio device glue (vendor/ma.c) ------------------------------------

fn C.vtrax_device_create(userdata voidptr, out_rate &u32) voidptr
fn C.vtrax_device_destroy(dev voidptr)

// --- atomics (vendor/atomics.c) ---------------------------------------------

fn C.vtx_load_u32(p voidptr) u32
fn C.vtx_store_u32(p voidptr, v u32)
fn C.vtx_load_u64(p voidptr) u64
fn C.vtx_store_u64(p voidptr, v u64)
fn C.vtx_add_u64(p voidptr, d u64) u64
fn C.vtx_swap_u32(p voidptr, v u32) u32
fn C.vtx_load_u64_acq(p voidptr) u64
fn C.vtx_store_u64_rel(p voidptr, v u64)
