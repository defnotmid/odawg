package odawg_render

import "core:math"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import base "../base"
import song "../song"
import spec "../spec"

@(private = "file")
compose_text :: proc(t: ^testing.T, text: string, arena: ^virtual.Arena) -> ^song.Song {
	_ = virtual.arena_init_growing(arena)
	context.allocator = virtual.arena_allocator(arena)
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(text, sp, &findings))
	out := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, out))
	append(&out.findings, ..findings[:])
	return out
}

@(private = "file")
has_edge :: proc(s: ^song.Song, from, to: i32, kind: song.Edge_Kind) -> bool {
	for x in s.edges {
		if x.from == from && x.to == to && x.kind == kind {
			return true
		}
	}
	return false
}

@(private = "file")
has_finding :: proc(s: ^song.Song, code: string) -> bool {
	for f in s.findings {
		if f.code == code {
			return true
		}
	}
	return false
}

// The routing is data: parts into a bus with its own effects (`to`), a send
// into it, a pad keyed by the drums; the bus is a stem after the parts and
// the returns, and the stems still sum to the mix.
@(test)
test_routes :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose_text(t, `{ bpm: 120, sections: [ { name: "a", duration: "2m" } ],
		buses: { glue: { effects: [ { name: "Compressor", threshold: -18, ratio: 3 } ] } },
		parts: {
			drums: { instrument: { name: "DrumMachine", machine: "909" }, to: "glue",
				play: [ { name: "a", steps: { kick: "x...x...x...x...", hat: "..x...x...x...x." } } ] },
			lead: { instrument: "pluck", sends: { glue: -6 }, play: [ { name: "a", notes: "C5 E5 G5 -" } ] },
			pad: { instrument: "pad", key: "drums", effects: [ { name: "Compressor", threshold: -40, ratio: 20, attack: 0.001, release: 0.1 } ],
				play: [ { name: "a", chords: true } ] } } }`, &arena)
	testing.expect(t, !has_finding(s, "bad_value"))
	drums, lead, pad := song.part_index(s, "drums"), song.part_index(s, "lead"), song.part_index(s, "pad")
	glue := song.node_from_name(s, "glue")
	master := song.master_node(s)
	testing.expect(t, glue >= 0 && s.nodes[glue].kind == .Bus)
	// drums go to the bus, not the master; the lead goes to both
	testing.expect(t, has_edge(s, song.part_node(s, drums), glue, .Audio))
	testing.expect(t, !has_edge(s, song.part_node(s, drums), master, .Audio))
	testing.expect(t, has_edge(s, song.part_node(s, lead), glue, .Audio))
	testing.expect(t, has_edge(s, song.part_node(s, lead), master, .Audio))
	testing.expect(t, has_edge(s, glue, master, .Audio))
	// the pad's tracks hear the drums as their key
	keyed := false
	for tr, i in s.tracks {
		if int(tr.part) == pad {
			keyed ||= has_edge(s, song.part_node(s, drums), i32(i), .Key)
		}
	}
	testing.expect(t, keyed)
	out := output_from_song(s, {stems = true, threads = 2})
	defer output_destroy(&out)
	testing.expect_value(t, len(out.stems), stem_count(s))
	testing.expect_value(t, stem_count(s), len(s.parts) + len(s.returns) + 1)
	// the master sums the parts it takes, the returns and the bus: the
	// drums' stem goes in through the bus only
	worst: f32
	for i in 0 ..< out.frames {
		sum: f32
		for st, p in out.stems {
			if p != drums {
				sum += st[0][i]
			}
		}
		worst = max(worst, abs(sum - out.left[i]))
	}
	testing.expectf(t, worst < 1e-5, "the master's inputs differ from the mix by %f", worst)
	// keyed by the drums, the pad dips on the kicks: quieter on the beat
	// than the same pad keyed by itself
	unkeyed := compose_text(t, `{ bpm: 120, sections: [ { name: "a", duration: "2m" } ],
		parts: {
			drums: { instrument: { name: "DrumMachine", machine: "909" }, play: [ { name: "a", steps: { kick: "x...x...x...x...", hat: "..x...x...x...x." } } ] },
			lead: { instrument: "pluck", play: [ { name: "a", notes: "C5 E5 G5 -" } ] },
			pad: { instrument: "pad", effects: [ { name: "Compressor", threshold: -40, ratio: 20, attack: 0.001, release: 0.1 } ],
				play: [ { name: "a", chords: true } ] } } }`, &arena)
	other := output_from_song(unkeyed, {stems = true, threads = 2})
	defer output_destroy(&other)
	beat := RATE / 2 // 120 bpm
	energy :: proc(x: []f32) -> f32 {
		e: f32
		for v in x {
			e += v * v
		}
		return e
	}
	on_k, off_k, on_u, off_u: f32
	for b in 1 ..< 7 {
		at := b * beat
		on_k += energy(out.stems[pad][0][at:][:1200])
		off_k += energy(out.stems[pad][0][at + beat / 2:][:1200])
		on_u += energy(other.stems[song.part_index(unkeyed, "pad")][0][at:][:1200])
		off_u += energy(other.stems[song.part_index(unkeyed, "pad")][0][at + beat / 2:][:1200])
	}
	testing.expectf(t, on_k / off_k < 0.7 * (on_u / off_u), "keyed %f vs itself %f (on/off the beat)", on_k / off_k, on_u / off_u)
}

