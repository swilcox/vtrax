module main

import os
import math
import term.ui as tui

// TUI application: owns the terminal (via term.ui), runs its event loop at
// ~30 fps, dispatches input, and renders the composed widget tree each frame.
// Ported from ztrax's app.zig.

enum Focus {
	pattern
	browser
}

// Which collection drives playback, fixed at launch.
enum PlayMode {
	queue
	browse
}

// Pattern-view layout settings (stacked lanes + compact cells).
struct PatternView {
mut:
	stack   u8 = 1
	compact bool
}

fn (mut v PatternView) cycle_stack() {
	v.stack = match v.stack {
		1 { u8(2) }
		2 { u8(4) }
		else { u8(1) }
	}
}

fn (mut v PatternView) toggle_compact() {
	v.compact = !v.compact
}

fn pattern_view_auto_for_channels(channels int) PatternView {
	if channels <= 8 {
		return PatternView{
			stack:   1
			compact: false
		}
	}
	if channels <= 16 {
		return PatternView{
			stack:   2
			compact: false
		}
	}
	return PatternView{
		stack:   4
		compact: true
	}
}

// Everything the CLI resolves before the TUI starts.
struct Launch {
mut:
	initial_path ?string
	mode         PlayMode = .browse
	playlist     Playlist
	has_playlist bool
	save_target  ?string
	browse_root  ?string
	shuffle      bool
}

@[heap]
struct App {
mut:
	tui    &tui.Context = unsafe { nil }
	state  &SharedState
	engine &Engine
	p      Painter

	spectrum     &Spectrum
	meter_state  MeterState
	master_state MasterMeterState

	theme               Theme
	theme_choices       []string
	theme_idx           int
	theme_dir           ?string
	progress_style      ProgressStyle = .blocks
	pattern_view        PatternView
	auto_layout         bool = true
	default_browse_path ?string
	last_layout_channels int = -1

	show_help      bool
	show_info      bool
	show_message   bool
	message_scroll int

	volume_millibel int
	notice_text     string
	notice_frames   int

	loaded     Loaded
	has_loaded bool
	focus      Focus = .pattern
	browser    &Browser

	mode          PlayMode = .browse
	playlist      Playlist
	has_playlist  bool
	queue_selected int
	shuffle       bool
	save_target   ?string
}

fn new_app(state &SharedState, engine &Engine, theme_name string, progress_style ProgressStyle, auto_layout bool, default_browse_path ?string) &App {
	tdir := theme_dir()
	choices := available_theme_choices(tdir)
	theme := resolve_theme(tdir, theme_name)
	canon := builtin_from_name(theme_name) or { theme_name }
	mut tidx := 0
	for i, c in choices {
		if c == canon {
			tidx = i
		}
	}
	return &App{
		state:               state
		engine:              engine
		spectrum:            new_spectrum(f32(fft_ring_rate_hz), 48)
		theme:               theme
		theme_choices:       choices
		theme_idx:           tidx
		theme_dir:           tdir
		progress_style:      progress_style
		auto_layout:         auto_layout
		default_browse_path: default_browse_path
		browser:             new_browser('.')
	}
}

fn (mut a App) run(launch Launch) ! {
	a.mode = launch.mode
	a.playlist = launch.playlist
	a.has_playlist = launch.has_playlist
	a.save_target = launch.save_target
	a.shuffle = launch.shuffle

	// Resolve the starting track. In queue mode shuffle is applied up front so
	// the initial track is the shuffled head.
	mut initial_path := launch.initial_path
	if a.mode == .queue && a.has_playlist {
		if a.shuffle {
			a.playlist.set_shuffle(true, none)
		}
		if initial_path == none {
			initial_path = a.playlist.start()
		}
	}

	// Root the file browser: an explicit directory argument, else the initial
	// track's folder, else the configured default, else cwd.
	mut broot := '.'
	if r := launch.browse_root {
		broot = r
	} else if p := initial_path {
		broot = os.dir(p)
	} else if d := a.default_browse_path {
		broot = d
	}
	a.browser.root = os.real_path(broot)
	a.browser.refresh()

	if p := initial_path {
		if a.has_playlist {
			if idx := a.playlist.position(p) {
				a.queue_selected = idx
			}
		}
		a.load_path(p)
	}

	a.tui = tui.init(
		user_data:            a
		frame_fn:             frame_cb
		event_fn:             event_cb
		hide_cursor:          true
		window_title:         'vtrax'
		use_alternate_buffer: true
	)
	a.p.ctx = a.tui
	a.tui.run()!
}

fn frame_cb(x voidptr) {
	mut a := unsafe { &App(x) }
	a.frame()
}

fn event_cb(e &tui.Event, x voidptr) {
	mut a := unsafe { &App(x) }
	a.handle_event(e)
}

fn (mut a App) frame() {
	a.p.width = a.tui.window_width
	a.p.height = a.tui.window_height
	a.p.bg = a.theme.bg

	mut ring := a.engine.fft_ring()
	a.spectrum.step(mut ring)
	a.meter_state.step(a.state)
	a.master_state.step(a.state)
	a.engine.drain_drops()
	a.maybe_auto_layout()

	// Auto-advance when a song ends.
	if a.state.swap_eof(false) {
		if next := a.next_track() {
			a.load_path(next)
		}
	}

	if a.notice_frames > 0 {
		a.notice_frames--
	}

	a.render()
	a.p.present()
}

// --- Input ------------------------------------------------------------------

