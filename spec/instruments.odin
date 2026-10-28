package odawg_spec

import "base:runtime"
import "core:encoding/json"
import "core:slice"
import "core:strconv"
import "core:strings"
import base "../base"
import device "../device"

// Instruments are rows of data over the node kinds of device's registry,
// read into a program where a part plays them (their times at that part's
// tempo). A part's instrument is one of:
//
//   - a name: a row the spec declares (`instruments = { name = row }`, or
//     a file of rows: `instruments = "instruments/classic.json"`; a style's
//     own, then its song's), else one of the built-in rows (Tone's classes,
//     tone_rows.json, written in the same shape as any file of rows);
//   - a file of one row: `"instruments/tb303.json"` (a name with a / or
//     ending .json, from the spec's folder or a source: the host reads it,
//     instrument_files);
//   - a name and changes: `{ "MonoSynth", oscillator = { type = "sine" } }`
//     (the row's `options`: Tone's names for its nodes' fields) or
//     `{ "my_pad", nodes = { env = { release = 2 } } }` (by node);
//   - a row: `{ nodes = { name = { "Kind", inputs..., fields } }, out,
//     length, note, mono, portamento, velocity }`, or a machine: `{ pads =
//     { name = instrument with key, choke, gain_db } }`.
//
// A row is read into a draft first (the named row, then each change over
// it, so a finding names where its value was written) and then placed: its
// nodes sorted by what they read (the order of a row's keys means nothing),
// those the out doesn't hear left out, their times in seconds, their sets
// the bank's, their outputs in buffers handed out by liveness.

TONE_ROWS_TEXT :: #load("tone_rows.json", string)

@(private = "file")
tone_rows: json.Object

@(init, private = "file")
tone_rows_init :: proc "contextless" () {
	context = runtime.default_context()
	v, err := json.parse_string(TONE_ROWS_TEXT, .JSON5, true)
	assert(err == nil, "tone_rows.json")
	tone_rows = v.(json.Object)
}

// The built-in rows' names, sorted.
tone_row_names :: proc(allocator := context.temp_allocator) -> []string {
	return sorted_keys(tone_rows, allocator)
}

// A built-in row as JSON text (what `odawg show instrument/NAME` prints).
tone_row_text :: proc(name: string, allocator := context.temp_allocator) -> (string, bool) {
	v, found := tone_rows[name]
	if !found {
		return "", false
	}
	b, _ := json.marshal(v, {pretty = true, use_spaces = true, spaces = 2}, allocator)
	return string(b), true
}

// A file of rows a spec reads (an instrument by path, or `instruments` by
// path), as the host handed its text back.
Instrument_File :: struct {
	path:  string,
	value: json.Value,
}

// An SFZ instrument at `path` (its file, then what it includes), as the
// assets layer read it declaring its samples: what compiling it and its
// options read, read once.
Sfz_File :: struct {
	path: string,
	sfz:  Sfz,
}

// The SFZ instrument at `path`, read from its texts (its file's and, by
// path, what it includes; "": one that couldn't be read) into the spec's
// memory: the song's (a style's spec is read again where it plays).
spec_add_sfz :: proc(s: ^Spec, path: string, texts: map[string]string) {
	s := song_spec(s)
	if s.sfz_files.allocator.procedure != nil {
		context.allocator = s.sfz_files.allocator
	}
	kept := make(map[string]string)
	for p, t in texts {
		if t != "" {
			kept[strings.clone(p)] = strings.clone(t)
		}
	}
	f := Sfz_File{path = strings.clone(path)}
	sfz_read(&f.sfz, f.path, kept[f.path], kept)
	for &x in s.sfz_files {
		if x.path == path {
			x = f
			return
		}
	}
	append(&s.sfz_files, f)
}

// The SFZ instrument at `path` the song was handed. Nil: none.
spec_sfz :: proc(s: ^Spec, path: string) -> ^Sfz {
	for &f in song_spec(s).sfz_files {
		if f.path == path {
			return &f.sfz
		}
	}
	return nil
}

// Whether an instrument's name is an SFZ file's.
is_sfz_name :: proc(name: string) -> bool {
	return strings.has_suffix(strings.to_lower(name, context.temp_allocator), ".sfz")
}

// Whether an instrument's name is a file's path.
is_file_name :: proc(name: string) -> bool {
	return strings.contains(name, "/") || strings.has_suffix(name, ".json")
}

// The instrument files s (its styles, the files already read) names that
// it hasn't been given yet, each once, from the song's folder: what a host
// reads and hands back (spec_add_instrument_text) before composing, until
// this lists none.
instrument_files :: proc(s: ^Spec, out: ^[dynamic]string) {
	add :: proc(s: ^Spec, from: ^Spec, out: ^[dynamic]string, name: string) {
		if !is_file_name(name) || is_sfz_name(name) {
			return // an SFZ file is read with its samples (the assets layer)
		}
		path := path_from(from, name, context.allocator)
		for f in s.instrument_files {
			if f.path == path {
				return
			}
		}
		if !slice.contains(out[:], path) {
			append(out, path)
		}
	}
	walk :: proc(s: ^Spec, from: ^Spec, out: ^[dynamic]string, v: json.Value) {
		#partial switch x in v {
		case json.String:
			add(s, from, out, x)
		case json.Object:
			add(s, from, out, named(x))
			if inst, has := x["instrument"].(json.String); has {
				add(s, from, out, inst)
			}
			if pads, has := x["pads"].(json.Object); has {
				for _, p in pads {
					walk(s, from, out, p)
				}
			}
			if layers, has := x["layers"].(json.Array); has {
				for l in layers {
					if lo, is_table := l.(json.Object); is_table {
						walk(s, from, out, lo["instrument"])
					}
				}
			}
		}
	}
	for d in s.devices {
		if device.DEVICE_TABLE[d.kind].program {
			walk(s, s, out, d.row)
		}
	}
	for x in s.instruments {
		walk(s, s, out, x.value)
	}
	for x in s.effects {
		walk(s, s, out, x.value)
	}
	for inc in s.instrument_includes {
		add(s, s, out, inc)
	}
	for inc in s.effect_includes {
		add(s, s, out, inc)
	}
	for f in s.instrument_files {
		if x, is_table := f.value.(json.Object); is_table {
			_, is_row := x["nodes"]
			_, is_machine := x["pads"]
			if is_row || is_machine {
				walk(s, s, out, x)
			} else {
				for _, row in x {
					walk(s, s, out, row)
				}
			}
		}
	}
	for st in s.styles {
		own := st.spec
		for d in own.devices {
			if device.DEVICE_TABLE[d.kind].program {
				walk(s, own, out, d.row)
			}
		}
		for x in own.instruments {
			walk(s, own, out, x.value)
		}
		for x in own.effects {
			walk(s, own, out, x.value)
		}
		for inc in own.instrument_includes {
			add(s, own, out, inc)
		}
		for inc in own.effect_includes {
			add(s, own, out, inc)
		}
	}
}

// A file of rows' text, as the file at `path` (instrument_files'). False:
// not JSON (a finding).
spec_add_instrument_text :: proc(s: ^Spec, path, text: string, findings: ^base.Findings) -> bool {
	v, err := json.parse_string(text, .JSON5, true)
	if err != nil {
		base.report(findings, "bad_json", .Error, path, "instrument file %s is not valid JSON (%v)", path, err)
		return false
	}
	append(&s.instrument_files, Instrument_File{path = strings.clone(path), value = v})
	return true
}

