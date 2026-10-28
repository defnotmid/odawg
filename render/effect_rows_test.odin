package odawg_render

import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:testing"
import base "../base"
import device "../device"
import spec "../spec"
import song "../song"

// A spec read with the example files, composed; its findings kept (errors
// included: what a test of findings reads).
@(private = "file")
compose_rows :: proc(t: ^testing.T, text: string, arena: ^virtual.Arena) -> ^song.Song {
	_ = virtual.arena_init_growing(arena)
	context.allocator = virtual.arena_allocator(arena)
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(text, sp, &findings))
	add_examples(sp, &findings)
	out := new(song.Song)
	song.song_from_spec(sp, out)
	append(&out.findings, ..findings[:])
	return out
}

@(private = "file")
no_errors :: proc(t: ^testing.T, s: ^song.Song) {
	for f in s.findings {
		testing.expectf(t, f.severity != .Error, "%s: %s", f.path, f.message)
	}
}

// Every library row on a part (two in a chain), the six-stage phaser on a
// return, a lane on the phaser's depth.
@(private = "file")
ROWS :: `{ bpm: 110, seed: 5, key: "D dorian", gain_db: 0,
	effects: "instruments/effects.json",
	sections: [ { name: "a", duration: "4m", chords: "Dm7 G7" }, { name: "b", duration: "4m", chords: "Em7 A7" } ],
	returns: { wide: [ "phaser6" ] },
	parts: {
		pad: { instrument: "Synth", effects: [ { name: "phaser", rate: 0.35, feedback: 0.6 } ], sends: { wide: -6 },
		       play: [ { name: "a..b", chords: { voicing: "open" }, octave: 4 } ] },
		keys: { instrument: "AMSynth", effects: [ "autowah", "flanger" ],
		        play: [ { name: "a..b", arpeggio: { pattern: "upDown", interval: "8n" }, octave: 4, velocity: 0.8 } ] },
		lead: { instrument: "MonoSynth", effects: [ { name: "tremolo", rate: 3, depth: 0.7 }, "autopan" ],
		        play: [ { name: "a..b", notes: "D5 . F5 A5 - . G5 E5", subdivision: "8n" } ] } },
	automation: { "parts/pad/effects/phaser/depth": [ [ "a", 0.5 ], [ "b", 2 ] ], "parts/keys/effects/autowah/bp/q": [ [ "a", 1.5 ], [ "b", 4 ] ] } }`

// A part's effect rows, a return's and lanes on a row's option and on a
// row's node/field (each read by its effect): from an
// exact seek the song is what a render straight through plays there (the
// rows' LFOs on the song clock, their memory pre-rolled), within -80 dB of
// each stem's peak; and the same samples in 800-sample blocks and on any
// pool. A row changes what it is put on.
@(test)
test_effect_rows_exact :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose_rows(t, ROWS, &arena)
	no_errors(t, s)
	{
		e: Engine
		testing.expect(t, engine_init(&e, s))
		defer engine_destroy(&e)
		read := 0
		for sp in e.lanes.fx {
			read += int(sp.count)
		}
		testing.expectf(t, read == 2 && len(s.automation) == 2, "%d of %d lanes read by an effect", read, len(s.automation))
	}
	whole := output_from_song(s, {stems = true})
	defer output_destroy(&whole)
	for threads in ([]int{1, 3, 8}) {
		tp := test_pool(threads)
		defer test_pool_free(tp)
		many := output_from_song(s, {pool = &tp.work_pool, stems = true})
		defer output_destroy(&many)
		testing.expectf(t, slice.equal(whole.slab, many.slab), "on %d threads the song differs", threads)
	}
	{
		e: Engine
		testing.expect(t, engine_init(&e, s))
		defer engine_destroy(&e)
		l, r := make([]f32, 800), make([]f32, 800)
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
	FROM :: 6.4321 // inside section a's last bar: every LFO mid-sweep, the lane moving
	cut := output_from_song(s, {from = FROM, to = base.seconds_from_samples(i64(whole.frames)), stems = true})
	defer output_destroy(&cut)
	offset := int(math.round(FROM * RATE))
	for stem, k in cut.stems {
		diff, peak: f32
		for v, i in stem[0] {
			diff = max(diff, abs(v - whole.stems[k][0][offset + i]), abs(stem[1][i] - whole.stems[k][1][offset + i]))
			peak = max(peak, abs(v), abs(stem[1][i]))
		}
		testing.expectf(t, peak > 0.005, "stem %d: silent", k)
		testing.expectf(t, diff <= peak * 1e-4, "stem %d: from a seek it differs by %g (peak %g)", k, diff, peak)
	}
	// without its rows, the song is another
	arena2: virtual.Arena
	defer virtual.arena_destroy(&arena2)
	dry := compose_rows(t, `{ bpm: 110, seed: 5, key: "D dorian", gain_db: 0,
		sections: [ { name: "a", duration: "4m", chords: "Dm7 G7" }, { name: "b", duration: "4m", chords: "Em7 A7" } ],
		parts: { pad: { instrument: "Synth", play: [ { name: "a..b", chords: { voicing: "open" }, octave: 4 } ] } } }`, &arena2)
	plain := output_from_song(dry, {stems = true})
	defer output_destroy(&plain)
	n := min(plain.frames, whole.frames)
	testing.expect(t, !slice.equal(plain.stems[0][0][:n], whole.stems[0][0][:n]))
}

