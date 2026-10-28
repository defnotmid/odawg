package odawg_song

import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import base "../base"
import spec "../spec"

// The example files (examples/): styles, instruments and machines, at the
// paths a song in examples/ names them by.
@(private = "file")
FILES := [?]struct {
	path, text: string,
	style:      bool,
} {
	{"styles/acid_house.json", #load("../examples/styles/acid_house.json", string), true},
	{"styles/ambient.json", #load("../examples/styles/ambient.json", string), true},
	{"styles/booty_house.json", #load("../examples/styles/booty_house.json", string), true},
	{"styles/chicago_house.json", #load("../examples/styles/chicago_house.json", string), true},
	{"styles/house.json", #load("../examples/styles/house.json", string), true},
	{"styles/lofi.json", #load("../examples/styles/lofi.json", string), true},
	{"styles/synthwave.json", #load("../examples/styles/synthwave.json", string), true},
	{"instruments/classic.json", #load("../examples/instruments/classic.json", string), false},
	{"instruments/tb303.json", #load("../examples/instruments/tb303.json", string), false},
	{"instruments/808_bass.json", #load("../examples/instruments/808_bass.json", string), false},
	{"machines/808.json", #load("../examples/machines/808.json", string), false},
	{"machines/909.json", #load("../examples/machines/909.json", string), false},
}

@(private = "file")
compose :: proc(t: ^testing.T, text: string, arena: ^virtual.Arena) -> ^Song {
	_ = virtual.arena_init_growing(arena)
	context.allocator = virtual.arena_allocator(arena)
	s := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(text, s, &findings))
	for f in FILES {
		if f.style {
			spec.spec_add_style_text(s, f.path, f.text, &findings)
		} else {
			spec.spec_add_instrument_text(s, f.path, f.text, &findings)
		}
	}
	out := new(Song)
	testing.expect(t, song_from_spec(s, out))
	append(&out.findings, ..findings[:])
	return out
}

@(private = "file")
has :: proc(s: ^Song, code: string) -> bool {
	for f in s.findings {
		if f.code == code {
			return true
		}
	}
	return false
}

// A section sized in seconds lasts the fewest whole bars that long; a ramp
// carries its end tempo into the next section; positions, ranges and bars
// resolve on the tempo map.
@(test)
test_form :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ sections: [
		{ name: "intro", duration: 9.5, bpm: 84 },
		{ name: "build", duration: "2m", bpm: [84, 124] },
		{ name: "drop", duration: "8m" } ] }`, &arena)
	testing.expect_value(t, len(s.sections), 3)
	testing.expect_value(t, s.sections[0].bars, 4) // 3 bars at 84 is 8.57 s, 4 is 11.43 s
	testing.expect(t, s.sections[0].stop >= 9.5)
	testing.expect_value(t, s.sections[2].bpm0, 124)
	b, ok := beat_from_position(s, "drop@1m")
	testing.expect(t, ok && b == s.sections[2].beat + 4)
	at, _ := seconds_from_position(s, "drop@-0.5s")
	testing.expect(t, math.abs(at - (s.sections[2].start - 0.5)) < 1e-9)
	from, to, in_song := beats_from_range(s, "build..drop")
	testing.expect(t, in_song && from == s.sections[1].beat && to == s.sections[2].beat + s.sections[2].beats)
	bar, _ := beat_from_position(s, "5:0:0")
	testing.expect_value(t, bar, s.sections[1].beat + 4)
}

// A section that must start at a time moves the flex sections before it by
// whole bars and the tempo by the rest; a duration out of reach is reported
// with each section's least length rather than met silently.
@(test)
test_constraints :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ bpm: 120, sections: [
		{ name: "a", duration: "4m", flex: ["2m", "8m"] },
		{ name: "b", duration: "4m", start: 12.5 } ] }`, &arena)
	testing.expect(t, math.abs(s.sections[1].start - 12.5) < 1e-6) // 6 bars (12 s at 120) and the tempo 4 % slower
	testing.expect(t, !has(s, "start_unreachable"))

	arena2: virtual.Arena
	defer virtual.arena_destroy(&arena2)
	s2 := compose(t, `{ bpm: 120, duration: 10, sections: [
		{ name: "a", duration: 12 },
		{ name: "b", duration: "4m", optional: true } ] }`, &arena2)
	testing.expect(t, has(s2, "section_dropped"))
	testing.expect(t, has(s2, "duration_unreachable")) // a's line needs 12 s
	testing.expect(t, s2.sections[0].stop >= 12 - 1e-9)
}

// A style fills its parts from the energy; the spec's own entries replace
// the style's for that part where they play; notes are sorted per track and
// the time index orders them all; pulses and hits read the real notes.
@(test)
test_arrangement :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ key: "A minor", sections: [
		{ name: "drop", duration: "2m", bpm: 120, style: "styles/house.json", energy: 1, chords: "Am F" } ],
		parts: { bass: { play: [ { name: "drop", steps: "xxxx", note: "A1" } ] } } }`, &arena)
	kicks := make([dynamic]i32, context.temp_allocator)
	testing.expect(t, notes_from_filter(s, {part = "drums", note = "kick"}, &kicks))
	testing.expect_value(t, len(kicks), 8) // four on the floor, two bars
	bass := make([dynamic]i32, context.temp_allocator)
	notes_from_filter(s, {part = "bass"}, &bass)
	testing.expect_value(t, len(bass), 8) // the spec's quarter notes, not the style's line
	for i in bass {
		testing.expect_value(t, s.notes.pitch[i], 33)
	}
	for k in 1 ..< len(s.by_time) {
		testing.expect(t, s.notes.time[s.by_time[k - 1]] <= s.notes.time[s.by_time[k]])
	}
	testing.expect(t, math.abs(pulse_from_seconds(s, 0.5, {part = "drums", note = "kick"}, 8) - 1) < 1e-9)
	testing.expect(t, pulse_from_seconds(s, 0.75, {part = "drums", note = "kick"}, 8) < 0.1)
}

// The same spec composes to the same notes.
@(test)
test_deterministic :: proc(t: ^testing.T) {
	text := `{ seed: 3, sections: [ { name: "a", duration: "4m", style: "styles/lofi.json", energy: 0.6, chords: "Am7 Fmaj7" } ] }`
	a1, a2: virtual.Arena
	defer virtual.arena_destroy(&a1)
	defer virtual.arena_destroy(&a2)
	x, y := compose(t, text, &a1), compose(t, text, &a2)
	testing.expect_value(t, len(x.notes), len(y.notes))
	for i in 0 ..< len(x.notes) {
		testing.expect(t, x.notes[i] == y.notes[i])
	}
}

// An energy band is [lo, hi), the top one closed: a section on the line
// between two bands plays one of them, so no hit doubles there, in any style.
@(test)
test_energy_bands :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ sections: [ { name: "a", duration: "2m", bpm: 120, style: "styles/house.json", energy: 0.7, chords: "Am F" } ] }`, &arena)
	kicks := make([dynamic]i32, context.temp_allocator)
	notes_from_filter(s, {part = "drums", note = "kick"}, &kicks)
	testing.expect_value(t, len(kicks), 8) // one a beat, not the two bands' both

	styles: virtual.Arena
	_ = virtual.arena_init_growing(&styles)
	defer virtual.arena_destroy(&styles)
	for style in FILES {
		if !style.style {
			continue
		}
		context.allocator = virtual.arena_allocator(&styles)
		st := new(spec.Spec)
		findings := make(base.Findings)
		spec.spec_from_json(style.text, st, &findings)
		for pl in st.plays {
			e := pl.energy[0]
			if e <= 0 {
				continue
			}
			a: virtual.Arena
			x := compose(t, fmt.tprint(`{ sections: [ { name: "a", duration: "4m", bpm: 120, style: "`, style.path, `", energy: `, e, `, chords: "Am F C G" } ] }`, sep = ""), &a)
			seen := make(map[[4]f64]bool, context.temp_allocator)
			for i in 0 ..< len(x.notes) {
				n := x.notes[i]
				key := [4]f64{f64(n.track), n.beat, f64(n.pad), f64(n.pitch)}
				if !testing.expectf(t, !seen[key], "%s at %v: %s plays twice at beat %v", style.path, e, x.parts[x.tracks[n.track].part], n.beat) {
					break
				}
				seen[key] = true
			}
			virtual.arena_destroy(&a)
		}
	}
}

// A fill rolls the pad its transition_part names, on any instrument that
// has it (here the 909 written out), in place of that pad's hits there.
@(test)
test_fill_drum_machine :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ sections: [
		{ name: "a", duration: "2m", bpm: 120, style: "styles/house.json", energy: 0.8, chords: "Am" },
		{ name: "b", duration: "2m", transition: "fill", transition_part: "drums/snare" } ],
		parts: { drums: { instrument: "machines/909.json" } } }`, &arena)
	roll := 0
	for i in 0 ..< len(s.notes) {
		n := s.notes[i]
		tr := s.tracks[n.track]
		if s.parts[tr.part] == "drums" && n.pad == base.name_id("snare") && n.beat >= 7 - 1e-9 && n.beat < 8 {
			roll += 1
		}
	}
	testing.expect_value(t, roll, 4)
}

// What reading a style found is the song's once, however many places
// read the style (its sections, the track a transition plays on).
@(test)
test_style_findings_once :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ styles: { mine: { bogus_key: 1, parts: { drums: { instrument: "machines/909.json", play: [ { steps: { kick: "x...x...x...x..." } } ] } } } },
		sections: [
		{ name: "a", duration: "2m", bpm: 120, style: "mine", chords: "Am" },
		{ name: "b", duration: "2m", style: "mine", transition: "impact", transition_part: "drums/kick" } ] }`, &arena)
	count := 0
	for f in s.findings {
		count += f.code == "unknown_key" && strings.contains(f.message, "bogus_key") ? 1 : 0
	}
	testing.expect_value(t, count, 1)
}

// Transitions are opt-in: a rise in energy adds nothing by itself. A riser
// and an impact play on the section's transition_part, at its level,
// through its effects and sends, on the root of the chord they land on; a
// riser without a part is a finding.
@(test)
test_transition_part :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	plain := compose(t, `{ sections: [
		{ name: "a", duration: "2m", bpm: 120, style: "styles/house.json", energy: 0.2, chords: "Am" },
		{ name: "b", duration: "2m", energy: 1, chords: "F" } ] }`, &arena)
	testing.expect_value(t, part_index(plain, "fx"), -1)
	for r in plain.regions {
		testing.expect(t, r.source != "sections/b/transition")
	}

	arena2: virtual.Arena
	defer virtual.arena_destroy(&arena2)
	s := compose(t, `{ sections: [
		{ name: "a", duration: "2m", bpm: 120, style: "styles/house.json", energy: 0.2, chords: "Am" },
		{ name: "b", duration: "2m", energy: 1, chords: "F", transition: "riser", transition_part: "sweep" },
		{ name: "c", duration: "2m", transition: "impact", transition_part: "sweep" },
		{ name: "d", duration: "2m", transition: "riser" } ],
		parts: { sweep: { instrument: { name: "NoiseSynth", envelope: { attack: 2, sustain: 1 } }, octave: 3, gain_db: -20,
			effects: [ { name: "Filter", type: "lowpass", frequency: 2000 } ], sends: { hall: -12 } } } }`, &arena2)
	sweep := part_index(s, "sweep")
	notes := 0
	for tr in s.tracks {
		if int(tr.part) != sweep {
			continue
		}
		testing.expect_value(t, tr.gain, base.db_to_gain(-20))
		testing.expect_value(t, tr.chain.count, 1)
		testing.expect_value(t, tr.sends.count, 1)
		for i in tr.notes.first ..< base.span_end(tr.notes) {
			testing.expect_value(t, s.notes.pitch[i], 53) // F3: the chord b lands on
			// the riser at v0.0.7's 0.35, the impact at 0.8
			testing.expect_value(t, s.notes.velocity[i], notes == 0 ? 0.35 : 0.8)
			notes += 1
		}
	}
	testing.expect_value(t, notes, 2) // the riser into b, the impact at c
	testing.expect(t, has(s, "transition_needs_part")) // d's
}

// A pulse with a range reads only the notes in it.
@(test)
test_pulse_range :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ sections: [
		{ name: "a", duration: "2m", bpm: 120, style: "styles/house.json", energy: 1, chords: "Am" },
		{ name: "b", duration: "2m" } ] }`, &arena)
	testing.expect_value(t, pulse_from_seconds(s, 0.5, {part = "drums", note = "kick"}, 8), 1)
	testing.expect_value(t, pulse_from_seconds(s, 0.5, {part = "drums", note = "kick", range = "b"}, 8), 0)
	testing.expect(t, math.abs(pulse_from_seconds(s, 4, {part = "drums", note = "kick", range = "b"}, 8) - 1) < 1e-9)
}

// A song brings a style of its own: its sections play the style's parts as
// they play a shipped style's, and a name it doesn't have is a finding.
@(test)
test_own_style :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ styles: { footwork: { swing: 0.1, parts: {
		drums: { instrument: "machines/808.json", play: [ { steps: { kick: "x..x..x.x..x..x.", clap: "....x.......x..." } } ] },
		bass: { instrument: { name: "Synth", oscillator: { type: "sine" } }, play: [ { degrees: "1 - - 5", subdivision: "4n" } ] } } } },
		sections: [ { name: "a", duration: "2m", bpm: 160, style: "footwork", chords: "Fm Db" } ] }`, &arena)
	testing.expect(t, !has(s, "unknown_style"))
	testing.expect(t, part_index(s, "drums") >= 0 && part_index(s, "bass") >= 0)
	kicks := 0
	for ti in s.tracks {
		for i in ti.notes.first ..< base.span_end(ti.notes) {
			if s.notes.pad[i] == base.name_id("kick") {
				kicks += 1
			}
		}
	}
	testing.expect_value(t, kicks, 12) // 6 a bar, 2 bars
	arena2: virtual.Arena
	defer virtual.arena_destroy(&arena2)
	u := compose(t, `{ sections: [ { name: "a", duration: "1m", style: "nope" } ] }`, &arena2)
	testing.expect(t, has(u, "unknown_style"))
}