fn (mut a App) handle_event(e &tui.Event) {
	if e.typ == .resized {
		// Force a full repaint (and one-time clear) at the new geometry.
		a.p.force = true
		return
	}
	if e.typ != .key_down {
		return
	}
	match e.code {
		.up { a.on_up() }
		.down { a.on_down() }
		.left { a.engine.send(Command{ kind: .seek_relative, seek: -5.0 }) }
		.right { a.engine.send(Command{ kind: .seek_relative, seek: 5.0 }) }
		.page_up { a.on_page(-10) }
		.page_down { a.on_page(10) }
		.escape { a.on_escape() }
		.enter {
			if a.focus == .browser {
				a.activate_left_panel()
			}
		}
		.tab {
			a.focus = if a.focus == .pattern { Focus.browser } else { Focus.pattern }
		}
		.space {
			playing := a.state.get_playing()
			a.engine.send(Command{
				kind: if playing { CommandKind.pause } else { CommandKind.play }
			})
		}
		else {
			a.handle_printable(e.ascii)
		}
	}
}

fn (mut a App) handle_printable(ascii u8) {
	match rune(ascii) {
		`q` {
			a.quit()
		}
		`/` {
			a.focus = .browser
		}
		`a` {
			a.add_to_playlist()
		}
		`z` {
			a.toggle_shuffle()
		}
		`?` {
			a.show_help = !a.show_help
			if a.show_help {
				a.show_message = false
			}
		}
		`m` {
			a.show_message = !a.show_message
			if a.show_message {
				a.message_scroll = 0
				a.show_help = false
			}
		}
		`i` {
			a.show_info = !a.show_info
		}
		`s` {
			a.engine.send(Command{ kind: .stop })
		}
		`n` {
			if p := a.next_track() {
				a.load_path(p)
			}
		}
		`p` {
			if p := a.prev_track() {
				a.load_path(p)
			}
		}
		`]` {
			a.volume_millibel = imin(a.volume_millibel + 200, 1200)
			a.apply_gain()
		}
		`[` {
			a.volume_millibel = imax(a.volume_millibel - 200, -4000)
			a.apply_gain()
		}
		`\\` {
			a.volume_millibel = 0
			a.apply_gain()
		}
		`t` {
			a.cycle_theme()
		}
		`b` {
			a.cycle_progress_style()
		}
		`w` {
			a.pattern_view.cycle_stack()
		}
		`c` {
			a.pattern_view.toggle_compact()
		}
		else {}
	}
}

fn (mut a App) on_escape() {
	if a.show_help {
		a.show_help = false
	} else if a.show_message {
		a.show_message = false
	} else if a.focus == .browser {
		a.focus = .pattern
	}
}

fn (mut a App) on_up() {
	if a.show_message {
		if a.message_scroll > 0 {
			a.message_scroll--
		}
	} else if a.focus == .browser {
		a.left_panel_delta(-1)
	}
}

fn (mut a App) on_down() {
	if a.show_message {
		a.message_scroll++
	} else if a.focus == .browser {
		a.left_panel_delta(1)
	}
}

fn (mut a App) on_page(d int) {
	if a.show_message {
		a.message_scroll = imax(0, a.message_scroll + d)
	} else if a.focus == .browser {
		a.left_panel_delta(d)
	}
}

fn (mut a App) quit() {
	a.engine.send(Command{ kind: .pause })
	a.engine.deinit()
	// term.ui's at_exit handler restores the terminal (leaves the alternate
	// buffer, shows the cursor, etc.).
	exit(0)
}

fn (mut a App) apply_gain() {
	a.engine.send(Command{ kind: .volume_millibel, millibel: a.volume_millibel })
	if a.volume_millibel == 0 {
		a.set_notice('gain 0 dB (unity)')
	} else {
		db := a.volume_millibel / 100
		sign := if db < 0 { '-' } else { '+' }
		a.set_notice('gain ${sign}${iabs(db)} dB')
	}
}

fn (mut a App) cycle_theme() {
	if a.theme_choices.len == 0 {
		return
	}
	a.theme_idx = (a.theme_idx + 1) % a.theme_choices.len
	name := a.theme_choices[a.theme_idx]
	a.theme = resolve_theme(a.theme_dir, name)
	a.set_notice('theme: ${name}')
}

fn (mut a App) cycle_progress_style() {
	cur := int(a.progress_style)
	a.progress_style = progress_styles[(cur + 1) % progress_styles.len]
	a.set_notice('progress bar: ${a.progress_style.name()}')
}

fn (mut a App) set_notice(s string) {
	a.notice_text = s
	a.notice_frames = 45
}

// --- Navigation -------------------------------------------------------------

fn (a &App) current_path() ?string {
	if a.has_loaded {
		return a.loaded.path
	}
	return none
}

fn (mut a App) next_track() ?string {
	if a.mode == .queue {
		cur := a.current_path() or { return none }
		if a.has_playlist {
			return a.playlist.next_after(cur)
		}
		return none
	}
	return a.browser.next_module(a.current_path())
}

fn (mut a App) prev_track() ?string {
	if a.mode == .queue {
		cur := a.current_path() or { return none }
		if a.has_playlist {
			return a.playlist.prev_before(cur)
		}
		return none
	}
	return a.browser.prev_module(a.current_path())
}

fn (mut a App) left_panel_delta(delta int) {
	if a.mode == .browse {
		a.browser.select_delta(delta)
	} else {
		n := if a.has_playlist { a.playlist.len() } else { 0 }
		if n == 0 {
			return
		}
		a.queue_selected = ((a.queue_selected + delta) % n + n) % n
	}
}

