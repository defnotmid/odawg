package odawg_song

import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:testing"
import base "../base"
import device "../device"
import spec "../spec"

@(private = "file")
compose :: proc(t: ^testing.T, text: string, arena: ^virtual.Arena) -> ^Song {
	_ = virtual.arena_init_growing(arena)
	context.allocator = virtual.arena_allocator(arena)
	s := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(text, s, &findings))
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
		{ name: "drop", duration: "2m", bpm: 120, style: "house", energy: 1, chords: "Am F" } ],
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
	text := `{ seed: 3, sections: [ { name: "a", duration: "4m", style: "lofi", energy: 0.6, chords: "Am7 Fmaj7" } ] }`
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
	s := compose(t, `{ sections: [ { name: "a", duration: "2m", bpm: 120, style: "house", energy: 0.7, chords: "Am F" } ] }`, &arena)
	kicks := make([dynamic]i32, context.temp_allocator)
	notes_from_filter(s, {part = "drums", note = "kick"}, &kicks)
	testing.expect_value(t, len(kicks), 8) // one a beat, not the two bands' both

	styles: virtual.Arena
	_ = virtual.arena_init_growing(&styles)
	defer virtual.arena_destroy(&styles)
	for style in STYLE_TABLE {
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
			x := compose(t, fmt.tprint(`{ sections: [ { name: "a", duration: "4m", bpm: 120, style: "`, style.name, `", energy: `, e, `, chords: "Am F C G" } ] }`, sep = ""), &a)
			seen := make(map[[4]f64]bool, context.temp_allocator)
			for i in 0 ..< len(x.notes) {
				n := x.notes[i]
				key := [4]f64{f64(n.track), n.beat, f64(n.pad), f64(n.pitch)}
				if !testing.expectf(t, !seen[key], "%s at %v: %s plays twice at beat %v", style.name, e, x.parts[x.tracks[n.track].part], n.beat) {
					break
				}
				seen[key] = true
			}
			virtual.arena_destroy(&a)
		}
	}
}

// A fill rolls the snare on a drum machine as on a kit.
@(test)
test_fill_drum_machine :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ sections: [
		{ name: "a", duration: "2m", bpm: 120, style: "house", energy: 0.8, chords: "Am" },
		{ name: "b", duration: "2m" } ],
		parts: { drums: { instrument: { name: "DrumMachine", machine: "909" } } } }`, &arena)
	roll := 0
	for i in 0 ..< len(s.notes) {
		n := s.notes[i]
		tr := s.tracks[n.track]
		if s.parts[tr.part] == "drums" && n.pad == .Snare && n.beat >= 7 - 1e-9 && n.beat < 8 {
			testing.expect_value(t, s.devices[tr.instrument], device.Device_Kind.Drum_Machine)
			roll += 1
		}
	}
	testing.expect_value(t, roll, 4)
}

// The transitions play on the song's own fx part, at its level, through its
// effects and sends, rather than on a second "fx".
@(test)
test_fx_part :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ sections: [
		{ name: "a", duration: "2m", bpm: 120, style: "house", energy: 0.2, chords: "Am" },
		{ name: "b", duration: "2m", energy: 1 } ],
		parts: { fx: { gain_db: -20, effects: [ { name: "Filter", type: "lowpass", frequency: 2000 } ], sends: { hall: -12 } } } }`, &arena)
	fx := 0
	for n in s.parts {
		fx += n == "fx" ? 1 : 0
	}
	testing.expect_value(t, fx, 1)
	sounds := 0
	for tr in s.tracks {
		if s.parts[tr.part] != "fx" || tr.notes.count == 0 {
			continue
		}
		sounds += 1 // the riser, the impact and the crash
		testing.expect_value(t, tr.gain_db, -20 + s.gain_db)
		testing.expect_value(t, tr.chain.count, 1)
		testing.expect_value(t, tr.sends.count, 1)
	}
	testing.expect_value(t, sounds, 3)
}

// A pulse with a range reads only the notes in it.
@(test)
test_pulse_range :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ sections: [
		{ name: "a", duration: "2m", bpm: 120, style: "house", energy: 1, chords: "Am" },
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
		drums: { instrument: { name: "DrumMachine", machine: "808" }, play: [ { steps: { kick: "x..x..x.x..x..x.", clap: "....x.......x..." } } ] },
		bass: { instrument: "sub", play: [ { degrees: "1 - - 5", subdivision: "4n" } ] } } } },
		sections: [ { name: "a", duration: "2m", bpm: 160, style: "footwork", chords: "Fm Db" } ] }`, &arena)
	testing.expect(t, !has(s, "unknown_style"))
	testing.expect(t, part_index(s, "drums") >= 0 && part_index(s, "bass") >= 0)
	kicks := 0
	for ti in s.tracks {
		for i in ti.notes.first ..< base.span_end(ti.notes) {
			if s.notes.pad[i] == .Kick {
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
		{ name: "a", duration: "2m", style: "house", energy: 0.5 },
		{ name: "b", duration: "2m", style: "house", energy: 0.5 },
		{ name: "c", duration: "2m", style: "house", energy: 1, transition: "impact" } ],
		parts: { lead: { instrument: "pluck", play: [ { name: "a", notes: "C5 E5" }, { name: "c", notes: "G5" } ] } } }`, &arena)
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
	testing.expect(t, len(spans(s, fx)) == 2) // the riser into c, the impact at it
	for i in 1 ..< len(s.regions) {
		a, b := s.regions[i - 1], s.regions[i]
		testing.expect(t, a.part < b.part || (a.part == b.part && a.start <= b.start))
	}
}