// The song is its parts' regions: an entry over its ranges (one where it
// carries on), a style's entry per run of sections, a transition's sound;
// a part has none where it doesn't play.
@(test)
test_regions :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ bpm: 120, sections: [
		{ name: "a", duration: "2m", style: "styles/house.json", energy: 0.5 },
		{ name: "b", duration: "2m", style: "styles/house.json", energy: 0.5 },
		{ name: "c", duration: "2m", style: "styles/house.json", energy: 1, transition: "riser", transition_part: "fx" } ],
		parts: {
			fx: { instrument: { name: "NoiseSynth" } },
			lead: { instrument: { name: "Synth" }, play: [ { name: "a", notes: "C5 E5" }, { name: "c", notes: "G5" } ] } } }`, &arena)
	lead := part_index(s, "lead")
	drums := part_index(s, "drums")
	fx := part_index(s, "fx")
	testing.expect(t, lead >= 0 && drums >= 0 && fx >= 0)
	spans := proc(s: ^Song, part: int) -> [dynamic][2]f64 {
		out := make([dynamic][2]f64, context.temp_allocator)
		for r in s.regions {
			if int(r.part) == part {
				append(&out, [2]f64{r.start, r.stop})
			}
		}
		return out
	}
	l := spans(s, lead)
	testing.expect_value(t, len(l), 2) // a and c, nothing over b
	testing.expect(t, len(l) == 2 && l[0] == {0, 4} && l[1] == {8, 12})
	// the style's kick entry over a and b is one region (it carries on)
	d := spans(s, drums)
	found := false
	for x in d {
		found ||= x == {0, 8}
	}
	testing.expectf(t, found, "drums regions %v", d)
	testing.expect(t, len(spans(s, fx)) == 1) // the riser into c
	for i in 1 ..< len(s.regions) {
		a, b := s.regions[i - 1], s.regions[i]
		testing.expect(t, a.part < b.part || (a.part == b.part && a.start <= b.start))
	}
}

// A section's fill rolls on the part it names, not on another drum machine
// that happens to come first (a crash of its own).
@(test)
test_fill_on_drums :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ bpm: 120, sections: [ { name: "a", duration: "2m", energy: 0.6 }, { name: "b", duration: "2m", energy: 0.6, transition: "fill", transition_part: "drums/snare" } ],
		parts: {
			crash: { instrument: "machines/909.json", play: [ { name: "a..b", steps: { crash: "x..............." } } ] },
			drums: { instrument: "machines/909.json", play: [ { name: "a..b", steps: { kick: "x...x...x...x...", snare: "....x.......x..." } } ] } } }`, &arena)
	rolls := [2]int{}
	last := 8.0 - 1 // the beat before b
	for tr in s.tracks {
		for i in tr.notes.first ..< base.span_end(tr.notes) {
			if s.notes.pad[i] == base.name_id("snare") && s.notes.beat[i] >= last - 1e-9 && s.notes.beat[i] < 8 - 1e-9 {
				rolls[0 if s.parts[tr.part] == "drums" else 1] += 1
			}
		}
	}
	testing.expectf(t, rolls[0] == 4 && rolls[1] == 0, "the roll's snares: %d on drums, %d elsewhere", rolls[0], rolls[1])
}

