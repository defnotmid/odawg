// A node kind a host adds to odawg without changing it: registered before
// specs are read, through the call the built-ins use, and then a row plays
// it like any of them.
package odawg_registry_test

import "base:runtime"
import "core:math"
import "core:mem/virtual"
import "core:testing"
import base "../../base"
import device "../../device"
import render "../../render"
import song "../../song"
import spec "../../spec"

// Bitcrush: its input held to `bits` of resolution (2^bits levels over -1..1).
BITCRUSH: device.Node_Kind

@(init)
register :: proc "contextless" () {
	context = runtime.default_context()
	BITCRUSH = device.register_node(&device.NODES, {
		name = "Bitcrush", inputs = 1, process = process_bitcrush,
		fields = {{name = "bits", unit = .Number, default = 4}},
	})
}

process_bitcrush :: proc(c: ^device.Node_Call) {
	for &lane in c.lanes {
		bits := device.node_value(c, &lane, device.slot_of(c, 0))
		steps := math.pow(2, bits - 1)
		in_l, in_r := device.node_input(c, &lane, 0)
		l, r := device.node_out(c, &lane)
		for i in 0 ..< len(l) {
			l[i] = math.round(in_l[i] * steps) / steps
		}
		if c.node.stereo {
			for i in 0 ..< len(r) {
				r[i] = math.round(in_r[i] * steps) / steps
			}
		}
	}
}

// A row over the host's kind composes and renders, every sample one of the
// crushed levels (times the out's level).
@(test)
test_host_kind :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(`{ bpm: 120, gain_db: 0, sections: [ { name: "a", duration: "1m" } ],
		parts: { p: { instrument: { velocity: "none", nodes: {
			tone: { class: "Osc", wave: "sine" },
			out: { class: "Bitcrush", input: "tone", bits: 2 } } },
			play: [ { name: "a", notes: "A4 - - -" } ] } } }`, sp, &findings))
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s))
	for f in s.findings {
		testing.expectf(t, f.severity != .Error, "%s: %s", f.code, f.message)
	}
	out := render.output_from_song(s, {threads = 1})
	defer render.output_destroy(&out)
	testing.expect(t, render.peak_from_samples(out.left, out.right) > 0.1)
	// 2 bits: -1, -0.5, 0, 0.5, 1 (the mix's master and pan leave the steps' ratios)
	levels := make(map[f32]bool, context.temp_allocator)
	for v in out.left[:int(0.5 * device.RATE)] {
		levels[v] = true
	}
	testing.expectf(t, len(levels) <= 5, "%d levels, not at most 5", len(levels))
}
