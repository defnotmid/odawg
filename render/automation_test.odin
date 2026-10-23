package odawg_render

import "core:math"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:testing"
import base "../base"
import spec "../spec"
import song "../song"

// A song whose lanes move each kind of value: an instrument's control, an
// effect's param on a part and on a return, a send, a fader, a pan and the
// song's level.
@(private = "file")
AUTOMATED :: `{ bpm: 120, seed: 4, key: "C major",
	sections: [ { name: "a", duration: "4m", chords: "C F" }, { name: "b", duration: "4m", chords: "G C" } ],
	returns: { hall: [ { name: "Reverb", decay: 1.5 } ] },
	parts: {
		lead: { instrument: "MonoSynth", effects: [ { name: "Filter", type: "lowpass", frequency: 2000 } ], sends: { hall: -12 },
		        play: [ { name: "a..b", notes: "C5 E5 G5 C6 . G5 E5 .", subdivision: "8n" } ] },
		pad: { instrument: "Synth", play: [ { name: "a..b", chords: { voicing: "open" }, octave: 4 } ] } },
	automation: {
		"parts/lead/filter/frequency": [ [ "a", 300 ], [ "b", 4000 ], [ "b@2m", 800, "step" ] ],
		"parts/lead/effects/Filter/frequency": [ [ "a", 500 ], [ "end", 6000 ] ],
		"parts/lead/sends/hall": [ [ "a", -40 ], [ "b", -6 ] ],
		"parts/pad/gain_db": [ [ "a", -24 ], [ "b", 0, "step" ] ],
		"parts/pad/pan": [ [ "a", -1 ], [ "end", 1 ] ],
		"returns/hall/Reverb/wet": [ [ "a", 0.2 ], [ "b", 0.9 ] ],
		"master/gain_db": [ [ "b@3m", 0 ], [ "end", -30 ] ] } }`

@(private = "file")
compose_text :: proc(t: ^testing.T, text: string, arena: ^virtual.Arena) -> ^song.Song {
	_ = virtual.arena_init_growing(arena)
	context.allocator = virtual.arena_allocator(arena)
	s := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(text, s, &findings))
	add_examples(s, &findings)
	out := new(song.Song)
	testing.expect(t, song.song_from_spec(s, out))
	for f in out.findings {
		testing.expectf(t, f.severity != .Error, "%s: %s", f.path, f.message)
	}
	return out
}

// Each lane moves what it names: the pad's fader steps from -24 dB to 0
// (its stem quiet in a, loud in b), its pan sweeps from left to right, and
// without the lanes the song is other samples.
@(test)
test_automation_moves :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose_text(t, AUTOMATED, &arena)
	testing.expectf(t, len(s.automation) >= 7, "%d rows", len(s.automation))
	out := output_from_song(s, {stems = true})
	defer output_destroy(&out)
	pad := song.part_index(s, "pad")
	b := int(math.round(s.sections[1].start * RATE))
	rms :: proc(x: []f32) -> f64 {
		sum: f64
		for v in x {
			sum += f64(v) * f64(v)
		}
		return math.sqrt(sum / f64(max(len(x), 1)))
	}
	st := out.stems[pad]
	a_level := rms(st[0][RATE:b]) + rms(st[1][RATE:b])
	b_level := rms(st[0][b + RATE:2 * b]) + rms(st[1][b + RATE:2 * b])
	testing.expectf(t, b_level > 6 * a_level, "the pad's fader: %f in a, %f in b", a_level, b_level)
	// panned left at the start, right at the end
	testing.expect(t, rms(st[0][:RATE]) > 4 * rms(st[1][:RATE]))
	testing.expect(t, rms(st[1][out.frames - 2 * RATE:out.frames - RATE]) > 4 * rms(st[0][out.frames - 2 * RATE:out.frames - RATE]))
	// the lanes are what makes it so
	arena2: virtual.Arena
	defer virtual.arena_destroy(&arena2)
	text := AUTOMATED
	i := strings.index(text, "automation:")
	s2 := compose_text(t, strings.concatenate({text[:i], "}"}, context.temp_allocator), &arena2)
	still := output_from_song(s2, {})
	defer output_destroy(&still)
	n := min(out.frames, still.frames)
	testing.expect(t, !slice.equal(out.left[:n], still.left[:n]))
}

