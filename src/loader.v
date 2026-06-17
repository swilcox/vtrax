module main

// Loads a module on the UI thread and captures everything the UI needs to
// display it -- metadata, sample/instrument names, and the preformatted pattern
// cache -- before the module handle is shipped to the audio thread.
//
// The libopenmpt handle's destruction is owned by the audio engine (its drop
// ring / deinit), so Loaded never destroys it.

@[heap]
struct Loaded {
mut:
	module_          Module
	path             string
	title            string
	format_label     string
	song_message     string
	artist           string
	tracker          string
	sample_names     []string
	instrument_names []string
	cache            PatternCache
}

fn load_loaded(path string) ?Loaded {
	m := load_module_from_path(path) or { return none }

	num_samples := imax(0, m.num_samples())
	mut sample_names := []string{len: num_samples}
	for i in 0 .. num_samples {
		sample_names[i] = m.sample_name(i)
	}

	num_instruments := imax(0, m.num_instruments())
	mut instrument_names := []string{len: num_instruments}
	for i in 0 .. num_instruments {
		instrument_names[i] = m.instrument_name(i)
	}

	cache := build_pattern_cache(m)

	return Loaded{
		module_:          m
		path:             path
		title:            m.metadata('title')
		format_label:     m.metadata('type_long')
		song_message:     m.metadata('message')
		artist:           m.metadata('artist')
		tracker:          m.metadata('tracker')
		sample_names:     sample_names
		instrument_names: instrument_names
		cache:            cache
	}
}

fn build_pattern_cache(m Module) PatternCache {
	num_patterns := imax(0, m.num_patterns())
	num_channels := imax(0, m.num_channels())
	mut patterns := []PatternData{len: num_patterns}

	for p in 0 .. num_patterns {
		num_rows := imax(0, m.pattern_num_rows(p))
		mut rows := []PatternRow{len: num_rows}
		for r in 0 .. num_rows {
			mut cells := []string{len: num_channels}
			mut insts := []u8{len: num_channels}
			for ch in 0 .. num_channels {
				cells[ch] = m.format_cell(p, r, ch)
				inst := m.cell_command(p, r, ch, openmpt_command_instrument)
				insts[ch] = u8(iclamp(inst, 0, 255))
			}
			rows[r] = PatternRow{
				row_index:   r
				cells:       cells
				instruments: insts
			}
		}
		patterns[p] = PatternData{
			rows:          rows
			channel_count: num_channels
		}
	}
	return PatternCache{
		patterns: patterns
	}
}
