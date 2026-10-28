package odawg_render

import "core:math"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import base "../base"
import spec "../spec"
import song "../song"
import tempo "../tempo"

@(private = "file")
compose_synced :: proc(t: ^testing.T, text: string, arena: ^virtual.Arena) -> ^song.Song {
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

// A held sine through `fx` (a chain), at `bpm` (from, to).
@(private = "file")
held :: proc(bpm, fx: string) -> string {
	return strings.concatenate({`{ key: "C major", gain_db: 0, effects: "instruments/effects.json",
		sections: [ { name: "a", duration: "8m", bpm: `, bpm, `, chords: "C" } ],
		parts: { p: { instrument: { nodes: { out: { class: "Osc", wave: "sine", gain_db: -12 } } }, effects: `, fx, `,
			play: [ { name: "a", events: [ { time: 0.05, note: "A4", duration: 12 } ] } ] } } }`}, context.temp_allocator)
}

// How far a stem strays from `want(t)` times the dry stem (where the dry is
// loud enough for a ratio), seconds a..b of the mix.
@(private = "file")
strays :: proc(wet, dry: []f32, a, b: f64, want: proc(t: f64, data: rawptr) -> f64, data: rawptr) -> (worst: f64) {
	for i in int(a * RATE) ..< min(int(b * RATE), len(wet), len(dry)) {
		if abs(dry[i]) < 0.02 {
			continue
		}
		worst = max(worst, abs(f64(wet[i] / dry[i]) - want(f64(i) / RATE, data)))
	}
	return
}

// Two songs placed in one mix at their own tempi (one steady at 100, one
// ramping 112 to 140, placed 1.3 s later), each with a tremolo row at "4n"
// (its rate in beats, given where the chain places it): each one's level is
// exactly 1 - depth/2 + depth/2 sin(2 pi beat), its own song's beat (its
// own map, its own clock), through the ramp; and from an exact seek the mix
// is what it plays straight through.
@(test)
test_tempo_sync_rows :: proc(t: ^testing.T) {
	arenas: [5]virtual.Arena
	defer for &a in arenas {
		virtual.arena_destroy(&a)
	}
	FX :: `[ { name: "tremolo", rate: "4n", depth: 0.5 } ]`
	steady := compose_synced(t, held("100", FX), &arenas[0])
	ramp := compose_synced(t, held("[ 112, 140 ]", FX), &arenas[1])
	steady_dry := compose_synced(t, held("100", "[]"), &arenas[2])
	ramp_dry := compose_synced(t, held("[ 112, 140 ]", "[]"), &arenas[3])
	_ = virtual.arena_init_growing(&arenas[4])
	context.allocator = virtual.arena_allocator(&arenas[4])
	AT :: 1.3
	mix :: proc(a, b: ^song.Song) -> ^song.Song {
		m := new(song.Song)
		song.mix_init(m)
		song.append_song(m, a, 0, "steady")
		song.append_song(m, b, AT, "ramp")
		song.mix_end(m)
		return m
	}
	wet := mix(steady, ramp)
	dry := mix(steady_dry, ramp_dry)
	w := output_from_song(wet, {stems = true})
	d := output_from_song(dry, {stems = true})
	Clock :: struct {
		m:  ^tempo.Tempo_Map,
		at: base.Seconds,
	}
	want :: proc(t: f64, data: rawptr) -> f64 {
		c := (^Clock)(data)
		beat := tempo.beat_from_seconds(c.m, base.Seconds(t) - c.at)
		return 0.75 + 0.25 * math.sin(math.TAU * beat)
	}
	a := song.part_index(wet, "steady/p")
	b := song.part_index(wet, "ramp/p")
	ca := Clock{&steady.tempo, 0}
	cb := Clock{&ramp.tempo, AT}
	sa := strays(w.stems[a][0], d.stems[a][0], 0.2, 11, want, &ca)
	sb := strays(w.stems[b][0], d.stems[b][0], AT + 0.2, AT + 11, want, &cb)
	testing.expectf(t, sa < 1e-3, "the steady song's tremolo strays %g from its beat", sa)
	testing.expectf(t, sb < 1e-3, "the ramping song's tremolo strays %g from its beat", sb)
	// at the ramp's end its beat is shorter than at its start: the dips moved
	// with it (a Hz rate read at the first section's tempo would be 25% off)
	testing.expect(t, ramp.sections[0].bpm1 > ramp.sections[0].bpm0 + 20)
	FROM :: 7.123
	cut := output_from_song(wet, {from = FROM, to = base.seconds_from_samples(i64(w.frames))})
	offset := int(math.round(FROM * RATE))
	diff, peak: f32
	for v, i in cut.left {
		diff = max(diff, abs(v - w.left[offset + i]), abs(cut.right[i] - w.right[offset + i]))
		peak = max(peak, abs(v))
	}
	testing.expectf(t, peak > 0.01 && diff <= peak * 1e-4, "from a seek it differs by %g (peak %g)", diff, peak)
}

// An instrument's Lfo at "4n" follows the song's tempo through a ramp: its
// phase restarts with the note, then counts the song's beats since the
// note's start (a held note's tremolo stays on the beat as the tempo
// rises). Written as a number, a rate is Hz, as before.
@(test)
test_tempo_sync_instrument :: proc(t: ^testing.T) {
	text :: proc(rate: string, depth: string) -> string {
		return strings.concatenate({`{ key: "C major", gain_db: 0,
			sections: [ { name: "a", duration: "8m", bpm: [ 90, 150 ], chords: "C" } ],
			parts: { p: { instrument: { nodes: { lfo: { class: "Lfo", rate: `, rate, ` },
				out: { class: "Osc", wave: "sine", gain_db: -12, amp: { by: "lfo", depth: `, depth, ` } } } },
				play: [ { name: "a", events: [ { time: 0.5, note: "A4", duration: 12 } ] } ] } } }`}, context.temp_allocator)
	}
	arenas: [3]virtual.Arena
	defer for &a in arenas {
		virtual.arena_destroy(&a)
	}
	synced := compose_synced(t, text(`"4n"`, "0.5"), &arenas[0])
	hz := compose_synced(t, text("2", "0.5"), &arenas[1])
	dry := compose_synced(t, text("2", "0"), &arenas[2])
	ws := output_from_song(synced, {})
	defer output_destroy(&ws)
	wh := output_from_song(hz, {})
	defer output_destroy(&wh)
	d := output_from_song(dry, {})
	defer output_destroy(&d)
	Clock :: struct {
		m:     ^tempo.Tempo_Map,
		start: base.Seconds,
		hz:    f64,
	}
	on_beat :: proc(t: f64, data: rawptr) -> f64 {
		c := (^Clock)(data)
		beats := tempo.beat_from_seconds(c.m, base.Seconds(t)) - tempo.beat_from_seconds(c.m, c.start)
		return 0.75 + 0.25 * math.sin(math.TAU * beats)
	}
	in_hz :: proc(t: f64, data: rawptr) -> f64 {
		c := (^Clock)(data)
		return 0.75 + 0.25 * math.sin(math.TAU * c.hz * (t - f64(c.start)))
	}
	note := synced.notes.time[0]
	c := Clock{&synced.tempo, note, 2}
	s := strays(ws.left, d.left, f64(note) + 0.1, f64(note) + 11, on_beat, &c)
	h := strays(wh.left, d.left, f64(note) + 0.1, f64(note) + 11, in_hz, &c)
	testing.expectf(t, s < 1e-3, "a \"4n\" rate strays %g from the song's beats", s)
	testing.expectf(t, h < 1e-3, "a rate of 2 strays %g from 2 Hz", h)
}
