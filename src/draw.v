module main

import term.ui as tui

// A double-buffered drawing layer over term.ui. All draw calls write styled
// cells into an in-memory back buffer; `present()` diffs it against the
// previous frame and emits escape sequences only for the cells that changed,
// batching contiguous same-style runs. This avoids the per-frame screen clear
// (which causes visible flicker) and keeps output minimal.
//
// term.ui uses 1-based screen coordinates; the Painter works in 0-based
// coordinates and converts on output.

// Eighth-block ramp, lowest to full. Indexed 0..7.
const blocks = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█']

struct Rect {
	x int
	y int
	w int
	h int
}

struct Cell {
mut:
	ch   string = ' '
	fg   Color
	bg   Color
	bold bool
}

@[heap]
struct Painter {
mut:
	ctx    &tui.Context = unsafe { nil }
	width  int
	height int
	bg     Color
	buf    []Cell // back buffer for the frame being built
	prev   []Cell // last presented frame
	force  bool   // emit every cell next present (first frame / after resize)
}

fn cell_eq(a Cell, b Cell) bool {
	return a.bold == b.bold && a.ch == b.ch && a.fg.eq(b.fg) && a.bg.eq(b.bg)
}

fn style_eq(a Cell, b Cell) bool {
	return a.bold == b.bold && a.fg.eq(b.fg) && a.bg.eq(b.bg)
}

// begin_frame resizes the buffers if the terminal changed size and clears the
// back buffer to the theme background (in memory only -- no output yet).
fn (mut p Painter) begin_frame() {
	n := p.width * p.height
	if n < 0 {
		return
	}
	if p.buf.len != n {
		p.buf = []Cell{len: n}
		p.prev = []Cell{len: n}
		for i in 0 .. n {
			p.prev[i] = Cell{
				ch: '\x00' // sentinel: differs from any real cell
			}
		}
		p.force = true
	}
	blank := Cell{
		ch: ' '
		fg: reset_color
		bg: p.bg
	}
	for i in 0 .. n {
		p.buf[i] = blank
	}
}

// present diffs the back buffer against the previous frame and writes only the
// changed cells, then swaps buffers and flushes.
fn (mut p Painter) present() {
	if p.force {
		// First frame after a resize: erase once so stale cells from the old
		// geometry don't linger. (Not done per-frame -- that is the flicker.)
		p.ctx.clear()
	}
	mut y := 0
	for y < p.height {
		mut x := 0
		for x < p.width {
			i := y * p.width + x
			c := p.buf[i]
			if !p.force && cell_eq(c, p.prev[i]) {
				x++
				continue
			}
			// Extend a run of changed, same-style cells on this row.
			mut run := c.ch
			mut j := x + 1
			for j < p.width {
				k := y * p.width + j
				cj := p.buf[k]
				if !p.force && cell_eq(cj, p.prev[k]) {
					break
				}
				if !style_eq(cj, c) {
					break
				}
				run += cj.ch
				j++
			}
			p.apply_style(c.fg, c.bg, c.bold)
			p.ctx.draw_text(x + 1, y + 1, run)
			x = j
		}
		y++
	}
	for i in 0 .. p.buf.len {
		p.prev[i] = p.buf[i]
	}
	p.force = false
	p.ctx.flush()
}

fn (mut p Painter) apply_style(fg Color, bg Color, bold bool) {
	p.ctx.reset()
	if bg.is_reset() {
		p.ctx.reset_bg_color()
	} else {
		p.ctx.set_bg_color(tui.Color{bg.r, bg.g, bg.b})
	}
	if !fg.is_reset() {
		p.ctx.set_color(tui.Color{fg.r, fg.g, fg.b})
	}
	if bold {
		p.ctx.bold()
	}
}

fn clip_runes(s string, max int) string {
	if max <= 0 {
		return ''
	}
	r := s.runes()
	if r.len <= max {
		return s
	}
	return r[..max].string()
}

fn rune_len(s string) int {
	return s.runes().len
}

fn (mut p Painter) set_cell(x int, y int, ch string, fg Color, bg Color, bold bool) {
	if x < 0 || y < 0 || x >= p.width || y >= p.height {
		return
	}
	p.buf[y * p.width + x] = Cell{
		ch:   ch
		fg:   fg
		bg:   bg
		bold: bold
	}
}