@(private = "file")
file_value :: proc(from: ^Spec, name: string) -> (json.Value, string, bool) {
	path := path_from(from, name)
	for o := from; o != nil; o = o.outer {
		for f in o.instrument_files {
			if f.path == path {
				return f.value, f.path, true
			}
		}
	}
	return nil, path, false
}

// Where a Lua table's positional entries go, by where the table sits (its
// path: `parts/bass/instrument/nodes/env`): the keys the first ones fill,
// and the key the rest are a list of ("": none). The one owner of the
// shorthand: a host turning `{ "Mix", "body", "tick" }` into a json.Value
// asks this, so the JSON and the Lua read the same.
positional_fields :: proc(path: string) -> (fields: []string, rest: string) {
	parts := strings.split(path, "/", context.temp_allocator)
	match :: proc(parts: []string, pattern: []string) -> bool {
		if len(parts) < len(pattern) {
			return false
		}
		tail := parts[len(parts) - len(pattern):]
		for p, i in pattern {
			if p != "*" && p != tail[i] {
				return false
			}
		}
		return true
	}
	for row in POSITIONAL {
		if match(parts, row.pattern) && (!row.anchored || len(parts) == len(row.pattern)) {
			return row.fields, row.rest
		}
	}
	return nil, ""
}

// Whether a table at `path` holding only positional entries (`entries` of
// them, none keyed; `first_is_string`: its first is a string) is a list,
// not a record: it is a list, unless the place reads it as a row (a node:
// its class, then its inputs) or it is one string where a record goes (an
// instrument's or an effect's name, a pad's instrument). A field's list of
// modulators, `inputs`, a bank of frequencies: lists. With any key it is a
// record (positional_fields says where its entries go).
positional_list :: proc(path: string, entries: int, first_is_string: bool) -> bool {
	fields, rest := positional_fields(path)
	if rest != "" {
		return false
	}
	if entries == 1 && first_is_string && len(fields) > 0 && fields[0] != "base" {
		return false
	}
	return true
}

@(private = "file")
Positional_Row :: struct {
	pattern:  []string, // the path's last parts (`*` any)
	anchored: bool, // the whole path
	fields:   []string,
	rest:     string,
}

@(private = "file")
POSITIONAL := []Positional_Row {
	{pattern = {"options", "*"}, fields = {"path"}}, // an option's target: { "node/field", op = "mul" }
	{pattern = {"options", "*", "*"}, fields = {"path"}}, // one of its list of targets
	{pattern = {"nodes", "*"}, fields = {"class"}, rest = "inputs"},
	{pattern = {"nodes", "*", "*"}, fields = {"base"}},
	{pattern = {"nodes", "*", "*", "*"}, fields = {"base"}}, // one of a field's list of modulators
	{pattern = {"pads", "*"}, fields = {"instrument"}},
	{pattern = {"instrument"}, fields = {"name"}},
	{pattern = {"instruments", "*"}, fields = {"name"}},
	{pattern = {"effects", "*"}, fields = {"name"}},
	{pattern = {"effects"}, fields = {"name"}},
	{pattern = {"returns", "*", "*"}, fields = {"name"}},
	{pattern = {"returns", "*"}, fields = {"name"}},
	{pattern = {"sections", "*"}, anchored = true, fields = {"name"}},
	{pattern = {"markers", "*"}, anchored = true, fields = {"name"}},
	{pattern = {"play", "*"}, fields = {"name"}},
	{pattern = {"play"}, fields = {"name"}},
	{pattern = {"sidechain"}, fields = {"name"}},
	{pattern = {"zones", "*"}, fields = {"file"}},
}

// ---- drafts ------------------------------------------------------------------------

@(private = "file")
Slots :: bit_set[0 ..< 64;u64]

@(private = "file")
Draft_Mod :: struct {
	slot:     int,
	source:   string,
	kind:     device.Mod_Kind,
	amount:   f32,
	exponent: f32,
	path:     string,
}

@(private = "file")
Draft_Node :: struct {
	name:     string,
	kind:     device.Node_Kind,
	values:   [device.MAX_FIELDS]f32,
	beats:    Slots, // a Tone length: times a beat's seconds (a rate: per beat)
	set_name: string, // a Sampler's
	set_from: ^Spec, // where its set's name was written: the spec it is read in
	set_path: string,
	inputs:   [dynamic]string,
	mods:     [dynamic]Draft_Mod,
	owner:    ^Spec, // whose sets its Sampler names
	path:     string,
}

// A layer of a layered row: its conditions and its instrument.
@(private = "file")
Draft_Layer :: struct {
	region: device.Layer_Region,
	gain:   f32,
	value: json.Value, // its instrument
	owner: ^Spec,
	path:  string,
}

@(private = "file")
Draft_Pad :: struct {
	name:    string,
	row:     json.Value, // its instrument
	key:     f64,
	gain_db: f64,
	chokes:  [dynamic]string,
	owner:   ^Spec,
	path:    string,
}

@(private)
Draft :: struct {
	nodes:        [dynamic]Draft_Node,
	pads:         [dynamic]Draft_Pad,
	layers:       [dynamic]Draft_Layer,
	sw_lo, sw_hi, sw_default: u8, // 1 + the keys that switch its layers (0: none)
	sfz_name:     string, // an SFZ instrument's file (as written; "": none)
	sfz_owner:    ^Spec, // where it was named (its path is from that spec's folder)
	sfz_cc:       [128]f32, // the CC values the row gave (ccN = v, or a label_ccN's name)
	sfz_cc_given: bit_set[0 ..< 128;u128],
	sfz_overrides: map[string]f64, // opcodes for every region (the Sampler form's attack, release)
	out:          string,
	length:       f64,
	length_beats: bool,
	note:         f64,
	mono:         bool,
	portamento:   f64,
	porta_beats:  bool,
	velocity:     bool, // the out is scaled by velocity
	controls:     [dynamic]Draft_Control, // its options: by name, each its targets and the value the row gave
	origin:       string, // the row's name, for findings ("MonoSynth"; "": written out)
	path:         string, // where its nodes or pads were written (the findings about them are there)
}

@(private = "file")
Draft_Control :: struct {
	name:       string,
	targets:    [dynamic]device.Target_Desc,
	value:      json.Value, // nil: none given
	value_path: string,
	path:       string, // where its targets were written
}

@(private = "file")
Ctx :: struct {
	writer:       ^Spec, // the spec whose row is being read (a set's name is read in it)
	progs:        ^device.Programs,
	bank:         ^device.Bank,
	beat_seconds: f64,
	findings:     ^base.Findings,
	drafts:       ^Drafts, // rows already drafted (nil: none kept)
	effect:       bool, // an effect row is read (its names are the `effects` tables'), not an instrument
	fixed:        ^[dynamic]Fixed_Tone, // where a Tone length was read once at beat_seconds (nil: not asked)
}

// A Tone length read once at the tempo a row is placed at: where it was
// written, and whether it is a rate (a frequency) or a length.
Fixed_Tone :: struct {
	path: string,
	rate: bool,
}