// A row's Lfo runs on the song's clock: a tremolo on a part that first
// plays in bar 3 (its track asleep until then, its effects reset where it
// wakes) dips where a tremolo from the song's start would, its level
// exactly 1 - depth/2 + depth/2 sin(2 pi rate t) of the dry part's.
@(test)
test_effect_row_clock :: proc(t: ^testing.T) {
	text :: proc(fx: string) -> string {
		return strings.concatenate({`{ bpm: 120, seed: 1, key: "C major", gain_db: 0, effects: "instruments/effects.json",
			sections: [ { name: "a", duration: "4m", chords: "C" } ],
			parts: { p: { instrument: { nodes: { out: { class: "Osc", wave: "sine", gain_db: -12 } } }, effects: `, fx, `,
				play: [ { name: "a", events: [ { time: 4.1, note: "A4", duration: 3 } ] } ] } } }`}, context.temp_allocator)
	}
	arena, arena2: virtual.Arena
	defer virtual.arena_destroy(&arena)
	defer virtual.arena_destroy(&arena2)
	s := compose_rows(t, text(`[ { name: "tremolo", rate: 2, depth: 0.5 } ]`), &arena)
	no_errors(t, s)
	dry := compose_rows(t, text(`[]`), &arena2)
	wet := output_from_song(s, {})
	defer output_destroy(&wet)
	plain := output_from_song(dry, {})
	defer output_destroy(&plain)
	worst: f64
	for i in int(4.2 * RATE) ..< int(6.9 * RATE) {
		if abs(plain.left[i]) < 0.02 {
			continue // a ratio near a zero crossing is noise
		}
		tt := f64(i) / RATE
		want := 0.75 + 0.25 * math.sin(math.TAU * 2 * tt)
		worst = max(worst, abs(f64(wet.left[i] / plain.left[i]) - want))
	}
	testing.expectf(t, worst < 1e-3, "the tremolo's gain strays %g from the song clock's", worst)
}

