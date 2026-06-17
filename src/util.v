module main

// Small numeric helpers shared across modules.

fn clampf(v f32, lo f32, hi f32) f32 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

fn maxf(a f32, b f32) f32 {
	return if a > b { a } else { b }
}

fn minf(a f32, b f32) f32 {
	return if a < b { a } else { b }
}

fn absf(a f32) f32 {
	return if a < 0 { -a } else { a }
}

fn imax(a int, b int) int {
	return if a > b { a } else { b }
}

fn imin(a int, b int) int {
	return if a < b { a } else { b }
}

fn iclamp(v int, lo int, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

fn iabs(n int) int {
	return if n < 0 { -n } else { n }
}

// div_ceil returns ceil(a / b) for positive integers (b > 0).
fn div_ceil(a int, b int) int {
	if b <= 0 {
		return 1
	}
	return (a + b - 1) / b
}

// rjust right-justifies `s` to width `w` with leading spaces.
fn rjust(s string, w int) string {
	if s.len >= w {
		return s
	}
	return ' '.repeat(w - s.len) + s
}
