module main

import os

// File browser: lists the module files and subdirectories of the current
// directory, tracks a selection cursor, and steps through the folder's modules
// for next/previous navigation.

const module_exts = ['mod', 'xm', 'it', 's3m', 'mtm', 'mptm', 'stm', 'ult', '669', 'far', 'okt',
	'med']

struct Entry {
	path   string
	is_dir bool
	label  string
}

@[heap]
struct Browser {
mut:
	root     string
	entries  []Entry
	selected int
}

fn new_browser(root string) &Browser {
	abs := os.real_path(root)
	mut b := &Browser{
		root: abs
	}
	b.refresh()
	return b
}

fn (mut b Browser) refresh() {
	b.entries = []Entry{}

	// ".." entry pointing at the parent directory.
	parent := os.dir(b.root)
	if parent.len > 0 && parent != b.root {
		b.entries << Entry{
			path:   parent
			is_dir: true
			label:  '..'
		}
	}

	names := os.ls(b.root) or {
		b.clamp_selection()
		return
	}
	mut dirs := []Entry{}
	mut files := []Entry{}
	for name in names {
		full := os.join_path(b.root, name)
		if os.is_dir(full) {
			if name.starts_with('.') {
				continue // skip hidden
			}
			dirs << Entry{
				path:   full
				is_dir: true
				label:  name + '/'
			}
		} else if is_module_file(name) {
			files << Entry{
				path:   full
				is_dir: false
				label:  name
			}
		}
	}
	dirs.sort(a.label < b.label)
	files.sort(a.label.to_lower() < b.label.to_lower())
	b.entries << dirs
	b.entries << files
	b.clamp_selection()
}

fn (mut b Browser) clamp_selection() {
	if b.entries.len == 0 {
		b.selected = 0
	} else if b.selected >= b.entries.len {
		b.selected = b.entries.len - 1
	}
}

fn (mut b Browser) select_delta(delta int) {
	n := b.entries.len
	if n == 0 {
		return
	}
	b.selected = ((b.selected + delta) % n + n) % n
}

fn (b &Browser) selected_entry() ?Entry {
	if b.selected >= 0 && b.selected < b.entries.len {
		return b.entries[b.selected]
	}
	return none
}

// next_module / prev_module step to the next/previous module after `from` (the
// playing path) or the current selection, wrapping.
fn (mut b Browser) next_module(from ?string) ?string {
	return b.step_module(from, 1)
}

fn (mut b Browser) prev_module(from ?string) ?string {
	return b.step_module(from, -1)
}

fn (mut b Browser) step_module(from ?string, dir int) ?string {
	mut order := []int{}
	for i, e in b.entries {
		if !e.is_dir {
			order << i
		}
	}
	if order.len == 0 {
		return none
	}

	mut entry_idx := -1
	if f := from {
		for i, e in b.entries {
			if !e.is_dir && e.path == f {
				entry_idx = i
			}
		}
	} else {
		entry_idx = b.selected
	}

	mut pos := 0
	for k, x in order {
		if x == entry_idx {
			pos = k
		}
	}
	next_pos := ((pos + dir) % order.len + order.len) % order.len
	idx := order[next_pos]
	b.selected = idx
	return b.entries[idx].path
}

// activate descends into a directory (returns none) or returns the chosen
// module's path.
fn (mut b Browser) activate() ?string {
	e := b.selected_entry() or { return none }
	if e.is_dir {
		b.root = e.path
		b.refresh()
		b.selected = 0
		return none
	}
	return e.path
}

fn is_module_file(name string) bool {
	dot := name.last_index('.') or { return false }
	ext := name[dot + 1..].to_lower()
	return ext in module_exts
}
