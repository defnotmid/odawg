package odawg_spec

import "core:encoding/json"
import "core:math"
import "core:slice"
import "core:strings"
import base "../base"
import device "../device"
import tempo "../tempo"
import theory "../theory"

// Reading a spec is one walk driven by tables: each record type is a table
// of fields (its key, how its value is read, where it lands), and each way
// of reading a value is one row of FIELD_READERS. An object's keys are
// checked against its table (a key nothing reads is `unknown_key`), a value
// of the wrong kind is `bad_value`, each at its `/` path, so a mistake reads
// the same from Lua and from JSON. Devices are read from dsp's tables alone.
//
// Values come as json.Value: JSON from the CLI, or a host's own tables
// converted (onimite's Lua tables, their [1] becoming "name").

Reader :: struct {
	spec:     ^Spec,
	findings: ^base.Findings,
}

Field_Kind :: enum u8 {
	Ignore,
	Number, // f64
	Bool,
	String,
	Time, // Time_Spec: seconds or a string
	Bpm, // [2]f64: a tempo or { from, to }
	Meter, // f64 beats a bar: 4, or { 6, 8 }
	Pair, // [2]f64
	Flex, // [2]Time_Spec
	Ranges, // Span into ranges: a range or a list
	Device, // i32 device
	Chain, // Span into chain: a device or a list
	Sends, // Span into sends: { hall = -12 }
	Sidechain, // Sidechain_Spec: "drums/kick" or { "drums/kick", depth, release }
	Steps, // the play: lanes
	Notes, // the play: tokens
	Degrees, // the play: tokens
	Events, // the play: events
	Arpeggio, // the play: its arpeggio options
	Chords, // the play: its chord options (or true)
	Sections, // the spec: sections
	Parts, // the spec: parts by name
	Returns, // the spec: returns by name
	Markers, // the spec: markers
	Room, // the spec: room spans
	Styles, // the spec: its own styles by name
	Instruments, // the spec: its instruments by name
	Buses, // the spec: its buses by name
	Sets, // the spec: its sample sets by name
	Sources, // the spec: the sources its files are fetched from, by name
	Note, // f64 MIDI: "C3", "F#2" or a number
}

Field_Row :: struct {
	key:    string,
	kind:   Field_Kind,
	offset: uintptr,
}

Field_Reader :: #type proc(r: ^Reader, v: json.Value, path: string, dst: rawptr)

FIELD_READERS := [Field_Kind]Field_Reader {
	.Ignore    = proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {},
	.Number    = read_number_field,
	.Bool      = read_bool_field,
	.String    = read_string_field,
	.Time      = read_time_field,
	.Bpm       = read_bpm_field,
	.Meter     = read_meter_field,
	.Pair      = read_pair_field,
	.Flex      = read_flex_field,
	.Ranges    = read_ranges_field,
	.Device    = read_device_field,
	.Chain     = read_chain_field,
	.Sends     = read_sends_field,
	.Sidechain = read_sidechain_field,
	.Steps     = read_steps_field,
	.Notes     = read_notes_field,
	.Degrees   = read_degrees_field,
	.Events    = read_events_field,
	.Arpeggio  = read_arpeggio_field,
	.Chords    = read_chords_field,
	.Sections  = read_sections_field,
	.Parts     = read_parts_field,
	.Returns   = read_returns_field,
	.Markers   = read_markers_field,
	.Room      = read_room_field,
	.Styles    = read_styles_field,
	.Instruments = read_instruments_field,
	.Buses     = read_buses_field,
	.Sets      = read_sets_field,
	.Sources   = read_sources_field,
	.Note      = read_note_field,
}

SPEC_FIELDS := []Field_Row {
	{"name", .String, offset_of(Spec, name)},
	{"start", .Number, offset_of(Spec, start)},
	{"bpm", .Number, offset_of(Spec, bpm)},
	{"time_signature", .Meter, offset_of(Spec, beats_per_bar)},
	{"key", .String, offset_of(Spec, key)},
	{"seed", .Number, offset_of(Spec, seed)},
	{"swing", .Number, offset_of(Spec, swing)},
	{"swing_subdivision", .String, offset_of(Spec, swing_subdivision)},
	{"duration", .Number, offset_of(Spec, duration)},
	{"gain_db", .Number, offset_of(Spec, gain_db)},
	{"from", .String, offset_of(Spec, from)},
	{"style", .String, offset_of(Spec, style)},
	{"energy", .Number, offset_of(Spec, energy)},
	{"chords", .String, offset_of(Spec, chords)},
	{"sections", .Sections, 0},
	{"parts", .Parts, 0},
	{"returns", .Returns, 0},
	{"markers", .Markers, 0},
	{"room", .Room, 0},
	{"styles", .Styles, 0},
	{"instruments", .Instruments, 0},
	{"buses", .Buses, 0},
	{"sets", .Sets, 0},
	{"sources", .Sources, 0},
	{"description", .Ignore, 0},
}

SECTION_FIELDS := []Field_Row {
	{"name", .String, offset_of(Section_Spec, name)},
	{"duration", .Time, offset_of(Section_Spec, duration)},
	{"start", .Number, offset_of(Section_Spec, start)},
	{"bpm", .Bpm, offset_of(Section_Spec, bpm)},
	{"time_signature", .Meter, offset_of(Section_Spec, beats_per_bar)},
	{"style", .String, offset_of(Section_Spec, style)},
	{"energy", .Number, offset_of(Section_Spec, energy)},
	{"chords", .String, offset_of(Section_Spec, chords)},
	{"transition", .String, offset_of(Section_Spec, transition)},
	{"transition_part", .String, offset_of(Section_Spec, transition_part)},
	{"flex", .Flex, offset_of(Section_Spec, flex)},
	{"optional", .Bool, offset_of(Section_Spec, optional)},
	{"stretch", .String, offset_of(Section_Spec, stretch)},
	{"at", .Time, offset_of(Section_Spec, at)},
}

