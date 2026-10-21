package odawg_render

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:testing"
import base "../base"
import device "../device"
import song "../song"
import spec "../spec"

@(private = "file")
compose_with :: proc(t: ^testing.T, text: string, arena: ^virtual.Arena) -> ^song.Song {
	_ = virtual.arena_init_growing(arena)
	context.allocator = virtual.arena_allocator(arena)
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(text, sp, &findings))
	add_examples(sp, &findings)
	out := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, out))
	append(&out.findings, ..findings[:])
	for f in out.findings {
		testing.expectf(t, f.severity != .Error, "%s: %s", f.code, f.message)
	}
	return out
}

// Checks a render: finite, audible, no wild level, silent after its last
// sound has had its tail.
@(private = "file")
expect_sound :: proc(t: ^testing.T, name: string, out: Output, quiet_after: int) {
	finite := true
	for v, i in out.left {
		finite &&= !math.is_nan(v) && !math.is_inf(v) && !math.is_nan(out.right[i]) && !math.is_inf(out.right[i])
	}
	testing.expectf(t, finite, "%s: non-finite samples", name)
	p := peak_from_samples(out.left, out.right)
	testing.expectf(t, p > 0.01 && p < 4, "%s: peak %v", name, p)
	if quiet_after < out.frames {
		testing.expectf(t, peak_from_samples(out.left[quiet_after:], out.right[quiet_after:]) == 0, "%s: sounded past its tail", name)
	}
}

// Every built-in row (but the Sampler and the Player, which need a set), every pad of
// the example machines and the 303 play: finite, audible, silent once
// their notes' tails are over.
@(test)
test_rows_render :: proc(t: ^testing.T) {
	names := spec.tone_row_names()
	for name in names {
		if name == "Sampler" || name == "Player" {
			continue // they play a set
		}
		arena: virtual.Arena
		s := compose_with(t, strings.concatenate({`{ bpm: 120, gain_db: 0, sections: [ { name: "a", duration: "1m" } ],
			parts: { p: { instrument: "`, name, `", play: [ { name: "a", notes: "C4 E4 G4 -" } ] } } }`}, context.temp_allocator), &arena)
		out := output_from_song(s, {threads = 1})
		expect_sound(t, name, out, out.frames)
		output_destroy(&out)
		virtual.arena_destroy(&arena)
	}
	for machine in ([]string{"machines/808.json", "machines/909.json"}) {
		pads := [?]string{"kick", "snare", "clap", "rim", "hat", "open_hat", "crash", "ride", "tom_low", "tom_mid", "tom_high", "shaker", "cowbell", "conga_low", "conga_mid", "conga_high", "clave", "maracas"}
		for pad in pads {
			arena: virtual.Arena
			s := compose_with(t, strings.concatenate({`{ bpm: 120, gain_db: 0, sections: [ { name: "a", duration: "1m" } ],
				parts: { d: { instrument: "`, machine, `", play: [ { name: "a", steps: { `, pad, `: "x..." } } ] } } }`}, context.temp_allocator), &arena)
			out := output_from_song(s, {threads = 1})
			expect_sound(t, fmt.tprintf("%s %s", machine, pad), out, out.frames)
			output_destroy(&out)
			virtual.arena_destroy(&arena)
		}
	}
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose_with(t, `{ bpm: 125, gain_db: 0, key: "A minor", sections: [ { name: "a", duration: "1m", chords: "Am" } ],
		parts: { acid: { instrument: "instruments/tb303.json", octave: 2, play: [ { name: "a", degrees: "1! . 1 8~ 1 . 5~ 8", subdivision: "16n", duration: "32n." } ] } } }`, &arena)
	out := output_from_song(s, {threads = 1})
	defer output_destroy(&out)
	expect_sound(t, "tb303", out, out.frames)
}

