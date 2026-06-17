module main

import math

// Starter tests for the hand-rolled radix-2 FFT and the Spectrum scaffolding.

fn f32_near(a f32, b f32, eps f32) bool {
	d := a - b
	return (if d < 0 { -d } else { d }) < eps
}

// A constant (DC) signal must put all of its energy in bin 0.
fn test_fft_radix2_dc() {
	n := 8
	mut re := []f32{len: n, init: 1.0}
	mut im := []f32{len: n}
	fft_radix2(mut re, mut im)
	assert f32_near(re[0], f32(n), 1e-4)
	assert f32_near(im[0], 0.0, 1e-4)
	for i in 1 .. n {
		mag := f32(math.sqrt(f64(re[i] * re[i] + im[i] * im[i])))
		assert f32_near(mag, 0.0, 1e-4)
	}
}

// A pure cosine at bin k must peak at bins k and n-k with magnitude n/2.
fn test_fft_radix2_single_tone() {
	n := 8
	k := 1
	mut re := []f32{len: n}
	mut im := []f32{len: n}
	for i in 0 .. n {
		re[i] = f32(math.cos(2.0 * math.pi * f64(k) * f64(i) / f64(n)))
	}
	fft_radix2(mut re, mut im)
	mut mags := []f32{len: n}
	for i in 0 .. n {
		mags[i] = f32(math.sqrt(f64(re[i] * re[i] + im[i] * im[i])))
	}
	assert f32_near(mags[k], f32(n) / 2.0, 1e-3)
	assert f32_near(mags[n - k], f32(n) / 2.0, 1e-3)
	for i in 0 .. n {
		if i == k || i == n - k {
			continue
		}
		assert f32_near(mags[i], 0.0, 1e-3)
	}
}

// new_spectrum exposes exactly `band_count` bands (clamped), all starting at 0.
fn test_spectrum_bands_len() {
	mut s := new_spectrum(48000.0, default_bands)
	assert s.bands().len == default_bands
	for v in s.bands() {
		assert v == 0
	}
	// resize_bands clamps into [1, max_bands].
	s.resize_bands(max_bands + 100)
	assert s.bands().len == max_bands
	s.resize_bands(0)
	assert s.bands().len == 1
}
