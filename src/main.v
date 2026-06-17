module main

import os
import time
import term.ui as tui

// vtrax CLI entry point: parse args, load config, start the audio engine,
// launch the TUI. Mirrors ztrax's main.zig.

struct Cli {
mut:
	files         []string
	playlist_path ?string
	shuffle       bool
	theme         ?string
	no_config     bool
}

fn main() {
	args := os.args[1..]

	// Headless smoke-test helpers (mirroring ztrax's load_print / play tools).
	if args.len >= 2 && args[0] == '--load-print' {
		load_print(args[1])
		return
	}
	if args.len >= 2 && args[0] == '--play' {
		secs := if args.len >= 3 { args[2].int() } else { 5 }
		play_headless(args[1], secs)
		return
	}
	if args.len >= 3 && args[0] == '--render' {
		parts := args[1].split('x')
		w := parts[0].int()
		h := if parts.len > 1 { parts[1].int() } else { 24 }
		render_once(w, h, args[2])
		return
	}

	cli := parse_args(args)

	mut cfg := if cli.no_config { Config{} } else { load_config() }
	theme_name := cli.theme or { cfg.theme_name }

	launch := resolve_sources(cli)

	mut state := new_shared_state()
	mut engine := new_engine(state) or {
		eprintln('error: could not initialize audio device')
		return
	}

	mut app := new_app(state, engine, theme_name, cfg.progress_style, cfg.auto_layout,
		cfg.default_browse_path)
	app.run(launch) or { eprintln('error: ${err}') }
}

fn parse_args(args []string) Cli {
	mut cli := Cli{}
	mut i := 0
	for i < args.len {
		a := args[i]
		if a == '--playlist' || a == '-l' {
			if i + 1 < args.len {
				i++
				cli.playlist_path = args[i]
			}
		} else if a == '--theme' {
			if i + 1 < args.len {
				i++
				cli.theme = args[i]
			}
		} else if a == '--shuffle' || a == '-z' {
			cli.shuffle = true
		} else if a == '--no-config' {
			cli.no_config = true
		} else if a.starts_with('-') {
			// Unknown flag -- ignore.
		} else {
			cli.files << a
		}
		i++
	}
	return cli
}

// resolve_sources decides playback mode, initial track, and playlist/save
// target from the CLI, mirroring ztrax's resolve_sources.
fn resolve_sources(cli Cli) Launch {
	if pl_path := cli.playlist_path {
		if cli.files.len == 0 {
			// Play the playlist as a queue.
			mut launch := Launch{
				mode:        .queue
				save_target: pl_path
				shuffle:     cli.shuffle
			}
			if queue := playlist_load_m3u(pl_path) {
				launch.playlist = queue
				launch.has_playlist = true
			}
			return launch
		}
		// Build mode: browse the given path, append to the playlist with `a`.
		t := browse_target(cli.files)
		return Launch{
			mode:         .browse
			initial_path: t.initial
			browse_root:  t.root
			save_target:  pl_path
			shuffle:      cli.shuffle
		}
	}

	if cli.files.len == 0 {
		return Launch{
			mode:    .browse
			shuffle: cli.shuffle
		}
	}
	if cli.files.len == 1 {
		t := browse_target(cli.files)
		return Launch{
			mode:         .browse
			initial_path: t.initial
			browse_root:  t.root
			shuffle:      cli.shuffle
		}
	}
	return Launch{
		mode:         .queue
		playlist:     playlist_from_files(cli.files)
		has_playlist: true
		shuffle:      cli.shuffle
	}
}

struct Target {
	initial ?string
	root    ?string
}

// browse_target: a directory argument roots the browser there with nothing
// playing; a file plays immediately and roots the browser at its parent folder.
fn browse_target(files []string) Target {
	p := files[0]
	if os.is_dir(p) {
		return Target{
			initial: none
			root:    p
		}
	}
	return Target{
		initial: p
		root:    os.dir(p)
	}
}

// load_print loads a module file and prints its metadata -- the FFI smoke test.
fn load_print(path string) {
	module_ := load_module_from_path(path) or {
		eprintln('error: libopenmpt could not parse ${path}')
		return
	}
	defer {
		module_.destroy()
	}
	println('path:        ${path}')
	println('title:       ${module_.metadata('title')}')
	println('format:      ${module_.metadata('type_long')}')
	println('tracker:     ${module_.metadata('tracker')}')
	println('channels:    ${module_.num_channels()}')
	println('patterns:    ${module_.num_patterns()}')
	println('orders:      ${module_.num_orders()}')
	println('samples:     ${module_.num_samples()}')
	println('instruments: ${module_.num_instruments()}')
	println('duration:    ${module_.duration_seconds():.1f}s')
}

// render_once renders a single TUI frame to stdout at a forced size, without
// entering raw mode -- a non-interactive rendering self-test.
fn render_once(w int, h int, path string) {
	mut state := new_shared_state()
	mut engine := new_engine(state) or {
		eprintln('error: audio device init failed')
		return
	}
	mut app := new_app(state, engine, 'default', ProgressStyle.blocks, true, none)
	if l := load_loaded(path) {
		app.loaded = l
		app.has_loaded = true
		engine.send(Command{
			kind:    .load
			module_: l.module_
		})
	}
	mut ctx := tui.init(
		user_data: app
		frame_fn:  frame_cb
		event_fn:  event_cb
	)
	app.tui = ctx
	app.p.ctx = ctx
	ctx.window_width = w
	ctx.window_height = h
	time.sleep(400 * time.millisecond) // let the audio thread populate live state
	app.frame()
	ctx.flush()
	engine.deinit()
	println('')
}

// play_headless plays a module through miniaudio for a few seconds without a
// UI -- the audio-engine smoke test.
fn play_headless(path string, secs int) {
	mut state := new_shared_state()
	mut engine := new_engine(state) or {
		eprintln('error: audio device init failed')
		return
	}
	loaded := load_loaded(path) or {
		eprintln('error: could not load ${path}')
		return
	}
	engine.send(Command{
		kind:    .load
		module_: loaded.module_
	})
	println('playing ${path} for ${secs}s at ${state.get_sample_rate()} Hz...')
	for i in 0 .. secs {
		time.sleep(time.second)
		println('t=${i + 1}s pos=${state.get_position_secs():.1f}s row=${state.get_current_row()} ch=${state.get_num_channels()} tempo=${state.get_tempo():.0f}')
	}
	engine.deinit()
}