PART_FIELDS := []Field_Row {
	{"instrument", .Device, offset_of(Part_Spec, instrument)},
	{"gain_db", .Number, offset_of(Part_Spec, gain_db)},
	{"pan", .Number, offset_of(Part_Spec, pan)},
	{"octave", .Number, offset_of(Part_Spec, octave)},
	{"room_db", .Number, offset_of(Part_Spec, room_db)},
	{"effects", .Chain, offset_of(Part_Spec, effects)},
	{"sends", .Sends, offset_of(Part_Spec, sends)},
	{"sidechain", .Sidechain, offset_of(Part_Spec, sidechain)},
	{"mute", .Ranges, offset_of(Part_Spec, mute)},
	{"to", .String, offset_of(Part_Spec, to)},
	{"key", .String, offset_of(Part_Spec, key)},
	{"play", .Ignore, 0}, // read by read_parts_field, so plays stay contiguous per part
}

PLAY_FIELDS := []Field_Row {
	{"name", .Ranges, offset_of(Play_Spec, ranges)},
	{"range", .Ranges, offset_of(Play_Spec, ranges)},
	{"steps", .Steps, 0},
	{"notes", .Notes, 0},
	{"degrees", .Degrees, 0},
	{"events", .Events, 0},
	{"arpeggio", .Arpeggio, 0},
	{"chords", .Chords, 0},
	{"note", .String, offset_of(Play_Spec, note)},
	{"subdivision", .String, offset_of(Play_Spec, subdivision)},
	{"loop", .String, offset_of(Play_Spec, loop)},
	{"velocity", .Number, offset_of(Play_Spec, velocity)},
	{"octave", .Number, offset_of(Play_Spec, octave)},
	{"humanize", .Number, offset_of(Play_Spec, humanize)},
	{"duration", .String, offset_of(Play_Spec, duration)},
	{"energy", .Pair, offset_of(Play_Spec, energy)},
}

ARPEGGIO_FIELDS := []Field_Row {
	{"pattern", .String, offset_of(Play_Spec, arpeggio) + offset_of(Arpeggio_Spec, pattern)},
	{"interval", .String, offset_of(Play_Spec, arpeggio) + offset_of(Arpeggio_Spec, interval)},
	{"octaves", .Number, offset_of(Play_Spec, arpeggio) + offset_of(Arpeggio_Spec, octaves)},
}

CHORDS_FIELDS := []Field_Row {
	{"voicing", .String, offset_of(Play_Spec, chords) + offset_of(Chords_Spec, voicing)},
	{"rhythm", .String, offset_of(Play_Spec, chords) + offset_of(Chords_Spec, rhythm)},
}

EVENT_FIELDS := []Field_Row {
	{"time", .Time, offset_of(Event_Spec, time)},
	{"note", .String, offset_of(Event_Spec, note)},
	{"duration", .Time, offset_of(Event_Spec, duration)},
	{"velocity", .Number, offset_of(Event_Spec, velocity)},
	{"accent", .Number, offset_of(Event_Spec, accent)},
}

MARKER_FIELDS := []Field_Row {
	{"name", .String, offset_of(Marker_Spec, name)},
	{"at", .Time, offset_of(Marker_Spec, at)},
}

SET_FIELDS := []Field_Row {
	{"gain_db", .Number, offset_of(Set_Spec, gain_db)},
	{"credit", .String, offset_of(Set_Spec, credit)},
	{"loop", .Bool, offset_of(Set_Spec, loop)},
	{"pads", .Ignore, 0}, // read by read_sets_field, so a set's zones stay contiguous
	{"zones", .Ignore, 0},
}

SET_ZONE_FIELDS := []Field_Row {
	{"name", .String, offset_of(Set_Zone_Spec, file)},
	{"file", .String, offset_of(Set_Zone_Spec, file)},
	{"root", .Note, offset_of(Set_Zone_Spec, root)},
	{"lo", .Note, offset_of(Set_Zone_Spec, lo)},
	{"hi", .Note, offset_of(Set_Zone_Spec, hi)},
	{"lo_velocity", .Number, offset_of(Set_Zone_Spec, lo_velocity)},
	{"hi_velocity", .Number, offset_of(Set_Zone_Spec, hi_velocity)},
	{"gain_db", .Number, offset_of(Set_Zone_Spec, gain_db)},
	{"one_shot", .Number, offset_of(Set_Zone_Spec, one_shot)},
	{"offset", .Number, offset_of(Set_Zone_Spec, offset)},
	{"key", .Note, offset_of(Set_Zone_Spec, key)},
}

SOURCE_FIELDS := []Field_Row {
	{"url", .String, offset_of(Source_Spec, url)},
	{"page", .String, offset_of(Source_Spec, page)},
	{"licence", .String, offset_of(Source_Spec, licence)},
	{"license", .String, offset_of(Source_Spec, licence)},
	{"credit", .String, offset_of(Source_Spec, credit)},
	{"pins", .String, offset_of(Source_Spec, pins)},
}

BUS_FIELDS := []Field_Row {
	{"effects", .Chain, offset_of(Bus_Spec, chain)},
	{"to", .String, offset_of(Bus_Spec, to)},
	{"key", .String, offset_of(Bus_Spec, key)},
}

