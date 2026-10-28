package odawg_render

import "core:math"
import "core:mem/virtual"
import "core:testing"
import base "../base"
import spec "../spec"
import song "../song"

// A Segments envelope as an instrument's sound: points 0, 1, 0.5, 0 reached
// at 0, 0.1, 0.2 and 0.4 s, held at the third while the note is held. A
// long note reaches the sustain and holds it; a short one is released on
// the way down (from where it was at its gate, straight to 0 over the last
// segment's 0.2 s). The level is the shape's at every sample, in 800-sample
// blocks too, and from a seek in a release.
@(test)
test_segments_shape :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(`{ bpm: 120, key: "C major", gain_db: 0, sections: [ { name: "a", duration: "4m" } ],
		parts: { p: { instrument: { velocity: "none", nodes: { out: { class: "Segments", times: [0, 0.1, 0.1, 0.2], levels: [0, 1, 0.5, 0], sustain: 2, points: 4 } } },
			play: [ { name: "a", events: [ { time: 0, note: "C4", duration: 1.3 }, { time: 3, note: "C4", duration: 0.15 } ] } ] } } }`, sp, &findings))
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s))
	for f in s.findings {
		testing.expectf(t, f.severity != .Error, "%s: %s", f.path, f.message)
	}
	shape :: proc(t: f64) -> f64 {
		switch {
		case t < 0.1:
			return t / 0.1
		case t < 0.2:
			return 1 - 0.5 * (t - 0.1) / 0.1
		case t < 0.4:
			return 0.5 - 0.5 * (t - 0.2) / 0.2
		}
		return 0
	}
	want :: proc(t, gate: f64) -> f64 {
		if t < gate {
			return shape(min(t, 0.2))
		}
		from := shape(min(gate, 0.2))
		r := t - gate
		return r < 0.2 ? from * (1 - r / 0.2) : 0
	}
	whole := output_from_song(s, {})
	g := base.db_to_gain(s.tracks[0].gain_db)
	worst: f64
	for k in 0 ..< len(s.notes) {
		start, gate := s.notes.time[k], s.notes.duration[k]
		for i in 0 ..< int((gate + 0.5) * RATE) {
			at := int(math.round(start * RATE)) + i
			worst = max(worst, abs(f64(whole.left[at]) / g - want(f64(i) / RATE, gate)))
		}
	}
	testing.expectf(t, worst < 1e-5, "the level strays %g from the envelope's shape", worst)
	e: Engine
	testing.expect(t, engine_init(&e, s))
	defer engine_destroy(&e)
	l, r := make([]f32, 800), make([]f32, 800)
	blocks: f32
	for at := 0; at + 800 <= whole.frames; at += 800 {
		engine_process(&e, l, r)
		for i in 0 ..< 800 {
			blocks = max(blocks, abs(l[i] - whole.left[at + i]), abs(r[i] - whole.right[at + i]))
		}
	}
	testing.expectf(t, blocks == 0, "800-sample blocks differ by %e", blocks)
	from := s.notes.time[1] + s.notes.duration[1] + 0.07 // in the short note's release
	cut := output_from_song(s, {from = from, to = f64(whole.frames) / RATE})
	offset := int(math.round(from * RATE))
	diff: f32
	for v, i in cut.left {
		diff = max(diff, abs(v - whole.left[offset + i]), abs(cut.right[i] - whole.right[offset + i]))
	}
	testing.expectf(t, diff == 0, "from a seek it differs by %g", diff)
}
