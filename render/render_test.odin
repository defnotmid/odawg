package odawg_render

import "core:math"
import "core:mem/virtual"
import "core:slice"
import "core:testing"
import base "../base"
import spec "../spec"
import song "../song"

@(private = "file")
SPEC :: `{ key: "A minor", seed: 5, sections: [
	{ name: "a", duration: "2m", bpm: 100, style: "styles/lofi.json", energy: 0.6, chords: "Am7 Fmaj7" },
	{ name: "b", duration: "2m", bpm: 124, style: "styles/house.json", energy: 1, chords: "Am F" } ] }`

@(private = "file")
compose :: proc(t: ^testing.T, arena: ^virtual.Arena) -> ^song.Song {
	_ = virtual.arena_init_growing(arena)
	context.allocator = virtual.arena_allocator(arena)
	s := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(SPEC, s, &findings))
	add_examples(s, &findings)
	out := new(song.Song)
	testing.expect(t, song.song_from_spec(s, out))
	return out
}

// The samples don't depend on how many workers rendered them, the stems sum
// to the mix, and the mix sounds (finite, not silent).
@(test)
test_render :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, &arena)
	one := output_from_song(s, {threads = 1, stems = true})
	defer output_destroy(&one)
	many := output_from_song(s, {threads = 8})
	defer output_destroy(&many)
	testing.expect_value(t, one.frames, many.frames)
	same := true
	for i in 0 ..< one.frames {
		same &&= one.left[i] == many.left[i] && one.right[i] == many.right[i]
	}
	testing.expect(t, same)
	worst: f32
	for i in 0 ..< one.frames {
		sum: f32
		for st in one.stems {
			sum += st[0][i]
		}
		worst = max(worst, abs(sum - one.left[i]))
	}
	testing.expectf(t, worst < 1e-5, "stems differ from the mix by %f", worst)
	peak := peak_from_samples(one.left, one.right)
	testing.expectf(t, peak > 0.01 && !math.is_nan(peak) && !math.is_inf(peak), "peak %f", peak)
}

// Streamed in a preview's blocks (800 samples, a 60 fps frame), the song is
// the same samples as rendered in one go.
@(test)
test_blocks :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, &arena)
	whole := output_from_song(s, {threads = 1})
	defer output_destroy(&whole)
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
}

// On any number of threads the export is the same stream, to the sample,
// stems and all: which worker renders a node, and when, changes nothing.
@(test)
test_threads :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, &arena)
	one := output_from_song(s, {threads = 1, stems = true})
	defer output_destroy(&one)
	for threads in ([]int{2, 5, 16}) {
		many := output_from_song(s, {threads = threads, stems = true})
		defer output_destroy(&many)
		testing.expectf(t, slice.equal(one.slab, many.slab), "on %d threads the export differs", threads)
	}
}

// A range renders the same samples as the whole song does over that range.
@(test)
test_range :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, &arena)
	whole := output_from_song(s, {threads = 1})
	defer output_destroy(&whole)
	from := s.sections[1].start
	part := output_from_song(s, {from = from, to = from + 2, threads = 1})
	defer output_destroy(&part)
	offset := int(math.round(from * RATE))
	worst: f32
	for i in 0 ..< part.frames {
		worst = max(worst, abs(part.left[i] - whole.left[offset + i]))
	}
	testing.expectf(t, worst < 1e-3, "the range differs by %f", worst)
}

// Mastering for streaming reaches -14 LUFS with true peaks at -1 dBTP, the
// target's master the export's: the song is as it was, and mastered again
// it reaches the same.
@(test)
test_master :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, &arena)
	devices, chain, master, gain := len(s.devices), len(s.chain), s.master, s.master_gain_db
	l := master_export(s, {threads = 4}, .Streaming, {})
	testing.expectf(t, math.abs(l.integrated + 14) < 0.5, "%f LUFS", l.integrated)
	testing.expectf(t, l.true_peak <= -0.9, "%f dBTP", l.true_peak)
	testing.expect(t, len(s.devices) == devices && len(s.chain) == chain && s.master == master && s.master_gain_db == gain, "mastering changed the song")
	again := master_export(s, {threads = 4}, .Streaming, {})
	testing.expectf(t, again.integrated == l.integrated, "mastered again: %f LUFS, first %f", again.integrated, l.integrated)
}
