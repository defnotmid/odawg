// spec: a song as data, the way `song{}` in onimite and a JSON file for the
// CLI describe it. Everything read lands in flat tables: sections, parts,
// their play entries, the step lanes and sequence tokens those play, the
// devices (instruments and effects) with only the values the spec set. A
// record names its children by Span. A style is a partial spec read into the
// same tables (spec_from_style).
package odawg_spec

import "core:encoding/json"
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

// The sample sets a spec names (to load into a Bank before composing).
asset_names :: proc(s: ^Spec, out: ^[dynamic]string) {
	// the song's own styles play theirs too
	for st in s.styles {
		own := new(Spec, context.temp_allocator)
		findings := make(base.Findings, context.temp_allocator)
		{
			context.allocator = context.temp_allocator
			spec_from_value(st.value, own, &findings)
		}
		asset_names(own, out)
	}
	for d in s.devices {
		for v in s.values[d.values.first:base.span_end(d.values)] {
			if device.PARAM_TABLE[v.param].unit == .Asset {
				name := s.strings[int(v.value)]
				found := false
				for x in out {
					found ||= x == name
				}
				if !found {
					append(out, name)
				}
			}
		}
	}
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
			set, found := device.bank_set_from_name(bank, s.strings[int(v.value)])
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