SIDECHAIN_FIELDS := []Field_Row {
	{"name", .String, offset_of(Sidechain_Spec, source)},
	{"source", .String, offset_of(Sidechain_Spec, source)},
	{"depth", .Number, offset_of(Sidechain_Spec, depth)},
	{"release", .Number, offset_of(Sidechain_Spec, release)},
}

// ---- the walk ------------------------------------------------------------------------

// Reads the fields of the object `v` into the record at `dst`.
read_record :: proc(r: ^Reader, v: json.Value, path: string, fields: []Field_Row, dst: rawptr) -> bool {
	o, is_object := v.(json.Object)
	if !is_object {
		base.report(r.findings, "bad_value", .Error, path, "%s: expected a table", path)
		return false
	}
	keys := make([dynamic]string, 0, len(o), context.temp_allocator)
	for k in o {
		append(&keys, k)
	}
	slice.sort(keys[:]) // findings in a stable order
	outer: for k in keys {
		for f in fields {
			if f.key == k {
				FIELD_READERS[f.kind](r, o[k], base.path_join(path, k), rawptr(uintptr(dst) + f.offset))
				continue outer
			}
		}
		if k == "class" || k == "name" {
			continue
		}
		base.report(r.findings, "unknown_key", .Warning, base.path_join(path, k), "%s: nothing reads %q", path, k)
	}
	return true
}

spec_init :: proc(s: ^Spec, allocator := context.allocator) {
	s^ = {
		bpm = 120, beats_per_bar = 4, key = "C major", seed = 1, swing_subdivision = "8n",
		duration = UNSET, energy = UNSET, start = 0, gain_db = -10,
	}
	s.sections.allocator, s.parts.allocator, s.plays.allocator = allocator, allocator, allocator
	s.lanes.allocator, s.bars.allocator, s.tokens.allocator = allocator, allocator, allocator
	s.events.allocator, s.ranges.allocator, s.devices.allocator = allocator, allocator, allocator
	s.values.allocator, s.chain.allocator, s.sends.allocator = allocator, allocator, allocator
	s.returns.allocator, s.markers.allocator, s.room.allocator = allocator, allocator, allocator
	s.strings.allocator, s.styles.allocator, s.buses.allocator = allocator, allocator, allocator
	s.sets.allocator, s.set_zones.allocator, s.sources.allocator = allocator, allocator, allocator
	s.instruments.allocator, s.instrument_includes.allocator, s.instrument_files.allocator = allocator, allocator, allocator
}

// Reads a spec from a value; context.allocator holds it (give it an arena).
spec_from_value :: proc(v: json.Value, s: ^Spec, findings: ^base.Findings) -> bool {
	spec_init(s)
	r := Reader{s, findings}
	if !read_record(&r, v, "song", SPEC_FIELDS, s) {
		return false
	}
	slice.sort_by(s.parts[:], proc(a, b: Part_Spec) -> bool {return a.name < b.name})
	if s.bpm <= 0 {
		base.report(findings, "bad_value", .Error, "song/bpm", "song/bpm: a tempo above 0")
		s.bpm = 120
	}
	if s.from != "" {
		base.report(findings, "not_supported", .Error, "song/from", "song/from: songs from files are not supported yet")
	}
	return true
}

spec_from_json :: proc(text: string, s: ^Spec, findings: ^base.Findings) -> bool {
	v, err := json.parse_string(text, .JSON5, true)
	if err != nil {
		base.report(findings, "bad_json", .Error, "", "the spec is not valid JSON (%v)", err)
		return false
	}
	return spec_from_value(v, s, findings)
}

// ---- field readers -------------------------------------------------------------------

number_from_value :: proc(v: json.Value) -> (f64, bool) {
	#partial switch x in v {
	case json.Integer:
		return f64(x), true
	case json.Float:
		return x, true
	}
	return 0, false
}

@(private = "file")
bad :: proc(r: ^Reader, path, want: string) {
	base.report(r.findings, "bad_value", .Error, path, "%s: expected %s", path, want)
}

@(private = "file")
read_number_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	n, ok := number_from_value(v)
	if !ok {
		bad(r, path, "a number")
		return
	}
	(^f64)(dst)^ = n
}

@(private = "file")
read_bool_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	b, ok := v.(json.Boolean)
	if !ok {
		bad(r, path, "true or false")
		return
	}
	(^bool)(dst)^ = b
}

@(private = "file")
read_string_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	s, ok := v.(json.String)
	if !ok {
		bad(r, path, "a string")
		return
	}
	(^string)(dst)^ = strings.clone(s)
}

@(private = "file")
read_time_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	t := (^Time_Spec)(dst)
	if n, ok := number_from_value(v); ok {
		t^ = {"", n}
		return
	}
	if s, ok := v.(json.String); ok {
		t^ = {strings.clone(s), UNSET}
		return
	}
	bad(r, path, "seconds or a Tone length (\"8m\", \"2:0:0\")")
}

@(private = "file")
read_bpm_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	b := (^[2]f64)(dst)
	if n, ok := number_from_value(v); ok && n > 0 {
		b^ = {n, n}
		return
	}
	if a, ok := v.(json.Array); ok && len(a) == 2 {
		x, ok_x := number_from_value(a[0])
		y, ok_y := number_from_value(a[1])
		if ok_x && ok_y && x > 0 && y > 0 {
			b^ = {x, y}
			return
		}
	}
	bad(r, path, "a tempo, or { from, to } for a ramp")
}