fn (mut a App) activate_left_panel() {
	if a.mode == .browse {
		if path := a.browser.activate() {
			a.load_path(path)
			a.focus = .pattern
		}
	} else {
		if a.has_playlist {
			if path := a.playlist.get(a.queue_selected) {
				a.load_path(path)
				a.focus = .pattern
			}
		}
	}
}

fn (mut a App) toggle_shuffle() {
	a.shuffle = !a.shuffle
	anchor := a.current_path()
	if a.mode == .queue && a.has_playlist {
		a.playlist.set_shuffle(a.shuffle, anchor)
	}
	a.set_notice(if a.shuffle { 'shuffle on' } else { 'shuffle off' })
}

fn (a &App) save_path() ?string {
	if s := a.save_target {
		return s
	}
	if a.has_playlist {
		if p := a.playlist.path {
			return p
		}
	}
	home := os.getenv('HOME')
	if home.len == 0 {
		return none
	}
	return os.join_path(home, 'Library', 'Application Support', 'vtrax', 'playlist.m3u')
}

fn (mut a App) add_to_playlist() {
	current := a.current_path() or { return }
	save := a.save_path() or {
		a.set_notice('no playlist path available')
		return
	}
	if file_contains(current, save) {
		a.set_notice('already in playlist')
		return
	}
	append_to_file(current, save) or {
		a.set_notice('failed to add to playlist')
		return
	}
	if a.has_playlist {
		if a.playlist.position(current) == none {
			a.playlist.push(current)
		}
	}
	a.set_notice('added to ${os.base(save)}')
}

fn (mut a App) load_path(path string) {
	new := load_loaded(path) or {
		a.set_notice('failed to load ${os.base(path)}')
		return
	}
	// The previous module handle is owned by the audio engine (its drop ring /
	// deinit destroys it); replacing a.loaded just drops the V-side wrapper.
	a.loaded = new
	a.has_loaded = true
	a.engine.send(Command{ kind: .load, module_: new.module_ })
	a.last_layout_channels = -1
}

fn (mut a App) maybe_auto_layout() {
	if !a.auto_layout {
		return
	}
	n := a.state.get_num_channels()
	if n > 0 && n != a.last_layout_channels {
		a.last_layout_channels = n
		a.pattern_view = pattern_view_auto_for_channels(n)
	}
}

// --- Rendering --------------------------------------------------------------

fn (mut a App) render() {
	a.p.begin_frame()
	w := a.p.width
	h := a.p.height
	if w < 20 || h < 12 {
		a.p.put_abs(0, 0, 'terminal too small', a.theme.fg_dim, a.theme.bg, false)
		return
	}

	header_h := 3
	spectrum_h := 8
	status_h := 1
	main_h := h - header_h - spectrum_h - status_h

	a.render_header(Rect{ x: 0, y: 0, w: w, h: header_h })

	browse := a.focus == .browser
	left_w := if browse { imax(16, w * 30 / 100) } else { 0 }
	right_w := if browse { imax(16, w * 20 / 100) } else { imax(20, w * 30 / 100) }
	pat_w := w - left_w - right_w
	if browse {
		if a.mode == .browse {
			a.render_browser(Rect{ x: 0, y: header_h, w: left_w, h: main_h })
		} else {
			a.render_queue(Rect{ x: 0, y: header_h, w: left_w, h: main_h })
		}
	}
	a.render_pattern(Rect{ x: left_w, y: header_h, w: pat_w, h: main_h })
	if a.show_info {
		a.render_info(Rect{ x: left_w + pat_w, y: header_h, w: right_w, h: main_h })
	} else {
		a.render_meters(Rect{ x: left_w + pat_w, y: header_h, w: right_w, h: main_h })
	}

	spec_y := header_h + main_h
	master_w := imin(30, w / 2)
	spec_w := w - master_w
	a.spectrum.resize_bands(iclamp(spec_w - 2, 8, 96))
	a.render_spectrum(Rect{ x: 0, y: spec_y, w: spec_w, h: spectrum_h })
	a.render_master(Rect{ x: spec_w, y: spec_y, w: master_w, h: spectrum_h })

	a.render_status(h - 1)

	if a.show_message {
		a.render_message(w, h)
	}
	if a.show_help {
		a.render_help(w, h)
	}
}

fn fmt_mmss(secs f64) string {
	if secs != secs || secs < 0 || secs > 1e8 {
		return '--:--'
	}
	t := u32(secs)
	return '${rjust((t / 60).str(), 2).replace(' ', '0')}:${rjust((t % 60).str(), 2).replace(' ',
		'0')}'
}

fn hex2_up(n int) string {
	s := n.hex().to_upper()
	if s.len >= 2 {
		return s
	}
	return '0'.repeat(2 - s.len) + s
}

// -- Header ------------------------------------------------------------------