// put_abs writes a run at absolute (x,y), one rune per cell, clipped to width.
fn (mut p Painter) put_abs(x int, y int, s string, fg Color, bg Color, bold bool) {
	if y < 0 || y >= p.height {
		return
	}
	mut cx := x
	for r in s.runes() {
		if cx >= p.width {
			break
		}
		if cx >= 0 {
			p.set_cell(cx, y, r.str(), fg, bg, bold)
		}
		cx++
	}
}

// rtext draws text at rect-relative (col,row) using the theme background.
fn (mut p Painter) rtext(r Rect, col int, row int, s string, fg Color, bold bool) {
	if row < 0 || row >= r.h || col < 0 || col >= r.w {
		return
	}
	p.put_abs(r.x + col, r.y + row, clip_runes(s, r.w - col), fg, p.bg, bold)
}

// rtext_style draws text at rect-relative (col,row) with an explicit background.
fn (mut p Painter) rtext_style(r Rect, col int, row int, s string, fg Color, bg Color, bold bool) {
	if row < 0 || row >= r.h || col < 0 || col >= r.w {
		return
	}
	p.put_abs(r.x + col, r.y + row, clip_runes(s, r.w - col), fg, bg, bold)
}

// rcell draws a single glyph at rect-relative (col,row).
fn (mut p Painter) rcell(r Rect, col int, row int, glyph string, fg Color, bg Color, bold bool) {
	if col < 0 || col >= r.w || row < 0 || row >= r.h {
		return
	}
	p.set_cell(r.x + col, r.y + row, glyph, fg, bg, bold)
}

// rtext_right draws a run right-aligned so it ends at the rect's right edge.
fn (mut p Painter) rtext_right(r Rect, row int, s string, fg Color, bold bool) {
	w := rune_len(s)
	col := if w >= r.w { 0 } else { r.w - w }
	p.rtext(r, col, row, s, fg, bold)
}

// rfill fills the whole rect with a background color.
fn (mut p Painter) rfill(r Rect, bg Color) {
	for row in 0 .. r.h {
		for col in 0 .. r.w {
			p.set_cell(r.x + col, r.y + row, ' ', reset_color, bg, false)
		}
	}
}

// rfill_row_at fills one rect row with a background color.
fn (mut p Painter) rfill_row_at(r Rect, row int, bg Color) {
	if row < 0 || row >= r.h {
		return
	}
	for col in 0 .. r.w {
		p.set_cell(r.x + col, r.y + row, ' ', reset_color, bg, false)
	}
}

// box draws a rounded border with `title` overprinted on the top border, fills
// the box background with the theme bg, and returns the inner (content) rect.
fn (mut p Painter) box(outer Rect, title string, border Color, title_fg Color, title_bold bool) Rect {
	p.rfill(outer, p.bg)
	inner := Rect{
		x: outer.x + 1
		y: outer.y + 1
		w: imax(0, outer.w - 2)
		h: imax(0, outer.h - 2)
	}
	if outer.w < 2 || outer.h < 2 {
		return inner
	}
	mid := '─'.repeat(outer.w - 2)
	p.put_abs(outer.x, outer.y, '╭' + mid + '╮', border, p.bg, false)
	p.put_abs(outer.x, outer.y + outer.h - 1, '╰' + mid + '╯', border, p.bg, false)
	for row in 1 .. outer.h - 1 {
		p.set_cell(outer.x, outer.y + row, '│', border, p.bg, false)
		p.set_cell(outer.x + outer.w - 1, outer.y + row, '│', border, p.bg, false)
	}
	if title.len > 0 && outer.w > 2 {
		p.put_abs(outer.x + 1, outer.y, clip_runes(title, outer.w - 2), title_fg, p.bg,
			title_bold)
	}
	return inner
}

// eighth_partial returns the partial left-block glyph for `eighths` in 1..7.
fn eighth_partial(eighths int) string {
	return match eighths {
		1 { '▏' }
		2 { '▎' }
		3 { '▍' }
		4 { '▌' }
		5 { '▋' }
		6 { '▊' }
		7 { '▉' }
		else { '█' }
	}
}
