package odawg_spec

import "base:runtime"
import "core:mem/virtual"
import "core:reflect"
import "core:testing"
import base "../base"
import device "../device"
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

// An instrument is a row: a built-in one's options by Tone's paths (a
// string for a table's type, Tone lengths in beats until the part's tempo is
// known), the rest its nodes' defaults; an option it hasn't is a finding at
// the part, and a name that isn't an instrument too. An effect is still a
// device from its table.
@(test)
test_rows :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	s: Spec
	fs := make(base.Findings)
	testing.expect(t, spec_from_json(`{ parts: {
		x: { instrument: { name: "MonoSynth", oscillator: { type: "fatsawtooth", count: 5 }, envelope: { release: "8n" }, filter: { cutoff: 3 } } },
		y: { instrument: { name: "NoiseSynth", noise: "pink" } },
		z: { instrument: "Theremin" },
		w: { instrument: "Synth", effects: [ { name: "Reverb", decay: 3 } ] } } }`, &s, &fs))
	progs: device.Programs
	at :: proc(s: ^Spec, part: string) -> i32 {
		for p in s.parts {
			if p.name == part {
				return p.instrument
			}
		}
		return -1
	}
	node :: proc(progs: ^device.Programs, program: i32, kind: string) -> ^device.Graph_Node {
		p := progs.programs[program]
		for &n in progs.nodes[p.nodes.first:base.span_end(p.nodes)] {
			if device.node_row(n.kind).name == kind {
				return &n
			}
		}
		return nil
	}
	x := instrument_program(&s, at(&s, "x"), 0.5, nil, &progs, &fs)
	testing.expect(t, x >= 0)
	testing.expect(t, find(fs, "unknown_key", "parts/x/instrument/filter/cutoff"))
	osc := node(&progs, x, "Osc")
	testing.expect_value(t, dsp.Wave(osc.values[3]), dsp.Wave.Fat_Sawtooth)
	testing.expect_value(t, osc.values[4], 5)
	testing.expect(t, osc.stereo)
	release := 0
	for &n in progs.nodes[progs.programs[x].nodes.first:base.span_end(progs.programs[x].nodes)] {
		if device.node_row(n.kind).name == "Env" && n.values[6] == 0.25 { // half a beat at 0.5 s a beat
			release += 1
		}
	}
	testing.expect_value(t, release, 1)
	y := instrument_program(&s, at(&s, "y"), 0.5, nil, &progs, &fs)
	testing.expect_value(t, dsp.Noise_Type(node(&progs, y, "Noise").values[3]), dsp.Noise_Type.Pink)
	testing.expect_value(t, instrument_program(&s, at(&s, "z"), 0.5, nil, &progs, &fs), -1)
	testing.expect(t, find(fs, "unknown_instrument", "parts/z/instrument"))
	for p in s.parts {
		if p.name == "w" {
			testing.expect_value(t, s.devices[s.chain[p.effects.first]].kind, device.Device_Kind.Reverb)
		}
	}
}

// A row's meaning doesn't hang on the order of its keys: the same nodes
// written in any order place into the same program (only what reads what
// orders them).
@(test)
test_row_order :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	orders := [?]string {
		`{ parts: { a: { instrument: { nodes: { out: { class: "Filter", input: "saw", frequency: { base: 300, by: "env", octaves: 3 }, amp: "env" }, env: { class: "Env", decay: 0.3 }, saw: { class: "Osc", wave: "sawtooth" }, lfo: { class: "Lfo", rate: 5 }, vib: { class: "Mix", inputs: ["lfo"] } } } } } }`,
		`{ parts: { a: { instrument: { nodes: { saw: { class: "Osc", wave: "sawtooth" }, vib: { class: "Mix", inputs: ["lfo"] }, env: { class: "Env", decay: 0.3 }, lfo: { class: "Lfo", rate: 5 }, out: { amp: "env", frequency: { by: "env", octaves: 3, base: 300 }, input: "saw", class: "Filter" } } } } } }`,
	}
	got: [2][dynamic]device.Graph_Node
	for text, k in orders {
		s: Spec
		fs := make(base.Findings)
		testing.expect(t, spec_from_json(text, &s, &fs))
		progs: device.Programs
		p := instrument_program(&s, s.parts[0].instrument, 0.5, nil, &progs, &fs)
		testing.expect(t, p >= 0)
		got[k] = progs.nodes
		testing.expect_value(t, progs.programs[p].nodes.count, 3) // the unheard lfo and vib left out
	}
	testing.expect_value(t, len(got[0]), len(got[1]))
	for n, i in got[0] {
		testing.expectf(t, n == got[1][i], "node %d differs", i)
	}
}

@(private = "file")
map_value :: proc(text: string) -> json_value {
	v, _ := json_parse(text)
	return v
}

// spec_init hands every table of a Spec the allocator it is given (one it
// missed would grow on whatever context.allocator is when it first grows).
@(test)
test_spec_init_allocator :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	s: Spec
	spec_init(&s, a)
	for f in reflect.struct_fields_zipped(Spec) {
		if _, table := runtime.type_info_base(f.type).variant.(runtime.Type_Info_Dynamic_Array); !table {
			continue
		}
		raw := (^runtime.Raw_Dynamic_Array)(uintptr(&s) + f.offset)
		testing.expectf(t, raw.allocator.procedure == a.procedure && raw.allocator.data == a.data, "spec_init leaves %s on another allocator", f.name)
	}
}