// Instruments as drafted (a row's bases, files, built-ins and overrides
// resolved), each row once: by the spec it is read in and where it was
// written (its durable id). A compose's, or a pass over a song's sets';
// drafting needs no tempo, so a row drafted once is placed at every tempo.
Drafts :: struct {
	rows: [dynamic]Drafted,
}

@(private)
Drafted :: struct {
	owner: ^Spec,
	path:  string,
	draft: ^Draft,
	ok:    bool,
}

drafts_init :: proc(d: ^Drafts, allocator := context.temp_allocator) {
	d.rows = make([dynamic]Drafted, allocator)
}

// The row written at `path` in `owner` (v), drafted: once per Drafts.
@(private = "file")
drafted :: proc(c: ^Ctx, v: json.Value, path: string, owner: ^Spec) -> (^Draft, bool) {
	if c.drafts != nil {
		for x in c.drafts.rows {
			if x.owner == owner && x.path == path {
				return x.draft, x.ok
			}
		}
	}
	d := new(Draft, context.temp_allocator)
	draft_init(d)
	ok := draft_read(c, d, v, path, owner, 0)
	if c.drafts != nil {
		append(&c.drafts.rows, Drafted{owner, path, d, ok})
	}
	return d, ok
}

@(private = "file")
draft_init :: proc(d: ^Draft) {
	d^ = {}
	d.nodes = make([dynamic]Draft_Node, context.temp_allocator)
	d.pads = make([dynamic]Draft_Pad, context.temp_allocator)
	d.layers = make([dynamic]Draft_Layer, context.temp_allocator)
	d.controls = make([dynamic]Draft_Control, context.temp_allocator)
	d.out = "out"
	d.velocity = true
}

@(private)
sorted_keys :: proc(o: json.Object, allocator := context.temp_allocator) -> []string {
	keys := make([dynamic]string, allocator)
	for k in o {
		append(&keys, k)
	}
	slice.sort(keys[:])
	return keys[:]
}

@(private = "file")
named :: proc(o: json.Object) -> string {
	if s, ok := o["name"].(json.String); ok {
		return s
	}
	if s, ok := o["class"].(json.String); ok {
		return s
	}
	return ""
}

@(private = "file")
report :: proc(c: ^Ctx, code: string, severity: base.Severity, path: string, format: string, args: ..any) {
	base.report(c.findings, code, severity, path, format, ..args)
}

// Reads an instrument as written onto d.
@(private = "file")
draft_read :: proc(c: ^Ctx, d: ^Draft, v: json.Value, path: string, owner: ^Spec, depth: int) -> bool {
	#partial switch x in v {
	case json.String:
		return draft_base(c, d, x, path, owner, depth)
	case json.Object:
		if name := named(x); name != "" && !draft_base(c, d, name, path, owner, depth) {
			return false
		}
		writer := c.writer
		c.writer = owner
		draft_apply(c, d, x, path, owner)
		c.writer = writer
		return true
	}
	report(c, "bad_value", .Error, path, "%s: an instrument: a name, or a row ({{ nodes = {{ ... }} }})", path)
	return false
}

// The named row: a file's, the spec's (or its song's) own, else a built-in one.
@(private = "file")
draft_base :: proc(c: ^Ctx, d: ^Draft, name, path: string, owner: ^Spec, depth: int) -> bool {
	if depth > 8 {
		report(c, "instrument_cycle", .Error, path, "%s: %q names itself (through other rows)", path, name)
		return false
	}
	if is_sfz_name(name) {
		// an SFZ instrument: compiled from its text when placed
		d.sfz_name, d.sfz_owner = name, owner
		d.path = path
		return true
	}
	if is_file_name(name) {
		v, file, found := file_value(owner, name)
		if !found {
			report(c, "missing_file", .Error, path, "%s: instrument file %s couldn't be read (a path beside the song, or in a source it declares)", path, file)
			return false
		}
		if o, is_table := v.(json.Object); is_table && len(o) == 0 {
			return false // a file the host couldn't read (its finding says so)
		}
		return draft_read(c, d, v, file, owner, depth + 1)
	}
	for o := owner; o != nil; o = o.outer {
		rows, includes, table_name := row_tables(c, o)
		for x in rows {
			if x.name == name {
				return draft_read(c, d, x.value, base.path_join(table_name, name), o, depth + 1)
			}
		}
		for inc in includes {
			v, file, found := file_value(o, inc)
			if !found {
				continue
			}
			if table, is_table := v.(json.Object); is_table {
				if row, has := table[name]; has {
					return draft_read(c, d, row, base.path_join(file, name), o, depth + 1)
				}
			}
		}
	}
	if v, found := tone_rows[name]; found && !c.effect {
		ok := draft_read(c, d, v, base.path_join("instrument", name), nil, depth + 1)
		d.origin = name
		return ok
	}
	names := make([dynamic]string, context.temp_allocator)
	for o := owner; o != nil; o = o.outer {
		rows, includes, _ := row_tables(c, o)
		for x in rows {
			append(&names, x.name)
		}
		for inc in includes {
			if v, _, found := file_value(o, inc); found {
				if table, is_table := v.(json.Object); is_table {
					append(&names, ..sorted_keys(table))
				}
			}
		}
	}
	if c.effect {
		for row in device.DEVICE_TABLE {
			if row.name != "" {
				append(&names, row.name)
			}
		}
		report(c, "unknown_effect", .Error, path, "%s: %q is not an effect here (%s)", path, name, strings.join(names[:], ", ", context.temp_allocator))
		return false
	}
	append(&names, ..tone_row_names())
	report(c, "unknown_instrument", .Error, path, "%s: %q is not an instrument here (%s)", path, name, strings.join(names[:], ", ", context.temp_allocator))
	return false
}

// The rows a spec names for what is read: its instruments, or (an effect
// row) its effect rows; and the table's name, for paths.
@(private = "file")
row_tables :: proc(c: ^Ctx, o: ^Spec) -> (rows: []Instrument_Spec, includes: []string, table_name: string) {
	if c.effect {
		return o.effects[:], o.effect_includes[:], "effects"
	}
	return o.instruments[:], o.instrument_includes[:], "instruments"
}