// How far a range rendered from an exact seek at `from` strays from the
// render played straight through over it.
@(private = "file")
seek_differs :: proc(straight, cut: Output, from: f64) -> (worst: f32) {
	offset := int(math.round(from * RATE))
	for v, i in cut.left {
		worst = max(worst, abs(v - straight.left[offset + i]), abs(cut.right[i] - straight.right[offset + i]))
	}
	return
}

// A range rendered from an exact seek mid-phrase (inside the 303's slides)
// is the render played straight through over it: the 909's notes (each
// drawing its drift from its own seed, never a running generator, summed in
// the order of their notes whatever slots they took) to the sample, and the
// 303's (one voice whose slew and slides carry from note to note: a seek
// replays the notes its memory holds) within -80 dB.
@(test)
test_seek_is_straight :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose_with(t, `{ bpm: 125, key: "A minor", seed: 9, sections: [ { name: "a", duration: "8m", style: "styles/acid_house.json", energy: 1, chords: "Am Am Am G" } ] }`, &arena)
	straight := output_from_song(s, {threads = 1, stems = true})
	defer output_destroy(&straight)
	FROM :: 5.37
	cut := output_from_song(s, {from = FROM, to = f64(straight.frames) / RATE, threads = 3, stems = true})
	defer output_destroy(&cut)
	offset := int(math.round(FROM * RATE))
	testing.expect_value(t, cut.frames, straight.frames - offset)
	worst :: proc(a, b: [2][]f32, offset: int) -> (diff, peak: f32) {
		for v, i in b[0] {
			diff = max(diff, abs(v - a[0][offset + i]), abs(b[1][i] - a[1][offset + i]))
			peak = max(peak, abs(v), abs(b[1][i]))
		}
		return
	}
	for name in ([]string{"drums", "acid", "acid2"}) {
		p := song.part_index(s, name)
		testing.expectf(t, p >= 0, "no part %s", name)
		if p < 0 {
			continue
		}
		diff, peak := worst(straight.stems[p], cut.stems[p], offset)
		testing.expectf(t, peak > 0.01, "%s: silent", name)
		limit := name == "drums" ? 0 : peak * 1e-4
		testing.expectf(t, diff <= limit, "%s: from a seek it differs by %g (peak %g)", name, diff, peak)
	}
}