// A part's name means nothing: two parts written the same play the same
// (one level, octave and room for what they leave out), and a part with no
// instrument doesn't play, with a finding at its path.
@(test)
test_no_meaning_in_names :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ sections: [ { name: "a", duration: "1m", bpm: 120, chords: "Am" } ],
		parts: {
			bass: { instrument: { name: "Synth" }, play: [ { name: "a", degrees: "1 . . .", subdivision: "4n" } ] },
			zz: { instrument: { name: "Synth" }, play: [ { name: "a", degrees: "1 . . .", subdivision: "4n" } ] },
			lead: { play: [ { name: "a", notes: "C5" } ] } } }`, &arena)
	bass, zz := part_index(s, "bass"), part_index(s, "zz")
	tb, tz := -1, -1
	for tr, i in s.tracks {
		if int(tr.part) == bass {
			tb = i
		}
		if int(tr.part) == zz {
			tz = i
		}
		testing.expect(t, s.parts[tr.part] != "lead")
	}
	testing.expect(t, tb >= 0 && tz >= 0)
	a, b := s.tracks[tb], s.tracks[tz]
	testing.expect(t, a.gain == b.gain && a.room == b.room && a.gain == PART_GAIN && a.room == PART_ROOM)
	testing.expect_value(t, s.placements[0].gain, s.gain) // the song's level is its placement's
	testing.expect_value(t, s.notes.pitch[a.notes.first], s.notes.pitch[b.notes.first])
	testing.expect_value(t, s.notes.pitch[a.notes.first], f32(69)) // A4: octave 4
	found := false
	for f in s.findings {
		found ||= f.code == "no_instrument" && f.path == "parts/lead" && f.severity == .Warning
	}
	testing.expect(t, found)
}

// A machine plays what its row writes: its pads by any name at their keys
// (a GM name's, else the lowest free), each a program of its own, with what
// they choke; steps naming a pad it hasn't are a finding at the entry, and
// don't play; a mix moves the programs past those already there.
@(test)
test_machine :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ sections: [ { name: "a", duration: "1m", bpm: 120 } ],
		parts: { foley: { instrument: { pads: {
			door: { nodes: { out: { class: "Noise", amp: "env" }, env: { class: "Decay", time: 0.05 } } },
			kick: { name: "MembraneSynth", envelope: { decay: 0.2 } },
			glass: { key: "C6", choke: "door", nodes: { out: { class: "Osc", wave: "sine", frequency: 2000, amp: "env" }, env: { class: "Decay", time: 0.3 } } } } },
			play: [ { name: "a", steps: { door: "x...x...x...x...", glass: "..x...x...x...x.", kick: "x.......", pot: "x" } } ] } } }`, &arena)
	testing.expect_value(t, len(s.tracks), 1)
	program := i32(s.params[s.tracks[0].instrument][.Program])
	machine := s.programs.programs[program]
	testing.expect_value(t, machine.layers.count, 3)
	keys := make(map[u32]f32, context.temp_allocator)
	for pr in s.programs.layers[machine.layers.first:base.span_end(machine.layers)] {
		pad := s.programs.pads[pr.row]
		keys[pad.pad] = pad.key
		if pad.pad == base.name_id("glass") {
			testing.expect_value(t, s.programs.chokes[pad.chokes.first], base.name_id("door"))
		}
	}
	testing.expect_value(t, keys[base.name_id("kick")], 36) // General MIDI's
	testing.expect_value(t, keys[base.name_id("glass")], 84)
	testing.expect_value(t, keys[base.name_id("door")], 0) // the lowest free
	testing.expect_value(t, len(s.notes), 4 + 4 + 1)
	found := false
	for f in s.findings {
		found ||= f.code == "unknown_pad" && f.path == "parts/foley/play/1/steps/pot"
	}
	testing.expect(t, found)

	context.allocator = virtual.arena_allocator(&arena)
	m: Song
	mix_init(&m)
	append_song(&m, s, 0, "a")
	append_song(&m, s, 2, "b")
	testing.expect_value(t, len(m.programs.programs), 2 * len(s.programs.programs))
	second := i32(m.params[m.tracks[1].instrument][.Program])
	testing.expect_value(t, second, program + i32(len(s.programs.programs)))
	for pr in m.programs.layers[m.programs.programs[second].layers.first:][:3] {
		testing.expect(t, pr.program >= i32(len(s.programs.programs)))
	}
}