// What a lane moves is a function of song time alone: streamed in 800-sample
// blocks, on a pool of any size, or from an exact seek between two cells,
// the song is the same samples.
@(test)
test_automation_exact :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose_text(t, AUTOMATED, &arena)
	whole := output_from_song(s, {stems = true})
	defer output_destroy(&whole)
	for threads in ([]int{1, 3, 8}) {
		tp := test_pool(threads)
		defer test_pool_free(tp)
		many := output_from_song(s, {pool = &tp.work_pool, stems = true})
		defer output_destroy(&many)
		testing.expectf(t, slice.equal(whole.slab, many.slab), "on %d threads the song differs", threads)
	}
	e: Engine
	testing.expect(t, engine_init(&e, s))
	defer engine_destroy(&e)
	l := make([]f32, 800)
	r := make([]f32, 800)
	defer delete(l)
	defer delete(r)
	worst: f32
	for at := 0; at + 800 <= whole.frames; at += 800 {
		engine_process(&e, l, r)
		for i in 0 ..< 800 {
			worst = max(worst, abs(l[i] - whole.left[at + i]), abs(r[i] - whole.right[at + i]))
		}
	}
	testing.expectf(t, worst == 0, "800-sample blocks differ by %e", worst)
	FROM :: 5.3701 // inside a cell, past where every lane moves
	cut := output_from_song(s, {from = FROM, to = f64(whole.frames) / RATE})
	defer output_destroy(&cut)
	offset := int(math.round(FROM * RATE))
	diff, peak: f32
	for v, i in cut.left {
		diff = max(diff, abs(v - whole.left[offset + i]), abs(cut.right[i] - whole.right[offset + i]))
		peak = max(peak, abs(v))
	}
	testing.expectf(t, peak > 0.01 && diff <= peak * 1e-4, "from a seek it differs by %g (peak %g)", diff, peak)
}

// A lane's curves: held before its first point and after its last, linear,
// geometric, a step jumping at its point; the cell's value its start's.
@(test)
test_automation_value :: proc(t: ^testing.T) {
	s: song.Song
	defer delete(s.automation_points)
	append(&s.automation_points, song.Automation_Point{1000, 100, .Linear}, song.Automation_Point{2000, 200, .Linear}, song.Automation_Point{3000, 800, .Exp}, song.Automation_Point{4000, 0, .Step})
	a := song.Automation{points = {0, 4}}
	testing.expect_value(t, song.automation_value(&s, a, 0), 100)
	testing.expect_value(t, song.automation_value(&s, a, 1500), 150)
	testing.expect(t, abs(song.automation_value(&s, a, 2500) - 400) < 1e-3) // 200 * 4^0.5
	testing.expect_value(t, song.automation_value(&s, a, 3999), 800)
	testing.expect_value(t, song.automation_value(&s, a, 4000), 0)
	testing.expect_value(t, song.automation_value(&s, a, 99999), 0)
	testing.expect_value(t, song.automation_cell_value(&s, a, 1063), song.automation_value(&s, a, 1024))
}

// What a lane can't move is a finding where it is written: a part, an
// effect or a param that isn't there, an exp curve through 0, a param that
// shapes its effect, points out of order.
@(test)
test_automation_findings :: proc(t: ^testing.T) {
	cases := [][2]string {
		{`"parts/nobody/gain_db": [ [ "a", 0 ] ]`, "automation/parts/nobody/gain_db"},
		{`"parts/lead/effects/Chorus/wet": [ [ "a", 0 ] ]`, "automation/parts/lead/effects/Chorus/wet"},
		{`"parts/lead/effects/Filter/nothing": [ [ "a", 0 ] ]`, "automation/parts/lead/effects/Filter/nothing"},
		{`"parts/lead/effects/Filter/rolloff": [ [ "a", -24 ] ]`, "automation/parts/lead/effects/Filter/rolloff"},
		{`"parts/lead/effects/Filter/frequency": [ [ "a", 0 ], [ "b", 800 ] ]`, "automation/parts/lead/effects/Filter/frequency/2"},
		{`"parts/lead/gain_db": [ [ "b", 0 ], [ "a", -6 ] ]`, "automation/parts/lead/gain_db/2"},
		{`"parts/lead/nowhere/frequency": [ [ "a", 0 ] ]`, "automation/parts/lead/nowhere/frequency"},
	}
	for c in cases {
		arena: virtual.Arena
		_ = virtual.arena_init_growing(&arena)
		context.allocator = virtual.arena_allocator(&arena)
		text := strings.concatenate({`{ bpm: 120, sections: [ { name: "a", duration: "1m" }, { name: "b", duration: "1m" } ],
			parts: { lead: { instrument: "MonoSynth", effects: [ { name: "Filter", frequency: 900 } ], play: [ { name: "a", notes: "C4" } ] } },
			automation: { `, c[0], ` } }`})
		sp := new(spec.Spec)
		findings := make(base.Findings)
		testing.expect(t, spec.spec_from_json(text, sp, &findings))
		s := new(song.Song)
		song.song_from_spec(sp, s)
		found := false
		for f in s.findings {
			found ||= f.severity == .Error && f.path == c[1]
		}
		testing.expectf(t, found, "no error at %s: %v", c[1], s.findings[:])
		virtual.arena_destroy(&arena)
	}
}