// A loop loses only the edge that closes it, named as the spec names its
// nodes: the bus loop is cut once, and a part beside it still reaches the
// master, heard.
@(test)
test_route_loop :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose_text(t, `{ bpm: 120, sections: [ { name: "a", duration: "1m" } ],
		buses: { x: { to: "y" }, y: { to: "x" } },
		parts: {
			looped: { instrument: "pluck", to: "x", play: [ { name: "a", notes: "C5 E5" } ] },
			heard: { instrument: "pluck", play: [ { name: "a", notes: "G5 - - -" } ] } } }`, &arena)
	out := output_from_song(s, {stems = true, threads = 1})
	defer output_destroy(&out)
	loops := 0
	named := false
	for f in s.findings {
		if f.code == "routing_loop" {
			loops += 1
			named ||= strings.contains(f.message, "bus x") && strings.contains(f.message, "bus y")
		}
	}
	testing.expect_value(t, loops, 1)
	testing.expectf(t, named, "the finding names the buses")
	heard := out.stems[song.part_index(s, "heard")]
	testing.expect(t, peak_from_samples(heard[0], heard[1]) > 0.01)
	testing.expectf(t, peak_from_samples(out.left, out.right) > 0.01, "the master is silent")
}

// A return sleeps once its input has been silent for its tail and wakes on
// the next sound, fresh: the same samples whatever blocks the song streams
// in, and nothing in the long silence between.
@(test)
test_return_sleeps :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose_text(t, `{ bpm: 120, sections: [ { name: "a", duration: "1m" }, { name: "gap", duration: "4m" }, { name: "b", duration: "1m" } ],
		returns: { hall: [ { name: "Reverb", decay: 0.5 } ] },
		parts: { lead: { instrument: "pluck", sends: { hall: -6 }, play: [ { name: "a", notes: "C5" }, { name: "b", notes: "E5" } ] } } }`, &arena)
	whole := output_from_song(s, {threads = 1, segment = 1000})
	defer output_destroy(&whole)
	e: Engine
	testing.expect(t, engine_init(&e, s))
	defer engine_destroy(&e)
	l := make([]f32, whole.frames, context.temp_allocator)
	r := make([]f32, whole.frames, context.temp_allocator)
	for at := 0; at < whole.frames; at += 333 {
		n := min(333, whole.frames - at)
		engine_process(&e, l[at:][:n], r[at:][:n])
	}
	same := true
	for i in 0 ..< whole.frames {
		same &&= l[i] == whole.left[i] && r[i] == whole.right[i]
	}
	testing.expect(t, same)
	// the middle of the gap is silence: the hall slept
	mid := int(5 * RATE)
	quiet := peak_from_samples(whole.left[mid:][:RATE], whole.right[mid:][:RATE])
	testing.expectf(t, quiet == 0, "%f in the gap", quiet)
	testing.expect(t, peak_from_samples(whole.left[int(10 * RATE):][:RATE / 2], whole.right[int(10 * RATE):][:RATE / 2]) > 0.001)
}

