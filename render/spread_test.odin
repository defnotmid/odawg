package odawg_render

import "core:math"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import base "../base"
import spec "../spec"
import song "../song"

@(private = "file")
compose_spread :: proc(t: ^testing.T, text: string, arena: ^virtual.Arena) -> ^song.Song {
	_ = virtual.arena_init_growing(arena)
	context.allocator = virtual.arena_allocator(arena)
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(text, sp, &findings))
	add_examples(sp, &findings)
	out := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, out))
	for f in out.findings {
		testing.expectf(t, f.severity != .Error, "%s: %s", f.path, f.message)
	}
	return out
}

// An Lfo with a spread writes two sides, the right `spread` degrees ahead:
// at 2 Hz and 90 degrees, the left sin(2 pi 2 t) and the right its cosine,
// from the note's start.
@(test)
test_lfo_spread :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose_spread(t, `{ bpm: 120, key: "C major", gain_db: 0, sections: [ { name: "a", duration: "2m" } ],
		parts: { p: { instrument: { velocity: "none", nodes: { out: { class: "Lfo", rate: 2, spread: 90, gain_db: -6 } } },
			play: [ { name: "a", events: [ { time: 0, note: "C4", duration: 3 } ] } ] } } }`, &arena)
	context.allocator = virtual.arena_allocator(&arena)
	out := output_from_song(s, {})
	worst: f64
	for i in 0 ..< int(2.5 * RATE) {
		tt := f64(i) / RATE
		g := base.db_to_gain(-6) * base.db_to_gain(s.tracks[0].gain_db)
		worst = max(worst, abs(f64(out.left[i]) - g * math.sin(math.TAU * 2 * tt)), abs(f64(out.right[i]) - g * math.cos(math.TAU * 2 * tt)))
	}
	testing.expectf(t, worst < 1e-4, "the sides stray %g from a sine and its cosine", worst)
}

// Every kind that moves a field a side each where a modulator of two sides
// (an Lfo's spread) moves it, over a mono saw: the modulator makes it two
// sided, from an exact seek it plays what it plays whole (to the sample),
// and its sides part where the same Lfo without a spread leaves them one.
@(test)
test_spread_kinds_seek :: proc(t: ^testing.T) {
	Kind :: struct {
		node: string,
	}
	kinds := []string {
		`{ class: "Filter", type: "lowpass", input: "excite", frequency: { base: 900, by: "lfo", octaves: 1.5 } }`,
		`{ class: "Filter", type: "allpass", input: "excite", q: 2, frequency: { base: 900, by: "lfo", octaves: 1.5 } }`,
		`{ class: "Ladder", input: "excite", q: 3, frequency: { base: 900, by: "lfo", octaves: 1.5 } }`,
		`{ class: "OnePole", input: "excite", frequency: { base: 900, by: "lfo", octaves: 1.5 } }`,
		`{ class: "Comb", input: "excite", feedback: 0.6, delay: { base: 0.004, by: "lfo", amount: 0.002 } }`,
		`{ class: "Mix", inputs: [ "excite" ], amp: { by: "lfo", depth: 0.8 } }`,
		`{ class: "Mix", inputs: [ "excite" ], pan: { by: "lfo", amount: 0.7 } }`,
	}
	for x in kinds {
		text :: proc(x: string, spread: string) -> string {
			return strings.concatenate({`{ key: "F dorian", seed: 42, gain_db: 0,
				sections: [ { name: "a", duration: "4m", bpm: 112, chords: "Fm9 Bb9" } ],
				parts: { p: { instrument: { nodes: {
					excite: { class: "Osc", wave: "sawtooth", gain_db: -8 },
					lfo: { class: "Lfo", rate: 1.3, spread: `, spread, ` },
					env: { class: "Env", attack: 0.01, decay: 0.8, sustain: 0.4, release: 0.35 },
					out: `, x, ` } , out: "out" },
					play: [ { name: "a", chords: { voicing: "open" }, octave: 3, velocity: 0.7 } ] } } }`}, context.temp_allocator)
		}
		arena, arena2: virtual.Arena
		defer virtual.arena_destroy(&arena)
		defer virtual.arena_destroy(&arena2)
		s := compose_spread(t, text(x, "120"), &arena)
		alike := compose_spread(t, text(x, "0"), &arena2)
		context.allocator = virtual.arena_allocator(&arena)
		whole := output_from_song(s, {})
		FROM :: 3 * 4 * 60.0 / 112 // the third bar
		cut := output_from_song(s, {from = FROM, to = f64(whole.frames) / RATE})
		offset := int(math.round(FROM * RATE))
		worst: f32
		for v, i in cut.left {
			worst = max(worst, abs(v - whole.left[offset + i]), abs(cut.right[i] - whole.right[offset + i]))
		}
		testing.expectf(t, worst == 0, "%s with a spread Lfo: from a seek it differs by %g", x, worst)
		plain := output_from_song(alike, {})
		parted, same, moved: f64
		for i in 0 ..< min(whole.frames, plain.frames) {
			parted += f64(abs(whole.left[i] - whole.right[i]))
			same += f64(abs(plain.left[i] - plain.right[i]))
			moved += f64(abs(whole.left[i] - plain.left[i]) + abs(whole.right[i] - plain.right[i]))
		}
		if strings.contains(x, "pan:") {
			// a pan parts them anyway: a spread moves each its own way
			testing.expectf(t, moved > 100, "%s: a spread changes nothing (%g)", x, moved)
		} else {
			testing.expectf(t, parted > 100 && same < 1e-3 * parted, "%s: a spread doesn't part the sides (%g against %g alike)", x, parted, same)
		}
	}
}

// The library's phaser spreads its sweep 90 degrees by default: a centred
// pad (its sides alike) comes out wide, its sides' correlation well under
// the phaser's at spread 0.
@(test)
test_phaser_spread :: proc(t: ^testing.T) {
	text :: proc(fx: string) -> string {
		return strings.concatenate({`{ bpm: 100, seed: 3, key: "D minor", gain_db: 0, effects: "instruments/effects.json",
			sections: [ { name: "a", duration: "4m", chords: "Dm7 Bbmaj7" } ],
			parts: { pad: { instrument: { nodes: { out: { class: "Noise", color: "pink", gain_db: -12 } } }, effects: `, fx, `,
				play: [ { name: "a", events: [ { time: 0, note: "C4", duration: 9 } ] } ] } } }`}, context.temp_allocator)
	}
	correlation :: proc(o: Output, a, b: int) -> f64 {
		lr, ll, rr: f64
		for i in a ..< b {
			l, r := f64(o.left[i]), f64(o.right[i])
			lr += l * r
			ll += l * l
			rr += r * r
		}
		return lr / math.sqrt(ll * rr + 1e-30)
	}
	arena, arena2: virtual.Arena
	defer virtual.arena_destroy(&arena)
	defer virtual.arena_destroy(&arena2)
	wide := compose_spread(t, text(`[ "phaser" ]`), &arena)
	narrow := compose_spread(t, text(`[ { name: "phaser", spread: 0 } ]`), &arena2)
	context.allocator = virtual.arena_allocator(&arena)
	w := output_from_song(wide, {})
	n := output_from_song(narrow, {})
	cw, cn := correlation(w, RATE, 8 * RATE), correlation(n, RATE, 8 * RATE)
	testing.expectf(t, cn > 0.99 && cw < 0.9, "the phaser's sides: %.3f spread, %.3f alike", cw, cn)
}