fn (mut a App) render_header(outer Rect) {
	th := a.theme
	inner := a.p.box(outer, ' vtrax ', th.border, th.accent, true)
	if inner.w == 0 || inner.h == 0 {
		return
	}

	playing := a.state.get_playing()
	eof := a.state.get_eof()
	channels := a.state.get_num_channels()
	tempo := a.state.get_tempo()
	speed := a.state.get_current_speed()
	pattern := a.state.get_current_pattern()
	orders := a.state.get_num_orders()
	order := a.state.get_current_order()
	pos := a.state.get_position_secs()
	dur := a.state.get_duration_secs()

	marker := if eof { '⏹ end' } else if playing { '▶ play' } else { '⏸ pause' }
	marker_dim := eof || !playing
	marker_color := if marker_dim { th.fg_dim } else { th.accent }
	a.p.rtext(inner, 0, 0, marker, marker_color, !marker_dim)

	// Right block (progress bar + time) is anchored to the right edge; compute
	// its leftmost column first so the title and stats can be clipped to stop
	// before it (no overprinting / overlap).
	time := '${fmt_mmss(pos)} / ${fmt_mmss(dur)}'
	time_w := rune_len(time)
	bar_w := iclamp(inner.w / 6, 6, 24)
	show_progress := inner.w > time_w + bar_w + 4
	bar_col := inner.w - time_w - 2 - bar_w
	right_block_left := if show_progress { bar_col } else { inner.w - time_w }

	mut title := 'no file loaded'
	if a.has_loaded {
		t := a.loaded.title.trim(' \t')
		title = if t.len > 0 { t } else { os.base(a.loaded.path) }
	}
	stats := '${channels} ch · ${tempo:.0f} BPM · spd ${speed} · ord ${order}/${imax(orders,
		1)} pat ${pattern}'

	// Title occupies the gap between the marker and the right block.
	disp_title := clip_runes(title, imax(0, right_block_left - 7 - 1))
	a.p.rtext(inner, 7, 0, disp_title, th.fg, true)

	// Stats sit just after the title, clipped to stop before the right block.
	stats_col := 7 + rune_len(disp_title) + 2
	stats_avail := imax(0, right_block_left - stats_col - 1)
	if stats_avail > 0 {
		a.p.rtext(inner, stats_col, 0, clip_runes(stats, stats_avail), th.fg, false)
	}

	frac := if dur > 0 { f32(pos / dur) } else { f32(0) }
	if show_progress {
		a.render_progress(inner, bar_col, 0, bar_w, frac)
	}
	a.p.rtext_right(inner, 0, time, th.fg, false)
}

// -- Progress bar ------------------------------------------------------------

fn (mut a App) render_progress(win Rect, col int, row int, width int, fraction f32) {
	th := a.theme
	frac := if fraction == fraction { clampf(fraction, 0.0, 1.0) } else { f32(0) }
	wf := f32(width)
	match a.progress_style {
		.triangle {
			if width < 3 {
				return
			}
			inner_w := width - 2
			pos := imin(int(frac * f32(inner_w)), inner_w - 1)
			a.p.rcell(win, col, row, '[', th.fg_dim, th.bg, false)
			for i in 0 .. inner_w {
				if i < pos {
					a.p.rcell(win, col + 1 + i, row, '━', th.fg, th.bg, false)
				} else if i == pos {
					a.p.rcell(win, col + 1 + i, row, '▲', th.accent, th.bg, true)
				} else {
					a.p.rcell(win, col + 1 + i, row, '─', th.fg_dim, th.bg, false)
				}
			}
			a.p.rcell(win, col + 1 + inner_w, row, ']', th.fg_dim, th.bg, false)
		}
		.blocks {
			total_eighths := imin(int(math.round(f64(frac * wf * 8.0))), width * 8)
			full := total_eighths / 8
			partial := total_eighths % 8
			for i in 0 .. full {
				a.p.rcell(win, col + i, row, '█', th.accent, th.bg, false)
			}
			if partial > 0 && full < width {
				a.p.rcell(win, col + full, row, eighth_partial(partial), th.accent, th.bg,
					false)
			}
		}
		.line {
			head := imin(int(frac * wf), width - 1)
			for i in 0 .. width {
				if i < head {
					a.p.rcell(win, col + i, row, '━', th.fg, th.bg, false)
				} else if i == head {
					a.p.rcell(win, col + i, row, '╸', th.accent, th.bg, true)
				} else {
					a.p.rcell(win, col + i, row, '─', th.fg_dim, th.bg, false)
				}
			}
		}
		.segments {
			filled := imin(int(math.round(f64(frac * wf))), width)
			for i in 0 .. width {
				if i < filled {
					a.p.rcell(win, col + i, row, '▰', th.accent, th.bg, false)
				} else {
					a.p.rcell(win, col + i, row, '▱', th.fg_dim, th.bg, false)
				}
			}
		}
	}
}

// -- Pattern view ------------------------------------------------------------

struct LaneSlice {
	start int
	len   int
}

const full_cell_w = 14
const compact_cell_w = 6
const row_label_budget = 4
const full_empty = '... .. .. ...'
const compact_empty = '... ..'

fn (mut a App) render_pattern(outer Rect) {
	th := a.theme
	focused := a.focus == .pattern
	title := pattern_title(a.pattern_view)
	border := if focused { th.border_focus } else { th.border }
	inner := a.p.box(outer, title, border, th.fg_dim, false)
	if inner.w == 0 || inner.h == 0 {
		return
	}

	if !a.has_loaded {
		a.p.rtext(inner, 0, 0, 'no pattern data — load a module to begin', th.fg_dim, false)
		return
	}
	pat := a.state.get_current_pattern()
	row := a.state.get_current_row()
	window := a.loaded.cache.window(pat, row)
	if window.channel_count == 0 {
		a.p.rtext(inner, 0, 0, 'no pattern data — load a module to begin', th.fg_dim, false)
		return
	}

	lanes := imax(1, imin(int(a.pattern_view.stack), window.channel_count))
	cell_w := if a.pattern_view.compact { compact_cell_w } else { full_cell_w }
	empty_cell := if a.pattern_view.compact { compact_empty } else { full_empty }

	avail := imax(0, inner.w - row_label_budget)
	max_cells_per_lane := imax(1, avail / (cell_w + 1))

	slices := lane_slices(window.channel_count, lanes, max_cells_per_lane)
	lane_height := imax(1, inner.h / lanes)
	for lane_idx, sl in slices {
		lane_y := lane_height * lane_idx
		if lane_y >= inner.h {
			break
		}
		remaining := inner.h - lane_y
		lane_h := if lane_idx + 1 == slices.len { remaining } else { imin(lane_height, remaining) }
		if lane_h == 0 {
			continue
		}
		show_header := lanes > 1 && lane_h >= 2
		a.render_lane(inner, lane_y, lane_h, window, sl.start, sl.len, cell_w, empty_cell,
			show_header)
	}
}

