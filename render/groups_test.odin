package odawg_render

import "core:math"
import "core:mem/virtual"
import "core:slice"
import "core:testing"
import base "../base"
import spec "../spec"
import song "../song"

// A machine whose `long` pad rings 2.5 s and whose `stop` pad chokes it:
// twelve long notes a sixteenth apart (with the next bar's, more voices at
// once than a group holds: groups, the notes taking turns), then a stop.
@(private = "file")
CHOKED :: `{ bpm: 120, key: "C major", gain_db: 0, sections: [ { name: "a", duration: "2m" } ],
	parts: { kit: { instrument: { pads: {
		long: { key: 60, instrument: { nodes: { env: { class: "Decay", time: 2.5 }, out: { class: "Osc", wave: "sine", amp: "env", gain_db: -18 } } } },
		stop: { key: 61, choke: [ "long" ], instrument: { nodes: { env: { class: "Decay", time: 0.01 }, out: { class: "Osc", wave: "sine", amp: "env", gain_db: -120 } } } } } },
		play: [ { name: "a", steps: { long: "xxxxxxxxxxxx....", stop: "..............x." } } ] } } }`

// A track sounding more voices than a group holds splits into groups that
// render side by side, and a pad's choke still cuts every voice it chokes,
// whichever group plays it (each voice knows from the note table where it
// is cut): after the stop the kit is silent within the choke's 5 ms. The
// same samples on any pool, in 800-sample blocks, and from an exact seek
// between the long notes and the stop.
@(test)
test_groups_choke :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(CHOKED, sp, &findings))
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s))
	for f in s.findings {
		testing.expectf(t, f.severity != .Error, "%s: %s", f.path, f.message)
	}
	groups := 0
	for g in s.groups {
		groups += int(g.track) == 0 ? 1 : 0
	}
	testing.expectf(t, groups >= 2, "voices overlapping by the dozen: groups, not %d", groups)
	whole := output_from_song(s, {})
	STOP :: 14 * 0.125 // the stop's sixteenth
	level :: proc(o: Output, a, b: f64) -> (peak: f32) {
		for i in int(a * RATE) ..< int(b * RATE) {
			peak = max(peak, abs(o.left[i]), abs(o.right[i]))
		}
		return
	}
	before, after := level(whole, STOP - 0.05, STOP - 0.001), level(whole, STOP + 0.006, 1.99) // bar 2 starts at 2 s
	testing.expectf(t, before > 0.05 && after < 1e-4, "the long voices before the stop %f, after it %f (every group's cut)", before, after)
	for threads in ([]int{1, 3, 8}) {
		tp := test_pool(threads)
		defer test_pool_free(tp)
		many := output_from_song(s, {pool = &tp.work_pool})
		testing.expectf(t, slice.equal(whole.slab, many.slab), "on %d threads the song differs", threads)
	}
	e: Engine
	testing.expect(t, engine_init(&e, s))
	defer engine_destroy(&e)
	l, r := make([]f32, 800), make([]f32, 800)
	worst: f32
	for at := 0; at + 800 <= whole.frames; at += 800 {
		engine_process(&e, l, r)
		for i in 0 ..< 800 {
			worst = max(worst, abs(l[i] - whole.left[at + i]), abs(r[i] - whole.right[at + i]))
		}
	}
	testing.expectf(t, worst == 0, "800-sample blocks differ by %e", worst)
	FROM :: 1.3
	cut := output_from_song(s, {from = FROM, to = f64(whole.frames) / RATE})
	offset := int(math.round(FROM * RATE))
	diff: f32
	for v, i in cut.left {
		diff = max(diff, abs(v - whole.left[offset + i]), abs(cut.right[i] - whole.right[offset + i]))
	}
	testing.expectf(t, diff == 0, "from a seek it differs by %g", diff)
}