// Each library row remembers its input no longer than its memory says (the
// sum of its nodes'): two instances that heard different pasts (loud
// noise, silence), then the same input on the same clock, agree once that
// memory has passed (within 40 dB of the past's peak).
@(test)
test_effect_row_memory :: proc(t: ^testing.T) {
	for name in ([]string{"phaser", "phaser6", "flanger", "tremolo", "autopan", "autowah"}) {
		arena: virtual.Arena
		defer virtual.arena_destroy(&arena)
		s := compose_rows(t, strings.concatenate({`{ bpm: 120, seed: 1, effects: "instruments/effects.json", sections: [ { name: "a", duration: "1m" } ],
			parts: { p: { instrument: "Synth", effects: [ "`, name, `" ], play: [ { name: "a", notes: "C4" } ] } } }`}, context.temp_allocator), &arena)
		no_errors(t, s)
		context.allocator = virtual.arena_allocator(&arena)
		d := s.chain[s.tracks[0].chain.first]
		testing.expect_value(t, s.devices[d], device.Device_Kind.Row)
		p := s.params[d]
		m := song.effect_memory_largest(s, d)
		testing.expectf(t, m.state > 0 || name == "tremolo" || name == "autopan", "%s remembers nothing", name)
		env := song.voice_env(s)
		scratch := new(device.Fx_Scratch)
		scratch.env = &env
		size := device.effect_size(.Row, &p, &s.programs)
		a, _ := mem.make_aligned([]u8, size, 16)
		b, _ := mem.make_aligned([]u8, size, 16)
		device.effect_reset(.Row, a, &p, 0)
		device.effect_reset(.Row, b, &p, 0)
		past := int(RATE)
		same := int(math.ceil(m.state * RATE)) + int(0.2 * RATE)
		n := past + same
		al, ar, bl, br := make([]f32, n), make([]f32, n), make([]f32, n), make([]f32, n)
		seed := u64(7)
		for i in 0 ..< past {
			seed = seed * 6364136223846793005 + 1442695040888963407
			al[i] = 0.7 * (f32(seed >> 40) / f32(1 << 24) * 2 - 1)
			ar[i] = -al[i]
		}
		for i in past ..< n {
			v := 0.25 * f32(math.sin(math.TAU * 220 * f64(i) / RATE))
			al[i], ar[i], bl[i], br[i] = v, v, v, v
		}
		for at := 0; at < n; at += 512 {
			end := min(at + 512, n)
			device.effect_row(a, &p, al[at:end], ar[at:end], nil, nil, scratch)
			device.effect_row(b, &p, bl[at:end], br[at:end], nil, nil, scratch)
		}
		worst: f32
		for i in past + int(math.ceil(m.state * RATE)) ..< n {
			worst = max(worst, abs(al[i] - bl[i]), abs(ar[i] - br[i]))
		}
		testing.expectf(t, base.gain_to_db(base.Gain(worst)) < base.gain_to_db(0.7) - 40, "%s still remembers its past %.3f s on: %.1f dB", name, m.state, base.gain_to_db(base.Gain(worst)))
	}
}

