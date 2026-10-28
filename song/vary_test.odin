package odawg_song

import "core:mem/virtual"
import "core:slice"
import "core:testing"
import base "../base"
import spec "../spec"

@(private = "file")
compose :: proc(t: ^testing.T, text: string, arena: ^virtual.Arena) -> ^Song {
	_ = virtual.arena_init_growing(arena)
	context.allocator = virtual.arena_allocator(arena)
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(text, sp, &findings))
	s := new(Song)
	song_from_spec(sp, s)
	return s
}

// A part's notes' pitches, in time order (its first track's).
@(private = "file")
pitches_of :: proc(s: ^Song, part: string) -> []f32 {
	out := make([dynamic]f32)
	p := part_index(s, part)
	for t in s.tracks {
		if int(t.part) != p {
			continue
		}
		for i in t.notes.first ..< t.notes.first + t.notes.count {
			append(&out, f32(s.notes.pitch[i]))
		}
	}
	return out[:]
}

// Each repeat of a sequence takes its variation in turn: as written, a
// step up the key, mirrored around its first note, reversed and an octave
// up; then round again.
@(test)
test_vary_repeats :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, `{ key: "C major", bpm: 120, sections: [ { name: "a", duration: "5m" } ],
		parts: { lead: { instrument: "Synth", play: [ { name: "a", notes: "C4 E4 G4 .", subdivision: "4n",
			vary: [ {}, { transpose: 1 }, { invert: true }, { reverse: true, octave: 1 } ] } ] } } }`, &arena)
	got := pitches_of(s, "lead")
	want := []f32{
		60, 64, 67, // as written
		62, 65, 69, // D F A
		60, 57, 53, // C, then E and G mirrored: A3 F3
		79, 76, 72, // G E C an octave up
		60, 64, 67, // round again
	}
	testing.expectf(t, slice.equal(got, want), "%v", got)
}

// A thinned repeat's rests are the same however the song around it
// changes (seeded by the play and the repeat), and never its first note; a
// filled rest steps from the note before toward the next.
@(test)
test_vary_thin_fill :: proc(t: ^testing.T) {
	arena, arena2, arena3: virtual.Arena
	defer virtual.arena_destroy(&arena)
	defer virtual.arena_destroy(&arena2)
	defer virtual.arena_destroy(&arena3)
	a := pitches_of(compose(t, `{ key: "C major", bpm: 120, seed: 3, sections: [ { name: "a", duration: "4m" } ],
		parts: { lead: { instrument: "Synth", play: [ { name: "a", notes: "C4 D4 E4 F4 G4 A4 B4 C5", subdivision: "8n", vary: [ { thin: 0.5 } ] } ] } } }`, &arena), "lead")
	b := pitches_of(compose(t, `{ key: "C major", bpm: 120, seed: 3, sections: [ { name: "a", duration: "4m" } ],
		parts: { lead: { instrument: "Synth", play: [ { name: "a", notes: "C4 D4 E4 F4 G4 A4 B4 C5", subdivision: "8n", vary: [ { thin: 0.5 } ] } ] },
		         bass: { instrument: "Synth", play: [ { name: "a", notes: "C2 . G2 .", subdivision: "4n" } ] } } }`, &arena2), "lead")
	testing.expectf(t, slice.equal(a, b), "another part reshuffled the rests: %v vs %v", a, b)
	testing.expectf(t, len(a) < 32 && len(a) > 4, "thinned to %d of 32", len(a))
	// each bar keeps its first note
	count := 0
	for p in a {
		count += p == 60 ? 1 : 0
	}
	testing.expect_value(t, count, 4)
	f := pitches_of(compose(t, `{ key: "C major", bpm: 120, sections: [ { name: "a", duration: "1m" } ],
		parts: { lead: { instrument: "Synth", play: [ { name: "a", notes: "C4 . . G4", subdivision: "4n", vary: [ { fill: true } ] } ] } } }`, &arena3), "lead")
	testing.expectf(t, slice.equal(f, []f32{60, 62, 64, 67}), "filled: %v", f)
}

// A pickup's notes end where its range starts; one that would start before
// the song is a finding.
@(test)
test_pickup :: proc(t: ^testing.T) {
	arena, arena2: virtual.Arena
	defer virtual.arena_destroy(&arena)
	defer virtual.arena_destroy(&arena2)
	s := compose(t, `{ key: "C major", bpm: 120, sections: [ { name: "a", duration: "1m" }, { name: "b", duration: "1m" } ],
		parts: { lead: { instrument: "Synth", play: [ { name: "b", notes: "C5 - - -", subdivision: "4n", pickup: "A4 B4" } ] } } }`, &arena)
	p := part_index(s, "lead")
	times := make([dynamic]f64)
	for tr in s.tracks {
		if int(tr.part) == p {
			for i in tr.notes.first ..< tr.notes.first + tr.notes.count {
				append(&times, f64(s.notes.time[i]))
			}
		}
	}
	testing.expectf(t, slice.equal(times[:], []f64{1, 1.5, 2}), "at %v s", times[:]) // beats 2, 3 and 4 at 120 bpm
	testing.expect(t, slice.equal(pitches_of(s, "lead"), []f32{69, 71, 72}))
	early := compose(t, `{ key: "C major", bpm: 120, sections: [ { name: "a", duration: "1m" } ],
		parts: { lead: { instrument: "Synth", play: [ { name: "a", notes: "C5", subdivision: "4n", pickup: "A4 B4" } ] } } }`, &arena2)
	found := false
	for f in early.findings {
		found ||= f.code == "bad_value" && f.severity == .Error
	}
	testing.expect(t, found)
}