// A row's keys over d: its nodes, pads, out, length, note, mono,
// portamento, velocity, options, and any of its options by their names
// (in that order, whatever order they were written in).
@(private = "file")
draft_apply :: proc(c: ^Ctx, d: ^Draft, o: json.Object, path: string, owner: ^Spec) {
	// its nodes and pads, then its options, then the rest (an option's
	// value, written beside `options` in the same row, finds it declared)
	keys := sorted_keys(o)
	rank :: proc(k: string) -> int {
		switch k {
		case "nodes", "pads", "layers":
			return 0
		case "options":
			return 1
		}
		return 2
	}
	slice.stable_sort_by(keys, proc(a, b: string) -> bool {return rank(a) < rank(b)})
	for k in keys {
		v := o[k]
		at := base.path_join(path, k)
		switch k {
		case "name", "class", "description":
		case "nodes":
			d.path = path
			nodes, ok := v.(json.Object)
			if !ok {
				report(c, "bad_value", .Error, at, "%s: {{ name = {{ \"Kind\", ... }} }} per node", at)
				continue
			}
			for name in sorted_keys(nodes) {
				draft_node(c, d, name, nodes[name], base.path_join(at, name), owner)
			}
		case "pads":
			d.path = path
			pads, ok := v.(json.Object)
			if !ok {
				report(c, "bad_value", .Error, at, "%s: {{ name = instrument }} per pad", at)
				continue
			}
			for name in sorted_keys(pads) {
				draft_pad(c, d, name, pads[name], base.path_join(at, name), owner)
			}
		case "layers":
			d.path = path
			list, ok := v.(json.Array)
			if !ok {
				report(c, "bad_value", .Error, at, "%s: a list of layers: {{ instrument, lo_key, hi_key, lo_vel, ... }}", at)
				continue
			}
			for x, i in list {
				draft_layer(c, d, x, base.path_index(at, i + 1), owner)
			}
		case "sw_lo":
			d.sw_lo = 1 + u8(clamp(note_value(c, v, at), 0, 127))
		case "sw_hi":
			d.sw_hi = 1 + u8(clamp(note_value(c, v, at), 0, 127))
		case "sw_default":
			d.sw_default = 1 + u8(clamp(note_value(c, v, at), 0, 127))
		case "out":
			if s, is_string := v.(json.String); is_string {
				d.out = s
			} else {
				report(c, "bad_value", .Error, at, "%s: the name of the node it plays", at)
			}
		case "length":
			d.length, d.length_beats = seconds_value(c, v, at)
		case "portamento":
			d.portamento, d.porta_beats = seconds_value(c, v, at)
		case "note":
			d.note = f64(note_value(c, v, at))
		case "mono":
			b, is_bool := v.(json.Boolean)
			if !is_bool {
				report(c, "bad_value", .Error, at, "%s: true or false", at)
			}
			d.mono = bool(b)
		case "velocity":
			s, _ := v.(json.String)
			switch s {
			case "amp":
				d.velocity = true
			case "none":
				d.velocity = false
			case:
				report(c, "bad_value", .Error, at, "%s: \"amp\" (the out follows the velocity) or \"none\" (the row reads it itself)", at)
			}
		case "options":
			opts, ok := v.(json.Object)
			if !ok {
				report(c, "bad_value", .Error, at, "%s: {{ option = \"node/field\" }}", at)
				continue
			}
			for name in sorted_keys(opts) {
				option_targets(c, d, name, opts[name], base.path_join(at, name))
			}
		case:
			draft_option(c, d, k, v, at)
		}
	}
}

@(private = "file")
seconds_value :: proc(c: ^Ctx, v: json.Value, path: string) -> (f64, bool) {
	if n, is_number := number_from_value(v); is_number {
		return n, false
	}
	if s, is_string := v.(json.String); is_string {
		if value, beats, _, ok := unit_from_text(.Seconds, nil, s); ok {
			return f64(value), beats
		}
	}
	report(c, "bad_value", .Error, path, "%s: seconds or a Tone length (\"4n\")", path)
	return 0, false
}

// An option's targets: one (`"node/field"`, or `{ path, op = set | mul |
// add | octaves, scale, offset }`) or a list of them.
@(private = "file")
option_targets :: proc(c: ^Ctx, d: ^Draft, name: string, v: json.Value, path: string) {
	x: ^Draft_Control
	for &y in d.controls {
		if y.name == name {
			x = &y
		}
	}
	if x == nil {
		append(&d.controls, Draft_Control{name = name})
		x = &d.controls[len(d.controls) - 1]
	}
	x.targets = make([dynamic]device.Target_Desc, context.temp_allocator)
	x.path = path
	one :: proc(c: ^Ctx, x: ^Draft_Control, v: json.Value, path: string) {
		#partial switch y in v {
		case json.String:
			append(&x.targets, device.Target_Desc{path = y})
			return
		case json.Object:
			t := device.Target_Desc{}
			ok := true
			for k in sorted_keys(y) {
				at := base.path_join(path, k)
				switch k {
				case "path":
					s, is_string := y[k].(json.String)
					t.path = s
					ok &&= is_string
				case "op":
					s, _ := y[k].(json.String)
					switch s {
					case "set":
						t.op = .Set
					case "mul":
						t.op = .Mul
					case "add":
						t.op = .Add
					case "octaves":
						t.op = .Octaves
					case:
						report(c, "bad_value", .Error, at, "%s: set, mul, add or octaves", at)
						ok = false
					}
				case "scale", "offset":
					n, is_number := number_from_value(y[k])
					if !is_number {
						report(c, "bad_value", .Error, at, "%s: a number", at)
						ok = false
					}
					if k == "scale" {
						t.scale = f32(n)
					} else {
						t.offset = f32(n)
					}
				case:
					report(c, "unknown_key", .Warning, at, "%s: a target reads path, op, scale, offset; not %q", at, k)
				}
			}
			if ok && t.path != "" {
				append(&x.targets, t)
				return
			}
		}
		report(c, "bad_value", .Error, path, "%s: a target: \"node/field\" or {{ \"node/field\", op = \"mul\", scale = 2 }}", path)
	}
	if list, is_list := v.(json.Array); is_list {
		for y, i in list {
			one(c, x, y, base.path_index(path, i + 1))
		}
	} else {
		one(c, x, v, path)
	}
}

// An option of the row by its name (Tone nests them: `envelope = {
// attack = 0.1 }` is envelope/attack): its control's value (a set's name:
// the Sampler's, read now).
@(private = "file")
draft_option :: proc(c: ^Ctx, d: ^Draft, key: string, v: json.Value, path: string) {
	find :: proc(d: ^Draft, name: string) -> ^Draft_Control {
		for &x in d.controls {
			if x.name == name {
				return &x
			}
		}
		return nil
	}
	x := find(d, key)
	if x == nil && d.sfz_name != "" {
		// an SFZ instrument's options: its CCs (cc64 = 127, or by their label)
		if cc, value, ok := sfz_cc_option(c, d, key, v); ok {
			d.sfz_cc[cc], d.sfz_cc_given = value, d.sfz_cc_given + {cc}
			return
		}
		// an SFZ opcode by its name: every region's value (ampeg_release = 0.8)
		if n, is_number := number_from_value(v); is_number && sfz_name(key).row >= 0 {
			if d.sfz_overrides == nil {
				d.sfz_overrides = make(map[string]f64, context.temp_allocator)
			}
			d.sfz_overrides[key] = n
			return
		}
	}
	if x == nil {
		if o, is_table := v.(json.Object); is_table {
			for k in sorted_keys(o) {
				draft_option(c, d, strings.concatenate({key, "/", k}, context.temp_allocator), o[k], base.path_join(path, k))
			}
			return
		}
		// `noise = "pink"`: the type of the options at that path
		if _, is_string := v.(json.String); is_string {
			x = find(d, strings.concatenate({key, "/type"}, context.temp_allocator))
		}
	}
	if x == nil {
		origin := d.origin != "" ? d.origin : "the row"
		report(c, "unknown_key", .Warning, path, "%s: %s has no option %q", path, origin, key)
		return
	}
	if syncs_written(c, d, x, v, path) {
		return
	}
	if s, is_string := v.(json.String); is_string && len(x.targets) > 0 {
		if f := target_field(d, x.targets[0].path); f != nil && f.unit == .Asset {
			for t in x.targets {
				parts := strings.split(t.path, "/", context.temp_allocator)
				if node := draft_node_named(d, parts[0]); node != nil {
					node.set_name, node.set_path, node.set_from = s, path, c.writer
				}
			}
			return
		}
	}
	x.value, x.value_path = v, path
}