@(private = "file")
read_meter_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	if n, ok := number_from_value(v); ok && n >= 1 {
		(^f64)(dst)^ = math.floor(n)
		return
	}
	if a, ok := v.(json.Array); ok && len(a) == 2 {
		num, _ := number_from_value(a[0])
		den, _ := number_from_value(a[1])
		if num >= 1 && den >= 1 {
			(^f64)(dst)^ = max(1, math.round(num * 4 / den))
			return
		}
	}
	bad(r, path, "beats a bar (4) or { 6, 8 }")
}

@(private = "file")
read_pair_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	a, ok := v.(json.Array)
	if ok && len(a) == 2 {
		x, ok_x := number_from_value(a[0])
		y, ok_y := number_from_value(a[1])
		if ok_x && ok_y {
			(^[2]f64)(dst)^ = {x, y}
			return
		}
	}
	bad(r, path, "{ low, high }")
}

@(private = "file")
read_flex_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	a, ok := v.(json.Array)
	if !ok || len(a) != 2 {
		bad(r, path, "{ \"4m\", \"8m\" }: the fewest and most bars")
		return
	}
	f := (^[2]Time_Spec)(dst)
	read_time_field(r, a[0], base.path_index(path, 1), &f[0])
	read_time_field(r, a[1], base.path_index(path, 2), &f[1])
}

@(private = "file")
read_ranges_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	sp := (^Span)(dst)
	if sp.count == 0 {
		sp.first = i32(len(r.spec.ranges))
	}
	#partial switch x in v {
	case json.String:
		append(&r.spec.ranges, strings.clone(x))
		sp.count += 1
	case json.Array:
		for y, i in x {
			s, ok := y.(json.String)
			if !ok {
				bad(r, base.path_index(path, i + 1), "a range (\"drop\", \"drop@4m..\")")
				continue
			}
			append(&r.spec.ranges, strings.clone(s))
			sp.count += 1
		}
	case:
		bad(r, path, "a range or a list of ranges")
	}
}

// A part's instrument: a Voice playing a row (read into a program where
// the part plays it: instrument_program).
@(private = "file")
read_device_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	#partial switch _ in v {
	case json.String, json.Object:
	case:
		bad(r, path, "an instrument: a name, or a row ({ nodes = { ... } })")
		(^i32)(dst)^ = -1
		return
	}
	append(&r.spec.devices, Device_Spec{kind = .Voice, path = strings.clone(path), row = json.clone_value(v)})
	(^i32)(dst)^ = i32(len(r.spec.devices) - 1)
}

@(private = "file")
read_chain_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	(^Span)(dst)^ = chain_from_value(r, v, path)
}

// An effect chain as a part's `effects` is written, read into s (its
// devices and chain): a host's own track's (a clip's), findings at `path`.
effects_from_value :: proc(s: ^Spec, v: json.Value, path: string, findings: ^base.Findings) -> Span {
	r := Reader{s, findings}
	return chain_from_value(&r, v, path)
}

chain_from_value :: proc(r: ^Reader, v: json.Value, path: string) -> Span {
	// devices first (each may add values), then their indices in a row
	found := make([dynamic]i32, context.temp_allocator)
	#partial switch x in v {
	case json.Array:
		for y, i in x {
			if d := device_from_value(r, y, base.path_index(path, i + 1)); d >= 0 {
				append(&found, d)
			}
		}
	case:
		if d := device_from_value(r, v, path); d >= 0 {
			append(&found, d)
		}
	}
	sp := Span{i32(len(r.spec.chain)), i32(len(found))}
	append(&r.spec.chain, ..found[:])
	return sp
}

@(private = "file")
read_sends_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	o, ok := v.(json.Object)
	if !ok {
		bad(r, path, "{ hall = -12 }: a level in dB per return")
		return
	}
	sp := Span{i32(len(r.spec.sends)), 0}
	keys := make([dynamic]string, context.temp_allocator)
	for k in o {
		append(&keys, k)
	}
	slice.sort(keys[:])
	for k in keys {
		db, is_number := number_from_value(o[k])
		if !is_number {
			bad(r, base.path_join(path, k), "a level in dB")
			continue
		}
		append(&r.spec.sends, Send_Spec{strings.clone(k), db})
		sp.count += 1
	}
	(^Span)(dst)^ = sp
}

@(private = "file")
read_sidechain_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	sc := (^Sidechain_Spec)(dst)
	if s, ok := v.(json.String); ok {
		sc.source = strings.clone(s)
		return
	}
	read_record(r, v, path, SIDECHAIN_FIELDS, sc)
	sc.depth = clamp(sc.depth, 0, 1)
	sc.release = max(sc.release, 0.005)
}

// A play's pattern: exactly one kind per entry.
@(private = "file")
set_kind :: proc(r: ^Reader, p: ^Play_Spec, kind: Play_Kind, path: string) -> bool {
	if p.kind != .None {
		if !p.refused {
			base.report(r.findings, "bad_value", .Error, p.path, "%s: a play entry plays one of steps, notes, degrees, events, arpeggio, chords", p.path)
		}
		p.refused = true
		return false
	}
	p.kind = kind
	return true
}