// An instrument's options are controls a command sets by name, after
// compose: the 303's cutoff and decay move their nodes (the decay both of
// its envelopes, read back the same), a machine's tone every pad's bands; a
// node's field by its own path too. A value that would make a mono node
// stereo is refused and nothing changes. An option reaching nothing, and
// one named as a field it doesn't set, are findings.
@(test)
test_controls :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose_with(t, `{ bpm: 125, sections: [ { name: "a", duration: "1m" } ],
		parts: { acid: { instrument: "instruments/tb303.json", play: [ { name: "a", notes: "C2 C2" } ] },
		         drums: { instrument: "machines/909.json", play: [ { name: "a", steps: { snare: "x..." } } ] } } }`, &arena)
	progs := &s.programs
	// each instrument's label: its row as named
	testing.expect_value(t, s.labels[s.tracks[song.part_index(s, "acid")].instrument], "instruments/tb303.json")
	testing.expect_value(t, s.labels[s.tracks[song.part_index(s, "drums")].instrument], "machines/909.json")
	node_of :: proc(s: ^song.Song, part, node: string) -> ^device.Graph_Node {
		d := s.tracks[song.part_index(s, part)].instrument
		p := s.programs.programs[i32(s.params[d][.Program])]
		for &n in s.programs.nodes[p.nodes.first:base.span_end(p.nodes)] {
			if n.name == base.name_id(node) {
				return &n
			}
		}
		return nil
	}
	ladder_frequency :: proc(s: ^song.Song) -> f32 {
		n := node_of(s, "acid", "ladder")
		_, slot, _ := device.node_field_from_name(n.kind, "frequency")
		return n.values[slot]
	}
	testing.expect(t, song.command_apply(s, {.Param_Set, "acid/cutoff", 800}))
	testing.expect_value(t, ladder_frequency(s), 800)
	testing.expect(t, song.command_apply(s, {.Param_Set, "acid/decay", 0.5}))
	meg, hit := node_of(s, "acid", "meg"), node_of(s, "acid", "hit")
	_, time_slot, _ := device.node_field_from_name(meg.kind, "time")
	testing.expectf(t, abs(meg.values[time_slot] - 0.5 * 0.43478) < 1e-6 && meg.values[time_slot] == hit.values[time_slot], "decay: %v %v", meg.values[time_slot], hit.values[time_slot])
	d := s.tracks[song.part_index(s, "acid")].instrument
	program := i32(s.params[d][.Program])
	alias := device.control_of(progs, program, base.name_id("envelope/decay"))
	testing.expect(t, alias != nil)
	// a node's field by its path; a pan on the mono saw is refused
	testing.expect(t, song.command_apply(s, {.Param_Set, "acid/ladder/q", 3}))
	testing.expect(t, !song.command_apply(s, {.Param_Set, "acid/saw/pan", 0.5}))
	testing.expect_value(t, node_of(s, "acid", "saw").values[device.FIELD_PAN], 0)
	// a machine's knob reaches every pad's program
	d = s.tracks[song.part_index(s, "drums")].instrument
	machine := i32(s.params[d][.Program])
	tone := device.control_of(progs, machine, base.name_id("tone"))
	testing.expect(t, tone != nil && abs(tone.value - 0.5) < 1e-6)
	testing.expect(t, tone != nil && tone.targets.count > 10)
	testing.expect(t, song.command_apply(s, {.Param_Set, "drums/tone", 1}))
	for tg in progs.control_targets[tone.targets.first:base.span_end(tone.targets)] {
		if tg.op == .Octaves {
			testing.expectf(t, abs(progs.nodes[tg.node].values[tg.slot] / tg.base - 2) < 1e-4, "tone 1: x%v", progs.nodes[tg.node].values[tg.slot] / tg.base)
		}
	}
	// findings
	findings_of :: proc(t: ^testing.T, text: string) -> [dynamic]string {
		arena: virtual.Arena
		_ = virtual.arena_init_growing(&arena)
		context.allocator = virtual.arena_allocator(&arena)
		sp := new(spec.Spec)
		findings := make(base.Findings)
		testing.expect(t, spec.spec_from_json(text, sp, &findings))
		out := new(song.Song)
		song.song_from_spec(sp, out)
		codes := make([dynamic]string, context.temp_allocator)
		for f in out.findings {
			append(&codes, strings.clone(f.code, context.temp_allocator))
		}
		virtual.arena_destroy(&arena)
		return codes
	}
	codes := findings_of(t, `{ bpm: 120, sections: [ { name: "a", duration: "1m" } ], parts: { p: { instrument: {
		options: { bright: "nowhere/frequency", "f/frequency": { path: "f/q", op: "mul" } },
		nodes: { o: { class: "Osc" }, f: { class: "Filter", input: "o" }, out: { class: "Mix", input: "f" } } }, play: [ { name: "a", notes: "C4" } ] } } }`)
	testing.expectf(t, slice.contains(codes[:], "unknown_option_target") && slice.contains(codes[:], "control_shadows_field"), "%v", codes)
}