// An option's value on a field that may follow the song's tempo (an Lfo's
// rate), where the option only sets it: written into its nodes as if there,
// so a Tone length keeps its beats (`sync`) and a number is Hz again. True:
// written.
@(private = "file")
syncs_written :: proc(c: ^Ctx, d: ^Draft, x: ^Draft_Control, v: json.Value, path: string) -> bool {
	if len(x.targets) == 0 {
		return false
	}
	f := target_field(d, x.targets[0].path)
	if f == nil || !f.syncs {
		return false
	}
	for t in x.targets {
		if t.op != .Set || (t.scale != 0 && t.scale != 1) || t.offset != 0 || strings.count(t.path, "/") != 1 {
			return false
		}
	}
	for t in x.targets {
		parts := strings.split(t.path, "/", context.temp_allocator)
		prefix := strings.has_suffix(parts[0], "*")
		for &n in d.nodes {
			if n.name != parts[0] && !(prefix && strings.has_prefix(n.name, parts[0][:len(parts[0]) - 1])) {
				continue
			}
			if field, slot, known := device.node_field_from_name(n.kind, parts[1]); known {
				draft_field(c, &n, field, slot, v, path, base_only = true)
			}
		}
	}
	return true
}

@(private = "file")
draft_node_named :: proc(d: ^Draft, name: string) -> ^Draft_Node {
	for &n in d.nodes {
		if n.name == name {
			return &n
		}
	}
	return nil
}

@(private = "file")
draft_node :: proc(c: ^Ctx, d: ^Draft, name: string, v: json.Value, path: string, owner: ^Spec) {
	o, ok := v.(json.Object)
	if !ok {
		report(c, "bad_value", .Error, path, "%s: a node: {{ \"Kind\", ... }}", path)
		return
	}
	if slice.contains(device.RESERVED_NAMES[:], name) {
		report(c, "bad_value", .Error, path, "%s: %q is the note's (a source), not a node's name", path, name)
		return
	}
	node := draft_node_named(d, name)
	if kind_name := named(o); kind_name != "" {
		kind, known := device.node_kind_from_name(kind_name)
		if !known {
			names := make([dynamic]string, context.temp_allocator)
			for row in device.NODES.kinds {
				append(&names, row.name)
			}
			report(c, "unknown_node", .Error, path, "%s: %q is not a node kind (%s)", path, kind_name, strings.join(names[:], ", ", context.temp_allocator))
			return
		}
		if node == nil || node.kind != kind {
			if node == nil {
				append(&d.nodes, Draft_Node{})
				node = &d.nodes[len(d.nodes) - 1]
			}
			node^ = {name = name, kind = kind, values = device.node_defaults(kind)}
			node.inputs = make([dynamic]string, context.temp_allocator)
			node.mods = make([dynamic]Draft_Mod, context.temp_allocator)
		}
	}
	if node == nil {
		report(c, "bad_value", .Error, path, "%s: a new node needs its kind ({{ \"Osc\", ... }})", path)
		return
	}
	node.owner, node.path = owner, path
	for k in sorted_keys(o) {
		at := base.path_join(path, k)
		x := o[k]
		switch k {
		case "name", "class":
		case "input", "inputs":
			clear(&node.inputs)
			#partial switch y in x {
			case json.String:
				append(&node.inputs, y)
			case json.Array:
				for z, i in y {
					if s, is_string := z.(json.String); is_string {
						append(&node.inputs, s)
					} else {
						report(c, "bad_value", .Error, base.path_index(at, i + 1), "%s: the name of a node", base.path_index(at, i + 1))
					}
				}
			case:
				report(c, "bad_value", .Error, at, "%s: a node's name, or a list of them", at)
			}
		case:
			field, slot, known := device.node_field_from_name(node.kind, k)
			if !known {
				report(c, "unknown_key", .Warning, at, "%s: %s reads no %q", at, device.node_row(node.kind).name, k)
				continue
			}
			draft_field(c, node, field, slot, x, at)
		}
	}
}

// A field's value: a number, a choice, a Tone length, a set's name, a list
// (a field of several); or what moves it (`{ base, by, octaves | ratio |
// sweep | index | amount | depth, exponent }`, a list of those; amp: a
// node's name too). `base_only` (an option's value): a number sets the base
// and keeps what moves it.
@(private = "file")
draft_field :: proc(c: ^Ctx, node: ^Draft_Node, field: ^device.Node_Field, slot: int, v: json.Value, path: string, base_only := false) {
	is_amp := slot == device.FIELD_AMP
	if field.list > 0 {
		// a list of numbers (the bank's frequencies)
		list, is_list := v.(json.Array)
		if !is_list || len(list) > field.list {
			report(c, "bad_value", .Error, path, "%s: a list of up to %d numbers", path, field.list)
			return
		}
		for k in 0 ..< field.list {
			node.values[slot + k] = 0
		}
		for x, k in list {
			n, _ := number_from_value(x)
			node.values[slot + k] = f32(n)
		}
		return
	}
	#partial switch x in v {
	case json.Object, json.Array:
		if !base_only {
			draft_moves(c, node, field, slot, v, path, true)
			return
		}
	case json.String:
		if is_amp {
			draft_moves(c, node, field, slot, v, path, !base_only)
			return
		}
	}
	if is_amp {
		report(c, "bad_value", .Error, path, "%s: the node it follows (amp = \"env\"), or {{ by, depth }}", path)
		return
	}
	if n, is_number := number_from_value(v); is_number {
		if field.unit == .Choice || field.unit == .Asset {
			report(c, "bad_value", .Error, path, "%s: one of %s", path, strings.join(field.choices, ", ", context.temp_allocator))
			return
		}
		node.values[slot] = field.unit == .Gain ? f32(base.db_to_gain(base.Db(n))) : f32(n)
		node.beats -= {slot}
		return
	}
	s, is_string := v.(json.String)
	if !is_string {
		report(c, "bad_value", .Error, path, "%s: a number or a string", path)
		return
	}
	if field.unit == .Asset {
		node.set_name, node.set_path, node.set_from = s, path, c.writer
		return
	}
	value, beats, expect, ok := unit_from_text(field.unit, field.choices, s)
	if !ok {
		report(c, "bad_value", .Error, path, "%s: %s", path, expect)
		return
	}
	node.values[slot] = value
	node.beats = beats ? node.beats + {slot} : node.beats - {slot}
}