@(private = "file")
read_steps_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	p := (^Play_Spec)(dst)
	if !set_kind(r, p, .Steps, path) {
		return
	}
	lane :: proc(r: ^Reader, pad: string, v: json.Value, path: string) {
		l := Lane_Spec{pad = strings.clone(pad), bars = {i32(len(r.spec.bars)), 0}}
		#partial switch x in v {
		case json.String:
			append(&r.spec.bars, strings.clone(x))
			l.bars.count = 1
		case json.Array:
			for y, i in x {
				s, ok := y.(json.String)
				if !ok {
					bad(r, base.path_index(path, i + 1), "a step string (\"x...x...\")")
					continue
				}
				append(&r.spec.bars, strings.clone(s))
				l.bars.count += 1
			}
		case:
			bad(r, path, "a step string or a list of them")
			return
		}
		append(&r.spec.lanes, l)
	}
	p.rows = {i32(len(r.spec.lanes)), 0}
	if o, is_pads := v.(json.Object); is_pads {
		keys := make([dynamic]string, context.temp_allocator)
		for k in o {
			append(&keys, k)
		}
		slice.sort(keys[:])
		for k in keys {
			lane(r, k, o[k], base.path_join(path, k))
		}
	} else {
		lane(r, "", v, path)
	}
	p.rows.count = i32(len(r.spec.lanes)) - p.rows.first
}

@(private = "file")
read_sequence :: proc(r: ^Reader, v: json.Value, path: string, p: ^Play_Spec) {
	flatten :: proc(r: ^Reader, v: json.Value, path: string, at, length: f64) {
		#partial switch x in v {
		case json.String:
			fields := strings.fields(x, context.temp_allocator)
			kept := make([dynamic]string, context.temp_allocator)
			for f in fields {
				if f != "|" {
					append(&kept, f)
				}
			}
			if len(kept) == 1 {
				append(&r.spec.tokens, Token_Spec{strings.clone(kept[0]), at, length})
				return
			}
			each := length / f64(max(len(kept), 1))
			for f, i in kept {
				append(&r.spec.tokens, Token_Spec{strings.clone(f), at + f64(i) * each, each})
			}
		case json.Boolean, json.Null:
			append(&r.spec.tokens, Token_Spec{".", at, length})
		case json.Array:
			each := length / f64(max(len(x), 1))
			for y, i in x {
				flatten(r, y, base.path_index(path, i + 1), at + f64(i) * each, each)
			}
		case:
			bad(r, path, "a note, a rest (false) or a group")
		}
	}
	slots := 0
	#partial switch x in v {
	case json.String:
		for f in strings.fields(x, context.temp_allocator) {
			if f != "|" {
				slots += 1
			}
		}
	case json.Array:
		slots = len(x)
	case:
		bad(r, path, "a string of notes or a list")
		return
	}
	p.rows.first = i32(len(r.spec.tokens))
	p.slots = f64(slots)
	flatten(r, v, path, 0, f64(slots))
	p.rows.count = i32(len(r.spec.tokens)) - p.rows.first
}

@(private = "file")
read_notes_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	p := (^Play_Spec)(dst)
	if set_kind(r, p, .Notes, path) {
		read_sequence(r, v, path, p)
	}
}

@(private = "file")
read_degrees_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	p := (^Play_Spec)(dst)
	if set_kind(r, p, .Degrees, path) {
		read_sequence(r, v, path, p)
	}
}

@(private = "file")
read_events_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	p := (^Play_Spec)(dst)
	if !set_kind(r, p, .Events, path) {
		return
	}
	a, ok := v.(json.Array)
	if !ok {
		bad(r, path, "a list of { time, note, duration, velocity }")
		return
	}
	p.rows.first = i32(len(r.spec.events))
	for x, i in a {
		e := Event_Spec{time = {"0:0:0", UNSET}, note = "C4", duration = {"8n", UNSET}, velocity = UNSET}
		if read_record(r, x, base.path_index(path, i + 1), EVENT_FIELDS, &e) {
			append(&r.spec.events, e)
		}
	}
	p.rows.count = i32(len(r.spec.events)) - p.rows.first
}

@(private = "file")
read_arpeggio_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	p := (^Play_Spec)(dst)
	if set_kind(r, p, .Arpeggio, path) {
		read_record(r, v, path, ARPEGGIO_FIELDS, p)
	}
}

@(private = "file")
read_chords_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	p := (^Play_Spec)(dst)
	if !set_kind(r, p, .Chords, path) {
		return
	}
	if b, ok := v.(json.Boolean); ok && b {
		return
	}
	read_record(r, v, path, CHORDS_FIELDS, p)
}

@(private = "file")
read_sections_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	a, ok := v.(json.Array)
	if !ok {
		bad(r, path, "a list of sections")
		return
	}
	for x, i in a {
		s := Section_Spec{start = UNSET, energy = UNSET, flex = {{"", UNSET}, {"", UNSET}}, duration = {"", UNSET}, at = {"", UNSET}}
		sp := base.path_index(path, i + 1)
		if !read_record(r, x, sp, SECTION_FIELDS, &s) {
			continue
		}
		if s.name == "" {
			base.report(r.findings, "bad_value", .Error, sp, "%s: a section needs a name", sp)
			continue
		}
		append(&r.spec.sections, s)
	}
}