// A clip (song.append_clip: a program of one Clip node) plays its set as
// recorded: from its offset, from start to stop on the mix, its fades of
// their curve; and a render cut into segments is the same, a segment
// starting deep in a long clip (past 30 s) included.
@(test)
test_clip :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	// 60 s of a ramp on the left, its negative on the right
	frames := 60 * RATE
	audio := make([]f32, 2 * frames)
	for i in 0 ..< frames {
		audio[2 * i] = f32(i % 1000) / 2000
		audio[2 * i + 1] = -audio[2 * i]
	}
	bank: device.Bank
	set := device.bank_borrow(&bank, "ramp", audio)
	m: song.Song
	song.mix_init(&m)
	m.bank = &bank
	song.append_clip(&m, {name = "bed", set = set, start = 1, stop = 50, offset = 2, fade_in = 0.5, fade_out = 1, curve = .Linear})
	song.mix_end(&m)
	testing.expect_value(t, m.labels[m.tracks[0].instrument], "Player")
	straight := output_from_song(&m, {threads = 1})
	cut := output_from_song(&m, {from = 37, to = f64(straight.frames) / RATE, threads = 3})
	worst := seek_differs(straight, cut, 37)
	testing.expectf(t, worst == 0, "from a seek the clip differs by %g", worst)
	// silent before its start; then the source from its offset, faded in
	testing.expect_value(t, straight.left[RATE - 1], 0)
	q := RATE / 4 + 123 // a quarter second in, where the ramp isn't 0
	gain := straight.left[RATE + q] / audio[2 * (2 * RATE + q)]
	testing.expectf(t, abs(gain - f32(q) / f32(RATE / 2)) < 0.01, "a quarter second into a half second fade: %v", gain)
	k := 10 * RATE + 321
	testing.expectf(t, abs(straight.left[RATE + k] - audio[2 * (2 * RATE + k)]) < 1e-3, "%v %v", straight.left[RATE + k], audio[2 * (2 * RATE + k)])
	// it ends at its stop, faded out to its last sample
	testing.expect_value(t, straight.frames, 50 * RATE)
	testing.expect_value(t, straight.left[50 * RATE - 1], 0)
	// with effects, as a part's are written: on the clip's track, labelled
	fx: song.Song
	song.mix_init(&fx)
	fx.bank = &bank
	effects, _ := json.parse_string(`[ { "name": "Filter", "type": "lowpass", "frequency": 200 }, { "name": "Nothing" } ]`, .JSON5, true)
	ti := song.append_clip(&fx, {name = "bed", set = set, start = 1, stop = 3, offset = 2, effects = effects})
	song.mix_end(&fx)
	chain := fx.tracks[ti].chain
	testing.expect_value(t, chain.count, 1)
	if chain.count == 1 {
		testing.expect_value(t, fx.labels[fx.chain[chain.first]], "Filter")
	}
	found := false
	for f in fx.findings {
		found ||= f.path == "bed/effects/2"
	}
	testing.expectf(t, found, "a bad effect is a finding at bed/effects/2: %v", fx.findings)
	filtered := output_from_song(&fx, {threads = 1})
	moved: f32
	for v, i in filtered.left[RATE:2 * RATE] {
		moved = max(moved, abs(v - straight.left[RATE + i]))
	}
	testing.expectf(t, moved > 0.05, "the filter changed the clip by %g", moved)
}

