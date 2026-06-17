module main

import os

// Configuration loaded from `$XDG_CONFIG_HOME/vtrax/config.toml` (falling back
// to `~/.config/vtrax/config.toml`): theme selection, progress-bar style,
// pattern auto-layout, and a default browse path.

enum ProgressStyle {
	triangle
	blocks
	line
	segments
}

const progress_styles = [ProgressStyle.triangle, ProgressStyle.blocks, ProgressStyle.line,
	ProgressStyle.segments]

fn (p ProgressStyle) name() string {
	return match p {
		.triangle { 'triangle' }
		.blocks { 'blocks' }
		.line { 'line' }
		.segments { 'segments' }
	}
}

fn progress_style_from_name(s string) ?ProgressStyle {
	n := s.trim(' \t').to_lower()
	return match n {
		'triangle', 'tri' { ProgressStyle.triangle }
		'blocks', 'block' { ProgressStyle.blocks }
		'line' { ProgressStyle.line }
		'segments', 'segment', 'segmented' { ProgressStyle.segments }
		else { none }
	}
}

struct Config {
mut:
	theme_name          string = 'default'
	progress_style      ProgressStyle = .blocks
	auto_layout         bool = true
	default_browse_path ?string
}

// config_dir returns `$XDG_CONFIG_HOME/vtrax` or `~/.config/vtrax`.
fn config_dir() ?string {
	xdg := os.getenv('XDG_CONFIG_HOME')
	if xdg.len > 0 {
		return os.join_path(xdg, 'vtrax')
	}
	home := os.getenv('HOME')
	if home.len == 0 {
		return none
	}
	return os.join_path(home, '.config', 'vtrax')
}

// theme_dir returns the custom-theme directory: `<config dir>/themes`.
fn theme_dir() ?string {
	d := config_dir() or { return none }
	return os.join_path(d, 'themes')
}

// load_config loads config from disk, or returns defaults if the file is
// absent/unreadable.
fn load_config() Config {
	mut cfg := Config{}
	dir := config_dir() or { return cfg }
	path := os.join_path(dir, 'config.toml')
	text := os.read_file(path) or { return cfg }

	if t := toml_get_string(text, 'theme') {
		cfg.theme_name = t
	}
	if p := toml_get_string(text, 'progress_bar_style') {
		if ps := progress_style_from_name(p) {
			cfg.progress_style = ps
		}
	}
	if b := toml_get_bool(text, 'auto_layout') {
		cfg.auto_layout = b
	}
	if d := toml_get_string(text, 'default_browse_path') {
		cfg.default_browse_path = d
	}
	return cfg
}