fn pattern_title(view PatternView) string {
	if view.stack > 1 && view.compact {
		return ' pattern ×${view.stack} compact '
	}
	if view.stack > 1 {
		return ' pattern ×${view.stack} '
	}
	if view.compact {
		return ' pattern compact '
	}
	return ' pattern '
}

fn lane_slices(channel_count int, lanes int, max_cells_per_lane int) []LaneSlice {
	lanes_c := imax(1, lanes)
	channels_per_lane := div_ceil(channel_count, lanes_c)
	cells_per_lane := imax(1, imin(channels_per_lane, imax(1, max_cells_per_lane)))
	mut out := []LaneSlice{}
	mut lane_idx := 0
	for lane_idx < lanes_c && lane_idx < 4 {
		ch_start := lane_idx * cells_per_lane
		if ch_start >= channel_count {
			break
		}
		ch_end := imin(ch_start + cells_per_lane, channel_count)
		out << LaneSlice{
			start: ch_start
			len:   ch_end - ch_start
		}
		lane_idx++
	}
	return out
}

fn (mut a App) render_lane(inner Rect, lane_y int, lane_h int, window PatternWindow, ch_start int, cells_in_lane int, cell_w int, empty_cell string, show_header bool) {
	th := a.theme
	mut rows_y := lane_y
	mut rows_h := lane_h
	if show_header {
		a.render_lane_header(inner, lane_y, ch_start, cells_in_lane)
		rows_y += 1
		rows_h -= 1
	}
	if rows_h == 0 {
		return
	}

	visible_rows := rows_h
	center := window_radius
	half := visible_rows / 2
	start := if center >= half { center - half } else { 0 }
	end := imin(start + visible_rows, window_rows)

	mut screen_row := rows_y
	mut i := start
	for i < end {
		is_current := i == center
		row_index := window.row_index_at(i)
		if is_current {
			a.p.rfill_row_at(inner, screen_row, th.current_row_bg)
		}

		mut col := 0
		prefix_color := if is_current { th.accent } else { th.fg_dim }
		if is_current {
			a.p.rcell(inner, col, screen_row, '▶', prefix_color, th.current_row_bg, true)
		}
		col += 2

		label := if row_index < 0 { '    ' } else { rjust(row_index.str(), 3) + ' ' }
		if is_current {
			a.p.rtext_style(inner, col, screen_row, label, th.fg_dim, th.current_row_bg,
				false)
		} else {
			a.p.rtext(inner, col, screen_row, label, th.fg_dim, false)
		}
		col += 4

		maybe_row := window.get(i)
		mut ci := 0
		for ci < cells_in_lane {
			channel := ch_start + ci
			if ci > 0 {
				bg := if is_current { th.current_row_bg } else { th.bg }
				a.p.rcell(inner, col, screen_row, '│', th.fg_dim, bg, false)
				col += 1
			}
			mut source := empty_cell
			if r := maybe_row {
				if channel < r.cells.len && r.cells[channel].trim(' \t').len > 0 {
					source = r.cells[channel]
				}
			}
			a.draw_cell(inner, col, screen_row, source, cell_w, is_current, th.current_row_bg)
			col += cell_w
			ci++
		}
		screen_row += 1
		if screen_row >= rows_y + rows_h {
			break
		}
		i += 1
	}
}

// draw_cell renders one pattern cell with per-character classification,
// grouping consecutive same-color characters into single styled runs.
fn (mut a App) draw_cell(r Rect, col int, row int, source string, cell_w int, current bool, cur_bg Color) {
	mut c := col
	n := imin(cell_w, source.len)
	mut i := 0
	for i < n {
		color := classify_cell(source[i], i, a.theme)
		mut j := i + 1
		for j < n && classify_cell(source[j], j, a.theme).eq(color) {
			j++
		}
		run := source[i..j]
		if current {
			a.p.rtext_style(r, c, row, run, color, cur_bg, true)
		} else {
			a.p.rtext(r, c, row, run, color, false)
		}
		c += j - i
		i = j
	}
}

fn (mut a App) render_lane_header(inner Rect, y int, ch_start int, cells_in_lane int) {
	th := a.theme
	label := if cells_in_lane == 1 {
		' ch ${ch_start + 1} '
	} else {
		' ch ${ch_start + 1}-${ch_start + cells_in_lane} '
	}
	a.p.rcell(inner, 0, y, '─', th.fg_dim, th.bg, false)
	a.p.rcell(inner, 1, y, '─', th.fg_dim, th.bg, false)
	a.p.rtext(inner, 2, y, label, th.fg_dim, false)
	after := 2 + rune_len(label)
	for cx in after .. inner.w {
		a.p.rcell(inner, cx, y, '─', th.fg_dim, th.bg, false)
	}
}