// A song sounds the same wherever a mix places it: its notes' draws (a
// pluck's noise) are its own, its effects (a delay, a chorus's and an
// auto-filter's LFO, a reverb return's wobble) keep its clock, and a window
// opening at or before its start doesn't declick its first attack.
@(test)
test_song_placed_sounds_alone :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose_with(t, `{ name: "s", bpm: 120, seed: 9, sections: [ { name: "a", duration: "2m" } ],
		returns: { hall: [ { name: "Reverb", decay: 2 } ] },
		parts: {
			drums: { instrument: "MembraneSynth", play: [ { name: "a", notes: "C2 - C2 -", subdivision: "8n" } ] },
			lead: { instrument: "PluckSynth", sends: { hall: -6 }, effects: [ { name: "FeedbackDelay", delay_time: "8n", feedback: 0.4, wet: 0.3 } ],
				play: [ { name: "a", notes: "A4 C5 E5 -", subdivision: "8n" } ] },
			pad: { instrument: "Synth", effects: [ { name: "Chorus" }, { name: "AutoFilter" } ], play: [ { name: "a", notes: "A3 - C4 -", subdivision: "4n" } ] } } }`, &arena)
	alone := output_from_song(s, {threads = 1})
	length := f64(alone.frames) / RATE
	for place in ([][2]f64{{1.25, 1.25}, {0.1, 0}}) {
		at, opens := place[0], place[1]
		m: song.Song
		song.mix_init(&m)
		song.append_song(&m, s, at, "s", 0, {opens, at + length + 1, 0, 0, .Linear})
		song.mix_end(&m)
		placed := output_from_song(&m, {threads = 1, from = at, to = at + length})
		testing.expect_value(t, placed.frames, alone.frames)
		first := -1
		for v, i in alone.left[:min(alone.frames, placed.frames)] {
			if v != placed.left[i] || alone.right[i] != placed.right[i] {
				first = i
				break
			}
		}
		testing.expectf(t, first < 0, "placed at %gs (its window from %gs) it differs from alone from sample %d", at, opens, first)
	}
	// a window cutting into it, at a level, faded: what it plays (its
	// echoes and its return's tails of notes before the cut too) through the
	// envelope, as its render played as a clip with the same placing is
	frames := make([]f32, 2 * alone.frames)
	for i in 0 ..< alone.frames {
		frames[2 * i], frames[2 * i + 1] = alone.left[i], alone.right[i]
	}
	start, offset, stop := 2000.0 / RATE, 1500.0 / RATE, length - 4000.0 / RATE
	placed, clip: Output
	for as_clip in ([]bool{false, true}) {
		bank: device.Bank
		m: song.Song
		song.mix_init(&m)
		if as_clip {
			m.bank = &bank
			song.append_clip(&m, {name = "s", set = device.bank_borrow(&bank, "s", frames), start = start, stop = stop, offset = offset, gain_db = -3, fade_in = 0.2, fade_out = 0.3})
		} else {
			song.append_song(&m, s, start - offset, "s", -3, {start, stop, 0.2, 0.3, .Linear})
		}
		song.mix_end(&m)
		(as_clip ? &clip : &placed)^ = output_from_song(&m, {threads = 1, to = length})
	}
	worst: f32
	for v, i in placed.left {
		worst = max(worst, abs(v - clip.left[i]), abs(placed.right[i] - clip.right[i]))
	}
	testing.expectf(t, worst < 1e-5, "a window cutting into it differs from its render as a clip by %g", worst)
}

// A host's 16-bit render lent as it is (bank_borrow over i16) plays as the
// same frames as floats: full scale 32768, a power of two, so exactly.
@(test)
test_clip_borrows_i16 :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	frames := 4 * RATE
	whole := make([]i16, 2 * frames)
	floats := make([]f32, 2 * frames)
	for i in 0 ..< 2 * frames {
		whole[i] = i16((i * 37) % 65536 - 32768)
		floats[i] = f32(whole[i]) / 32768
	}
	play :: proc(bank: ^device.Bank, set: i32) -> Output {
		m: song.Song
		song.mix_init(&m)
		m.bank = bank
		song.append_clip(&m, {name = "render", set = set, start = 0.5, stop = 3.5, offset = 0.25, fade_in = 0.1, fade_out = 0.2})
		song.mix_end(&m)
		return output_from_song(&m, {threads = 1})
	}
	bank: device.Bank
	a := play(&bank, device.bank_borrow(&bank, "render", whole))
	b := play(&bank, device.bank_borrow(&bank, "floats", floats))
	testing.expect_value(t, a.frames, b.frames)
	same := a.frames > 0
	for v, i in a.left {
		same &&= v == b.left[i] && a.right[i] == b.right[i]
	}
	testing.expect(t, same, "the 16-bit clip differs from its floats")
	testing.expect(t, a.left[RATE] != 0, "the 16-bit clip is silent")
}