// Paths of different latency line up where they meet: a part through a
// lookahead limiter bus and a part straight to the master hit together.
@(test)
test_route_latency :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose_text(t, `{ bpm: 120, sections: [ { name: "a", duration: "1m" } ],
		buses: { brick: { effects: [ { name: "Limiter", threshold: -3 } ] } },
		parts: {
			a: { instrument: { name: "DrumMachine", machine: "909" }, to: "brick", play: [ { name: "a", steps: { rim: "....x..........." } } ] },
			b: { instrument: { name: "DrumMachine", machine: "909" }, play: [ { name: "a", steps: { rim: "....x..........." } } ] } } }`, &arena)
	out := output_from_song(s, {stems = true, threads = 1})
	defer output_destroy(&out)
	first :: proc(x: []f32) -> int {
		for v, i in x {
			if abs(v) > 1e-4 {
				return i
			}
		}
		return -1
	}
	bus := int(song.node_from_name(s, "brick")) - len(s.tracks)
	through, straight := first(out.stems[bus][0]), first(out.stems[song.part_index(s, "b")][0])
	testing.expectf(t, through > 0 && abs(through - straight) <= 1, "through the limiter at %d, straight at %d", through, straight)
}

// Every stem has a name a file can take: the parts by theirs, the returns
// and buses by kind and name, as many as stem_count.
@(test)
test_stem_names :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose_text(t, `{ bpm: 120, sections: [ { name: "a", duration: "1m" } ],
		returns: { hall: [ { name: "Reverb", decay: 1 } ] },
		buses: { glue: {} },
		parts: { lead: { instrument: "pluck", to: "glue", sends: { hall: -6 }, play: [ { name: "a", notes: "C5" } ] } } }`, &arena)
	names := make([dynamic]string, context.temp_allocator)
	for p in 0 ..< stem_count(s) {
		append(&names, stem_name(s, p))
	}
	testing.expect_value(t, len(names), len(s.parts) + 2)
	testing.expect_value(t, names[song.part_index(s, "lead")], "lead")
	testing.expect_value(t, names[len(s.parts)], "return-hall")
	testing.expect_value(t, names[len(s.parts) + 1], "bus-glue")
}

// A bus keyed by a part: its compressor hears the kick, so what goes
// through the bus ducks on every beat (the pump), and the kick itself
// doesn't go through it.
@(test)
test_bus_key :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose_text(t, `{ bpm: 120, gain_db: 0, sections: [ { name: "a", duration: "2m" } ],
		buses: { pump: { key: "kick", effects: [ { name: "Compressor", threshold: -40, ratio: 20, attack: 0.001, release: 0.05, knee: 0 } ] } },
		parts: {
			kick: { instrument: { name: "DrumMachine", machine: "909" }, play: [ { name: "a", steps: { kick: "x...x...x...x..." } } ] },
			pad: { instrument: { name: "Synth", oscillator: { type: "sawtooth" }, envelope: { attack: 0.01, sustain: 1, release: 0.1 } }, to: "pump",
				play: [ { name: "a", notes: "C4", subdivision: "1m" } ] } } }`, &arena)
	testing.expect(t, !has_finding(s, "bad_value"))
	kick, pump := song.part_node(s, song.part_index(s, "kick")), song.node_from_name(s, "pump")
	testing.expect(t, pump >= 0 && has_edge(s, kick, pump, .Key))
	testing.expect(t, !has_edge(s, kick, pump, .Audio))
	out := output_from_song(s, {stems = true, threads = 1})
	defer output_destroy(&out)
	bus := out.stems[stem_count(s) - 1] // the buses come last
	rms :: proc(x: []f32) -> f32 {
		sum: f32
		for v in x {
			sum += v * v
		}
		return math.sqrt(sum / f32(len(x)))
	}
	// the second beat (0.5 s): ducked just after the kick, back up before the next
	beat := RATE / 2
	ducked := rms(bus[0][beat + RATE / 100:][:RATE / 50])
	open := rms(bus[0][beat + RATE * 4 / 10:][:RATE / 50])
	testing.expectf(t, ducked < 0.5 * open, "ducked %f, open %f", ducked, open)
}