// What a row can't be, each a finding where it is written: a node playing
// from a note or reading the note's sources in an effect row
// (effect_reads_note), an Lfo rate something moves there, a lane on a
// row's Lfo rate or on a field read as the row is placed (fixed_value), an
// Input in an instrument, a row named as a built-in, a name that is no
// effect; and a lane on what does move is no finding.
@(test)
test_effect_row_findings :: proc(t: ^testing.T) {
	Case :: struct {
		code, path, text: string,
	}
	HEAD :: `{ bpm: 120, key: "C major", sections: [ { name: "a", duration: "1m" } ], `
	cases := []Case {
		{"effect_reads_note", "effects/env/nodes/env", `effects: [ "instruments/effects.json", { env: { nodes: { in: { class: "Input" }, env: { class: "Env" }, out: { class: "Mix", inputs: [ "in" ], amp: "env" } } } } ],
			parts: { p: { instrument: "Synth", effects: [ "env" ], play: [ { name: "a", notes: "C4" } ] } } }`},
		{"effect_reads_note", "effects/vel/nodes/out/amp/by", `effects: [ "instruments/effects.json", { vel: { nodes: { in: { class: "Input" }, out: { class: "Mix", inputs: [ "in" ], amp: { by: "velocity", depth: 1 } } } } } ],
			parts: { p: { instrument: "Synth", effects: [ "vel" ], play: [ { name: "a", notes: "C4" } ] } } }`},
		{"fixed_value", "effects/wob/nodes/lfo/rate", `effects: [ "instruments/effects.json", { wob: { nodes: { in: { class: "Input" }, slow: { class: "Lfo", rate: 0.1 }, lfo: { class: "Lfo", rate: { base: 2, by: "slow", amount: 1 } }, out: { class: "Mix", inputs: [ "in" ], amp: { by: "lfo", depth: 0.5 } } } } } ],
			parts: { p: { instrument: "Synth", effects: [ "wob" ], play: [ { name: "a", notes: "C4" } ] } } }`},
		{"fixed_value", "automation/parts/p/effects/phaser/rate", `effects: "instruments/effects.json", parts: { p: { instrument: "Synth", effects: [ "phaser" ], play: [ { name: "a", notes: "C4" } ] } },
			automation: { "parts/p/effects/phaser/rate": [ [ "a", 0.2 ], [ "end", 2 ] ] } }`},
		{"fixed_value", "automation/parts/p/effects/flanger/delay", `effects: "instruments/effects.json", parts: { p: { instrument: "Synth", effects: [ "flanger" ], play: [ { name: "a", notes: "C4" } ] } },
			automation: { "parts/p/effects/flanger/delay": [ [ "a", 0.002 ], [ "end", 0.004 ] ] } }`},
		{"bad_value", "parts/p/instrument/nodes/in", `parts: { p: { instrument: { nodes: { in: { class: "Input" }, out: { class: "Mix", inputs: [ "in" ] } } }, play: [ { name: "a", notes: "C4" } ] } } }`},
		{"bad_value", "song/effects/Chorus", `effects: [ "instruments/effects.json", { Chorus: { nodes: { out: { class: "Input" } } } } ],
			parts: { p: { instrument: "Synth", play: [ { name: "a", notes: "C4" } ] } } }`},
		{"unknown_effect", "parts/p/effects/1", `parts: { p: { instrument: "Synth", effects: [ "phazer" ], play: [ { name: "a", notes: "C4" } ] } } }`},
		{"", "", `effects: "instruments/effects.json", parts: { p: { instrument: "Synth", effects: [ "phaser" ], play: [ { name: "a", notes: "C4" } ] } },
			automation: { "parts/p/effects/phaser/depth": [ [ "a", 0.5 ], [ "end", 2 ] ], "parts/p/effects/1/mix": [ [ "a", 1 ], [ "end", 0.2 ] ], "parts/p/effects/phaser/ap2/q": [ [ "a", 1 ], [ "end", 3 ] ] } }`},
	}
	for c in cases {
		arena: virtual.Arena
		defer virtual.arena_destroy(&arena)
		s := compose_rows(t, strings.concatenate({HEAD, c.text}, context.temp_allocator), &arena)
		found := false
		for f in s.findings {
			found ||= f.code == c.code && f.path == c.path
			if c.code == "" {
				testing.expectf(t, f.severity != .Error, "a lane on what moves: %s %s: %s", f.code, f.path, f.message)
			}
		}
		if c.code != "" && !found {
			testing.expectf(t, false, "no %s at %s; found:", c.code, c.path)
			for f in s.findings {
				testing.expectf(t, false, "  %s %s: %s", f.code, f.path, f.message)
			}
		}
	}
}

// An effect row's option set by a command while an engine plays reaches it
// at its next walk (its program copied whole, as an instrument's is): the
// phaser's mix taken to 0 mid-song makes the part what a song placing the
// phaser at mix 0 plays. A node/field edited twice is one control, and a
// row's Lfo rate is no command's.
@(test)
test_effect_row_live :: proc(t: ^testing.T) {
	text :: proc(mix: string) -> string {
		return strings.concatenate({`{ bpm: 120, seed: 4, key: "C major", gain_db: 0, effects: "instruments/effects.json",
			sections: [ { name: "a", duration: "4m", chords: "C F" } ],
			parts: { pad: { instrument: "Synth", effects: [ { name: "phaser", mix: `, mix, ` } ], play: [ { name: "a", chords: { voicing: "open" }, octave: 4 } ] } } }`}, context.temp_allocator)
	}
	arena, arena2: virtual.Arena
	defer virtual.arena_destroy(&arena)
	defer virtual.arena_destroy(&arena2)
	s := compose_rows(t, text("1"), &arena)
	no_errors(t, s)
	e: Engine
	testing.expect(t, engine_init(&e, s))
	defer engine_destroy(&e)
	N :: 800
	frames := frames_from_song(s)
	l, r := make([]f32, N), make([]f32, N)
	defer delete(l)
	defer delete(r)
	got := make([]f32, frames)
	defer delete(got)
	EDIT :: 2 * RATE
	for at := 0; at + N <= frames; at += N {
		if at == EDIT {
			row := song.Command_Row{.Effect_Param_Set, "pad/effects/phaser/mix", 0}
			testing.expect(t, song.command_apply(s, row))
			engine_sync(&e, row)
			controls := len(s.programs.controls)
			for _ in 0 ..< 2 {
				q := song.Command_Row{.Effect_Param_Set, "pad/effects/phaser/ap1/q", 1}
				testing.expect(t, song.command_apply(s, q))
				engine_sync(&e, q)
			}
			testing.expect_value(t, len(s.programs.controls), controls + 1)
			testing.expect(t, !song.command_apply(s, {.Effect_Param_Set, "pad/effects/phaser/rate", 2}))
		}
		engine_process(&e, l, r)
		copy(got[at:], l)
	}
	quiet := compose_rows(t, text("0"), &arena2)
	want := output_from_song(quiet, {})
	defer output_destroy(&want)
	worst, moved: f32
	for i in EDIT + 2 * N ..< frames - N {
		worst = max(worst, abs(got[i] - want.left[i]))
	}
	for i in RATE ..< EDIT {
		moved = max(moved, abs(got[i] - want.left[i]))
	}
	testing.expectf(t, moved > 1e-3, "before the edit the phaser at mix 1 sounds as at mix 0")
	testing.expectf(t, worst == 0, "past the edit the part differs from the phaser placed at mix 0 by %e", worst)
}