// A clip at a rate reads frame offset + k * rate for its sample k: at 2
// and 0.5 a slow sine comes out as the sine at those positions (through
// the kernel), at -1 the source exactly, backwards from the offset, then
// silence past the recording's start; and each the same cut into segments.
@(test)
test_clip_rate :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	// 20 s of a 110 Hz sine on the left, a 70 Hz one on the right
	frames := 20 * RATE
	wave :: proc(hz, frame: f64) -> f32 {return f32(0.5 * math.sin(2 * math.PI * hz * frame / RATE))}
	audio := make([]f32, 2 * frames)
	for i in 0 ..< frames {
		audio[2 * i], audio[2 * i + 1] = wave(110, f64(i)), wave(70, f64(i))
	}
	bank: device.Bank
	set := device.bank_borrow(&bank, "sines", audio)
	for rate in ([]f64{2, 0.5, -1}) {
		m: song.Song
		song.mix_init(&m)
		m.bank = &bank
		song.append_clip(&m, {name = "bed", set = set, start = 1, stop = 9, offset = 4, rate = rate})
		song.mix_end(&m)
		straight := output_from_song(&m, {threads = 1})
		cut := output_from_song(&m, {from = 3.7, to = f64(straight.frames) / RATE, threads = 3})
		worst := seek_differs(straight, cut, 3.7)
		testing.expectf(t, worst == 0, "rate %v: from a seek the clip differs by %g", rate, worst)
		// past the declick fades, the source at offset + k * rate (a 2x clip
		// runs out of recording at 8 s in, a backwards one at 4 s)
		off: f32
		for k in RATE / 100 ..< 8 * RATE - RATE / 100 {
			pos := 4 * f64(RATE) + f64(k) * rate
			want_l, want_r: f32
			if pos >= 0 && pos < f64(frames) {
				want_l, want_r = wave(110, pos), wave(70, pos)
			}
			if abs(pos - f64(frames)) < 64 || abs(pos) < 64 {
				continue // the kernel at the recording's edges
			}
			off = max(off, abs(straight.left[RATE + k] - want_l), abs(straight.right[RATE + k] - want_r))
		}
		limit: f32 = rate == -1 ? 0 : 2e-4
		testing.expectf(t, off <= limit, "rate %v: off the source at offset + k * rate by %g", rate, off)
	}
}

// A Lua table of entries alone is a list but where a row or one name goes.
@(test)
test_positional_list :: proc(t: ^testing.T) {
	testing.expect(t, !spec.positional_list("parts/bass/instrument/nodes/out", 3, true)) // { "Mix", "a", "b" }
	testing.expect(t, spec.positional_list("parts/bass/instrument/nodes/out/amp", 2, true)) // { "env", "level" }
	testing.expect(t, spec.positional_list("parts/bass/instrument/nodes/out/inputs", 2, true))
	testing.expect(t, spec.positional_list("parts/bass/instrument/nodes/osc/hz", 3, false))
	testing.expect(t, !spec.positional_list("parts/bass/instrument", 1, true)) // { "pad" }
	testing.expect(t, spec.positional_list("parts/bass/effects", 2, true)) // { "Reverb", "Chorus" }
	// an option's targets: one ({ "meg/time", op = "mul" }), or a list of them
	fields, _ := spec.positional_fields("parts/acid/instrument/options/decay")
	testing.expect(t, len(fields) == 1 && fields[0] == "path")
	fields, _ = spec.positional_fields("parts/acid/instrument/options/decay/2")
	testing.expect(t, len(fields) == 1 && fields[0] == "path")
	testing.expect(t, spec.positional_list("parts/acid/instrument/options/decay", 2, true)) // { "meg/time", "hit/time" }
}

