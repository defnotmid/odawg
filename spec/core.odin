// spec: a song as data, the way `song{}` in onimite and a JSON file for the
// CLI describe it. Everything read lands in flat tables: sections, parts,
// their play entries, the step lanes and sequence tokens those play, the
// devices (instruments and effects) with only the values the spec set. A
// record names its children by Span. A style is a partial spec read into the
// same tables (spec_from_style).
package odawg_spec

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import base "../base"
import device "../device"

Span :: base.Span

// Optional numbers are NaN when the spec leaves them out.
UNSET :: base.UNSET

Spec :: struct {
	name:              string,
	start:             f64, // where the song sits on an outside clock (onimite: the video)
	bpm:               f64,
	beats_per_bar:     f64,
	key:               string,
	seed:              f64,
	swing:             f64,
	swing_subdivision: string,
	duration:          f64, // a target length, seconds (UNSET: none)
	gain_db:           f64, // the whole song's level: headroom for a mix it joins (-10)
	from:              string,
	// The first section's style, energy and chords when it names none.
	style:             string,
	energy:            f64,
	chords:            string,
	sections:          [dynamic]Section_Spec,
	parts:             [dynamic]Part_Spec, // sorted by name
	plays:             [dynamic]Play_Spec,
	lanes:             [dynamic]Lane_Spec,
	bars:              [dynamic]string, // a lane's step strings, cycled per bar
	tokens:            [dynamic]Token_Spec,
	events:            [dynamic]Event_Spec,
	ranges:            [dynamic]string,
	devices:           [dynamic]Device_Spec,
	values:            [dynamic]device.Param_Value, // what a device sets
	chain:             [dynamic]i32, // device indices, in order
	sends:             [dynamic]Send_Spec,
	returns:           [dynamic]Return_Spec,
	markers:           [dynamic]Marker_Spec,
	room:              [dynamic][2]f64, // spans (outside clock) another sound needs room in
	room_from:         string, // or a sound the host places, by name ("voice"): its spans
	strings:           [dynamic]string, // an `.Asset` param's name ("vcsl/upright_piano"): its value is the index here
	styles:            [dynamic]Style_Spec, // the song's own, beside the ones odawg ships
	buses:             [dynamic]Bus_Spec,
	sets:              [dynamic]Set_Spec, // the song's own sample sets
	set_zones:         [dynamic]Set_Zone_Spec,
	// A style's: the song it is read for, whose sets its parts can name too
	// (a set the style brings itself wins).
	outer:             ^Spec,
}

// A style the song brings: a partial spec like the shipped ones (its parts,
// returns, swing), kept as the value it was given and read where a section
// uses it, the way a shipped style's text is.
Style_Spec :: struct {
	name:  string,
	value: json.Value,
}

Section_Spec :: struct {
	name:          string,
	duration:      Time_Spec, // a Tone length, or at least so many seconds
	start:         f64, // exactly here on the outside clock (UNSET: anywhere)
	bpm:           [2]f64, // from, to (0: carry over; equal: steady)
	beats_per_bar: f64, // 0: carry over
	style:         string,
	energy:        f64, // UNSET: carry over
	chords:        string,
	transition:    string,
	flex:          [2]Time_Spec,
	optional:      bool,
	stretch:       string, // "tempo"
	at:            Time_Spec, // in a song from a file
}

Part_Spec :: struct {
	name:       string,
	instrument: i32, // a device; -1: the style's, or the part's role's
	gain_db:    f64,
	pan:        f64,
	octave:     f64,
	effects:    Span, // into chain; count -1: not given (the style's)
	sends:      Span,
	sidechain:  Sidechain_Spec,
	mute:       Span, // into ranges
	plays:      Span,
	to:         string, // the bus it goes into ("": the master)
	key:        string, // the part, return or bus its effects' sidechain hears ("": itself)
}

// A sample set the song brings, played by a Sampler naming it (`set =
// "my_kit"`): drum pads or keyed zones over sample files, by their paths as
// the host resolves them (the CLI: from the spec's folder).
Set_Spec :: struct {
	name:    string,
	zones:   Span, // into set_zones
	gain_db: f64,
	credit:  string, // what to credit, for odawg credits and a host's
	loop:    bool, // its zones' files' loops play (a sustained instrument's)
}

