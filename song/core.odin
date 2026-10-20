// song: a spec composed into tables a renderer and a picture read. The form
// (sections on a tempo map, chords per bar), the devices with their values
// resolved, the tracks (a part as one instrument plays it: the part's name,
// its device, effect chain, sends and sidechain, a span of notes), and every
// note in one table, sorted by track so a track's notes are contiguous,
// with an index in time order for questions (when are the kicks).
package odawg_song

import "core:math"
import "core:slice"
import "core:strings"
import base "../base"
import device "../device"
import spec "../spec"
import tempo "../tempo"
import theory "../theory"

Span :: base.Span

// What happens into a section: nothing unless the section asks. A riser, an
// impact and a fill play on the part the section names (`transition_part`).
Transition :: enum u8 {
	None,
	Cut,
	Riser,
	Fill,
	Impact,
	Pause,
}

Section :: struct {
	name:          string,
	beat, beats:   f64,
	start, stop:   f64, // song seconds
	bpm0, bpm1:    f64,
	beats_per_bar: int,
	bars:          int,
	style:         i32, // into styles (-1: none)
	energy:        f64,
	chords:        Span, // into chords: one per bar, cycled
	transition:    Transition, // into this section
	transition_part: string, // what a riser, impact or fill plays on
}

Marker :: struct {
	name:          string,
	beat, seconds: f64,
}

// Where a placed song is let through: from `start` to `stop` seconds (stop
// <= start: always), fading in and out over its edges with `curve`.
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
	style:      i32, // into styles: the style it plays for (-1: the song's own)
	instrument: i32, // into devices
	gain_db:    f64,
	pan:        f64,
	pan_law:    Pan_Law,
	muted:      bool, // heard by nothing (still ducking the ducked: one track heard alone)
	room:       f64, // dB it dips by where its song makes room
	chain:      Span, // into chain: its effects in order
	sends:      Span, // into sends
	sidechains: Span, // into sidechains: what ducks it (a part's kick and a voice, both)
	notes:      Span, // into notes
}