// The example songs and the styles, instruments and machines they use read
// without a warning about their rows (an option reaching nothing, a key no
// one reads), and no finding's message is garbled.
@(test)
test_examples_clean :: proc(t: ^testing.T) {
	for ex in EXAMPLE_SONGS {
		arena: virtual.Arena
		_ = virtual.arena_init_growing(&arena)
		context.allocator = virtual.arena_allocator(&arena)
		sp := new(spec.Spec)
		findings := make(base.Findings)
		testing.expectf(t, spec.spec_from_json(ex.text, sp, &findings), "%s", ex.name)
		add_examples(sp, &findings)
		s := new(song.Song)
		song.song_from_spec(sp, s)
		append(&s.findings, ..findings[:])
		for f in s.findings {
			testing.expectf(t, f.code != "unknown_option_target" && f.code != "unknown_key" && f.code != "control_shadows_field", "%s: %s %s", ex.name, f.code, f.message)
			testing.expectf(t, !strings.contains(f.message, "%!"), "%s: a garbled message: %s", ex.name, f.message)
		}
		virtual.arena_destroy(&arena)
	}
}

// A row's own option values apply whatever order its keys are in (`bright`
// sorts before `options`), and a finding naming a shape reads as written.
@(test)
test_row_option_order :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(`{ bpm: 120, sections: [ { name: "a", duration: "1m" } ], parts: {
		p: { instrument: { bright: 900, options: { bright: "f/frequency" }, nodes: { o: { class: "Osc" }, f: { class: "Filter", input: "o" }, out: { class: "Mix", input: "f" } } }, play: [ { name: "a", notes: "C4" } ] },
		q: { instrument: { nodes: { out: { class: "Osc", amp: 0.15 } } }, play: [ { name: "a", notes: "C4" } ] } } }`, sp, &findings))
	s := new(song.Song)
	song.song_from_spec(sp, s)
	amp_message := ""
	for f in s.findings {
		testing.expectf(t, f.code != "unknown_key", "%s", f.message)
		if f.code == "bad_value" && strings.contains(f.path, "amp") {
			amp_message = f.message
		}
	}
	testing.expectf(t, strings.contains(amp_message, "{ by, depth }"), "the amp finding reads: %q", amp_message)
	d := s.tracks[song.part_index(s, "p")].instrument
	p := s.programs.programs[i32(s.params[d][.Program])]
	for n in s.programs.nodes[p.nodes.first:base.span_end(p.nodes)] {
		if n.name == base.name_id("f") {
			_, slot, _ := device.node_field_from_name(n.kind, "frequency")
			testing.expect_value(t, n.values[slot], 900)
		}
	}
}

