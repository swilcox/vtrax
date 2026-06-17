module main

import os

// M3U playlist -- a list of module paths with an optional backing file.
//
// Plain-text M3U: one path per line, `#`-prefixed lines are comments. Relative
// entries in a loaded file resolve against the playlist's directory.

@[heap]
struct Playlist {
mut:
	entries []string
	// Play order: a permutation of indices into `entries`. Identity unless
	// shuffled.
	order []int
	path  ?string
}

// playlist_from_files builds an in-memory playlist from a list of paths (no
// backing file).
fn playlist_from_files(files []string) Playlist {
	mut pl := Playlist{}
	for i, f in files {
		pl.entries << f
		pl.order << i
	}
	return pl
}

// playlist_load_m3u loads an M3U file. Comment/blank lines are skipped;
// relative entries resolve against the file's directory.
fn playlist_load_m3u(path string) ?Playlist {
	text := os.read_file(path) or { return none }
	mut pl := Playlist{
		path: path
	}
	base := os.dir(path)
	mut idx := 0
	for raw in text.split_into_lines() {
		line := raw.trim(' \t\r')
		if line.len == 0 || line[0] == `#` {
			continue
		}
		entry := if os.is_abs_path(line) { line } else { os.join_path(base, line) }
		pl.entries << entry
		pl.order << idx
		idx++
	}
	return pl
}

fn (pl &Playlist) len() int {
	return pl.entries.len
}

fn (pl &Playlist) is_empty() bool {
	return pl.entries.len == 0
}

fn (pl &Playlist) get(index int) ?string {
	if index >= 0 && index < pl.entries.len {
		return pl.entries[index]
	}
	return none
}

fn (pl &Playlist) position(path string) ?int {
	for i, e in pl.entries {
		if paths_equal(e, path) {
			return i
		}
	}
	return none
}

// start is the first entry in play order -- the shuffled head when shuffle is
// on.
fn (pl &Playlist) start() ?string {
	if pl.order.len == 0 {
		return none
	}
	return pl.entries[pl.order[0]]
}

// next_after is the entry immediately after `current` in play order, or none at
// the end.
fn (pl &Playlist) next_after(current string) ?string {
	pos := pl.order_pos(current) or { return none }
	if pos + 1 >= pl.order.len {
		return none
	}
	return pl.entries[pl.order[pos + 1]]
}

// prev_before is the entry immediately before `current` in play order, or none
// at the start.
fn (pl &Playlist) prev_before(current string) ?string {
	pos := pl.order_pos(current) or { return none }
	if pos == 0 {
		return none
	}
	return pl.entries[pl.order[pos - 1]]
}

fn (pl &Playlist) is_shuffled() bool {
	for i, v in pl.order {
		if v != i {
			return true
		}
	}
	return false
}

// push appends an entry (e.g. via `a`), keeping play order consistent.
fn (mut pl Playlist) push(path string) {
	pl.order << pl.entries.len
	pl.entries << path
}

// set_shuffle turns shuffle on/off. When turning on, `anchor` (the playing
// track) is moved to the head so playback continues from it.
fn (mut pl Playlist) set_shuffle(on bool, anchor ?string) {
	n := pl.entries.len
	pl.order = []int{}
	if !on {
		for i in 0 .. n {
			pl.order << i
		}
		return
	}
	pl.order = []int{len: n}
	mut r := rng_from_entropy()
	permutation(mut pl.order, mut r)
	if a := anchor {
		if ai := pl.position(a) {
			for pos, x in pl.order {
				if x == ai {
					pl.order[0], pl.order[pos] = pl.order[pos], pl.order[0]
					break
				}
			}
		}
	}
}

fn (pl &Playlist) order_pos(current string) ?int {
	entry_idx := pl.position(current) or { return none }
	for i, x in pl.order {
		if x == entry_idx {
			return i
		}
	}
	return none
}

// paths_equal: exact, or case-insensitive (for case-insensitive filesystems
// like macOS's default).
fn paths_equal(a string, b string) bool {
	if a == b {
		return true
	}
	return a.to_lower() == b.to_lower()
}

// file_contains reports whether the playlist file already lists `entry`. False
// (proceed) if the file is missing/unreadable.
fn file_contains(entry string, playlist_path string) bool {
	text := os.read_file(playlist_path) or { return false }
	base := os.dir(playlist_path)
	for raw in text.split_into_lines() {
		line := raw.trim(' \t\r')
		if line.len == 0 || line[0] == `#` {
			continue
		}
		resolved := if os.is_abs_path(line) { line } else { os.join_path(base, line) }
		if paths_equal(resolved, entry) {
			return true
		}
	}
	return false
}

// append_to_file appends `entry` to the playlist file, creating it (with an
// `#EXTM3U` header) and any parent directories if needed.
fn append_to_file(entry string, playlist_path string) ! {
	parent := os.dir(playlist_path)
	if parent.len > 0 {
		os.mkdir_all(parent) or {}
	}
	mut buf := ''
	if os.exists(playlist_path) {
		existing := os.read_file(playlist_path) or { '' }
		buf += existing
		if existing.len > 0 && existing[existing.len - 1] != `\n` {
			buf += '\n'
		}
	} else {
		buf += '#EXTM3U\n'
	}
	buf += entry + '\n'
	os.write_file(playlist_path, buf)!
}