// A pad at a level of its own on a track (Pad_Gain_Set): Song.pad_gains,
// only the pads given one.
Pad_Gain :: struct {
	track: i32, // into tracks
	pad:   u32,
	db:    f32,
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
	pad:     u32, // Hits: the pad (0: any)
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

// A song where it plays (its own, composed; or placed in a mix by
// append_song): the rows it owns, where its clock starts on the song's,
// and what its node does to everything it plays (the graph's .Song node,
// between its parts, returns and buses and the master): its level (the
// spec's gain, and a placement's), a duck under the voice (a spans
// sidechain; .None: none) and a window. Its effects keep its clock: a
// placed song sounds as it does alone.
Placement :: struct {
	name:    string, // the song's, or what a mix calls it ("score")
	at:      f64, // seconds its clock starts on this one
	gain_db: f64,
	duck:    Sidechain,
	window:  Window,
	tracks:  Span,
	parts:   Span,
	returns: Span,
	buses:   Span,
}

// A stretch where a placed song makes room (its parts dip by their room
// dB, ramping in and out): its own spans, or the host's for it (a mix).
Room_Span :: struct {
	placement:   i32, // into placements
	start, stop: f64, // song seconds
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
	pad:            u32, // base.name_id of its name (0: a pitched note)
	accent:         f32, // 0..1: an accented step (X), a note's !
	track:          u16,
	kind:           device.Note_Kind, // played, or made at compose (a release trigger's, a keyswitch)
	round:          u16, // earlier notes of its key on its track
	keyswitch:      u8, // 1 + the last keyswitch key before it (0: none)
	legato:         bool, // another note of its track is held when it starts
	level:          f32, // a gain on it (0: 1)
	// its draws, from its song's seed, its part and style, its time,
	// pitch and pad as the song composed them (note_seed): the same in a
	// mix, where the song is moved, renamed and seeded otherwise
	seed:           u64,
}

// A note row as the engine and the devices read it.
note_of :: proc(s: ^Song, i: int) -> device.Note {
	n := s.notes[i]
	return {n.time, n.duration, n.pitch, n.velocity, n.pad, n.accent, n.kind, n.round, n.keyswitch, n.legato, n.level}
}

// A composed note's seed: its track's (the song's seed, its part's and its
// style's names, their durable ids), then its time, pitch and pad (the same
// from a seek).
note_seed :: proc(s: ^Song, t: Track, n: Note_Row) -> u64 {
	track := base.hash_combine(s.seed, base.hash_combine(base.hash_string(s.parts[t.part]), base.hash_string(style_name(s, t.style))))
	return base.hash_combine(track, base.hash_combine(u64(n.time * base.RATE + 0.5), u64(n.pitch * 100) ~ u64(n.pad) << 32))
}

Song :: struct {
	name:     string,
	start:    f64, // on the outside clock
	duration: f64, // seconds to the end of the last section
	gain_db:  f64, // the spec's: its placement's level
	key:      theory.Key,
	seed:     u64,
	tempo:    tempo.Tempo_Map,
	sections: [dynamic]Section,
	chords:   [dynamic]theory.Chord,
	markers:  [dynamic]Marker,
	parts:    [dynamic]string, // names: the spec's and its styles', sorted
	styles:   [dynamic]string, // the styles its sections play, by name ("styles/house.json")
	tracks:   [dynamic]Track,
	devices:  [dynamic]device.Device_Kind,
	params:   [dynamic]device.Params, // parallel to devices: the resolved values
	labels:   [dynamic]string, // parallel to devices: an instrument's name as written ("MonoSynth", "machines/909.json"; a clip's "Player"), an effect's kind
	programs: device.Programs, // the Voices' instruments (a Voice's `Program` param indexes them)
	pad_names: [dynamic]string, // every pad a note or a question names (its id: base.name_id)
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
	room:     [dynamic]Room_Span,
	// Or where a sound the host places plays, by name ("voice"): a mix the
	// song joins adds its spans to `room` (append_song's caller).
	room_from: string,
	placements: [dynamic]Placement, // the songs it plays (its own: one)
	voices:   [dynamic][2]f64, // the voice tracks' spans, sorted (a spans sidechain ducks under them)
	sidechains: [dynamic]Sidechain,
	pad_gains: [dynamic]Pad_Gain,
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
	notes:  [dynamic][dynamic]Note_Row, // by track
	drafts: spec.Drafts, // the instruments drafted, each row once (placed at each tempo)
	styles: [dynamic]^spec.Spec, // by style (Song.styles): the spec its parts are read from (nil: none)
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
		append(&out.room, Room_Span{0, span[0] - s.start, span[1] - s.start})
	}
	work: Work
	work.notes = make([dynamic][dynamic]Note_Row, context.temp_allocator)
	spec.drafts_init(&work.drafts)
	arrange(s, out, &work)
	add_transitions(s, out, &work)
	layered_notes(out, &work)
	index_notes(out, &work)
	sort_regions(out)
	append(&out.placements, Placement {
		name = out.name, gain_db = out.gain_db,
		tracks = {0, i32(len(out.tracks))}, parts = {0, i32(len(out.parts))},
		returns = {0, i32(len(out.returns))}, buses = {0, i32(len(out.buses))},
	})
	graph_build(out)
	return true
}

// The time-order index over the notes (by time, then part).
notes_by_time :: proc(s: ^Song) {
	clear(&s.by_time)
	for i in 0 ..< len(s.notes) {
		append(&s.by_time, i32(i))
	}
	context.user_ptr = s
	slice.stable_sort_by(s.by_time[:], proc(a, b: i32) -> bool {
		s := (^Song)(context.user_ptr)
		ta, tb := s.notes.time[a], s.notes.time[b]
		if ta != tb {
			return ta < tb
		}
		return s.tracks[s.notes.track[a]].part < s.tracks[s.notes.track[b]].part
	})
}

// A style's index, by name ("": none, -1), added (its name copied) the first
// time.
style_intern :: proc(s: ^Song, name: string) -> i32 {
	if name == "" {
		return -1
	}
	for x, i in s.styles {
		if x == name {
			return i32(i)
		}
	}
	append(&s.styles, strings.clone(name))
	return i32(len(s.styles) - 1)
}

// A style's name ("": none).
style_name :: proc(s: ^Song, style: i32) -> string {
	return style >= 0 ? s.styles[style] : ""
}

// What the song's voices read beyond their notes.
voice_env :: proc(s: ^Song) -> device.Voice_Env {
	return {bank = s.bank, programs = &s.programs}
}

// A pad's id, its name kept for what prints it.
pad_intern :: proc(s: ^Song, name: string) -> u32 {
	id := base.name_id(name)
	for n in s.pad_names {
		if n == name {
			return id
		}
		if base.name_id(n) == id {
			base.report(&s.findings, "pad_collision", .Error, "", "pads %q and %q have the same id: rename one", n, name)
			return id
		}
	}
	append(&s.pad_names, name)
	return id
}

// A pad's name ("" none or unknown).
pad_name :: proc(s: ^Song, id: u32) -> string {
	if id == 0 {
		return ""
	}
	for n in s.pad_names {
		if base.name_id(n) == id {
			return n
		}
	}
	return "?"
}