// A layered row (layers = { ... }: what an SFZ instrument compiles to, and
// a row of its own): a note starts every layer whose conditions it meets.
// Keys in its keyswitch range switch (they don't sound) and later notes
// play the layers of the last switch; a release layer sounds at each
// note's end; a round robin alternates; a group whose off_by is itself
// cuts its earlier voice. A render cut into segments is the same.
@(test)
test_layers :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	tone :: `{ nodes: { env: { class: "Env", attack: 0.001, decay: 0.01, sustain: 1, release: 0.005 }, out: { class: "Osc", wave: "sine", amp: "env" } } }`
	click :: `{ nodes: { env: { class: "Decay", time: 0.01 }, out: { class: "Noise", amp: "env" } } }`
	text := strings.concatenate({`{ bpm: 120, gain_db: 0, sections: [ { name: "a", duration: "4m" } ], parts: {
		sw: { gain_db: 0, instrument: { sw_lo: "C1", sw_hi: "C#1", sw_default: "C1", layers: [
			{ instrument: `, tone, `, lo_key: "C3", hi_key: "C5", sw_last_lo: "C1" },
			{ instrument: `, tone, `, lo_key: "C3", hi_key: "C5", sw_last_lo: "C#1", gain_db: -20 },
			{ instrument: `, click, `, trigger: "release", rt_decay: 0 } ] },
			play: [ { name: "a", notes: "C4 . C#1 . C4 . . .", subdivision: "4n", duration: "8n" } ] },
		rr: { gain_db: 0, instrument: { layers: [
			{ instrument: `, tone, `, seq_length: 2, seq_position: 1 },
			{ instrument: `, tone, `, seq_length: 2, seq_position: 2, gain_db: -20 } ] },
			play: [ { name: "a", notes: "E4 . E4 . E4 . . .", subdivision: "4n", duration: "8n" } ] },
		cut: { gain_db: 0, instrument: { layers: [ { instrument: `, tone, `, group: 1, off_by: 1 } ] },
			play: [ { name: "a", events: [ { time: 0, note: "G4", duration: 2 }, { time: 0.5, note: "C4", duration: 0.25 } ] } ] } } }`})
	s := compose_with(t, text, &arena)
	out := output_from_song(s, {threads = 1, stems = true})
	defer output_destroy(&out)
	rms :: proc(st: [2][]f32, from, to: f64) -> f32 {
		a, b := int(from * RATE), min(int(to * RATE), len(st[0]))
		sum: f64
		for i in a ..< b {
			sum += f64(st[0][i] * st[0][i])
		}
		return f32(math.sqrt(sum / f64(max(b - a, 1))))
	}
	sw := out.stems[song.part_index(s, "sw")]
	// a beat is 0.5 s: C4 at 0 (switch C1: layer 1), C#1 at 1 s (a switch,
	// silent), C4 at 2 s (switch C#1: layer 2, 20 dB down)
	first, silent, second := rms(sw, 0.05, 0.2), rms(sw, 1.05, 1.2), rms(sw, 2.05, 2.2)
	testing.expectf(t, first > 0.1 && silent < first * 0.01 && second > first * 0.05 && second < first * 0.2, "keyswitch: %v %v %v", first, silent, second)
	// the release layer: a click as each note ends (at 0.25 s), after the
	// tone's own short release
	testing.expectf(t, rms(sw, 0.26, 0.28) > 0.01, "no release click: %v", rms(sw, 0.26, 0.28))
	rr := out.stems[song.part_index(s, "rr")]
	a, b, c := rms(rr, 0.05, 0.2), rms(rr, 1.05, 1.2), rms(rr, 2.05, 2.2)
	testing.expectf(t, b < a * 0.2 && c > b * 5, "round robin: %v %v %v", a, b, c)
	cut := out.stems[song.part_index(s, "cut")]
	// G4 held to 2 s, C4 at 0.5 s cuts it: after C4 ends only silence
	testing.expectf(t, rms(cut, 0.9, 1.5) < rms(cut, 0.1, 0.4) * 0.01, "off_by: %v %v", rms(cut, 0.9, 1.5), rms(cut, 0.1, 0.4))
	// the same from an exact seek mid-phrase
	FROM :: 0.37
	seg := output_from_song(s, {from = FROM, to = f64(out.frames) / RATE, threads = 3, stems = true})
	defer output_destroy(&seg)
	worst := seek_differs(out, seg, FROM)
	testing.expectf(t, worst == 0, "from a seek it differs by %g", worst)
	offset := int(math.round(FROM * RATE))
	for name in ([]string{"sw", "rr", "cut"}) {
		st, sg := out.stems[song.part_index(s, name)], seg.stems[song.part_index(s, name)]
		at := -1
		w: f32
		for v, i in sg[0] {
			if abs(v - st[0][offset + i]) > w {
				w = abs(v - st[0][offset + i])
				if at < 0 && w > 1e-6 {
					at = offset + i
				}
			}
		}
		if w > 0 {
			testing.expectf(t, false, "%s differs by %g from sample %d (%.3f s)", name, w, at, f64(at) / RATE)
		}
	}
	// the notes compose made don't count as played
	for tr, ti in s.tracks {
		if int(tr.part) == song.part_index(s, "sw") {
			testing.expect_value(t, song.track_note_count(s, ti), 4) // C4 twice a pass, two passes (not the switches, not the release notes)
		}
	}
}
