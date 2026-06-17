module main

import math

// Spectrum analyzer FFT pipeline. Drains decimated mono samples from the audio
// thread's FFT ring into a rolling window, applies a Hann window, runs a
// hand-rolled radix-2 FFT, computes magnitudes, log-bins into N bands, and
// smooths each band with a fast-attack / slow-decay envelope.

const fft_size = 2048
const default_bands = 32
const max_bands = 128
const fft_attack = f32(0.9)
const fft_decay = f32(0.18)

@[heap]
struct Spectrum {
mut:
	sample_rate f32
	window      []f32
	head        int // index of the oldest sample in `window`
	hann        []f32
	re          []f32
	im          []f32
	band_buf    []f32
	bands_len   int
}

fn new_spectrum(sample_rate f32, band_count int) &Spectrum {
	mut s := &Spectrum{
		sample_rate: sample_rate
		window:      []f32{len: fft_size}
		hann:        []f32{len: fft_size}
		re:          []f32{len: fft_size}
		im:          []f32{len: fft_size}
		band_buf:    []f32{len: max_bands}
		bands_len:   iclamp(band_count, 1, max_bands)
	}
	for i in 0 .. fft_size {
		phase := 2.0 * math.pi * f64(i) / (f64(fft_size) - 1.0)
		s.hann[i] = f32(0.5 - 0.5 * math.cos(phase))
	}
	return s
}

fn (s &Spectrum) bands() []f32 {
	return s.band_buf[0..s.bands_len]
}

fn (mut s Spectrum) resize_bands(n int) {
	clamped := iclamp(n, 1, max_bands)
	if clamped > s.bands_len {
		for i in s.bands_len .. clamped {
			s.band_buf[i] = 0
		}
	}
	s.bands_len = clamped
}

// step drains the ring, slides the window, runs the FFT, updates smoothed bands.
fn (mut s Spectrum) step(mut ring Spsc[f32]) {
	mut consumed := 0
	for {
		sample := ring.pop() or { break }
		s.window[s.head] = sample
		s.head = (s.head + 1) % fft_size
		consumed++
		if consumed >= fft_size {
			break
		}
	}

	// Copy the window in chronological order (oldest at `head`) and apply the
	// Hann taper.
	for i in 0 .. fft_size {
		s.re[i] = s.window[(s.head + i) % fft_size] * s.hann[i]
		s.im[i] = 0
	}
	fft_radix2(mut s.re, mut s.im)

	nyquist := s.sample_rate * 0.5
	lo_hz := minf(30.0, nyquist - 1.0)
	hi_hz := maxf(nyquist, lo_hz + 1.0)
	log_lo := f32(math.log(f64(lo_hz)))
	log_hi := f32(math.log(f64(hi_hz)))
	bands_len_f := f32(s.bands_len)
	bin_hz := s.sample_rate / f32(fft_size)

	for i in 0 .. s.bands_len {
		fi := f32(i)
		f0 := f32(math.exp(f64(log_lo + (log_hi - log_lo) * fi / bands_len_f)))
		f1 := f32(math.exp(f64(log_lo + (log_hi - log_lo) * (fi + 1.0) / bands_len_f)))
		mut b0 := int(maxf(0.0, f32(math.floor(f64(f0 / bin_hz)))))
		mut b1 := int(math.ceil(f64(f1 / bin_hz)))
		b1 = imax(b1, b0 + 1)
		b1 = imin(b1, fft_size / 2)
		b0 = imin(b0, b1)

		mut peak := f32(0)
		for b in b0 .. b1 {
			mag := f32(math.sqrt(f64(s.re[b] * s.re[b] + s.im[b] * s.im[b])))
			if mag > peak {
				peak = mag
			}
		}
		norm := maxf(peak / f32(fft_size), f32(1e-6))
		db := f32(20.0 * math.log10(f64(norm)))
		v := clampf((db + 60.0) / 60.0, 0.0, 1.0)

		cur := s.band_buf[i]
		s.band_buf[i] = if v > cur {
			cur + (v - cur) * fft_attack
		} else {
			cur + (v - cur) * fft_decay
		}
	}
}

// fft_radix2 is an in-place iterative radix-2 Cooley-Tukey FFT. `re.len` must be
// a power of two.
fn fft_radix2(mut re []f32, mut im []f32) {
	n := re.len
	// Bit-reversal permutation.
	mut j := 0
	for i in 1 .. n {
		mut bit := n >> 1
		for j & bit != 0 {
			j ^= bit
			bit >>= 1
		}
		j |= bit
		if i < j {
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		}
	}
	mut length := 2
	for length <= n {
		ang := -2.0 * math.pi / f64(length)
		wre := f32(math.cos(ang))
		wim := f32(math.sin(ang))
		mut i := 0
		for i < n {
			mut cwre := f32(1)
			mut cwim := f32(0)
			half := length / 2
			for k in 0 .. half {
				a := i + k
				b := a + half
				vre := re[b] * cwre - im[b] * cwim
				vim := re[b] * cwim + im[b] * cwre
				re[b] = re[a] - vre
				im[b] = im[a] - vim
				re[a] += vre
				im[a] += vim
				nwre := cwre * wre - cwim * wim
				cwim = cwre * wim + cwim * wre
				cwre = nwre
			}
			i += length
		}
		length <<= 1
	}
}
