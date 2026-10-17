package odawg_spec

import "core:mem/virtual"
import "core:testing"
import base "../base"
import dsp "../dsp"

@(private = "file")
find :: proc(fs: base.Findings, code, path: string) -> bool {
	for f in fs {
		if f.code == code && f.path == path {
			return true
		}
	}
	return false
}

// One walk reads every record: unknown keys warn at their `/` path, values
// of the wrong kind are errors, and the tables fill (plays, lanes, tokens).
@(test)
test_read :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	s: Spec
	fs := make(base.Findings)
	ok := spec_from_json(`{ bpm: 100, colour: "red", sections: [ { name: "a", duration: "4m", bmp: 3, energy: "high" } ],
		parts: { lead: { play: [ { name: "a", notes: ["E5", ["G5", "A5"], false] }, { name: "a", steps: { kick: "x..." }, notes: "C4" } ] } } }`, &s, &fs)
	testing.expect(t, ok)
	testing.expect(t, find(fs, "unknown_key", "song/colour"))
	testing.expect(t, find(fs, "unknown_key", "song/sections/1/bmp"))
	testing.expect(t, find(fs, "bad_value", "song/sections/1/energy"))
	testing.expect_value(t, len(s.plays), 1) // the second plays two patterns: refused
	testing.expect(t, find(fs, "bad_value", "song/parts/lead/play/2"))
	p := s.plays[0]
	testing.expect_value(t, p.kind, Play_Kind.Notes)
	testing.expect_value(t, p.slots, 3)
	toks := s.tokens[p.rows.first:base.span_end(p.rows)]
	testing.expect_value(t, len(toks), 4)
	testing.expect(t, toks[1].text == "G5" && toks[1].at == 1 && toks[1].length == 0.5)
	testing.expect(t, toks[3].text == "." && toks[3].at == 2)
}

// A device is read from dsp's tables alone: nested options by `/` path among
// the params its kind reads, a string for a table's type, Tone lengths kept
// in beats until the part's tempo is known, defaults for the rest.
@(test)
test_devices :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	s: Spec
	fs := make(base.Findings)
	spec_init(&s)
	r := Reader{&s, &fs}
	d := device_from_value(&r, map_value(`{ name: "MonoSynth", oscillator: { type: "fatsawtooth", count: 5 }, envelope: { release: "8n" }, filter: { cutoff: 3 } }`), "x")
	testing.expect(t, d >= 0)
	testing.expect(t, find(fs, "unknown_key", "x/filter/cutoff"))
	p, _ := params_from_device(&s, d, 0.5)
	testing.expect_value(t, dsp.Wave(p[.Oscillator_Type]), dsp.Wave.Fat_Sawtooth)
	testing.expect_value(t, p[.Oscillator_Count], 5)
	testing.expect_value(t, p[.Envelope_Release], 0.25) // half a beat at 0.5 s a beat
	testing.expect_value(t, p[.Envelope_Attack], 0.005) // Tone's default
	n := device_from_value(&r, map_value(`{ name: "NoiseSynth", noise: "pink" }`), "y")
	pn, _ := params_from_device(&s, n, 0.5)
	testing.expect_value(t, dsp.Noise_Type(pn[.Noise_Type]), dsp.Noise_Type.Pink)
	testing.expect_value(t, device_from_value(&r, map_value(`"Theremin"`), "z"), -1)
}

@(private = "file")
map_value :: proc(text: string) -> json_value {
	v, _ := json_parse(text)
	return v
}