// A host's clip names effect rows as a song's part does, from the rows the
// host hands the mix (host_rows: its `effects` tables and their files): a
// tremolo row on a clip's chain plays (the clip's level dips at its rate on
// the clip clock: 120 bpm, no tempo); without them the name is a finding
// and the clip plays as it is.
@(test)
test_effect_row_host_clip :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	frames := 4 * RATE
	audio := make([]f32, 2 * frames)
	for i in 0 ..< frames {
		v := 0.3 * f32(math.sin(math.TAU * 330 * f64(i) / RATE))
		audio[2 * i], audio[2 * i + 1] = v, v
	}
	bank: device.Bank
	set := device.bank_borrow(&bank, "tone", audio)
	findings := make(base.Findings)
	rows := new(spec.Spec)
	testing.expect(t, spec.spec_from_json(`{ effects: "instruments/effects.json" }`, rows, &findings))
	add_examples(rows, &findings)
	effects, _ := spec.json_parse(`[ { name: "tremolo", rate: 2, depth: 1 } ]`)
	play :: proc(rows: ^spec.Spec, bank: ^device.Bank, set: i32, effects: spec.json_value) -> (^song.Song, Output) {
		m := new(song.Song)
		song.mix_init(m)
		m.bank = bank
		m.host_rows = rows
		{
			// what append_clip reads the chain with is its own: gone after it
			scratch: virtual.Arena
			_ = virtual.arena_init_growing(&scratch)
			context.temp_allocator = virtual.arena_allocator(&scratch)
			song.append_clip(m, {name = "bed", set = set, start = 0, stop = 3, effects = effects})
			virtual.arena_destroy(&scratch)
		}
		song.mix_end(m)
		return m, output_from_song(m, {})
	}
	m, wet := play(rows, &bank, set, effects)
	testing.expect_value(t, m.devices[m.chain[m.tracks[0].chain.first]], device.Device_Kind.Row)
	// depth 1 at 2 Hz on the clip clock: silent where sin(2 pi 2 t) = -1
	quiet := int(0.375 * RATE) // 2 t = 0.75
	loud := int(0.125 * RATE)
	testing.expectf(t, abs(wet.left[quiet]) < 0.01 && abs(wet.left[loud - 50]) + abs(wet.left[loud + 50]) > 0.05, "the tremolo on the clip: %f at its dip, %f near its top", wet.left[quiet], wet.left[loud])
	bare, dry := play(nil, &bank, set, effects)
	testing.expect_value(t, bare.tracks[0].chain.count, i32(0))
	found := false
	for f in bare.findings {
		found ||= f.code == "unknown_effect" && f.path == "bed/effects/1"
	}
	testing.expectf(t, found, "a row with no host rows is a finding: %v", bare.findings)
	testing.expectf(t, abs(dry.left[quiet]) > 0.01 || abs(dry.left[quiet + 40]) > 0.01, "without the row the clip plays as it is")
}
