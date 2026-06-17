module main

import os

// Theme palettes, ported from ztrax/rtrax. Colors are either the terminal
// default (`reset`) or truecolor RGB. The 16 ANSI names map to a fixed xterm
// palette so they render identically through term.ui's truecolor output.

enum ColorKind {
	reset
	rgb
}

struct Color {
	kind ColorKind = .rgb
	r    u8
	g    u8
	b    u8
}

fn rgb(r u8, g u8, b u8) Color {
	return Color{
		kind: .rgb
		r:    r
		g:    g
		b:    b
	}
}

const reset_color = Color{
	kind: .reset
}

fn (c Color) is_reset() bool {
	return c.kind == .reset
}

fn (a Color) eq(b Color) bool {
	if a.kind != b.kind {
		return false
	}
	if a.kind == .reset {
		return true
	}
	return a.r == b.r && a.g == b.g && a.b == b.b
}

// The 16 ANSI colors as a fixed xterm-style palette.
fn idx(n u8) Color {
	return match n {
		0 { rgb(0, 0, 0) } // black
		1 { rgb(205, 0, 0) } // red
		2 { rgb(0, 205, 0) } // green
		3 { rgb(205, 205, 0) } // yellow
		4 { rgb(0, 0, 238) } // blue
		5 { rgb(205, 0, 205) } // magenta
		6 { rgb(0, 205, 205) } // cyan
		7 { rgb(229, 229, 229) } // gray / white
		8 { rgb(127, 127, 127) } // dark gray
		9 { rgb(255, 0, 0) } // light red
		10 { rgb(0, 255, 0) } // light green
		11 { rgb(255, 255, 0) } // light yellow
		12 { rgb(92, 92, 255) } // light blue
		13 { rgb(255, 0, 255) } // light magenta
		14 { rgb(0, 255, 255) } // light cyan
		15 { rgb(255, 255, 255) } // white
		else { rgb(229, 229, 229) }
	}
}

struct Theme {
mut:
	bg             Color
	fg             Color
	fg_dim         Color
	border         Color
	border_focus   Color
	accent         Color
	note           Color
	instrument     Color
	volume         Color
	effect         Color
	meter_low      Color
	meter_mid      Color
	meter_high     Color
	current_row_bg Color
}

const builtin_theme_names = ['default', 'high-contrast', 'sixteen', 'neon-blue', 'neon-green',
	'neon-orange', 'c64', 'mono']

// builtin_from_name resolves a configuration name (with aliases) to a built-in
// theme name, or none if it names a custom theme.
fn builtin_from_name(s string) ?string {
	mut n := s.trim(' \t').to_lower()
	if n.len == 0 {
		return none
	}
	n = n.replace('_', '-').replace(' ', '-')
	return match n {
		'default' { 'default' }
		'high-contrast', 'highcontrast' { 'high-contrast' }
		'sixteen', '16' { 'sixteen' }
		'neon-blue' { 'neon-blue' }
		'neon-green' { 'neon-green' }
		'neon-orange' { 'neon-orange' }
		'c64', 'commodore-64', 'commodore64' { 'c64' }
		'mono', 'monochrome' { 'mono' }
		else { none }
	}
}

fn theme_builtin(name string) Theme {
	return match name {
		'high-contrast' { theme_high_contrast() }
		'sixteen' { theme_sixteen() }
		'neon-blue' { theme_neon_blue() }
		'neon-green' { theme_neon_green() }
		'neon-orange' { theme_neon_orange() }
		'c64' { theme_c64() }
		'mono' { theme_mono() }
		else { theme_default() }
	}
}

fn theme_default() Theme {
	return Theme{
		bg:             reset_color
		fg:             rgb(0xc8, 0xd0, 0xc4)
		fg_dim:         rgb(0x60, 0x6a, 0x66)
		border:         rgb(0x36, 0x44, 0x44)
		border_focus:   rgb(0x7a, 0xc8, 0xb0)
		accent:         rgb(0xff, 0x6f, 0xc0)
		note:           rgb(0x9d, 0xe6, 0xc5)
		instrument:     rgb(0x8d, 0xc2, 0xff)
		volume:         rgb(0xff, 0xc4, 0x7a)
		effect:         rgb(0xff, 0x8a, 0xa9)
		meter_low:      rgb(0x5d, 0xa8, 0x88)
		meter_mid:      rgb(0xff, 0xc4, 0x7a)
		meter_high:     rgb(0xff, 0x5d, 0x5d)
		current_row_bg: rgb(0x1d, 0x2a, 0x28)
	}
}

fn theme_high_contrast() Theme {
	mut t := theme_default()
	t.fg = idx(15)
	t.fg_dim = idx(7)
	t.border = idx(15)
	t.border_focus = idx(3)
	t.accent = idx(5)
	t.current_row_bg = idx(8)
	return t
}