// classify_cell colors a character of a "C-5 01 v40 A20" cell by position.
fn classify_cell(ch u8, idx int, theme Theme) Color {
	if ch == `.` || ch == ` ` {
		return theme.fg_dim
	}
	return match idx {
		0, 1, 2 { theme.note }
		3 { theme.fg_dim }
		4, 5 { theme.instrument }
		6 { theme.fg_dim }
		7, 8, 9 { theme.volume }
		10 { theme.fg_dim }
		11, 12, 13 { theme.effect }
		else { theme.fg }
	}
}

// -- Per-channel meters ------------------------------------------------------

const bar_w_const = 8
const entry_w = 2 + 1 + 1 + 1 + bar_w_const // "NN L ████████"
const col_gap = 2

fn (mut a App) render_meters(outer Rect) {
	th := a.theme
	inner := a.p.box(outer, ' meters ', th.border, th.fg_dim, false)
	if inner.w == 0 || inner.h == 0 {
		return
	}
	n := imax(0, a.state.get_num_channels())
	if n == 0 {
		return
	}

	cols := imax(1, inner.w / (entry_w + col_gap))
	channels_per_col := div_ceil(n, cols)
	visible_rows := (inner.h / 2) * 2
	actual_rows := imin(channels_per_col * 2, visible_rows)
	visible_per_col := actual_rows / 2
	if visible_per_col == 0 {
		return
	}

	for row in 0 .. actual_rows {
		local_ch := row / 2
		is_left := row % 2 == 0
		mut col_x := 0
		for c in 0 .. cols {
			ch := c * visible_per_col + local_ch
			if ch >= n {
				col_x += entry_w + col_gap
				continue
			}
			label := if is_left { rjust((ch + 1).str(), 2) + ' L ' } else { '   R ' }
			a.p.rtext(inner, col_x, row, label, th.fg_dim, false)
			env := if is_left { a.meter_state.left_env(ch) } else { a.meter_state.right_env(ch) }
			a.draw_bar(inner, col_x + 5, row, bar_w_const, env.smoothed, env.peak)
			col_x += entry_w + col_gap
		}
	}
}

// draw_bar draws a horizontal level bar with the meter color ramp and a bold
// peak marker. Shared by the channel meters and the master meter.
fn (mut a App) draw_bar(win Rect, col int, row int, width int, level f32, peak f32) {
	th := a.theme
	ramp := blocks.len
	total_steps := width * ramp
	filled_steps := int(math.round(f64(clampf(level, 0.0, 1.0) * f32(total_steps))))
	peak_pos := int(math.round(f64(clampf(peak, 0.0, 1.0) * f32(width))))
	wm1 := maxf(1.0, f32(width) - 1.0)
	for i in 0 .. width {
		cell_lo := i * ramp
		cell_hi := cell_lo + ramp
		glyph := if filled_steps >= cell_hi {
			blocks[ramp - 1]
		} else if filled_steps > cell_lo {
			blocks[filled_steps - cell_lo - 1]
		} else {
			' '
		}
		frac := f32(i) / wm1
		color := if frac < 0.6 {
			th.meter_low
		} else if frac < 0.85 {
			th.meter_mid
		} else {
			th.meter_high
		}
		bold := i + 1 == peak_pos && peak_pos > 0
		if glyph != ' ' {
			a.p.rcell(win, col + i, row, glyph, color, th.bg, bold)
		}
	}
}

// -- Master meter ------------------------------------------------------------

fn (mut a App) render_master(outer Rect) {
	th := a.theme
	inner := a.p.box(outer, ' master ', th.border, th.fg_dim, false)
	if inner.w < 4 || inner.h == 0 {
		return
	}

	db := a.volume_millibel / 100
	glabel := if db == 0 {
		'gain 0 dB'
	} else {
		'gain ${if db < 0 { '-' } else { '+' }}${iabs(db)} dB'
	}
	a.p.rtext_right(inner, 0, glabel, th.fg_dim, false)

	label_w := 2
	right_margin := 1
	bar_w := imax(0, inner.w - (label_w + right_margin))
	if bar_w == 0 {
		return
	}
	total_rows := inner.h
	top_pad := imax(0, total_rows - 2) / 2
	ly := imin(top_pad + 1, total_rows - 1)
	ry := imin(top_pad + 2, total_rows - 1)

	a.p.rtext(inner, 0, ly, 'L ', th.fg_dim, false)
	a.draw_bar(inner, 2, ly, bar_w, a.master_state.left.smoothed, a.master_state.left.peak)
	if total_rows >= 2 {
		a.p.rtext(inner, 0, ry, 'R ', th.fg_dim, false)
		a.draw_bar(inner, 2, ry, bar_w, a.master_state.right.smoothed, a.master_state.right.peak)
	}
}

// -- Spectrum ----------------------------------------------------------------

fn (mut a App) render_spectrum(outer Rect) {
	th := a.theme
	inner := a.p.box(outer, ' spectrum ', th.border, th.fg_dim, false)
	if inner.w == 0 || inner.h == 0 {
		return
	}
	bands := a.spectrum.bands()
	if bands.len == 0 {
		return
	}

	width := inner.w
	height := inner.h
	for c in 0 .. width {
		frac := f32(c) / f32(imax(1, width))
		bi := imin(bands.len - 1, int(frac * f32(bands.len)))
		v := clampf(bands[bi], 0.0, 1.0)
		color := if v < 0.55 {
			th.meter_low
		} else if v < 0.85 {
			th.meter_mid
		} else {
			th.meter_high
		}
		level := v * f32(height)
		level_int := int(math.floor(f64(level)))
		for r in 0 .. height {
			row_from_bottom := height - r
			mut glyph := ' '
			if level_int >= row_from_bottom {
				glyph = blocks[blocks.len - 1]
			} else if level_int + 1 == row_from_bottom {
				fpart := level - f32(level_int)
				step := imin(blocks.len - 1, int(fpart * f32(blocks.len)))
				glyph = blocks[step]
			}
			if glyph != ' ' {
				a.p.rcell(inner, c, r, glyph, color, th.bg, false)
			}
		}
	}
}