// What moves a field: a source's name (amp), a modulator, or a list.
@(private = "file")
draft_moves :: proc(c: ^Ctx, node: ^Draft_Node, field: ^device.Node_Field, slot: int, v: json.Value, path: string, replace: bool) {
	is_amp := slot == device.FIELD_AMP
	if replace {
		#reverse for m, i in node.mods {
			if m.slot == slot {
				ordered_remove(&node.mods, i)
			}
		}
	}
	#partial switch x in v {
	case json.String:
		append(&node.mods, Draft_Mod{slot = slot, source = x, kind = is_amp ? .Depth : .Amount, amount = 1, exponent = 1, path = path})
	case json.Object:
		m := Draft_Mod{slot = slot, kind = is_amp ? .Depth : .Amount, amount = 1, exponent = 1, path = path}
		if b, has := x["base"]; has {
			draft_field(c, node, field, slot, b, base.path_join(path, "base"), base_only = true)
		}
		by, has_by := x["by"].(json.String)
		if !has_by {
			if _, has_base := x["base"]; !has_base {
				report(c, "bad_value", .Error, path, "%s: what moves it: {{ by = \"node\", amount = 1 }}", path)
			}
			return
		}
		m.source = by
		for k in sorted_keys(x) {
			if k != "base" && k != "by" {
				mod_field(c, &m, k, x[k], base.path_join(path, k))
			}
		}
		append(&node.mods, m)
	case json.Array:
		for y, i in x {
			draft_moves(c, node, field, slot, y, base.path_index(path, i + 1), false)
		}
	case:
		report(c, "bad_value", .Error, path, "%s: a modulator: {{ by = \"node\", ... }}", path)
	}
}

// One of a modulator's fields.
@(private = "file")
mod_field :: proc(c: ^Ctx, m: ^Draft_Mod, k: string, v: json.Value, path: string) {
	n, is_number := number_from_value(v)
	if !is_number {
		report(c, "bad_value", .Error, path, "%s: a number", path)
		return
	}
	f, known := device.mod_field_from_name(k)
	if !known {
		report(c, "unknown_key", .Warning, path, "%s: a modulator reads by, base, octaves, ratio, sweep, index, amount, depth, at_most, exponent; not %q", path, k)
		return
	}
	d := device.Mod_Desc{kind = m.kind, amount = m.amount, exponent = m.exponent}
	device.mod_field_set(&d, f, f32(n))
	m.kind, m.amount, m.exponent = d.kind, d.amount, d.exponent
}

@(private = "file")
draft_pad :: proc(c: ^Ctx, d: ^Draft, name: string, v: json.Value, path: string, owner: ^Spec) {
	pad := Draft_Pad{name = name, key = UNSET, owner = owner, path = path, row = v}
	pad.chokes = make([dynamic]string, context.temp_allocator)
	if o, is_table := v.(json.Object); is_table {
		rest := make(json.Object, context.temp_allocator)
		for k, x in o {
			at := base.path_join(path, k)
			switch k {
			case "key":
				pad.key = f64(note_value(c, x, at))
			case "gain_db":
				n, is_number := number_from_value(x)
				if !is_number {
					report(c, "bad_value", .Error, at, "%s: dB", at)
				}
				pad.gain_db = n
			case "choke":
				#partial switch y in x {
				case json.String:
					append(&pad.chokes, y)
				case json.Array:
					for z in y {
						if s, is_string := z.(json.String); is_string {
							append(&pad.chokes, s)
						}
					}
				case:
					report(c, "bad_value", .Error, at, "%s: a pad's name or a list of them", at)
				}
			case "instrument":
				#partial switch y in x {
				case json.Object:
					for kk, xx in y {
						rest[kk] = xx
					}
				case:
					rest["name"] = x
				}
			case:
				rest[k] = x
			}
		}
		pad.row = rest
	}
	for &x in d.pads {
		if x.name == name {
			x = pad
			return
		}
	}
	append(&d.pads, pad)
}

// A layer: its instrument and the conditions a note meets for it to sound
// (Layer_Row's fields, by their names; keys may be note names).
@(private = "file")
draft_layer :: proc(c: ^Ctx, d: ^Draft, v: json.Value, path: string, owner: ^Spec) {
	o, ok := v.(json.Object)
	if !ok {
		report(c, "bad_value", .Error, path, "%s: a layer: {{ instrument, lo_key, hi_key, ... }}", path)
		return
	}
	l := Draft_Layer{owner = owner, path = path}
	l.region, l.gain = {hi_key = 127, hi_vel = 127, hi_rand = 1, seq_length = 1, seq_position = 1}, 1
	for k in sorted_keys(o) {
		x := o[k]
		at := base.path_join(path, k)
		n, is_number := number_from_value(x)
		key :: proc(c: ^Ctx, v: json.Value, at: string) -> u8 {return u8(clamp(note_value(c, v, at), 0, 127))}
		switch k {
		case "instrument":
			l.value = x
		case "lo_key":
			l.region.lo_key = key(c, x, at)
		case "hi_key":
			l.region.hi_key = key(c, x, at)
		case "sw_last_lo":
			l.region.sw_last_lo = 1 + key(c, x, at)
		case "sw_last_hi":
			l.region.sw_last_hi = 1 + key(c, x, at)
		case "trigger":
			s, _ := x.(json.String)
			switch s {
			case "attack":
				l.region.trigger = .Attack
			case "release":
				l.region.trigger = .Release
			case "first":
				l.region.trigger = .First
			case "legato":
				l.region.trigger = .Legato
			case:
				report(c, "bad_value", .Error, at, "%s: attack, release, first or legato", at)
			}
		case "off_mode":
			s, _ := x.(json.String)
			switch s {
			case "fast":
				l.region.off_mode = .Fast
			case "normal":
				l.region.off_mode = .Normal
			case "time":
				l.region.off_mode = .Time
			case:
				report(c, "bad_value", .Error, at, "%s: fast, normal or time", at)
			}
		case "lo_vel", "hi_vel", "lo_rand", "hi_rand", "seq_length", "seq_position", "group", "off_by", "off_time", "polyphony", "note_polyphony", "rt_decay", "gain_db":
			if !is_number {
				report(c, "bad_value", .Error, at, "%s: a number", at)
				continue
			}
			switch k {
			case "lo_vel":
				l.region.lo_vel = u8(clamp(n, 0, 127))
			case "hi_vel":
				l.region.hi_vel = u8(clamp(n, 0, 127))
			case "lo_rand":
				l.region.lo_rand = f32(n)
			case "hi_rand":
				l.region.hi_rand = f32(n)
			case "seq_length":
				l.region.seq_length = u16(max(n, 1))
			case "seq_position":
				l.region.seq_position = u16(max(n, 1))
			case "group":
				l.region.group = i32(n)
			case "off_by":
				l.region.off_by = i32(n)
			case "off_time":
				l.region.off_time = f32(n)
			case "polyphony":
				l.region.polyphony = u16(max(n, 0))
			case "note_polyphony":
				l.region.note_polyphony = u16(max(n, 0))
			case "rt_decay":
				l.region.rt_decay = f32(n)
			case "gain_db":
				l.gain = f32(base.db_to_gain(base.Db(n)))
			}
		case:
			report(c, "unknown_key", .Warning, at, "%s: a layer reads instrument, lo_key, hi_key, lo_vel, hi_vel, lo_rand, hi_rand, seq_length, seq_position, trigger, sw_last_lo, sw_last_hi, group, off_by, off_mode, off_time, polyphony, note_polyphony, rt_decay, gain_db; not %q", at, k)
		}
	}
	if l.region.sw_last_lo != 0 && l.region.sw_last_hi == 0 {
		l.region.sw_last_hi = l.region.sw_last_lo
	}
	if l.value == nil {
		report(c, "bad_value", .Error, path, "%s: a layer plays an instrument", path)
		return
	}
	append(&d.layers, l)
}

