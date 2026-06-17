module main

// A deliberately tiny TOML reader -- just enough for vtrax's flat config and
// theme files: top-level `key = "string"` / `key = true|false` lines, `#`
// comments, and `[section]` headers (which are skipped).

// toml_raw_value returns the raw right-hand side of `key = ...` at the top level
// (outside any `[section]`), or none. Trailing inline comments are not stripped.
fn toml_raw_value(text string, key string) ?string {
	mut in_section := false
	for raw in text.split_into_lines() {
		line := raw.trim(' \t\r')
		if line.len == 0 || line[0] == `#` {
			continue
		}
		if line[0] == `[` {
			in_section = true
			continue
		}
		if in_section {
			continue // only read top-level keys
		}
		eq := line.index('=') or { continue }
		k := line[..eq].trim(' \t')
		if k == key {
			return line[eq + 1..].trim(' \t')
		}
	}
	return none
}

// toml_get_string returns a top-level string value with surrounding quotes
// stripped, or none.
fn toml_get_string(text string, key string) ?string {
	v := toml_raw_value(text, key) or { return none }
	if v.len >= 2 && (v[0] == `"` || v[0] == `'`) && v[v.len - 1] == v[0] {
		return v[1..v.len - 1]
	}
	return v
}

// toml_get_bool returns a top-level boolean value, or none if absent / not a
// bool.
fn toml_get_bool(text string, key string) ?bool {
	v := toml_raw_value(text, key) or { return none }
	if v == 'true' {
		return true
	}
	if v == 'false' {
		return false
	}
	return none
}