// -- Status line -------------------------------------------------------------

fn (mut a App) render_status(y int) {
	th := a.theme
	if a.notice_frames > 0 {
		a.p.put_abs(1, y, a.notice_text, th.accent, th.bg, true)
		return
	}
	hint := if a.mode == .queue {
		'[space] play  [n] next  [/] queue  [a] add  [?] help  [q] quit'
	} else {
		'[space] play  [n] next  [/] browse  [a] add  [?] help  [q] quit'
	}
	a.p.put_abs(1, y, hint, th.fg_dim, th.bg, false)
	if a.shuffle {
		col := imin(2 + hint.len, a.p.width)
		a.p.put_abs(col, y, '  ⤮ shuffle', th.accent, th.bg, true)
	}
}

// -- File browser ------------------------------------------------------------

fn (mut a App) render_browser(outer Rect) {
	th := a.theme
	title := if a.shuffle {
		' browser · ${a.browser.root} · ⤮ shuffle '
	} else {
		' browser · ${a.browser.root} '
	}
	inner := a.p.box(outer, title, th.border_focus, th.fg_dim, false)
	if inner.w == 0 || inner.h == 0 {
		return
	}

	entries := a.browser.entries
	if entries.len == 0 {
		a.p.rtext(inner, 0, 0, '(empty)', th.fg_dim, false)
		return
	}

	rows := inner.h
	sel := a.browser.selected
	start := if sel >= rows { sel - rows + 1 } else { 0 }
	mut row := 0
	mut i := start
	for i < entries.len && row < inner.h {
		e := entries[i]
		is_sel := i == sel
		if is_sel {
			a.p.rfill_row_at(inner, row, th.current_row_bg)
			a.p.rcell(inner, 0, row, '▶', th.accent, th.current_row_bg, true)
			a.p.rtext_style(inner, 2, row, e.label, th.accent, th.current_row_bg, true)
		} else {
			base_fg := if e.is_dir { th.instrument } else { th.fg }
			a.p.rtext(inner, 2, row, e.label, base_fg, false)
		}
		row++
		i++
	}
}

// -- Queue panel -------------------------------------------------------------

fn (mut a App) render_queue(outer Rect) {
	th := a.theme
	count := if a.has_playlist { a.playlist.len() } else { 0 }
	title := if a.shuffle {
		' queue · ${count} tracks · ⤮ shuffle '
	} else {
		' queue · ${count} tracks '
	}
	inner := a.p.box(outer, title, th.border_focus, th.fg_dim, false)
	if inner.w == 0 || inner.h == 0 {
		return
	}

	if count == 0 {
		a.p.rtext(inner, 0, 0, '(empty)', th.fg_dim, false)
		return
	}

	now_playing := a.current_path()
	sel := imin(a.queue_selected, count - 1)
	rows := inner.h
	start := if sel >= rows { sel - rows + 1 } else { 0 }
	mut row := 0
	mut i := start
	for i < count && row < inner.h {
		path := a.playlist.entries[i]
		is_sel := i == sel
		is_playing := if np := now_playing { paths_equal(np, path) } else { false }
		if is_sel {
			a.p.rfill_row_at(inner, row, th.current_row_bg)
			a.p.rcell(inner, 0, row, '▶', th.accent, th.current_row_bg, true)
			a.p.rtext_style(inner, 2, row, os.base(path), th.accent, th.current_row_bg,
				true)
		} else if is_playing {
			a.p.rcell(inner, 0, row, '♪', th.accent, th.bg, true)
			a.p.rtext(inner, 2, row, os.base(path), th.accent, true)
		} else {
			a.p.rtext(inner, 2, row, os.base(path), th.fg, false)
		}
		row++
		i++
	}
}

// -- Info panel --------------------------------------------------------------

fn (mut a App) render_info(outer Rect) {
	th := a.theme
	inner := a.p.box(outer, ' info ', th.border, th.fg_dim, false)
	if inner.w < 6 || inner.h < 3 {
		return
	}
	if !a.has_loaded {
		return
	}
	ch_h := imax(1, inner.h * 60 / 100)
	a.render_info_channels(inner, 0, ch_h)
	if inner.h > ch_h {
		a.render_info_meta(inner, ch_h, inner.h - ch_h)
	}
}

fn (mut a App) render_info_channels(inner Rect, top int, height int) {
	th := a.theme
	a.info_divider(inner, top, 'channels')
	content_top := top + 1
	if height < 2 {
		return
	}
	n := imax(0, a.state.get_num_channels())
	if n == 0 {
		return
	}
	rows_avail := height - 1
	rows_visible := imin(rows_avail, n)
	width := inner.w
	for ch in 0 .. rows_visible {
		sr := content_top + ch
		if n > rows_visible && ch + 1 == rows_visible {
			a.p.rtext(inner, 0, sr, '  … +${n - rows_visible + 1} more channels', th.fg_dim,
				false)
			break
		}
		a.p.rtext(inner, 0, sr, rjust((ch + 1).str(), 2) + ' ', th.fg_dim, false)
		inst := a.state.last_instrument(ch)
		if inst <= 0 {
			a.p.rtext(inner, 3, sr, '·  (idle)', th.fg_dim, false)
		} else {
			a.p.rtext(inner, 3, sr, '▶', th.accent, true)
			a.p.rtext(inner, 5, sr, hex2_up(imin(inst, 255)) + ' ', th.instrument, false)
			name := resolve_instrument_name(a.loaded, inst)
			if width > 8 {
				a.p.rtext(inner, 8, sr, name, th.fg, false)
			}
		}
	}
}