fn theme_sixteen() Theme {
	return Theme{
		bg:             reset_color
		fg:             idx(7)
		fg_dim:         idx(8)
		border:         idx(8)
		border_focus:   idx(6)
		accent:         idx(5)
		note:           idx(2)
		instrument:     idx(6)
		volume:         idx(3)
		effect:         idx(13)
		meter_low:      idx(2)
		meter_mid:      idx(3)
		meter_high:     idx(1)
		current_row_bg: idx(8)
	}
}

fn theme_neon_blue() Theme {
	return Theme{
		bg:             reset_color
		fg:             rgb(0xd8, 0xf7, 0xff)
		fg_dim:         rgb(0x5a, 0x8f, 0xaa)
		border:         rgb(0x16, 0x48, 0x66)
		border_focus:   rgb(0x00, 0xcc, 0xff)
		accent:         rgb(0x33, 0xf6, 0xff)
		note:           rgb(0x8f, 0xef, 0xff)
		instrument:     rgb(0x4c, 0xb8, 0xff)
		volume:         rgb(0x6c, 0xe7, 0xff)
		effect:         rgb(0xb6, 0xf4, 0xff)
		meter_low:      rgb(0x16, 0x8d, 0xff)
		meter_mid:      rgb(0x22, 0xd8, 0xff)
		meter_high:     rgb(0xe2, 0xfb, 0xff)
		current_row_bg: rgb(0x06, 0x28, 0x3b)
	}
}

fn theme_neon_green() Theme {
	return Theme{
		bg:             reset_color
		fg:             rgb(0xd8, 0xff, 0xdf)
		fg_dim:         rgb(0x5a, 0xaa, 0x6a)
		border:         rgb(0x16, 0x5a, 0x22)
		border_focus:   rgb(0x00, 0xff, 0x66)
		accent:         rgb(0x33, 0xff, 0x88)
		note:           rgb(0x8f, 0xff, 0xa0)
		instrument:     rgb(0x4c, 0xff, 0xaa)
		volume:         rgb(0x6c, 0xff, 0xc0)
		effect:         rgb(0xb6, 0xff, 0xe0)
		meter_low:      rgb(0x16, 0xcc, 0x44)
		meter_mid:      rgb(0x22, 0xff, 0x77)
		meter_high:     rgb(0xe2, 0xff, 0xf0)
		current_row_bg: rgb(0x06, 0x28, 0x10)
	}
}

fn theme_neon_orange() Theme {
	return Theme{
		bg:             reset_color
		fg:             rgb(0xff, 0xf0, 0xd8)
		fg_dim:         rgb(0xaa, 0x88, 0x5a)
		border:         rgb(0x66, 0x33, 0x16)
		border_focus:   rgb(0xff, 0x88, 0x00)
		accent:         rgb(0xff, 0xaa, 0x33)
		note:           rgb(0xff, 0xd5, 0x8f)
		instrument:     rgb(0xff, 0x8c, 0x4c)
		volume:         rgb(0xff, 0xc6, 0x6c)
		effect:         rgb(0xff, 0xd4, 0xb6)
		meter_low:      rgb(0xff, 0x6a, 0x16)
		meter_mid:      rgb(0xff, 0xa0, 0x22)
		meter_high:     rgb(0xff, 0xf2, 0xe2)
		current_row_bg: rgb(0x3b, 0x1f, 0x06)
	}
}

fn theme_c64() Theme {
	return Theme{
		bg:             rgb(0x35, 0x28, 0x79)
		fg:             rgb(0x6c, 0x5e, 0xb5)
		fg_dim:         rgb(0x4a, 0x3d, 0x99)
		border:         rgb(0x6c, 0x5e, 0xb5)
		border_focus:   idx(15)
		accent:         idx(15)
		note:           rgb(0x6c, 0x5e, 0xb5)
		instrument:     rgb(0x70, 0xa4, 0xb2)
		volume:         idx(15)
		effect:         rgb(0x9a, 0x67, 0x59)
		meter_low:      rgb(0x6c, 0x5e, 0xb5)
		meter_mid:      idx(15)
		meter_high:     rgb(0x9a, 0x67, 0x59)
		current_row_bg: rgb(0x4a, 0x3d, 0x99)
	}
}

fn theme_mono() Theme {
	return Theme{
		bg:             idx(0)
		fg:             rgb(0xe0, 0xe0, 0xe0)
		fg_dim:         rgb(0x70, 0x70, 0x70)
		border:         rgb(0x40, 0x40, 0x40)
		border_focus:   idx(15)
		accent:         idx(15)
		note:           rgb(0xd0, 0xd0, 0xd0)
		instrument:     rgb(0xb0, 0xb0, 0xb0)
		volume:         rgb(0xc0, 0xc0, 0xc0)
		effect:         rgb(0x90, 0x90, 0x90)
		meter_low:      rgb(0x60, 0x60, 0x60)
		meter_mid:      rgb(0xa0, 0xa0, 0xa0)
		meter_high:     idx(15)
		current_row_bg: rgb(0x1a, 0x1a, 0x1a)
	}
}