@(private = "file")
note_value :: proc(c: ^Ctx, v: json.Value, path: string) -> f32 {
	if n, ok := note_from_value(v); ok {
		return f32(n)
	}
	report(c, "bad_value", .Error, path, "%s: a note (\"C2\") or a MIDI number", path)
	return 0
}

// ---- a draft as a program ---------------------------------------------------------

// The program a draft is, as plain data for device.compile_program: its
// times in seconds (a Tone length at the part's tempo), its sets the
// bank's, its Sampler's named keys, its options as controls with the values
// the row gave them; a machine's pads each its own.
@(private = "file")
draft_desc :: proc(c: ^Ctx, d: ^Draft, written: string) -> ^device.Program_Desc {
	// the Sampler over an SFZ file (v0.0.5's form) is that SFZ instrument
	if d.sfz_name == "" && len(d.nodes) == 1 && d.nodes[0].kind == device.NODE_SAMPLER && is_sfz_name(d.nodes[0].set_name) {
		d.sfz_name, d.sfz_owner = d.nodes[0].set_name, d.nodes[0].set_from
		// the attack and release it gives: every region's amp envelope's
		if d.sfz_overrides == nil {
			d.sfz_overrides = make(map[string]f64, context.temp_allocator)
		}
		for x in d.controls {
			if x.value == nil {
				continue
			}
			n, is_number := number_from_value(x.value)
			switch {
			case !is_number:
			case x.name == "attack":
				d.sfz_overrides["ampeg_attack"] = n
			case x.name == "release":
				d.sfz_overrides["ampeg_release"] = n
			}
		}
		report(c, "sfz_instrument", .Info, d.nodes[0].set_path, "%s: an SFZ file plays as an instrument: instrument = {{ %q, ampeg_attack = ..., ampeg_release = ... }} (its own envelopes and layers; a Sampler's attack and release are its ampeg's)", d.nodes[0].set_path, d.sfz_name)
	}
	if d.sfz_name != "" {
		return sfz_desc(c, d, written)
	}
	if c.fixed != nil {
		if d.length_beats {
			append(c.fixed, Fixed_Tone{base.path_join(d.path != "" ? d.path : written, "length"), false})
		}
		if d.porta_beats {
			append(c.fixed, Fixed_Tone{base.path_join(d.path != "" ? d.path : written, "portamento"), false})
		}
	}
	desc := new(device.Program_Desc, context.temp_allocator)
	desc^ = {
		length     = f32(d.length * (d.length_beats ? c.beat_seconds : 1)),
		portamento = f32(d.portamento * (d.porta_beats ? c.beat_seconds : 1)),
		note       = f32(d.note),
		mono       = d.mono,
		velocity   = d.velocity,
		out        = d.out,
		effect     = c.effect,
		path       = d.path != "" ? d.path : written,
	}
	nodes := make([]device.Node_Desc, len(d.nodes), context.temp_allocator)
	keys := make([dynamic]device.Key_Desc, context.temp_allocator)
	for &n, i in d.nodes {
		x := &nodes[i]
		x^ = {name = n.name, kind = n.kind, values = n.values, inputs = n.inputs[:], path = n.path}
		for slot in 0 ..< device.MAX_FIELDS {
			if slot not_in n.beats {
				continue
			}
			f := device.field_of_slot(n.kind, slot)
			switch {
			case f != nil && f.syncs:
				// it keeps its beats, read against the song's tempo as it plays
				x.values[device.node_row(n.kind).sync] = 1
			case f != nil && f.unit == .Hz:
				x.values[slot] = f32(f64(n.values[slot]) / c.beat_seconds) // cycles a beat
				fixed_at(c, n.path, f)
			case:
				x.values[slot] = f32(f64(n.values[slot]) * c.beat_seconds)
				fixed_at(c, n.path, f)
			}
		}
		mods := make([]device.Mod_Desc, len(n.mods), context.temp_allocator)
		for m, k in n.mods {
			mods[k] = {slot = m.slot, source = m.source, kind = m.kind, amount = m.amount, exponent = m.exponent, path = m.path}
		}
		x.mods = mods
		if n.set_name != "" {
			key := asset_key(n.set_from, n.set_name)
			set, found := device.bank_set_from_name(c.bank, key)
			if !found {
				report(c, "asset_unavailable", .Error, n.set_path, "%s: sample set %q is not loaded (offline, or not in the register)", n.set_path, n.set_name)
			}
			row := device.node_row(n.kind)
			for f, fi in row.fields {
				if f.unit == .Asset {
					x.values[row.slots[fi]] = f32(set)
				}
			}
			sampler_keys(&n, &keys)
		}
	}
	desc.nodes, desc.keys = nodes, keys[:]
	pads := make([]device.Pad_Desc, len(d.pads), context.temp_allocator)
	for &p, i in d.pads {
		pads[i] = {name = p.name, key = f32(p.key), gain = base.db_to_gain(base.Db(p.gain_db)), chokes = p.chokes[:], path = p.path}
		if sub, ok := drafted(c, p.row, p.path, p.owner); ok {
			pads[i].program = draft_desc(c, sub, p.path)
		}
	}
	desc.pads = pads
	layers := make([]device.Layer_Desc, len(d.layers), context.temp_allocator)
	for &l, i in d.layers {
		layers[i] = {region = l.region, gain = l.gain, path = l.path}
		if sub, ok := drafted(c, l.value, l.path, l.owner); ok {
			layers[i].program = draft_desc(c, sub, l.path)
		}
	}
	desc.layers = layers
	desc.sw_lo, desc.sw_hi, desc.sw_default = d.sw_lo, d.sw_hi, d.sw_default
	controls := make([]device.Control_Desc, len(d.controls), context.temp_allocator)
	for &x, i in d.controls {
		controls[i] = {name = x.name, targets = x.targets[:], path = x.path}
		if x.value != nil {
			controls[i].value, controls[i].given = control_value(c, d, &x)
		}
	}
	desc.controls = controls
	return desc
}

// An option's value as its control's number: a number (dB on a gain), a
// choice's name, a Tone length (of the field its first target is).
@(private = "file")
control_value :: proc(c: ^Ctx, d: ^Draft, x: ^Draft_Control) -> (f32, bool) {
	if n, is_number := number_from_value(x.value); is_number {
		return f32(n), true
	}
	s, is_string := x.value.(json.String)
	field: ^device.Node_Field
	if len(x.targets) > 0 {
		field = target_field(d, x.targets[0].path)
	}
	if !is_string || field == nil {
		report(c, "bad_value", .Error, x.value_path, "%s: a number", x.value_path)
		return 0, false
	}
	value, beats, expect, ok := unit_from_text(field.unit, field.choices, s)
	if !ok {
		report(c, "bad_value", .Error, x.value_path, "%s: %s", x.value_path, expect)
		return 0, false
	}
	if beats {
		// a length's beats, or a rate's cycles a beat, at the instrument's tempo
		value = field.unit == .Hz ? f32(f64(value) / c.beat_seconds) : f32(f64(value) * c.beat_seconds)
		if c.fixed != nil {
			append(c.fixed, Fixed_Tone{x.value_path, field.unit == .Hz})
		}
	}
	return value, true
}