@(private = "file")
read_parts_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	o, ok := v.(json.Object)
	if !ok {
		bad(r, path, "{ name = { ... } } per part")
		return
	}
	names := make([dynamic]string, context.temp_allocator)
	for k in o {
		append(&names, k)
	}
	slice.sort(names[:])
	for name in names {
		pp := base.path_join(path, name, context.allocator)
		p := Part_Spec{name = strings.clone(name), instrument = -1, gain_db = UNSET, pan = UNSET, octave = UNSET, room_db = UNSET, effects = {0, -1}, sidechain = {depth = 0.8, release = 0.07}}
		if !read_record(r, o[name], pp, PART_FIELDS, &p) {
			continue
		}
		p.pan = math.is_nan(p.pan) ? p.pan : clamp(p.pan, -1, 1)
		// the plays, one contiguous run per part
		p.plays.first = i32(len(r.spec.plays))
		po := o[name].(json.Object)
		#partial switch plays in po["play"] {
		case json.Array:
			for x, i in plays {
				read_play(r, x, base.path_index(base.path_join(pp, "play"), i + 1, context.allocator))
			}
		case json.Object:
			read_play(r, plays, base.path_join(pp, "play", context.allocator))
		case nil:
		case:
			bad(r, base.path_join(pp, "play"), "a play entry or a list of them")
		}
		p.plays.count = i32(len(r.spec.plays)) - p.plays.first
		append(&r.spec.parts, p)
	}
}

@(private = "file")
read_play :: proc(r: ^Reader, v: json.Value, path: string) {
	p := Play_Spec{path = path, velocity = 0.8, octave = UNSET, energy = {0, 1}}
	p.arpeggio = {"up", "16n", 1}
	p.chords.voicing = "close"
	if !read_record(r, v, path, PLAY_FIELDS, &p) || p.refused {
		return
	}
	if p.kind == .None {
		base.report(r.findings, "bad_value", .Error, path, "%s: play one of steps, notes, degrees, events, arpeggio, chords", path)
		return
	}
	p.velocity = clamp(p.velocity, 0, 1)
	if p.humanize > HUMANIZE_LIKELY {
		at := base.path_join(path, "humanize")
		base.report(r.findings, "bad_value", .Warning, at, "%s: humanize is seconds (Tone's): %g moves each note up to ±%.0f ms; a player is within ±0.01", at, p.humanize, p.humanize * 1000)
	}
	append(&r.spec.plays, p)
}

// The most a play's humanize (seconds either way) is likely meant to be; more
// is a warning (it reads like a fraction: 0.12 is ±120 ms).
HUMANIZE_LIKELY :: 0.03

@(private = "file")
read_returns_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	o, ok := v.(json.Object)
	if !ok {
		bad(r, path, "{ name = { effects } } per return")
		return
	}
	names := make([dynamic]string, context.temp_allocator)
	for k in o {
		append(&names, k)
	}
	slice.sort(names[:])
	for name in names {
		append(&r.spec.returns, Return_Spec{strings.clone(name), chain_from_value(r, o[name], base.path_join(path, name))})
	}
}

@(private = "file")
read_markers_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	a, ok := v.(json.Array)
	if !ok {
		bad(r, path, "a list of { name, at }")
		return
	}
	for x, i in a {
		m := Marker_Spec{at = {"", UNSET}}
		mp := base.path_index(path, i + 1)
		if read_record(r, x, mp, MARKER_FIELDS, &m) && m.name != "" {
			append(&r.spec.markers, m)
		} else if m.name == "" {
			base.report(r.findings, "bad_value", .Error, mp, "%s: a marker needs a name", mp)
		}
	}
}

// sets = { name = { pads = { kick = "kick.wav", snare = { "snare.wav", gain_db = -2 } },
// zones = { { "C3.wav", root = "C3" }, ... }, gain_db, credit, loop } }
@(private = "file")
read_sets_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	o, ok := v.(json.Object)
	if !ok {
		bad(r, path, "{ name = { pads or zones } } per set")
		return
	}
	names := make([dynamic]string, context.temp_allocator)
	for k in o {
		append(&names, k)
	}
	slice.sort(names[:])
	zone :: proc() -> Set_Zone_Spec {
		return {root = UNSET, lo = UNSET, hi = UNSET, lo_velocity = 0, hi_velocity = 127, one_shot = UNSET, key = UNSET}
	}
	for name in names {
		sp := base.path_join(path, name, context.allocator)
		set := Set_Spec{name = strings.clone(name)}
		if !read_record(r, o[name], sp, SET_FIELDS, &set) {
			continue
		}
		set.zones.first = i32(len(r.spec.set_zones))
		so := o[name].(json.Object)
		// pads: a file (or a zone's record) per drum pad
		if pads, has := so["pads"]; has {
			po, is_object := pads.(json.Object)
			if !is_object {
				bad(r, base.path_join(sp, "pads"), "{ kick = \"kick.wav\", ... }")
			}
			keys := make([dynamic]string, context.temp_allocator)
			for k in po {
				append(&keys, k)
			}
			slice.sort(keys[:])
			for k in keys {
				zp := base.path_join(base.path_join(sp, "pads"), k)
				// a file or a zone's record, or a list of them: a round robin
				entries := []json.Value{po[k]}
				if list, is_list := po[k].(json.Array); is_list {
					entries = list[:]
				}
				for e, i in entries {
					ep := len(entries) > 1 ? base.path_index(zp, i + 1) : zp
					z := zone()
					z.pad = strings.clone(k)
					if f, is_file := e.(json.String); is_file {
						z.file = strings.clone(f)
					} else if !read_record(r, e, ep, SET_ZONE_FIELDS, &z) {
						continue
					}
					append(&r.spec.set_zones, z)
				}
			}
			pad_keys(r.spec.set_zones[set.zones.first:])
		}
		// zones: a file per key range and velocity range
		if zones, has := so["zones"]; has {
			za, is_list := zones.(json.Array)
			if !is_list {
				bad(r, base.path_join(sp, "zones"), "a list of { file, root, lo, hi, ... }")
			}
			for x, i in za {
				zp := base.path_index(base.path_join(sp, "zones"), i + 1)
				z := zone()
				if f, is_file := x.(json.String); is_file {
					z.file = strings.clone(f)
				} else if !read_record(r, x, zp, SET_ZONE_FIELDS, &z) {
					continue
				}
				append(&r.spec.set_zones, z)
			}
		}
		set.zones.count = i32(len(r.spec.set_zones)) - set.zones.first
		for z in r.spec.set_zones[set.zones.first:] {
			if z.file == "" {
				base.report(r.findings, "bad_value", .Error, sp, "%s: a zone needs its file", sp)
			}
		}
		if set.zones.count == 0 {
			base.report(r.findings, "bad_value", .Error, sp, "%s: a set needs pads or zones", sp)
			continue
		}
		append(&r.spec.sets, set)
	}
}