// What a row gets wrong is a finding at the path where it was written: a
// node kind that isn't one, a wire to nothing, a loop, no out, a name that
// isn't an instrument here (with the ones that are).
@(test)
test_row_findings :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ sections: [ { name: "a", duration: "1m", bpm: 120 } ],
		instruments: {
			kick: { nodes: { out: { class: "Mix", inputs: ["body"] }, body: { class: "Osc", frequency: { by: "fall", octaves: 2 } } } },
			loop: { nodes: { out: { class: "Mix", inputs: ["a"] }, a: { class: "Filter", input: "b" }, b: { class: "Filter", input: "a" } } },
			odd: { nodes: { out: { class: "Wobble" } } },
			mute: { nodes: { x: { class: "Osc" } } } },
		parts: {
			a: { instrument: "kick", play: [ { name: "a", notes: "C4" } ] },
			b: { instrument: "loop", play: [ { name: "a", notes: "C4" } ] },
			c: { instrument: "odd", play: [ { name: "a", notes: "C4" } ] },
			d: { instrument: "mute", play: [ { name: "a", notes: "C4" } ] },
			e: { instrument: "nope", play: [ { name: "a", notes: "C4" } ] } } }`, &arena)
	want := [?]struct {
		code, path: string,
	} {
		{"unknown_input", "instruments/kick/nodes/body/frequency/by"},
		{"voice_cycle", "instruments/loop"},
		{"unknown_node", "instruments/odd/nodes/out"},
		{"no_out", "instruments/mute"},
		{"unknown_instrument", "parts/e/instrument"},
	}
	for w in want {
		found := false
		for f in s.findings {
			found ||= f.code == w.code && f.path == w.path
		}
		testing.expectf(t, found, "no %s at %s", w.code, w.path)
	}
}

// A song's part over a style's part of the same name is changes over it:
// what it doesn't set (its octave, instrument, level, sends) is the
// style's, its own entries included; what it sets wins.
@(test)
test_part_over_style :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ key: "A minor", sections: [ { name: "a", duration: "2m", bpm: 120, style: "styles/house.json", energy: 0.8, chords: "Am" } ],
		parts: { bass: { gain_db: 3, play: [ { name: "a", degrees: "1 . . ." } ] } } }`, &arena)
	bass := part_index(s, "bass")
	testing.expect(t, bass >= 0)
	notes := 0
	for tr in s.tracks {
		if int(tr.part) != bass {
			continue
		}
		testing.expect_value(t, tr.gain, base.db_to_gain(3)) // its own level
		testing.expect(t, tr.instrument >= 0 && s.labels[tr.instrument] == "bass") // the style's instrument
		for i in tr.notes.first ..< base.span_end(tr.notes) {
			testing.expectf(t, s.notes.pitch[i] == 45, "A in the style's octave 2 (45), not %v", s.notes.pitch[i])
			notes += 1
		}
	}
	testing.expect(t, notes > 0)
}