// A node's field written as a Tone length and read once, at the tempo the
// row is placed at.
@(private = "file")
fixed_at :: proc(c: ^Ctx, node_path: string, f: ^device.Node_Field) {
	if c.fixed != nil {
		append(c.fixed, Fixed_Tone{base.path_join(node_path, f != nil ? f.name : "?"), f != nil && f.unit == .Hz})
	}
}

// The field a target's path names in the draft (its first node's).
@(private = "file")
target_field :: proc(d: ^Draft, path: string) -> ^device.Node_Field {
	parts := strings.split(path, "/", context.temp_allocator)
	if len(parts) != 2 {
		return nil
	}
	for n in d.nodes {
		if parts[0] == n.name || (strings.has_suffix(parts[0], "*") && strings.has_prefix(n.name, parts[0][:len(parts[0]) - 1])) {
			f, _, known := device.node_field_from_name(n.kind, parts[1])
			return known ? f : nil
		}
	}
	return nil
}

// An SFZ instrument's program: its text (and what it includes, as the
// assets layer read them declaring its samples) read and compiled, its CCs
// at the values the row gave, else its own.
@(private = "file")
sfz_desc :: proc(c: ^Ctx, d: ^Draft, written: string) -> ^device.Program_Desc {
	key := asset_key(d.sfz_owner, d.sfz_name)
	s := spec_sfz(d.sfz_owner, key)
	if s == nil {
		report(c, "missing_file", .Error, written, "%s: SFZ file %s couldn't be read or fetched (a path beside the song, or SOURCE/PATH in a source it declares; a source's finding above says why)", written, key)
		return nil
	}
	for m in s.missing {
		report(c, "missing_file", .Error, written, "%s: %s includes %s, which was not read", written, key, m)
	}
	cc := s.cc
	for k in d.sfz_cc_given {
		cc[k] = d.sfz_cc[k]
	}
	set, found_set := device.bank_set_from_name(c.bank, key)
	if !found_set {
		report(c, "asset_unavailable", .Error, written, "%s: SFZ %q's samples are not declared (offline, or not read)", written, d.sfz_name)
		set = -1
	}
	desc := sfz_program_desc(s, i32(set), cc, written, c.findings, d.sfz_overrides)
	if len(desc.layers) == 0 {
		report(c, "sfz_silent", .Warning, written, "%s: no region of %s plays at its CCs' values (set them: cc64 = 127, or by their labels)", written, d.sfz_name)
		return nil
	}
	return desc
}

// An SFZ instrument's option: a CC's value (cc64 = 127), or one by its
// label_ccN's name (sustain = 127). False: neither.
@(private = "file")
sfz_cc_option :: proc(c: ^Ctx, d: ^Draft, key: string, v: json.Value) -> (cc: int, value: f32, ok: bool) {
	n, is_number := number_from_value(v)
	if !is_number {
		return
	}
	if strings.has_prefix(key, "cc") {
		if k, parsed := strconv.parse_int(key[2:]); parsed && k >= 0 && k < 128 {
			return k, f32(n), true
		}
	}
	if s := spec_sfz(d.sfz_owner, asset_key(d.sfz_owner, d.sfz_name)); s != nil {
		for label, k in s.cc_labels {
			if label != "" && (label == key || strings.to_lower(label, context.temp_allocator) == strings.to_lower(key, context.temp_allocator)) {
				return k, f32(n), true
			}
		}
	}
	return
}

// A Sampler's named keys: its set's pads (a set of the song's), else
// General MIDI's names (a kit keyed to them).
@(private = "file")
sampler_keys :: proc(n: ^Draft_Node, out: ^[dynamic]device.Key_Desc) {
	set, owner := set_from_name(n.set_from, n.set_name)
	declared := false
	if set != nil {
		for z in owner.set_zones[set.zones.first:base.span_end(set.zones)] {
			if z.pad != "" {
				append(out, device.Key_Desc{z.pad, f32(z.key)})
				declared = true
			}
		}
	}
	if !declared {
		for g in device.GM_PADS {
			append(out, device.Key_Desc{g.name, g.key})
		}
	}
}

// ---- reading a part's instrument ---------------------------------------------------

// The program device d of s plays (a Voice's row, or a Row's: an effect
// row, read and placed into progs at `beat_seconds` a beat, its Samplers'
// sets the bank's), and where it read a Tone length once at that tempo
// (appended to `fixed`: an Lfo's rate in beats isn't, it follows the
// tempo). -1: none (findings say why).
instrument_program :: proc(s: ^Spec, d: i32, beat_seconds: f64, bank: ^device.Bank, progs: ^device.Programs, findings: ^base.Findings, drafts: ^Drafts = nil, fixed: ^[dynamic]Fixed_Tone = nil) -> i32 {
	dev := &s.devices[d]
	c := Ctx{progs = progs, bank = bank, beat_seconds = beat_seconds, findings = findings, drafts = drafts, effect = dev.kind == .Row, fixed = fixed}
	path := strings.trim_prefix(dev.path, "song/")
	draft, ok := drafted(&c, dev.row, path, s)
	if !ok {
		return -1
	}
	desc := draft_desc(&c, draft, path)
	if desc == nil {
		return -1
	}
	return device.compile_program(progs, desc, findings)
}

// The sample sets a Voice's row plays (its Samplers', its pads' too), each
// with the spec its name is read in.
instrument_sets :: proc(s: ^Spec, d: i32, out: ^[dynamic]Asset_Ref, drafts: ^Drafts = nil) {
	c := Ctx{drafts = drafts}
	if draft, ok := drafted(&c, s.devices[d].row, s.devices[d].path, s); ok {
		draft_sets(&c, draft, s, out)
	}
}

@(private = "file")
draft_sets :: proc(c: ^Ctx, d: ^Draft, from: ^Spec, out: ^[dynamic]Asset_Ref) {
	if d.sfz_name != "" {
		scope := d.sfz_owner != nil ? d.sfz_owner : from
		found := false
		for x in out {
			found ||= x.name == d.sfz_name && x.from == scope
		}
		if !found {
			append(out, Asset_Ref{d.sfz_name, nil, scope}) // no owner: not a set of the song's own
		}
		return
	}
	for n in d.nodes {
		if n.set_name == "" {
			continue
		}
		scope := n.set_from != nil ? n.set_from : from
		_, owner := set_from_name(scope, n.set_name)
		found := false
		for x in out {
			found ||= x.name == n.set_name && x.owner == owner
		}
		if !found {
			append(out, Asset_Ref{n.set_name, owner, scope})
		}
	}
	for p in d.pads {
		if sub, ok := drafted(c, p.row, p.path, p.owner); ok {
			draft_sets(c, sub, from, out)
		}
	}
	for l in d.layers {
		if sub, ok := drafted(c, l.value, l.path, l.owner); ok {
			draft_sets(c, sub, from, out)
		}
	}
}

// The pads an instrument has, by id (a machine's, its Sampler's set's):
// for steps that name one it doesn't (unknown_pad).
program_pads :: proc(progs: ^device.Programs, program: i32, out: ^[dynamic]u32) {
	if program < 0 {
		return
	}
	p := &progs.programs[program]
	if p.layer_mode != .One {
		return
	}
	for pr in progs.layers[p.layers.first:base.span_end(p.layers)] {
		append(out, progs.pads[pr.row].pad)
	}
}