// A file of a set and what it answers: a drum pad (its General MIDI key, a
// one-shot) or a key range around its root (UNSET lo and hi: split with
// the set's other roots at their midpoints), a velocity range.
Set_Zone_Spec :: struct {
	file:        string,
	pad:         device.Pad,
	root:        f64, // MIDI (UNSET: the pad's key, else 60)
	lo, hi:      f64, // MIDI keys (UNSET: split)
	lo_velocity: f64,
	hi_velocity: f64,
	gain_db:     f64,
	one_shot:    f64, // 1 yes, 0 no (UNSET: a pad's is, a key's isn't)
	offset:      f64, // frames into the file a note starts at
}

// A bus the spec names: its effects, and where it goes ("": the master).
Bus_Spec :: struct {
	name:  string,
	chain: Span,
	to:    string,
}

Sidechain_Spec :: struct {
	source:  string, // "drums/kick": a part and the pad or note that ducks this one
	depth:   f64,
	release: f64,
}

Send_Spec :: struct {
	to:      string,
	gain_db: f64,
}

Return_Spec :: struct {
	name:  string,
	chain: Span,
}

Marker_Spec :: struct {
	name: string,
	at:   Time_Spec,
}

// A number (seconds) or a string (a Tone length or a position), as written.
Time_Spec :: struct {
	text:    string,
	seconds: f64, // UNSET when text is set
}

Play_Kind :: enum u8 {
	None,
	Steps, // lanes
	Notes, // tokens
	Degrees, // tokens
	Events, // events
	Arpeggio,
	Chords,
}

// What a part plays over its ranges: one kind of pattern, its rows, and the
// options any kind reads.
Play_Spec :: struct {
	path:        string,
	ranges:      Span, // into ranges (none: the section a style applies it to)
	kind:        Play_Kind,
	refused:     bool, // it named two patterns: reported and left out
	rows:        Span, // lanes, tokens or events, by kind
	slots:       f64, // Notes/Degrees: top-level slots a cycle has
	note:        string, // Steps on a pitched part: the note or degree
	subdivision: string,
	loop:        string,
	arpeggio:    Arpeggio_Spec,
	chords:      Chords_Spec,
	velocity:    f64,
	octave:      f64,
	humanize:    f64,
	duration:    string,
	energy:      [2]f64,
}

// Tone.Pattern's names ("up", "upDown", "random"), a note every interval.
Arpeggio_Spec :: struct {
	pattern:  string,
	interval: string,
	octaves:  f64,
}

// "close", "open" or "spread"; a step string per bar, or "" for a chord
// held until the next change.
Chords_Spec :: struct {
	voicing: string,
	rhythm:  string,
}

// A drum pad's (or a pitched part's single) lane of steps.
Lane_Spec :: struct {
	pad:  string,
	bars: Span, // into bars
}

// A token of a sequence, flattened: its slot and length in top-level slots
// (a group splits its slot).
Token_Spec :: struct {
	text:       string, // "E5", "5", "." rest, "-" hold
	at, length: f64,
}

Event_Spec :: struct {
	time:     Time_Spec,
	note:     string,
	duration: Time_Spec,
	velocity: f64,
}

// An instrument or effect: its kind, the values the spec set (the rest are
// the kind's defaults), and which of those were Tone lengths in beats (the
// composer turns them into seconds at the part's tempo).
Device_Spec :: struct {
	kind:   device.Device_Kind,
	values: Span, // into values
	beats:  device.Param_Set,
	path:   string,
}

// A sample set a Sampler names, and the spec that says what it is (a set
// of the song's own, or of one of its styles: nil when the name is the
// register's or an SFZ file's).
Asset_Ref :: struct {
	name:  string,
	owner: ^Spec,
}

// The sample sets the song's Samplers name, its own styles' included, each
// once: what a host declares in its bank (assets.bank_declare_spec).
// Styles' specs are read into temp memory.
asset_refs :: proc(s: ^Spec, out: ^[dynamic]Asset_Ref) {
	for st in s.styles {
		own := new(Spec, context.temp_allocator)
		findings := make(base.Findings, context.temp_allocator)
		{
			context.allocator = context.temp_allocator
			spec_from_value(st.value, own, &findings)
		}
		own.outer = s
		asset_refs(own, out)
	}
	for d in s.devices {
		for v in s.values[d.values.first:base.span_end(d.values)] {
			if device.PARAM_TABLE[v.param].unit != .Asset {
				continue
			}
			name := s.strings[int(v.value)]
			_, owner := set_from_name(s, name)
			found := false
			for x in out {
				found ||= x.name == name && x.owner == owner
			}
			if !found {
				append(out, Asset_Ref{name, owner})
			}
		}
	}
}