// A set's pads' keys: a pad's own, else its General MIDI name's, else the
// lowest key none of the set's pads has (in the pads' name order).
@(private = "file")
pad_keys :: proc(zones: []Set_Zone_Spec) {
	used: bit_set[0 ..< 128;u128]
	for &z in zones {
		if math.is_nan(z.key) {
			if k, gm := device.gm_key(z.pad); gm {
				z.key = f64(k)
			}
		}
		if !math.is_nan(z.key) && z.key >= 0 && z.key < 128 {
			used += {int(z.key)}
		}
	}
	next := 0
	for &z, i in zones {
		if !math.is_nan(z.key) {
			continue
		}
		// a round robin's zones share their pad's key
		for y in zones[:i] {
			if y.pad == z.pad {
				z.key = y.key
			}
		}
		if !math.is_nan(z.key) {
			continue
		}
		for next < 127 && (next in used) {
			next += 1
		}
		z.key = f64(next)
		used += {next}
	}
}

@(private = "file")
read_note_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	if n, ok := number_from_value(v); ok {
		(^f64)(dst)^ = n
		return
	}
	if s, ok := v.(json.String); ok {
		if p, is_pitch := theory.pitch_from_string(s); is_pitch {
			(^f64)(dst)^ = f64(p)
			return
		}
	}
	bad(r, path, "a note (\"C3\", \"F#2\") or a MIDI number")
}

@(private = "file")
read_sources_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	o, ok := v.(json.Object)
	if !ok {
		bad(r, path, "{ name = { url, licence, credit, pins } } per source")
		return
	}
	names := make([dynamic]string, context.temp_allocator)
	for k in o {
		append(&names, k)
	}
	slice.sort(names[:])
	for name in names {
		sp := base.path_join(path, name)
		x := Source_Spec{name = strings.clone(name)}
		if !read_record(r, o[name], sp, SOURCE_FIELDS, &x) {
			continue
		}
		if x.url == "" || x.pins == "" || x.licence == "" {
			base.report(r.findings, "bad_value", .Error, sp, "%s: a source needs its url, its pins file and its licence", sp)
			continue
		}
		// its name is a folder of the data directory, its url fetched by curl
		named := true
		for c in transmute([]u8)name {
			named &&= (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
		}
		if !named {
			base.report(r.findings, "bad_value", .Error, sp, "%s: a source's name is lowercase letters, digits, _ and -", sp)
			continue
		}
		if !strings.has_prefix(x.url, "https://") {
			base.report(r.findings, "bad_value", .Error, sp, "%s: a source's url is https://", sp)
			continue
		}
		// odawg pin writes the pins: beside the spec, never out of its folder
		if !plain_path(x.pins) {
			base.report(r.findings, "bad_value", .Error, sp, "%s: its pins are a plain path in the spec's folder (no .., \\, drive or leading /)", sp)
			continue
		}
		if !strings.has_suffix(x.url, "/") {
			x.url = strings.concatenate({x.url, "/"})
		}
		append(&r.spec.sources, x)
	}
}

read_buses_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	o, ok := v.(json.Object)
	if !ok {
		bad(r, path, "{ name = { effects, to } } per bus")
		return
	}
	names := make([dynamic]string, context.temp_allocator)
	for k in o {
		append(&names, k)
	}
	slice.sort(names[:])
	for name in names {
		b := Bus_Spec{name = strings.clone(name)}
		if read_record(r, o[name], base.path_join(path, name), BUS_FIELDS, &b) {
			append(&r.spec.buses, b)
		}
	}
}

@(private = "file")
read_styles_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	o, ok := v.(json.Object)
	if !ok {
		bad(r, path, "{ name = { parts, returns, swing } } per style")
		return
	}
	names := make([dynamic]string, context.temp_allocator)
	for k in o {
		append(&names, k)
	}
	slice.sort(names[:])
	for name in names {
		if _, is_object := o[name].(json.Object); !is_object {
			bad(r, base.path_join(path, name), "a style: a table of parts, returns, swing")
			continue
		}
		append(&r.spec.styles, style_read(r.spec, name, json.clone_value(o[name])))
	}
}

@(private = "file")
read_instruments_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	#partial switch x in v {
	case json.String:
		// a file of rows
		append(&r.spec.instrument_includes, strings.clone(x))
		return
	case json.Array:
		for y, i in x {
			read_instruments_field(r, y, base.path_index(path, i + 1), dst)
		}
		return
	}
	o, ok := v.(json.Object)
	if !ok {
		bad(r, path, "{ name = { nodes = { ... } } } per instrument, a file of them, or a list of those")
		return
	}
	names := make([dynamic]string, context.temp_allocator)
	for k in o {
		append(&names, k)
	}
	slice.sort(names[:])
	for name in names {
		append(&r.spec.instruments, Instrument_Spec{strings.clone(name), json.clone_value(o[name])})
	}
}

