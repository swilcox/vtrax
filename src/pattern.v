module main

// Preformatted pattern data captured at load time, plus a helper for slicing a
// window of rows around the currently-playing row. The cache is built once per
// loaded module and owns all its strings; the window is a lightweight view.

// How many rows above and below the current row the window spans.
const window_radius = 16
const window_rows = window_radius * 2 + 1

struct PatternRow {
mut:
	row_index int
	// One pre-formatted cell per channel, e.g. "C-5 01 v32 A20".
	cells []string
	// Raw instrument number per channel (0 = none).
	instruments []u8
}

struct PatternData {
mut:
	rows          []PatternRow
	channel_count int
}

@[heap]
struct PatternCache {
mut:
	patterns []PatternData
}

// window returns a view of rows centered on `row` within `pattern`.
fn (c &PatternCache) window(pattern int, row int) PatternWindow {
	mut data := &PatternData(unsafe { nil })
	mut chcount := 0
	if pattern >= 0 && pattern < c.patterns.len {
		data = unsafe { &c.patterns[pattern] }
		chcount = data.channel_count
	}
	return PatternWindow{
		pattern:       pattern
		data:          data
		start_row:     row - window_radius
		channel_count: chcount
	}
}

struct PatternWindow {
	pattern       int
	data          &PatternData = unsafe { nil }
	start_row     int
	channel_count int
}

// get returns the row at window offset `i` (0..window_rows), or none if it
// falls outside the pattern (render as an empty placeholder).
fn (w &PatternWindow) get(i int) ?&PatternRow {
	if w.data == unsafe { nil } {
		return none
	}
	row_index := w.start_row + i
	if row_index < 0 || row_index >= w.data.rows.len {
		return none
	}
	return unsafe { &w.data.rows[row_index] }
}

// row_index_at is the row index displayed at window offset `i` (may be negative
// / past end).
fn (w &PatternWindow) row_index_at(i int) int {
	return w.start_row + i
}

fn (w &PatternWindow) current_row() ?&PatternRow {
	return w.get(window_radius)
}