// parse_color parses a theme color string: `#rrggbb`, `reset`, or an ANSI color
// name (`cyan`, `dark-gray`, `light-magenta`, ...).
fn parse_color(value string) ?Color {
	trimmed := value.trim(' \t')
	if trimmed.len == 0 {
		return none
	}
	if trimmed[0] == `#` && trimmed.len == 7 {
		r := hex2(trimmed[1..3]) or { return none }
		g := hex2(trimmed[3..5]) or { return none }
		b := hex2(trimmed[5..7]) or { return none }
		return rgb(r, g, b)
	}
	mut norm := trimmed.to_lower().replace('_', '-').replace(' ', '-')
	return match norm {
		'reset' { reset_color }
		'black' { idx(0) }
		'red' { idx(1) }
		'green' { idx(2) }
		'yellow' { idx(3) }
		'blue' { idx(4) }
		'magenta' { idx(5) }
		'cyan' { idx(6) }
		'gray', 'grey' { idx(7) }
		'dark-gray', 'dark-grey' { idx(8) }
		'light-red' { idx(9) }
		'light-green' { idx(10) }
		'light-yellow' { idx(11) }
		'light-blue' { idx(12) }
		'light-magenta' { idx(13) }
		'light-cyan' { idx(14) }
		'white' { idx(15) }
		else { none }
	}
}

fn hex2(s string) ?u8 {
	mut v := 0
	for c in s {
		d := match true {
			c >= `0` && c <= `9` { int(c - `0`) }
			c >= `a` && c <= `f` { int(c - `a`) + 10 }
			c >= `A` && c <= `F` { int(c - `A`) + 10 }
			else { return none }
		}
		v = v * 16 + d
	}
	return u8(v)
}

// resolve_theme resolves a theme name to a Theme: a built-in (with aliases),
// else a custom `<theme_dir>/<name>.toml` file, else the default theme.
fn resolve_theme(theme_dir ?string, name string) Theme {
	if b := builtin_from_name(name) {
		return theme_builtin(b)
	}
	dir := theme_dir or { return theme_default() }
	return load_custom_theme(dir, name, 0) or { theme_default() }
}

// load_custom_theme loads `<theme_dir>/<name>.toml`: starts from its `extends`
// base (a built-in or another custom file) and applies the overrides it sets.
fn load_custom_theme(theme_dir string, name string, depth int) ?Theme {
	if depth > 8 {
		return none
	}
	path := os.join_path(theme_dir, '${name}.toml')
	text := os.read_file(path) or { return none }

	mut theme := theme_default()
	if parent := toml_get_string(text, 'extends') {
		if b := builtin_from_name(parent) {
			theme = theme_builtin(b)
		} else {
			theme = load_custom_theme(theme_dir, parent, depth + 1) or { theme_default() }
		}
	}

	apply_override(text, 'bg', mut theme.bg)
	apply_override(text, 'fg', mut theme.fg)
	apply_override(text, 'fg_dim', mut theme.fg_dim)
	apply_override(text, 'border', mut theme.border)
	apply_override(text, 'border_focus', mut theme.border_focus)
	apply_override(text, 'accent', mut theme.accent)
	apply_override(text, 'note', mut theme.note)
	apply_override(text, 'instrument', mut theme.instrument)
	apply_override(text, 'volume', mut theme.volume)
	apply_override(text, 'effect', mut theme.effect)
	apply_override(text, 'meter_low', mut theme.meter_low)
	apply_override(text, 'meter_mid', mut theme.meter_mid)
	apply_override(text, 'meter_high', mut theme.meter_high)
	apply_override(text, 'current_row_bg', mut theme.current_row_bg)
	return theme
}

fn apply_override(text string, key string, mut slot Color) {
	if v := toml_get_string(text, key) {
		if c := parse_color(v) {
			slot = c
		}
	}
}

// available_theme_choices is the list of selectable theme names for the `t`
// cycle: every built-in, followed by the stems of any `<theme_dir>/*.toml`
// files that don't shadow a built-in (sorted).
fn available_theme_choices(theme_dir ?string) []string {
	mut list := builtin_theme_names.clone()
	dir := theme_dir or { return list }
	entries := os.ls(dir) or { return list }
	mut customs := []string{}
	for entry in entries {
		if !entry.to_lower().ends_with('.toml') {
			continue
		}
		if !os.is_file(os.join_path(dir, entry)) {
			continue
		}
		stem := entry[..entry.len - '.toml'.len]
		if _ := builtin_from_name(stem) {
			continue // shadows a built-in
		}
		customs << stem
	}
	customs.sort()
	list << customs
	return list
}
