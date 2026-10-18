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

// A render cut into segments (each from engine_seek, on its own thread)
// is the render played straight through: the 909's notes (each drawing
// its drift from its own seed, never a running generator, summed in the
// order of their notes whatever slots they took) to the sample, and the 303's (one voice whose slew and slides carry from note to note:
// a seek replays the notes its memory holds) within -80 dB, cut mid-phrase
// and inside its slides.
@(test)
test_segments_are_straight :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose_with(t, `{ bpm: 125, key: "A minor", seed: 9, sections: [ { name: "a", duration: "8m", style: "styles/acid_house.json", energy: 1, chords: "Am Am Am G" } ] }`, &arena)
	straight := output_from_song(s, {threads = 1, segment = 1000, stems = true})
	defer output_destroy(&straight)
	cut := output_from_song(s, {threads = 3, segment = 1.37, stems = true})
	defer output_destroy(&cut)
	testing.expect_value(t, cut.frames, straight.frames)
	worst :: proc(a, b: [2][]f32) -> (diff, peak: f32) {
		for v, i in a[0] {
			diff = max(diff, abs(v - b[0][i]), abs(a[1][i] - b[1][i]))
			peak = max(peak, abs(v), abs(a[1][i]))
		}
		return
	}
	for name in ([]string{"drums", "acid", "acid2"}) {
		p := song.part_index(s, name)
		testing.expectf(t, p >= 0, "no part %s", name)
		if p < 0 {
			continue
		}
		diff, peak := worst(straight.stems[p], cut.stems[p])
		testing.expectf(t, peak > 0.01, "%s: silent", name)
		limit := name == "drums" ? 0 : peak * 1e-4
		testing.expectf(t, diff <= limit, "%s: cut into segments it differs by %g (peak %g)", name, diff, peak)
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
	straight := output_from_song(&m, {threads = 1, segment = 1000})
	cut := output_from_song(&m, {threads = 3, segment = 37})
	testing.expect_value(t, cut.frames, straight.frames)
	worst: f32
	for v, i in straight.left {
		worst = max(worst, abs(v - cut.left[i]), abs(straight.right[i] - cut.right[i]))
	}
	testing.expectf(t, worst == 0, "cut into segments the clip differs by %g", worst)
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
