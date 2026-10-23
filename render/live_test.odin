package odawg_render

import "core:math"
import "core:mem/virtual"
import "core:sync"
import "core:testing"
import "core:thread"
import base "../base"
import device "../device"
import spec "../spec"
import song "../song"

@(private = "file")
LIVE :: `{ bpm: 120, seed: 4, key: "C major", gain_db: 0,
	sections: [ { name: "a", duration: "8m", chords: "C F G C" } ],
	returns: { hall: [ { name: "Reverb", decay: 1.2 } ] },
	parts: {
		lead: { instrument: "MonoSynth", effects: [ { name: "Filter", type: "lowpass", frequency: 3000 } ], sends: { hall: -12 },
		        play: [ { name: "a", notes: "C5 E5 G5 C6 G5 E5 C5 .", subdivision: "8n" } ] },
		pad: { instrument: "Synth", play: [ { name: "a", chords: { voicing: "open" }, octave: 4 } ] } } }`

@(private = "file")
compose_live :: proc(t: ^testing.T, arena: ^virtual.Arena) -> ^song.Song {
	_ = virtual.arena_init_growing(arena)
	context.allocator = virtual.arena_allocator(arena)
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(LIVE, sp, &findings))
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s))
	return s
}

// An edit applied to the song while an engine plays it reaches the engine
// at its next walk, a level gliding there: the lead's fader dropped to -60
// dB mid-song makes its stem what a song composed at -60 plays, once the
// glide is past; the song itself holds the new level (a new export plays
// it).
@(test)
test_live_fader :: proc(t: ^testing.T) {
	arena, arena2: virtual.Arena
	defer virtual.arena_destroy(&arena)
	defer virtual.arena_destroy(&arena2)
	s := compose_live(t, &arena)
	lead := song.part_index(s, "lead")
	e: Engine
	testing.expect(t, engine_init(&e, s))
	defer engine_destroy(&e)
	BLOCK_N :: 800
	frames := frames_from_song(s)
	parts := stem_count(s)
	stems := make([][2][]f32, parts)
	defer delete(stems)
	slab := make([]f32, 2 * BLOCK_N * parts)
	defer delete(slab)
	for p in 0 ..< parts {
		stems[p] = {slab[2 * BLOCK_N * p:][:BLOCK_N], slab[2 * BLOCK_N * p + BLOCK_N:][:BLOCK_N]}
	}
	l := make([]f32, BLOCK_N)
	r := make([]f32, BLOCK_N)
	defer delete(l)
	defer delete(r)
	got := make([]f32, frames)
	defer delete(got)
	EDIT :: 3 * RATE
	for at := 0; at + BLOCK_N <= frames; at += BLOCK_N {
		if at == EDIT {
			row := song.Command_Row{.Part_Gain_Set, "lead", -60}
			testing.expect(t, song.command_apply(s, row))
			engine_sync(&e, row)
		}
		engine_process(&e, l, r, stems)
		copy(got[at:], stems[lead][0])
	}
	// what a song composed with the lead at -60 plays
	quiet := compose_live(t, &arena2)
	song.command_apply(quiet, {.Part_Gain_Set, "lead", -60})
	want := output_from_song(quiet, {stems = true})
	defer output_destroy(&want)
	after := EDIT + int(GLIDE) + BLOCK_N
	worst, before: f32
	for i in after ..< frames - BLOCK_N {
		worst = max(worst, abs(got[i] - want.stems[lead][0][i]))
	}
	for i in RATE ..< EDIT {
		before = max(before, abs(got[i]))
	}
	testing.expectf(t, before > 0.01, "the lead is silent before the edit (%f)", before)
	testing.expectf(t, worst < 1e-6, "past the glide the lead differs from a song made at -60 dB by %e", worst)
	// the glide: no step from loud to quiet within a sample
	jump: f32
	for i in EDIT ..< EDIT + int(GLIDE) + BLOCK_N {
		jump = max(jump, abs(got[i]) - abs(got[i - 1]))
	}
	testing.expectf(t, jump < before, "a step at the edit (%f)", jump)
}