// The names asset_refs finds (what bank_declare took before sets of a
// song's own: the register's names, an SFZ's path).
asset_names :: proc(s: ^Spec, out: ^[dynamic]string) {
	refs := make([dynamic]Asset_Ref, context.temp_allocator)
	asset_refs(s, &refs)
	for x in refs {
		append(out, x.name)
	}
}

// The set named `name` that `s` reads: its own, else its outer song's
// (nil: none), and the spec that defines it (its zones are in that spec).
set_from_name :: proc(s: ^Spec, name: string) -> (set: ^Set_Spec, owner: ^Spec) {
	for o := s; o != nil; o = o.outer {
		for &x in o.sets {
			if x.name == name {
				return &x, o
			}
		}
	}
	return nil, nil
}

// What a Sampler's `set = name` is in the bank: a set of the song's own is
// its name and a hash of what it is ("my_kit#5f1c09a2": two songs' sets of
// one name, or a set edited, are different sets); the register's and an
// SFZ file's, the name as written.
asset_key :: proc(s: ^Spec, name: string, allocator := context.temp_allocator) -> string {
	set, owner := set_from_name(s, name)
	if set == nil {
		return name
	}
	h := base.hash_string(set.name)
	h = base.hash_combine(h, transmute(u64)set.gain_db)
	h = base.hash_combine(h, base.hash_string(set.credit))
	h = base.hash_combine(h, u64(set.loop))
	for z in owner.set_zones[set.zones.first:base.span_end(set.zones)] {
		h = base.hash_combine(h, base.hash_string(z.file))
		h = base.hash_combine(h, u64(z.pad))
		for x in ([?]f64{z.root, z.lo, z.hi, z.lo_velocity, z.hi_velocity, z.gain_db, z.one_shot, z.offset}) {
			h = base.hash_combine(h, transmute(u64)x)
		}
	}
	return fmt.aprintf("%s#%08x", name, u32(h ~ (h >> 32)), allocator = allocator)
}

// The styles the song names that are files ("styles/footwork.json": a name
// with a / or ending in .json) and that it doesn't define itself: what a
// host reads and hands back (spec_add_style_text) before composing.
style_files :: proc(s: ^Spec, out: ^[dynamic]string) {
	add :: proc(s: ^Spec, out: ^[dynamic]string, name: string) {
		if name == "" || !(strings.contains(name, "/") || strings.has_suffix(name, ".json")) {
			return
		}
		for st in s.styles {
			if st.name == name {
				return
			}
		}
		for x in out {
			if x == name {
				return
			}
		}
		append(out, name)
	}
	add(s, out, s.style)
	for sec in s.sections {
		add(s, out, sec.style)
	}
}

// A style file's text, as style `name` of the song (a partial spec in the
// shape of odawg's styles/*.json). False: not JSON (a finding).
spec_add_style_text :: proc(s: ^Spec, name, text: string, findings: ^base.Findings) -> bool {
	v, err := json.parse_string(text, .JSON5, true)
	if err != nil {
		base.report(findings, "bad_json", .Error, name, "style %s is not valid JSON (%v)", name, err)
		return false
	}
	append(&s.styles, Style_Spec{strings.clone(name), v})
	return true
}

// The device's values: its kind's defaults, then what the spec set, a
// length in beats taking `beat_seconds` a beat, a sample set's name as its
// index in `bank` (-1 when the bank lacks it; ok is then false).
params_from_device :: proc(s: ^Spec, d: i32, beat_seconds: f64, bank: ^device.Bank = nil) -> (p: device.Params, ok: bool) {
	dev := s.devices[d]
	p = device.params_from_kind(dev.kind)
	ok = true
	for v in s.values[dev.values.first:base.span_end(dev.values)] {
		switch {
		case device.PARAM_TABLE[v.param].unit == .Asset:
			set, found := device.bank_set_from_name(bank, asset_key(s, s.strings[int(v.value)]))
			p[v.param] = f32(set)
			ok &&= found
		case v.param not_in dev.beats:
			p[v.param] = v.value
		case device.PARAM_TABLE[v.param].unit == .Hz:
			p[v.param] = f32(f64(v.value) / beat_seconds) // cycles a beat
		case:
			p[v.param] = f32(f64(v.value) * beat_seconds)
		}
	}
	return
}
