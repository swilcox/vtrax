module main

// Starter tests for the minimal TOML reader.

const sample = '# a comment line
name = "vtrax"
single = \'quoted\'
shuffle = true
no_ui = false
bare = plain

[section]
name = "ignored"
shuffle = false
'

fn test_toml_get_string() {
	assert toml_get_string(sample, 'name')? == 'vtrax'
	assert toml_get_string(sample, 'single')? == 'quoted'
	// Unquoted values are returned verbatim.
	assert toml_get_string(sample, 'bare')? == 'plain'
}

fn test_toml_get_bool() {
	assert toml_get_bool(sample, 'shuffle')? == true
	assert toml_get_bool(sample, 'no_ui')? == false
}

// Keys inside [section] are not visible at the top level.
fn test_toml_skips_sections() {
	// `name`/`shuffle` resolve to the top-level values, never the section ones.
	assert toml_get_string(sample, 'name')? == 'vtrax'
	assert toml_get_bool(sample, 'shuffle')? == true
}

fn test_toml_absent_and_wrong_type() {
	if _ := toml_raw_value(sample, 'missing') {
		assert false
	}
	if _ := toml_get_string(sample, 'missing') {
		assert false
	}
	// A non-bool value yields none from toml_get_bool.
	if _ := toml_get_bool(sample, 'name') {
		assert false
	}
}

// Comment lines are ignored entirely.
fn test_toml_ignores_comments() {
	if _ := toml_raw_value('# name = "nope"\n', 'name') {
		assert false
	}
}