fn (mut a App) render_info_meta(inner Rect, top int, height int) {
	th := a.theme
	a.info_divider(inner, top, 'module')
	if height < 2 {
		return
	}
	mut sr := top + 1
	bottom := top + height

	n_ch := a.state.get_num_channels()
	n_samp := a.loaded.sample_names.len
	n_inst := a.loaded.instrument_names.len

	if a.loaded.format_label.len > 0 && sr < bottom {
		a.kv(inner, sr, 'format', a.loaded.format_label)
		sr++
	}
	if sr < bottom {
		a.kv(inner, sr, 'channels', '${n_ch}')
		sr++
	}
	if sr < bottom {
		samples := if n_inst > 0 { '${n_samp} (${n_inst} inst)' } else { '${n_samp}' }
		a.kv(inner, sr, 'samples', samples)
		sr++
	}
	if sr < bottom {
		a.kv(inner, sr, 'duration', fmt_mmss(a.state.get_duration_secs()))
		sr++
	}
	if a.loaded.artist.len > 0 && sr < bottom {
		a.kv(inner, sr, 'artist', a.loaded.artist)
		sr++
	}
	if a.loaded.tracker.len > 0 && sr < bottom {
		a.kv(inner, sr, 'tracker', a.loaded.tracker)
		sr++
	}

	if a.loaded.song_message.len > 0 && sr + 1 < bottom {
		a.p.rtext(inner, 0, sr, '  message:', th.fg_dim, false)
		sr++
		for line in a.loaded.song_message.split_into_lines() {
			if sr >= bottom {
				break
			}
			a.p.rtext(inner, 1, sr, line, th.fg_dim, false)
			sr++
		}
	}
}

fn (mut a App) kv(inner Rect, row int, key string, val string) {
	a.p.rtext(inner, 0, row, rjust(key, 10) + ': ', a.theme.fg_dim, false)
	a.p.rtext(inner, 12, row, val, a.theme.fg, false)
}

fn (mut a App) info_divider(inner Rect, row int, label string) {
	th := a.theme
	a.p.rcell(inner, 0, row, '─', th.fg_dim, th.bg, false)
	a.p.rcell(inner, 1, row, ' ', th.fg_dim, th.bg, false)
	a.p.rtext(inner, 2, row, label, th.fg_dim, false)
	mut cx := imin(3 + rune_len(label), inner.w)
	if cx < inner.w {
		a.p.rcell(inner, cx, row, ' ', th.fg_dim, th.bg, false)
	}
	cx++
	for cx < inner.w {
		a.p.rcell(inner, cx, row, '─', th.fg_dim, th.bg, false)
		cx++
	}
}

// resolve_instrument_name maps a 1-based instrument number to a name:
// instrument list first, then the sample list, else a dash.
fn resolve_instrument_name(l Loaded, instrument_1based int) string {
	idx := imax(0, instrument_1based - 1)
	if idx < l.instrument_names.len {
		if l.instrument_names[idx].trim(' \t').len > 0 {
			return l.instrument_names[idx]
		}
	}
	if idx < l.sample_names.len {
		if l.sample_names[idx].trim(' \t').len > 0 {
			return l.sample_names[idx]
		}
	}
	return '—'
}

// -- Song message overlay ----------------------------------------------------

fn (mut a App) render_message(w int, h int) {
	th := a.theme
	bw := imin(imax(0, w - 4), 70)
	bh := imin(imax(0, h - 4), 24)
	bx := (w - bw) / 2
	by := (h - bh) / 2
	inner := a.p.box(Rect{ x: bx, y: by, w: bw, h: bh }, ' song message ', th.border_focus,
		th.accent, true)
	msg := if a.has_loaded { a.loaded.song_message } else { '' }
	lines := msg.split_into_lines()
	mut row := 0
	mut idx := a.message_scroll
	for idx < lines.len && row < inner.h {
		a.p.rtext(inner, 0, row, lines[idx], th.fg, false)
		row++
		idx++
	}
}

// -- Help overlay ------------------------------------------------------------

const help_lines = [
	'space   play / pause          t   cycle theme',
	's       stop                  b   cycle progress bar',
	'n / p   next / previous       w   cycle pattern stack',
	'← / →   seek −5s / +5s        c   toggle compact cells',
	'[ / ]   gain down / up        i   toggle info panel',
	'\\       reset gain (0 dB)     m   song message',
	'/       focus browser/queue   a   add to playlist',
	'tab     cycle focus           z   toggle shuffle',
	'↑/↓ enter   browse / pick      ?   help    q   quit',
]

fn (mut a App) render_help(w int, h int) {
	th := a.theme
	bw := imin(imax(0, w - 4), 60)
	bh := imin(imax(0, h - 4), help_lines.len + 2)
	bx := (w - bw) / 2
	by := (h - bh) / 2
	inner := a.p.box(Rect{ x: bx, y: by, w: bw, h: bh }, ' help ', th.border_focus, th.accent,
		true)
	for i, line in help_lines {
		if i >= inner.h {
			break
		}
		a.p.rtext(inner, 1, i, line, th.fg, false)
	}
}