// Every kind of edit reaches a playing engine: a pan, a mute, a send (its
// return hears less), an effect's param, an instrument's control (its copy
// of the program as the song's), the master's gain.
@(test)
test_live_edits :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose_live(t, &arena)
	e: Engine
	testing.expect(t, engine_init(&e, s))
	defer engine_destroy(&e)
	l := make([]f32, 4096)
	r := make([]f32, 4096)
	defer delete(l)
	defer delete(r)
	engine_process(&e, l, r)
	rows := []song.Command_Row {
		{.Part_Pan_Set, "pad", -0.5},
		{.Part_Mute_Set, "pad", 1},
		{.Send_Set, "lead/sends/hall", -40},
		{.Effect_Param_Set, "lead/effects/Filter/frequency", 700},
		{.Effect_Param_Set, "returns/hall/Reverb/wet", 0.3},
		{.Param_Set, "lead/filter/frequency", 450},
		{.Master_Gain_Set, "master", -3},
	}
	for row in rows {
		testing.expectf(t, song.command_apply(s, row), "%v changed nothing", row)
		engine_sync(&e, row)
	}
	engine_process(&e, l, r)
	pad, lead := song.part_index(s, "pad"), song.part_index(s, "lead")
	for tr, ti in s.tracks {
		if int(tr.part) == pad {
			testing.expect_value(t, e.mix.tracks[ti].pan.to, -0.5)
			testing.expect(t, e.mix.tracks[ti].muted)
		}
	}
	for x, i in s.edges {
		testing.expect_value(t, e.mix.edges[i].to, f64(x.gain))
	}
	for d in 0 ..< len(s.devices) {
		testing.expect(t, e.mix.params[d] == s.params[d])
	}
	found := false
	for tr in s.tracks {
		if int(tr.part) != lead {
			continue
		}
		p := s.programs.programs[i32(s.params[tr.instrument][.Program])]
		for n, k in s.programs.nodes[p.nodes.first:base.span_end(p.nodes)] {
			testing.expect(t, e.programs.nodes[int(p.nodes.first) + k].values == n.values)
			found = true
		}
	}
	testing.expect(t, found)
	testing.expect_value(t, e.master.own_gain, -3)
	for v in l {
		testing.expect(t, !math.is_nan(v))
	}
}

// A host's thread editing while the engine renders on a pool: no tear, no
// race (the song edited, the engine reading its own copies).
@(test)
test_live_threads :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose_live(t, &arena)
	tp := test_pool(4)
	defer test_pool_free(tp)
	e: Engine
	testing.expect(t, engine_init(&e, s, &tp.work_pool))
	defer engine_destroy(&e)
	Host :: struct {
		s:    ^song.Song,
		e:    ^Engine,
		done: bool,
		arena: ^virtual.Arena,
	}
	host := Host{s, &e, false, &arena}
	th := thread.create_and_start_with_data(&host, proc(data: rawptr) {
		h := (^Host)(data)
		context.allocator = virtual.arena_allocator(h.arena)
		for k := 0; !sync.atomic_load(&h.done); k += 1 {
			row := song.Command_Row{.Part_Gain_Set, "lead", f64(-(k % 24))}
			if k % 3 == 1 {
				row = {.Param_Set, "lead/filter/frequency", f64(300 + 100 * (k % 30))}
			} else if k % 3 == 2 {
				row = {.Effect_Param_Set, "lead/effects/Filter/frequency", f64(500 + 50 * (k % 40))}
			}
			song.command_apply(h.s, row)
			engine_sync(h.e, row)
		}
	})
	l := make([]f32, 2048)
	r := make([]f32, 2048)
	defer delete(l)
	defer delete(r)
	peak: f32
	for _ in 0 ..< 200 {
		engine_process(&e, l, r)
		for v in l {
			testing.expect(t, !math.is_nan(v))
			peak = max(peak, abs(v))
		}
	}
	sync.atomic_store(&host.done, true)
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, peak > 0.001)
	_ = device.Param.Frequency
}