// An event's note that is no pitch is a pad's name: a part whose instrument
// has no such pad gives the finding, it doesn't stop composing.
@(test)
test_event_pad_unknown :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ sections: [ { name: "a", duration: "1m" } ], parts: {
		p: { instrument: "Synth", play: [ { name: "a", events: [ { time: 0, note: "D", duration: 1 } ] } ] } } }`, &arena)
	testing.expect(t, has(s, "unknown_pad"))
}

// A chord rhythm can be a list of bar strings, cycled from its range's
// start as steps' are: bar 1 "X...", bar 2 "..x.", bar 3 "X..." again. A
// single string still plays every bar.
@(test)
test_chord_rhythm_bars :: proc(t: ^testing.T) {
	Case :: struct {
		rhythm: string,
		want:   []f64, // the beats chords start on (bars of 4 beats)
	}
	cases := []Case {
		{`[ "X...", "..x." ]`, {0, 6, 8, 14}},
		{`"x.x."`, {0, 2, 4, 6, 8, 10, 12, 14}},
	}
	for c in cases {
		arena: virtual.Arena
		defer virtual.arena_destroy(&arena)
		s := compose(t, strings.concatenate({`{ bpm: 120, sections: [ { name: "a", duration: "4m", chords: "C F G C" } ],
			parts: { keys: { instrument: "Synth", play: [ { name: "a", chords: { rhythm: `, c.rhythm, ` }, octave: 4 } ] } } }`}, context.temp_allocator), &arena)
		starts := make([dynamic]f64, context.temp_allocator)
		for i in 0 ..< len(s.notes) {
			beat := math.round(s.notes.time[i] * 2 * 100) / 100 // 120 bpm: 2 beats a second
			found := false
			for x in starts {
				found ||= x == beat
			}
			if !found {
				append(&starts, beat)
			}
		}
		same := len(starts) == len(c.want)
		for b, i in c.want {
			same &&= i < len(starts) && starts[i] == b
		}
		testing.expectf(t, same, "rhythm %s: chords on beats %v, want %v", c.rhythm, starts[:], c.want)
	}
}

// A long range of voiced chords stays where it starts: 32 bars of 5-note
// chords, voice-led bar to bar, keep within an octave of the first chord
// whatever the voicing (an open voicing's raised tone once led the next
// chord up, until the notes left MIDI's range).
@(test)
test_voicing_holds_register :: proc(t: ^testing.T) {
	for voicing in ([]string{"open", "spread", "close"}) {
		arena: virtual.Arena
		defer virtual.arena_destroy(&arena)
		s := compose(t, strings.concatenate({`{ bpm: 120, key: "C major", sections: [ { name: "a", duration: "32m", chords: "Cmaj9 Fmaj9 G9 Am9 Dm9 G9 Em9 A9" } ],
			parts: { pad: { instrument: "Synth", play: [ { name: "a", chords: { voicing: "`, voicing, `", rhythm: "x..." }, octave: 3 } ] } } }`}, context.temp_allocator), &arena)
		lo0, hi0, lo, hi := f32(200), f32(-200), f32(200), f32(-200)
		first_bar := s.notes.time[0] + 1.9 // the first chord: its notes within a bar
		for i in 0 ..< len(s.notes) {
			p := s.notes.pitch[i]
			if s.notes.time[i] < first_bar {
				lo0, hi0 = min(lo0, p), max(hi0, p)
			}
			lo, hi = min(lo, p), max(hi, p)
		}
		testing.expectf(t, len(s.notes) >= 32 * 5 && hi <= hi0 + 12 && lo >= lo0 - 12, "%s: the first chord %v..%v, the range %v..%v over %d notes", voicing, lo0, hi0, lo, hi, len(s.notes))
	}
}

// A note that can't sound is a finding: a pitch outside MIDI's range
// (note_range); one no layer of a layered row or pad of a machine answers
// (no_region). A note in range on a plain instrument is neither. (Two bars:
// each pattern plays twice.)
@(test)
test_notes_reach :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	tone :: `{ nodes: { env: { class: "Env", attack: 0.001, decay: 0.01, sustain: 1, release: 0.005 }, out: { class: "Osc", wave: "sine", amp: "env" } } }`
	s := compose(t, strings.concatenate({`{ bpm: 120, sections: [ { name: "a", duration: "2m" } ], parts: {
		high: { instrument: "Synth", play: [ { name: "a", notes: "C4 C10", subdivision: "2n" } ] },
		narrow: { instrument: { layers: [ { instrument: `, tone, `, lo_key: "C4", hi_key: "C5" } ] }, play: [ { name: "a", notes: "C2 C4", subdivision: "2n" } ] },
		kit: { instrument: "machines/808.json", play: [ { name: "a", notes: "C8", subdivision: "1m" } ] },
		fine: { instrument: "Synth", play: [ { name: "a", notes: "C4 E4", subdivision: "2n" } ] } } }`}, context.temp_allocator), &arena)
	said: map[string]string
	for f in s.findings {
		if f.code == "note_range" || f.code == "no_region" {
			said[strings.concatenate({f.code, " ", f.path}, context.temp_allocator)] = f.message
		}
	}
	testing.expectf(t, strings.contains(said["note_range parts/high"], "2 notes at pitches 132..132"), "C10 is outside MIDI: %v", said)
	testing.expectf(t, strings.contains(said["no_region parts/narrow"], "2 notes (pitches 36..36)"), "C2 below the layer's C4..C5: %v", said)
	testing.expectf(t, "no_region parts/kit" in said, "C8 on no pad of the 808: %v", said)
	testing.expectf(t, "note_range parts/fine" not_in said && "no_region parts/fine" not_in said && "no_region parts/high" not_in said, "a note that sounds is told: %v", said)
}

// A song on most of the defaults at once is a finding (default_song, at 4
// signs), one on a few isn't. Each case moves a song across the line by one
// sign: swing off makes "no feel" hold, an accent takes it back; one
// section counts neither the same parts nor one progression; C G Am F is
// i-VI-III-VII turned; a drums part's lowest pitch on every beat is a kick.
// A one-shot isn't music, and isn't read.
@(test)
test_default_song :: proc(t: ^testing.T) {
	Case :: struct {
		name:     string,
		bpm:      string,
		key:      string,
		chords:   string,
		swing:    string,
		sections: string,
		kick:     string,
		drums:    string, // "machine" or "role"
		fires:    bool,
	}
	cases := []Case {
		// a kick on every beat, the same parts, one progression: 3
		{"three signs", "140", "E minor", "Em9 A9 Bm7 Em9", "0.3", `[ { name: "a", duration: "4m" }, { name: "b", duration: "4m" } ]`, "x...x...x...x...", "machine", false},
		{"no swing: no feel holds", "140", "E minor", "Em9 A9 Bm7 Em9", "0", `[ { name: "a", duration: "4m" }, { name: "b", duration: "4m" } ]`, "x...x...x...x...", "machine", true},
		{"an accent is feel", "140", "E minor", "Em9 A9 Bm7 Em9", "0", `[ { name: "a", duration: "4m" }, { name: "b", duration: "4m" } ]`, "X...x...x...x...", "machine", false},
		{"one section", "140", "E minor", "Em9 A9 Bm7 Em9", "0", `[ { name: "a", duration: "8m" } ]`, "x...x...x...x...", "machine", false},
		{"I-V-vi-IV turned", "140", "E minor", "C G Am F", "0.3", `[ { name: "a", duration: "4m" }, { name: "b", duration: "4m" } ]`, "x...x...x...x...", "machine", true},
		{"a drums part's lowest pitch", "140", "E minor", "Em9 A9 Bm7 Em9", "0", `[ { name: "a", duration: "4m" }, { name: "b", duration: "4m" } ]`, "", "role", true},
	}
	for c in cases {
		arena: virtual.Arena
		defer virtual.arena_destroy(&arena)
		drums := strings.concatenate({`drums: { instrument: "machines/909.json", play: [ { name: ["a", "b"], steps: { kick: "`, c.kick, `", hat: "..x...x...x...x." } } ] }`}, context.temp_allocator)
		if c.drums == "role" {
			drums = `drums: { instrument: "Synth", role: "drums", play: [ { name: ["a", "b"], notes: "C2 E3 C2 E3 C2 E3 C2 E3", subdivision: "8n" } ] }`
		}
		sections := c.sections
		if strings.contains(c.sections, `"8m"`) {
			drums, _ = strings.replace_all(drums, `["a", "b"]`, `"a"`, context.temp_allocator)
		}
		pad := `pad: { instrument: "Synth", play: [ { name: ["a", "b"], chords: { voicing: "close" }, octave: 4 } ] }`
		if strings.contains(c.sections, `"8m"`) {
			pad, _ = strings.replace_all(pad, `["a", "b"]`, `"a"`, context.temp_allocator)
		}
		text := strings.concatenate({`{ bpm: `, c.bpm, `, key: "`, c.key, `", swing: `, c.swing, `, chords: "`, c.chords, `", sections: `, sections, `, parts: { `, drums, `, `, pad, ` } }`}, context.temp_allocator)
		s := compose(t, text, &arena)
		said := ""
		for f in s.findings {
			if f.code == "default_song" {
				said = f.message
			}
		}
		testing.expectf(t, (said != "") == c.fires, "%s: default_song %v, want %v (%q)", c.name, said != "", c.fires, said)
	}
	// a one-shot (a host's sound: one part, one note, no tempo or key) isn't
	// music: no findings at all, though it shows the defaults
	{
		arena: virtual.Arena
		defer virtual.arena_destroy(&arena)
		s := compose(t, `{ sections: [ { name: "a", duration: "1m" } ], parts: { thump: { instrument: "MembraneSynth", play: [ { name: "a", notes: "C2", subdivision: "1m" } ] } } }`, &arena)
		testing.expectf(t, len(s.findings) == 0, "a one-shot is told: %v", s.findings[:])
	}
}

// A Tone length read once at one tempo is a finding where its part or
// chain plays at another (tempo_fixed), naming it and the sections: a
// FeedbackDelay's "8n." and an envelope's "16n" on a part playing into a
// ramp; not an Lfo's rate in beats (it follows the tempo), not a part that
// plays only where the tempo is the one it read, not a song at one tempo.
@(test)
test_tempo_fixed :: proc(t: ^testing.T) {
	text :: proc(second: string) -> string {
		return strings.concatenate({`{ key: "C major", sections: [ { name: "a", duration: "2m", bpm: 100 }, { name: "b", duration: "2m", bpm: `, second, ` } ],
			parts: {
				both: { instrument: { nodes: { env: { class: "Env", attack: "16n" }, lfo: { class: "Lfo", rate: "8n" }, out: { class: "Osc", amp: "env", pan: { by: "lfo", amount: 0.3 } } } },
				        effects: [ { name: "FeedbackDelay", delay_time: "8n.", feedback: 0.3 } ], play: [ { name: ["a", "b"], notes: "C4" } ] },
				first: { instrument: { nodes: { env: { class: "Env", attack: "16n" }, out: { class: "Osc", amp: "env" } } }, play: [ { name: "a", notes: "C4" } ] },
				synced: { instrument: { nodes: { lfo: { class: "Lfo", rate: "8n" }, out: { class: "Osc", pan: { by: "lfo", amount: 0.3 } } } }, play: [ { name: ["a", "b"], notes: "C4" } ] } } }`}, context.temp_allocator)
	}
	arena, arena2: virtual.Arena
	defer virtual.arena_destroy(&arena)
	defer virtual.arena_destroy(&arena2)
	s := compose(t, text("[ 100, 140 ]"), &arena)
	said := make([dynamic]string, context.temp_allocator)
	for f in s.findings {
		if f.code == "tempo_fixed" {
			append(&said, f.message)
		}
	}
	joined := strings.join(said[:], "\n", context.temp_allocator)
	testing.expectf(t, len(said) == 2, "two devices off the beat (both's instrument and its delay): %s", joined)
	testing.expectf(t, strings.contains(joined, "parts/both/instrument/nodes/env/attack: a Tone length read once at 100 bpm, where it plays at another tempo: b (100-140 bpm)"), "the envelope's 16n: %s", joined)
	testing.expectf(t, strings.contains(joined, "parts/both/effects/1/delay_time: a Tone length read once at 100 bpm"), "the delay's 8n.: %s", joined)
	testing.expectf(t, !strings.contains(joined, "lfo/rate") && !strings.contains(joined, "parts/first") && !strings.contains(joined, "parts/synced"), "a rate in beats, or a part only at its tempo: %s", joined)
	steady := compose(t, text("100"), &arena2)
	for f in steady.findings {
		testing.expectf(t, f.code != "tempo_fixed", "at one tempo: %s", f.message)
	}
}

// A part's Tone lengths are read at the tempo of the section it first
// plays in: a lead entering at 128 after a 60 bpm intro has its "8n."
// delay at 128 (0.3515625 s) and isn't told; a part playing from the intro
// on reads at 60 and is told where it plays at 128.
@(test)
test_first_section_tempo :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ key: "C major", sections: [ { name: "intro", duration: "1m", bpm: 60 }, { name: "race", duration: "2m", bpm: 128 } ],
		parts: {
			lead: { instrument: "Synth", effects: [ { name: "FeedbackDelay", delay_time: "8n." } ], play: [ { name: "race", notes: "C5" } ] },
			bed: { instrument: "Synth", effects: [ { name: "FeedbackDelay", delay_time: "8n." } ], play: [ { name: ["intro", "race"], notes: "C4" } ] } } }`, &arena)
	delay :: proc(s: ^Song, part: string) -> f32 {
		for tr in s.tracks {
			if s.parts[tr.part] == part {
				return s.params[s.chain[tr.chain.first]][.Delay_Time]
			}
		}
		return -1
	}
	testing.expect_value(t, delay(s, "lead"), f32(0.75 * 60.0 / 128))
	testing.expect_value(t, delay(s, "bed"), f32(0.75))
	told := make([dynamic]string, context.temp_allocator)
	for f in s.findings {
		if f.code == "tempo_fixed" {
			append(&told, f.path)
		}
	}
	testing.expectf(t, len(told) == 1 && strings.has_prefix(told[0], "parts/bed"), "only the bed is off the beat: %v", told)
}