@(private = "file")
read_room_field :: proc(r: ^Reader, v: json.Value, path: string, dst: rawptr) {
	// a name: the host's spans of it (a mix's voice bus)
	if name, is_name := v.(json.String); is_name {
		r.spec.room_from = strings.clone(name)
		return
	}
	a, ok := v.(json.Array)
	if !ok {
		bad(r, path, "a list of { from, to } spans in seconds, or the name of a host's sound (\"voice\")")
		return
	}
	for x, i in a {
		pair: [2]f64
		read_pair_field(r, x, base.path_index(path, i + 1), &pair)
		append(&r.spec.room, pair)
	}
}

// ---- devices -------------------------------------------------------------------------

// An instrument or effect: a name (a Tone class, an effect: "Synth",
// "MonoSynth", "Reverb"), or a table whose name is one, its options nested as
// Tone nests them. Each option is found in device.PARAM_TABLE by its `/` path
// among the params its kind reads; a string where a table of options with a
// `type` is expected is that type (`noise = "pink"`).
device_from_value :: proc(r: ^Reader, v: json.Value, path: string) -> i32 {
	name: string
	o: json.Object
	#partial switch x in v {
	case json.String:
		name = x
	case json.Object:
		o = x
		if s, ok := x["name"].(json.String); ok {
			name = s
		} else if s, ok := x["class"].(json.String); ok {
			name = s
		}
	case:
		bad(r, path, "an instrument or effect: a name or { name, options }")
		return -1
	}
	kind, known := device.device_from_name(name)
	if !known {
		base.report(r.findings, "bad_value", .Error, path, "%s: %q is not an instrument or effect", path, name)
		return -1
	}
	d := Device_Spec{kind = kind, values = {i32(len(r.spec.values)), 0}, path = strings.clone(path)}
	if o != nil {
		read_options(r, o, "", path, &d)
	}
	d.values.count = i32(len(r.spec.values)) - d.values.first
	append(&r.spec.devices, d)
	return i32(len(r.spec.devices) - 1)
}

@(private = "file")
read_options :: proc(r: ^Reader, o: json.Object, prefix, path: string, d: ^Device_Spec) {
	keys := make([dynamic]string, context.temp_allocator)
	for k in o {
		append(&keys, k)
	}
	slice.sort(keys[:])
	reads := device.DEVICE_TABLE[d.kind].reads
	for k in keys {
		if prefix == "" && (k == "name" || k == "class") {
			continue
		}
		key := prefix == "" ? k : strings.concatenate({prefix, "/", k}, context.temp_allocator)
		at := base.path_join(path, k)
		v := o[k]
		if sub, is_table := v.(json.Object); is_table {
			read_options(r, sub, key, at, d)
			continue
		}
		param := param_from_path(key, reads)
		if s, is_string := v.(json.String); is_string && param == .None {
			// `noise = "pink"`: the type of the options at that path
			param = param_from_path(strings.concatenate({key, "/type"}, context.temp_allocator), reads)
			if param != .None {
				set_option(r, d, param, s, at)
				continue
			}
		}
		if param == .None {
			base.report(r.findings, "unknown_key", .Warning, at, "%s: %s reads no %q", at, device.DEVICE_TABLE[d.kind].name, key)
			continue
		}
		set_option(r, d, param, v, at)
	}
}

@(private = "file")
param_from_path :: proc(path: string, reads: device.Param_Set) -> device.Param {
	for row, p in device.PARAM_TABLE {
		if p != .None && p in reads && row.path == path {
			return p
		}
	}
	return .None
}

@(private = "file")
set_option :: proc(r: ^Reader, d: ^Device_Spec, p: device.Param, v: json.Value, path: string) {
	row := device.PARAM_TABLE[p]
	value: f32
	if n, ok := number_from_value(v); ok {
		if row.unit == .Choice {
			bad(r, path, strings.join(row.choices, ", ", context.temp_allocator))
			return
		}
		value = f32(n)
	} else if s, is_string := v.(json.String); is_string {
		switch row.unit {
		case .Choice:
			i, found := slice.linear_search(row.choices, s)
			if !found {
				base.report(r.findings, "bad_value", .Error, path, "%s: %q is not one of %s", path, s, strings.join(row.choices, ", ", context.temp_allocator))
				return
			}
			value = f32(i)
		case .Seconds:
			l, parsed := tempo.length_from_string(s, 4)
			if !parsed {
				bad(r, path, "seconds or a Tone length (\"8n.\")")
				return
			}
			value = f32(l.value)
			if !l.in_seconds {
				d.beats += {p}
			}
		case .Hz:
			// an LFO's rate as a length: one cycle per that long
			l, parsed := tempo.length_from_string(s, 4)
			if !parsed || l.in_seconds || l.value <= 0 {
				bad(r, path, "Hz, or a Tone length for a rate")
				return
			}
			value = f32(1 / l.value)
			d.beats += {p} // cycles per beat: the composer divides by a beat's seconds
		case .Asset:
			value = f32(len(r.spec.strings))
			append(&r.spec.strings, strings.clone(s))
		case .Number, .Db, .Cents, .Table:
			bad(r, path, "a number")
			return
		}
	} else {
		bad(r, path, "a number or a string")
		return
	}
	append(&r.spec.values, device.Param_Value{p, value})
}

// For tests and hosts: a value from JSON text.
json_value :: json.Value
json_parse :: proc(text: string) -> (json.Value, json.Error) {return json.parse_string(text, .JSON5, true)}
