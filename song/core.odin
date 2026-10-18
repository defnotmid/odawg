// song: a spec composed into tables a renderer and a picture read. The form
// (sections on a tempo map, chords per bar), the devices with their values
// resolved, the tracks (a part as one instrument plays it: the part's name,
// its device, effect chain, sends and sidechain, a span of notes), and every
// note in one table, sorted by track so a track's notes are contiguous,
// with an index in time order for questions (when are the kicks).
package odawg_song

import "core:math"
import base "../base"
import device "../device"
import spec "../spec"
import tempo "../tempo"
import theory "../theory"

Span :: base.Span

Transition :: enum u8 {
	Auto,
	None,
	Cut,
	Riser,
	Fill,
	Impact,
	Pause,
	Filter,
}

TRANSITION_NAMES := [Transition]string {
	.Auto   = "",
	.None   = "none",
	.Cut    = "cut",
	.Riser  = "riser",
	.Fill   = "fill",
	.Impact = "impact",
	.Pause  = "pause",
	.Filter = "filter",
}

Section :: struct {
	name:          string,
	beat, beats:   f64,
	start, stop:   f64, // song seconds
	bpm0, bpm1:    f64,
	beats_per_bar: int,
	bars:          int,
	style:         string,
	energy:        f64,
	chords:        Span, // into chords: one per bar, cycled
	transition:    Transition, // into this section
}

Marker :: struct {
	name:          string,
	beat, seconds: f64,
}

// Where a track is let through: from `start` to `stop` seconds (stop <=
// start: always), fading in and out over its edges with `curve`.
Window :: struct {
	start, stop:       f64,
	fade_in, fade_out: f64,
	curve:             device.Curve,
}

// How a track's pan sets its two sides: odawg's equal-power law (the
// centre at 0 dB, a side +3 dB), or onimite's balance (the far side turned
// down, the near side kept).
Pan_Law :: enum u8 {
	Equal_Power,
	Balance,
}

PAN_LAW_TABLE := [Pan_Law]proc(pan: f64) -> (l, r: f64) {
	.Equal_Power = proc(pan: f64) -> (l, r: f64) {
		a := (clamp(pan, -1, 1) + 1) * math.PI / 4
		return math.cos(a) * math.SQRT_TWO, math.sin(a) * math.SQRT_TWO
	},
	.Balance = proc(pan: f64) -> (l, r: f64) {
		return min(1, 1 - pan), min(1, 1 + pan)
	},
}

// One instrument playing a part: a part has a track per style it plays in
// (a lo-fi kit for the intro, a house kit for the drop) and per transition
// sound; its stem is the sum of its tracks.
Track :: struct {
	part:       i32, // into parts
	variant:    string, // the style (or transition sound) it plays for
	instrument: i32, // into devices
	gain_db:    f64,
	pan:        f64,
	pan_law:    Pan_Law,
	voice:      bool, // speech: what a spans sidechain ducks under
	muted:      bool, // heard by nothing (still ducking the ducked: one track heard alone)
	window:     Window, // where it is let through, with fades (a placed song's)
	room:       f64, // dB it dips by where the song makes room
	pad_gain_db: [device.Pad]f32, // each drum pad's level (Pad_Gain_Set)
	chain:      Span, // into chain: its effects in order
	sends:      Span, // into sends
	sidechains: Span, // into sidechains: what ducks it (a part's kick and a voice, both)
	notes:      Span, // into notes
}

// What ducks a track, and how: under each hit of a part (synth.lua's: the
// gain falls by `depth` at a hit and recovers with time constant
// `release`), or under the spans of the voice tracks (onimite's, fframes'
// duck_under_voice: `depth` in dB, ramping over `attack` before a span and
// `release` after `hold`, spans closer than `merge` merged).
Sidechain_Mode :: enum u8 {
	None,
	Hits,
	Spans,
}

Sidechain :: struct {
	mode:    Sidechain_Mode,
	part:    i32, // Hits: the source part
	pad:     device.Pad,
	pitch:   f32, // Hits: -1 any note of the part
	depth:   f64, // Hits: 0..1; Spans: dB
	attack:  f64,
	hold:    f64,
	release: f64,
	merge:   f64,
}

Send :: struct {
	ret:  i32, // into returns
	gain: f32, // linear
}

Return :: struct {
	name:  string,
	chain: Span,
}

// Where a part is triggered: an entry (the spec's own, or its style's in a
// section) over a range of the song, or a transition's sound. The song is
// its parts' regions: a part sounds only in them (and their tails), and
// what is measured of it (render's tables) and drawn of it takes their
// shape.
Region :: struct {
	part:        i32, // into parts
	start, stop: f64, // song seconds: the range it plays over
	// What triggered it: an entry's path ("parts/bass/play/2"), a style's
	// ("style/house/parts/bass/play/1"), a transition ("sections/drop/transition").
	source:      string,
}

// A note in the song: what the voice plays, where it is in beats, whose.
Note_Row :: struct {
	time, duration: f64,
	beat:           f64,
	pitch:          f32,
	velocity:       f32,
	pad:            device.Pad,
	track:          u16,
}

Song :: struct {
	name:     string,
	start:    f64, // on the outside clock
	duration: f64, // seconds to the end of the last section
	gain_db:  f64, // the spec's: in every track's level
	key:      theory.Key,
	seed:     u64,
	tempo:    tempo.Tempo_Map,
	sections: [dynamic]Section,
	chords:   [dynamic]theory.Chord,
	markers:  [dynamic]Marker,
	parts:    [dynamic]string, // names: the spec's sorted, then its styles', then "fx" (transitions) unless the spec has one
	tracks:   [dynamic]Track,
	devices:  [dynamic]device.Device_Kind,
	params:   [dynamic]device.Params, // parallel to devices: the resolved values
	chain:    [dynamic]i32, // device indices
	sends:    [dynamic]Send,
	returns:  [dynamic]Return,
	regions:  [dynamic]Region, // by part, then start
	// The routing (graph.odin): the spec's buses and routes, the nodes, the
	// edges.
	buses:    [dynamic]Bus,
	routes:   [dynamic]Route,
	nodes:    [dynamic]Node,
	edges:    [dynamic]Edge, // by `to`, then `from`
	notes:    #soa[dynamic]Note_Row, // by track, then time
	by_time:  [dynamic]i32, // notes in time order
	room:     [dynamic][2]f64, // song seconds
	// Or where a sound the host places plays, by name ("voice"): a mix the
	// song joins adds its spans to `room` (append_song's caller).
	room_from: string,
	voices:   [dynamic][2]f64, // the voice tracks' spans, sorted (a spans sidechain ducks under them)
	sidechains: [dynamic]Sidechain,
	// The master: its gain, then its chain (into chain; a mix's limiter).
	master_gain_db: f64,
	master:   Span,
	bank:     ^device.Bank, // the sample sets its Samplers play (nil: none)
	findings: base.Findings,
	// Edits since it was composed (command_apply): every one, and each
	// part's; what render's tables were measured at.
	version:       u32,
	part_versions: [dynamic]u32,
}

// What composing keeps until the note table is built: each track's notes.
Work :: struct {
	notes: [dynamic][dynamic]Note_Row, // by track
}

// Tempo the song may move by to meet a section's `start` (6 %) or its
// `duration` (3 %).
START_TEMPO_LIMIT :: 0.06
DURATION_TEMPO_LIMIT :: 0.03

// Composes `s` into `out`, its Samplers playing sets of `bank` (load the
// sets spec.asset_names lists first). Everything is allocated with
// context.allocator: give it an arena and release the arena with the song.
song_from_spec :: proc(s: ^spec.Spec, out: ^Song, bank: ^device.Bank = nil) -> bool {
	out.bank = bank
	out.name, out.start, out.seed, out.gain_db = s.name, s.start, u64(s.seed), s.gain_db
	out.findings = make(base.Findings)
	key, key_ok := theory.key_from_string(s.key)
	if !key_ok {
		base.report(&out.findings, "bad_value", .Error, "song/key", "song/key: %q is not a key (\"A minor\", \"D dorian\", \"C\")", s.key)
		key, _ = theory.key_from_string("C major")
	}
	out.key = key
	if !lay_out(s, out) {
		return false
	}
	for m in s.markers {
		b: f64
		ok: bool
		if math.is_nan(m.at.seconds) {
			b, ok = beat_from_position(out, m.at.text)
		} else {
			b, ok = tempo.beat_from_seconds(&out.tempo, m.at.seconds - s.start), true
		}
		if !ok {
			base.report(&out.findings, "bad_value", .Error, base.path_join("markers", m.name), "marker %s: %q is not a position in the song", m.name, m.at.text)
			continue
		}
		append(&out.markers, Marker{m.name, b, tempo.seconds_from_beat(&out.tempo, b)})
	}
	out.room_from = s.room_from
	for span in s.room {
		append(&out.room, [2]f64{span[0] - s.start, span[1] - s.start})
	}
	work: Work
	work.notes = make([dynamic][dynamic]Note_Row, context.temp_allocator)
	arrange(s, out, &work)
	add_transitions(out, &work)
	index_notes(out, &work)
	sort_regions(out)
	graph_build(out)
	return true
}
