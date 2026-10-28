package odawg_device

import "core:math"
import "core:slice"
import "core:strings"
import base "../base"

// Compiling an instrument. A Program_Desc is a row as plain data: its nodes
// by name, what each reads and what moves its fields, its controls (knobs);
// or a machine's pads. compile_program places it into Programs:
//
//   - its nodes sorted by what they read (the lowest name first among those
//     ready, so the order they were given in means nothing), those the out
//     doesn't hear left out, their outputs in buffers handed out by
//     liveness, their state laid out;
//   - its controls' targets found (by name, a part ending `*` a prefix) and
//     the values given set (control_apply, the path a host's knob takes);
//   - then what follows from the values (program_derive): what is stereo,
//     steady, has a level; the modulators' coefficients.
//
// spec reads a row of JSON into one (its times already seconds, its sets
// the bank's); a host or an agent can build one in memory.

// How a modulator was written: its op and coefficients follow from it and
// its amount a (mod_coefficients).
Mod_Kind :: enum u8 {
	Amount, // + a m (on a level: × (1 + a m), an accent's lift)
	Octaves, // × 2^(a m)
	Sweep, // linearly in Hz from b to a octaves above it (Tone's FrequencyEnvelope)
	Index, // + a b m (Tone's FM index)
	Depth, // a gain: b (1 - a + a m), a -1..1 source taken to 0..1
	At_Most, // toward min(v, a) by m (an accent's shorter decay)
}

// A modulator's fields as written (`{ by, octaves = 2 }`); ratio is octaves
// as a frequency ratio.
Mod_Field :: enum u8 {
	None,
	Amount,
	Octaves,
	Ratio,
	Sweep,
	Index,
	Depth,
	At_Most,
	Exponent,
}

MOD_FIELD_NAMES := [Mod_Field]string {
	.None     = "",
	.Amount   = "amount",
	.Octaves  = "octaves",
	.Ratio    = "ratio",
	.Sweep    = "sweep",
	.Index    = "index",
	.Depth    = "depth",
	.At_Most  = "at_most",
	.Exponent = "exponent",
}

@(private = "file")
MOD_FIELD_KIND := [Mod_Field]Mod_Kind {
	.None     = .Amount,
	.Amount   = .Amount,
	.Octaves  = .Octaves,
	.Ratio    = .Octaves,
	.Sweep    = .Sweep,
	.Index    = .Index,
	.Depth    = .Depth,
	.At_Most  = .At_Most,
	.Exponent = .Amount,
}

mod_field_from_name :: proc(name: string) -> (Mod_Field, bool) {
	for n, f in MOD_FIELD_NAMES {
		if f != .None && n == name {
			return f, true
		}
	}
	return .None, false
}

// A modulator's field set to v (its kind too, but for the exponent).
mod_field_set :: proc(m: ^Mod_Desc, f: Mod_Field, v: f32) {
	switch f {
	case .None:
	case .Exponent:
		m.exponent = v
	case .Ratio:
		m.kind, m.amount = .Octaves, f32(math.log2(max(f64(v), 1e-6)))
	case .Amount, .Octaves, .Sweep, .Index, .Depth, .At_Most:
		m.kind, m.amount = MOD_FIELD_KIND[f], v
	}
}

Mod_Desc :: struct {
	slot:     int, // the field it moves (node_field_from_name)
	source:   string, // a node's name, or a note's (velocity, accent, slide, gate)
	kind:     Mod_Kind,
	amount:   f32,
	exponent: f32, // m^exponent (0: 1)
	path:     string, // where it was written (its findings')
}

Node_Desc :: struct {
	name:   string,
	kind:   Node_Kind,
	values: [MAX_FIELDS]f32, // node_defaults(kind) and what was written: seconds, Hz, gain linear
	inputs: []string,
	mods:   []Mod_Desc,
	path:   string,
}

// A node's table (a Curve's points, CURVE_POINTS): placed in
// Programs.tables, its kind's .Table field set to where.
Table_Desc :: struct {
	node:   string, // its name
	points: []f32,
}

Pad_Desc :: struct {
	name:    string,
	key:     f32, // NaN: its General MIDI name's, else the lowest key no other pad has
	gain:    base.Gain,
	chokes:  []string, // the pads it cuts
	program: ^Program_Desc,
	path:    string,
}

// A layer of a layered program (an SFZ region): the program it plays and
// the conditions a note must meet for it (Layer_Row's), every one meeting
// them sounding.
Layer_Desc :: struct {
	program: ^Program_Desc,
	region:  Layer_Region, // its conditions
	gain:    f32, // its level (0: 1)
	path:    string,
}

// A named key of a program's own (a Sampler's set's pads).
Key_Desc :: struct {
	name: string,
	key:  f32,
}

// How a control's value x (value scale + offset) sets a target from its
// base b: x, b x, b + x, b 2^x. On gain_db x is dB for set and add.
Control_Op :: enum u8 {
	Set,
	Mul,
	Add,
	Octaves,
}

Target_Desc :: struct {
	path:   string, // node/field, node/field/modulator's field, pads/pad/node/...; a part ending `*` is a prefix
	op:     Control_Op,
	scale:  f32, // 0: 1
	offset: f32,
}

Control_Desc :: struct {
	name:    string,
	targets: []Target_Desc,
	value:   f32,
	given:   bool, // value set (else it is read back from its first target)
	fixed:   bool, // read once, at compile (an SFZ's CC): a change after is refused
	path:    string,
}

Program_Desc :: struct {
	nodes:      []Node_Desc,
	pads:       []Pad_Desc, // a machine (and no nodes)
	layers:     []Layer_Desc, // a layered instrument (and no nodes): every layer a note meets sounds
	tables:     []Table_Desc, // its nodes' tables
	keys:       []Key_Desc,
	controls:   []Control_Desc,
	out:        string, // the node it plays
	length:     f32, // seconds (0: the gate and its nodes' tails)
	portamento: f32,
	note:       f32,
	mono:       bool,
	velocity:   bool, // the out follows the note's velocity
	one_shot:   bool, // its notes play to their end whatever the gate
	sw_lo, sw_hi, sw_default: u8, // 1 + a layered instrument's keyswitch keys and default (0: none)
	effect:     bool, // an effect row: nodes over its Input, no note, on the song's clock (rows.odin)
	path:       string, // where its nodes or pads were written
}

// A target of a control in Programs: a node's field (mod -1) or one of its
// modulators' fields.
Control_Target :: struct {
	node:   i32, // into Programs.nodes
	mod:    i32, // into Programs.mods (-1: the field itself)
	slot:   u8,
	field:  Mod_Field, // a modulator's
	op:     Control_Op,
	base:   f32, // the value it was compiled with
	scale:  f32,
	offset: f32,
}

Control_Row :: struct {
	name:    u32, // base.name_id of its name
	value:   f32,
	targets: Span, // into Programs.control_targets
	fixed:   bool, // read at compile: a change after is refused (until automation)
}

// Places desc into progs; its program's index (-1: it can't play, the
// findings say why).
compile_program :: proc(progs: ^Programs, desc: ^Program_Desc, findings: ^base.Findings) -> i32 {
	prog := Program {
		length     = desc.length,
		portamento = desc.portamento,
		note       = desc.note,
		mono       = desc.mono,
		velocity   = desc.velocity,
		one_shot   = desc.one_shot,
	}
	for &n in desc.nodes {
		node_desc_resolve(&n)
	}
	id: i32
	if desc.effect && (len(desc.layers) > 0 || len(desc.pads) > 0) {
		base.report(findings, "bad_value", .Error, desc.path, "%s: an effect row plays nodes over its Input, not pads or layers", desc.path)
		return -1
	}
	if len(desc.layers) > 0 {
		if len(desc.nodes) > 0 || len(desc.pads) > 0 {
			base.report(findings, "bad_value", .Error, desc.path, "%s: a row plays nodes, pads or layers, one of them", desc.path)
			return -1
		}
		id = compile_layers(progs, desc, prog, findings)
	} else if len(desc.pads) > 0 {
		if len(desc.nodes) > 0 {
			base.report(findings, "bad_value", .Error, desc.path, "%s: a row plays nodes or pads, not both", desc.path)
			return -1
		}
		id = compile_machine(progs, desc, prog, findings)
	} else {
		id = compile_nodes(progs, desc, prog, findings)
	}
	if id < 0 {
		return -1
	}
	compile_controls(progs, id, desc, findings)
	program_derive(progs, id)
	return id
}

// Where a name a node reads is: a node's index in desc, a note's source
// (-1 - its buffer), or min(int): neither.
@(private = "file")
read_index :: proc(desc: ^Program_Desc, name: string) -> int {
	for n, i in desc.nodes {
		if n.name == name {
			return i
		}
	}
	if k, reserved := slice.linear_search(RESERVED_NAMES[:], name); reserved {
		return -1 - k
	}
	return min(int)
}

@(private = "file")
compile_nodes :: proc(progs: ^Programs, desc: ^Program_Desc, prog: Program, findings: ^base.Findings) -> i32 {
	prog := prog
	path := desc.path
	nodes := desc.nodes
	out := read_index(desc, desc.out)
	if out < 0 {
		base.report(findings, "no_out", .Error, path, "%s: no node %q to play (give `out`, or name a node `out`)", path, desc.out)
		return -1
	}
	// what each node reads: its inputs and its modulators' sources
	ok := true
	reads := make([][dynamic]int, len(nodes), context.temp_allocator)
	check :: proc(desc: ^Program_Desc, name, path: string, reads: ^[dynamic]int, findings: ^base.Findings) -> bool {
		k := read_index(desc, name)
		if k == min(int) {
			base.report(findings, "unknown_input", .Error, path, "%s: the row has no node %q (nor is it velocity, accent, slide or gate)", path, name)
			return false
		}
		if k < 0 && desc.effect {
			base.report(findings, "effect_reads_note", .Error, path, "%s: an effect row plays no note, so it has no %s (its Input is what it is put on)", path, name)
			return false
		}
		if k >= 0 {
			append(reads, k)
		}
		return true
	}
	for &n, i in nodes {
		reads[i] = make([dynamic]int, context.temp_allocator)
		row := node_row(n.kind)
		if row.inputs >= 0 && len(n.inputs) != row.inputs {
			base.report(findings, "bad_value", .Error, n.path, "%s: %s reads %d input%s, not %d", n.path, row.name, row.inputs, row.inputs == 1 ? "" : "s", len(n.inputs))
			ok = false
		}
		if row.inputs < 0 && len(n.inputs) == 0 {
			base.report(findings, "bad_value", .Error, n.path, "%s: a %s needs its inputs", n.path, row.name)
			ok = false
		}
		// what it plays from: a note (an effect row has none), what an effect
		// is put on (an instrument has nothing)
		if row.needs == .Note && desc.effect {
			base.report(findings, "effect_reads_note", .Error, n.path, "%s: %s plays from a note's start or pitch, and an effect row plays no note (an Lfo, a Follower or its Input move it)", n.path, row.name)
			ok = false
		}
		if row.needs == .Input && !desc.effect {
			base.report(findings, "bad_value", .Error, n.path, "%s: %s is what an effect row is put on; an instrument has none (name the row in an `effects` table)", n.path, row.name)
			ok = false
		}
		// an effect row's phases are the song clock's: what sets their pace
		// can't move
		for m in n.mods {
			if f := field_of_slot(n.kind, m.slot); f != nil && f.pace && desc.effect {
				base.report(findings, "fixed_value", .Error, m.path, "%s: an effect row's %s %s can't move: its phase runs on the song clock, so a seek lands where a render from the start is", m.path, row.name, f.name)
				ok = false
			}
		}
		// every one checked (each a finding), not only up to the first bad one
		for name in n.inputs {
			found := check(desc, name, base.path_join(n.path, "inputs"), &reads[i], findings)
			ok = ok && found
		}
		for m in n.mods {
			found := check(desc, m.source, base.path_join(m.path, "by"), &reads[i], findings)
			ok = ok && found
		}
	}
	if !ok {
		return -1
	}
	// the nodes the out hears, each after what it reads (the lowest name
	// first among those ready)
	heard := make([]bool, len(nodes), context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	append(&stack, out)
	for len(stack) > 0 {
		k := pop(&stack)
		if heard[k] {
			continue
		}
		heard[k] = true
		append(&stack, ..reads[k][:])
	}
	by_name := make([]int, len(nodes), context.temp_allocator)
	for i in 0 ..< len(nodes) {
		by_name[i] = i
	}
	context.user_ptr = desc
	slice.sort_by(by_name, proc(a, b: int) -> bool {
		d := (^Program_Desc)(context.user_ptr)
		return d.nodes[a].name < d.nodes[b].name
	})
	order := make([dynamic]int, context.temp_allocator)
	placed := make([]bool, len(nodes), context.temp_allocator)
	for {
		next := -1
		for i in by_name {
			if !heard[i] || placed[i] {
				continue
			}
			ready := true
			for k in reads[i] {
				ready &&= placed[k]
			}
			if ready {
				next = i
				break
			}
		}
		if next < 0 {
			break
		}
		placed[next] = true
		append(&order, next)
	}
	heard_count := 0
	for h in heard {
		heard_count += h ? 1 : 0
	}
	if len(order) < heard_count {
		names := make([dynamic]string, context.temp_allocator)
		for i in by_name {
			if heard[i] && !placed[i] {
				append(&names, nodes[i].name)
			}
		}
		base.report(findings, "voice_cycle", .Error, path, "%s: %s read each other in a loop", path, strings.join(names[:], ", ", context.temp_allocator))
		return -1
	}
	if len(order) > MAX_NODES {
		base.report(findings, "voice_too_big", .Error, path, "%s: %d nodes play; a voice plays at most %d", path, len(order), MAX_NODES)
		return -1
	}
	// buffers by liveness: a node's output is free again after its last reader
	position := make([]int, len(nodes), context.temp_allocator)
	last := make([]int, len(nodes), context.temp_allocator)
	for i, at in order {
		position[i] = at
		last[i] = at
	}
	for i, at in order {
		for k in reads[i] {
			last[k] = max(last[k], at)
		}
	}
	last[out] = len(order)
	buf := make([]u8, len(nodes), context.temp_allocator)
	free := make([dynamic]u8, context.temp_allocator)
	bufs := RESERVED
	source :: proc(desc: ^Program_Desc, buf: []u8, position: []int, name: string) -> (u8, i16) {
		k := read_index(desc, name)
		if k < 0 {
			return u8(-1 - k), -1
		}
		return buf[k], i16(position[k])
	}
	prog.nodes.first = i32(len(progs.nodes))
	state := GRAPH_HEADER
	for i, at in order {
		n := &nodes[i]
		row := node_row(n.kind)
		if len(free) > 0 {
			buf[i] = pop(&free)
		} else {
			buf[i] = u8(bufs)
			bufs += 1
		}
		g := Graph_Node{kind = n.kind, name = base.name_id(n.name), values = n.values, state = i32(state), buf = buf[i]}
		if points := desc_table(desc, n.name); points != nil {
			g.values[node_table_slot(n.kind)] = f32(len(progs.tables) / CURVE_POINTS)
			append(&progs.tables, ..points)
		}
		state += (row.state + 15) &~ 15
		g.inputs = {i32(len(progs.inputs)), i32(len(n.inputs))}
		for name in n.inputs {
			b, k := source(desc, buf, position, name)
			append(&progs.inputs, Graph_Input{buf = b, node = k})
		}
		g.mods = {i32(len(progs.mods)), i32(len(n.mods))}
		for m in n.mods {
			b, k := source(desc, buf, position, m.source)
			append(&progs.mods, Mod{slot = u8(m.slot), source = b, node = k, kind = m.kind, amount = m.amount, exponent = m.exponent == 0 ? 1 : m.exponent})
		}
		append(&progs.nodes, g)
		// what it was the last reader of is free
		for k in reads[i] {
			if last[k] == at && !slice.contains(free[:], buf[k]) {
				append(&free, buf[k])
			}
		}
	}
	if state > VOICE_STATE_SIZE {
		base.report(findings, "voice_too_big", .Error, path, "%s: its nodes keep %d bytes a voice; a voice keeps at most %d", path, state, VOICE_STATE_SIZE)
		resize(&progs.nodes, int(prog.nodes.first))
		return -1
	}
	prog.nodes.count = i32(len(order))
	prog.out = i32(position[out])
	prog.state = i32(state)
	prog.bufs = i32(bufs)
	// its named keys (a Sampler's set's), each once
	prog.layers.first = i32(len(progs.layers))
	for k in desc.keys {
		id := base.name_id(k.name)
		known := false
		for pr in progs.layers[prog.layers.first:] {
			known ||= progs.pads[pr.row].pad == id
		}
		if !known {
			append(&progs.layers, Layer_Row{program = -1, gain = 1, row = i32(len(progs.pads))})
			append(&progs.pads, Layer_Pad{pad = id, key = k.key})
			prog.layers.count += 1
		}
	}
	append(&progs.programs, prog)
	return i32(len(progs.programs) - 1)
}

// A machine: its pads' programs, each at its key (its own, its General MIDI
// name's, else the lowest no other pad has) and level, with what it chokes.
@(private = "file")
compile_machine :: proc(progs: ^Programs, desc: ^Program_Desc, prog: Program, findings: ^base.Findings) -> i32 {
	m := prog
	pads := make([]^Pad_Desc, len(desc.pads), context.temp_allocator)
	for &p, i in desc.pads {
		pads[i] = &p
	}
	slice.sort_by(pads, proc(a, b: ^Pad_Desc) -> bool {return a.name < b.name})
	keys := make([]f32, len(pads), context.temp_allocator)
	used: bit_set[0 ..< 128;u128]
	for p, i in pads {
		keys[i] = p.key
		if math.is_nan(keys[i]) {
			if k, gm := gm_key(p.name); gm {
				keys[i] = k
			}
		}
		if !math.is_nan(keys[i]) && keys[i] >= 0 && keys[i] < 128 {
			used += {int(keys[i])}
		}
	}
	next := 0
	for _, i in pads {
		if !math.is_nan(keys[i]) {
			continue
		}
		for next < 127 && (next in used) {
			next += 1
		}
		keys[i] = f32(next)
		used += {next}
	}
	programs := make([]i32, len(pads), context.temp_allocator)
	state := i32(GRAPH_HEADER)
	bufs := i32(RESERVED)
	for p, i in pads {
		programs[i] = -1
		if p.program == nil {
			continue
		}
		if len(p.program.pads) > 0 {
			base.report(findings, "bad_value", .Error, p.path, "%s: a pad plays an instrument, not a machine", p.path)
			continue
		}
		programs[i] = compile_program(progs, p.program, findings)
		if programs[i] >= 0 {
			pp := &progs.programs[programs[i]]
			state = max(state, pp.state)
			bufs = max(bufs, pp.bufs)
		}
	}
	m.layers.first = i32(len(progs.layers))
	for p, i in pads {
		if programs[i] < 0 {
			continue
		}
		row := Layer_Pad{pad = base.name_id(p.name), key = keys[i]}
		row.chokes.first = i32(len(progs.chokes))
		for name in p.chokes {
			found := false
			for x in pads {
				found ||= x.name == name
			}
			if !found {
				base.report(findings, "unknown_pad", .Error, base.path_join(p.path, "choke"), "%s/choke: the machine has no pad %q", p.path, name)
				continue
			}
			append(&progs.chokes, base.name_id(name))
			row.chokes.count += 1
		}
		append(&progs.layers, Layer_Row{program = programs[i], gain = f32(p.gain), row = i32(len(progs.pads))})
		append(&progs.pads, row)
		m.layers.count += 1
	}
	m.state, m.bufs = state, bufs
	append(&progs.programs, m)
	return i32(len(progs.programs) - 1)
}

// A layered instrument: its layers' programs, one per shape (the regions
// whose programs have the same nodes, wiring and modulators share one, so
// their voices play in one call), each layer its row of conditions and the
// values where it differs from its shape's program (its zone, tuning,
// level, times, velocity table). A layer that is itself layered (an SFZ, a
// layered row) plays as its layers (layers_flat).
@(private = "file")
compile_layers :: proc(progs: ^Programs, desc: ^Program_Desc, prog: Program, findings: ^base.Findings) -> i32 {
	m := prog
	m.layer_mode = .All
	flat: Flat_Layers
	layers_flat(&flat, desc.layers, findings)
	m.sw_lo, m.sw_hi, m.sw_default = desc.sw_lo, desc.sw_hi, desc.sw_default
	if m.sw_lo == 0 {
		m.sw_lo, m.sw_hi, m.sw_default = flat.sw_lo, flat.sw_hi, flat.sw_default
	}
	layers := flat.out
	Shape :: struct {
		key:     string,
		program: i32,
	}
	shapes := make([dynamic]Shape, context.temp_allocator)
	tables := make(map[u64]f32, context.temp_allocator) // a table's contents: its index
	programs := make([]i32, len(layers), context.temp_allocator)
	state := i32(GRAPH_HEADER)
	bufs := i32(RESERVED)
	for &l, i in layers {
		programs[i] = -1
		if l.program == nil {
			continue
		}
		for &n in l.program.nodes {
			node_desc_resolve(&n)
		}
		key := desc_shape(l.program)
		for x in shapes {
			if x.key == key {
				programs[i] = x.program
			}
		}
		if programs[i] < 0 {
			programs[i] = compile_program(progs, l.program, findings)
			if programs[i] < 0 {
				continue
			}
			append(&shapes, Shape{key, programs[i]})
			// its tables, by their contents, for the layers after it: where
			// each went, read back from its node
			placed := progs.programs[programs[i]]
			for tb in l.program.tables {
				id := base.name_id(tb.node)
				for g in progs.nodes[placed.nodes.first:base.span_end(placed.nodes)] {
					if g.name == id && len(tb.points) == CURVE_POINTS {
						tables[table_hash(tb.points)] = g.values[node_table_slot(g.kind)]
					}
				}
			}
		}
		pp := &progs.programs[programs[i]]
		state = max(state, pp.state)
		bufs = max(bufs, pp.bufs)
	}
	m.layers.first = i32(len(progs.layers))
	for &l, i in layers {
		if programs[i] < 0 {
			continue
		}
		row := Layer_Row{program = programs[i], gain = l.gain != 0 ? l.gain : 1, row = i32(len(progs.regions))}
		row.params = layer_values(progs, programs[i], l.program, &tables)
		m.release_layers ||= l.region.trigger == .Release
		append(&progs.layers, row)
		append(&progs.regions, l.region)
		m.layers.count += 1
	}
	m.state, m.bufs = state, bufs
	append(&progs.programs, m)
	return i32(len(progs.programs) - 1)
}

// A layered instrument's layers as one table: a layer whose instrument is
// itself layered (an SFZ, a layered row) is its layers, each within the
// outer's conditions (layer_within) at the product of their levels, its
// groups its own (renumbered past the row's, so its off_by and polyphony
// count only its own voices), the keyswitches the union of theirs (the
// first default). The row's own layers are as written; a machine can't be
// a layer (a finding).
@(private = "file")
Flat_Layers :: struct {
	out:                      []Layer_Desc, // in temp memory
	sw_lo, sw_hi, sw_default: u8,
	next:                     i32, // the group a layered layer's next group becomes
	spaces:                   i32, // layered layers so far: each its groups' own
	groups:                   map[[2]i32]i32, // (its layered layer, its group): the table's
}

@(private = "file")
layers_flat :: proc(f: ^Flat_Layers, layers: []Layer_Desc, findings: ^base.Findings) {
	f.out = make([]Layer_Desc, layers_count(layers), context.temp_allocator)
	f.groups = make(map[[2]i32]i32, context.temp_allocator)
	for l in layers {
		f.next = max(f.next, l.region.group + 1, l.region.off_by + 1)
	}
	at := 0
	layers_fill(f, &at, layers, nil, 1, 0, findings)
	f.out = f.out[:at]
}

@(private = "file")
layers_count :: proc(layers: []Layer_Desc) -> int {
	n := 0
	for l in layers {
		n += l.program != nil && len(l.program.layers) > 0 ? layers_count(l.program.layers) : 1
	}
	return n
}

@(private = "file")
layers_fill :: proc(f: ^Flat_Layers, at: ^int, layers: []Layer_Desc, outer: ^Layer_Desc, gain: f32, space: i32, findings: ^base.Findings) {
	for &l in layers {
		x := l
		if outer != nil {
			ok: bool
			if x.region, ok = layer_within(outer.region, l.region); !ok {
				continue
			}
			x.gain = gain * (l.gain != 0 ? l.gain : 1)
			x.region.group = layer_group(f, space, l.region.group)
			if l.region.off_by != 0 {
				x.region.off_by = layer_group(f, space, l.region.off_by)
			}
		}
		switch {
		case x.program == nil:
			// nothing drafted (its finding says why)
		case len(x.program.pads) > 0:
			base.report(findings, "bad_value", .Error, l.path, "%s: a machine plays its pads by key; it can't be a layer (play it as a part of its own)", l.path)
		case len(x.program.layers) > 0:
			if r := l.region; r.group != 0 || r.off_by != 0 || r.polyphony != 0 || r.note_polyphony != 0 {
				base.report(findings, "bad_value", .Warning, l.path, "%s: its instrument is layered: its own layers' groups and polyphony play, not this layer's", l.path)
			}
			p := x.program
			if p.sw_lo != 0 {
				f.sw_lo = f.sw_lo == 0 ? p.sw_lo : min(f.sw_lo, p.sw_lo)
				f.sw_hi = max(f.sw_hi, p.sw_hi)
			}
			if f.sw_default == 0 {
				f.sw_default = p.sw_default
			}
			f.spaces += 1
			layers_fill(f, at, p.layers, &x, x.gain != 0 ? x.gain : 1, f.spaces, findings)
		case:
			f.out[at^] = x
			at^ += 1
		}
	}
}

// A layered layer's group as the table's: its own, past the row's.
@(private = "file")
layer_group :: proc(f: ^Flat_Layers, space, group: i32) -> i32 {
	key := [2]i32{space, group}
	if id, found := f.groups[key]; found {
		return id
	}
	f.groups[key] = f.next
	f.next += 1
	return f.next - 1
}

// A layer's conditions inside an outer layer's: both hold. An outer trigger
// of attack (the default) leaves the inner's; two round robins on the one
// count are one, of their lcm. False where no note can meet them.
@(private = "file")
layer_within :: proc(outer, inner: Layer_Region) -> (r: Layer_Region, ok: bool) {
	r = inner
	r.lo_key, r.hi_key = max(outer.lo_key, inner.lo_key), min(outer.hi_key, inner.hi_key)
	r.lo_vel, r.hi_vel = max(outer.lo_vel, inner.lo_vel), min(outer.hi_vel, inner.hi_vel)
	r.lo_rand, r.hi_rand = max(outer.lo_rand, inner.lo_rand), min(outer.hi_rand, inner.hi_rand)
	if r.lo_key > r.hi_key || r.lo_vel > r.hi_vel || r.lo_rand >= r.hi_rand {
		return r, false
	}
	if outer.trigger != .Attack {
		if inner.trigger != .Attack && inner.trigger != outer.trigger {
			return r, false
		}
		r.trigger = outer.trigger
	}
	if outer.sw_last_lo != 0 {
		r.sw_last_lo, r.sw_last_hi = outer.sw_last_lo, outer.sw_last_hi
		if inner.sw_last_lo != 0 {
			r.sw_last_lo, r.sw_last_hi = max(outer.sw_last_lo, inner.sw_last_lo), min(outer.sw_last_hi, inner.sw_last_hi)
			if r.sw_last_lo > r.sw_last_hi {
				return r, false
			}
		}
	}
	if outer.seq_length > 1 {
		r.seq_length, r.seq_position = outer.seq_length, outer.seq_position
		if inner.seq_length > 1 {
			a, b := int(outer.seq_length), int(inner.seq_length)
			g, x := a, b
			for x != 0 {
				g, x = x, g % x
			}
			lcm := a / g * b
			if lcm > int(max(u16)) {
				return r, false
			}
			// the one position of the lcm (if any) where both hold
			ok = false
			for p in 0 ..< lcm {
				if p % a + 1 == int(outer.seq_position) && p % b + 1 == int(inner.seq_position) {
					r.seq_length, r.seq_position, ok = u16(lcm), u16(p + 1), true
					break
				}
			}
			return r, ok
		}
	}
	return r, true
}

// What a desc's program is made of, but its values: its nodes, what each
// reads and what moves it, and what of its values decides how it is placed
// (a level, a pan, a filter's type, an oscillator's sides): programs of one
// shape are one program with different values.
@(private = "file")
desc_shape :: proc(d: ^Program_Desc) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, d.out)
	strings.write_byte(&b, d.one_shot ? 'o' : '-')
	strings.write_byte(&b, d.velocity ? 'v' : '-')
	strings.write_byte(&b, d.mono ? 'm' : '-')
	for n in d.nodes {
		strings.write_byte(&b, '|')
		strings.write_string(&b, n.name)
		strings.write_byte(&b, ':')
		strings.write_int(&b, int(n.kind))
		for x in n.inputs {
			strings.write_byte(&b, '<')
			strings.write_string(&b, x)
		}
		for m in n.mods {
			strings.write_string(&b, "~")
			strings.write_int(&b, m.slot)
			strings.write_string(&b, m.source)
			strings.write_int(&b, int(m.kind))
			strings.write_f64(&b, f64(m.amount), 'g')
			strings.write_f64(&b, f64(m.exponent), 'g')
		}
		strings.write_byte(&b, desc_table(d, n.name) != nil ? 't' : '-')
		strings.write_byte(&b, n.values[FIELD_GAIN] != 1 ? 'g' : '-')
		strings.write_byte(&b, n.values[FIELD_PAN] != 0 ? 'p' : '-')
		row := node_row(n.kind)
		for f, i in row.fields {
			if f.shapes {
				strings.write_f64(&b, f64(n.values[row.slots[i]]), 'g')
			}
		}
		if sides := node_row(n.kind).sides; sides != nil {
			v := n.values
			strings.write_byte(&b, sides(&v) ? 's' : '-')
		}
	}
	return strings.to_string(b)
}

// A node's table in its desc (nil: none, or not CURVE_POINTS long).
@(private = "file")
desc_table :: proc(d: ^Program_Desc, node: string) -> []f32 {
	for t in d.tables {
		if t.node == node && len(t.points) == CURVE_POINTS {
			return t.points
		}
	}
	return nil
}

// The slot of a kind's .Table field (-1: none).
node_table_slot :: proc(kind: Node_Kind) -> int {
	row := node_row(kind)
	for f, i in row.fields {
		if f.unit == .Table {
			return row.slots[i]
		}
	}
	return -1
}

@(private = "file")
table_hash :: proc(t: []f32) -> u64 {
	h: u64 = 0x7ab1e
	for x in t {
		h = base.hash_combine(h, u64(transmute(u32)x))
	}
	return h
}

// A layer's values where its desc differs from the program it shares (by
// its nodes' names), its tables placed (once per contents).
@(private = "file")
layer_values :: proc(progs: ^Programs, program: i32, d: ^Program_Desc, tables: ^map[u64]f32) -> Span {
	sp := Span{i32(len(progs.layer_params)), 0}
	prog := progs.programs[program]
	nodes := progs.nodes[prog.nodes.first:base.span_end(prog.nodes)]
	for n in d.nodes {
		id := base.name_id(n.name)
		for g, j in nodes {
			if g.name != id {
				continue
			}
			values := n.values
			if points := desc_table(d, n.name); points != nil {
				h := table_hash(points)
				at, placed := tables[h]
				if !placed {
					at = f32(len(progs.tables) / CURVE_POINTS)
					append(&progs.tables, ..points)
					tables[h] = at
				}
				values[node_table_slot(n.kind)] = at
			}
			for slot in 0 ..< MAX_FIELDS {
				if values[slot] != g.values[slot] {
					append(&progs.layer_params, Layer_Param{node = u16(j), slot = u8(slot), value = values[slot]})
					sp.count += 1
				}
			}
		}
	}
	return sp
}

// ---- controls ----------------------------------------------------------------------

@(private = "file")
glob_match :: proc(pattern, name: string) -> bool {
	if strings.has_suffix(pattern, "*") {
		return strings.has_prefix(name, pattern[:len(pattern) - 1])
	}
	return pattern == name
}

// The targets `parts` (a target's path, split) names in program `id`
// (compiled from desc), appended; how many.
@(private = "file")
targets_add :: proc(progs: ^Programs, id: i32, desc: ^Program_Desc, parts: []string, t: Target_Desc) -> int {
	count := 0
	prog := progs.programs[id]
	if len(parts) >= 2 && parts[0] == "pads" && len(desc.pads) > 0 {
		for &p in desc.pads {
			if !glob_match(parts[1], p.name) || p.program == nil {
				continue
			}
			pid := base.name_id(p.name)
			for pr in progs.layers[prog.layers.first:base.span_end(prog.layers)] {
				if progs.pads[pr.row].pad == pid && pr.program >= 0 {
					count += targets_add(progs, pr.program, p.program, parts[2:], t)
				}
			}
		}
		return count
	}
	if len(parts) < 2 || len(parts) > 3 {
		return 0
	}
	for n in desc.nodes {
		if !glob_match(parts[0], n.name) {
			continue
		}
		field, slot, known := node_field_from_name(n.kind, parts[1])
		if !known || field.list > 0 {
			continue
		}
		mf := Mod_Field.None
		if len(parts) == 3 {
			f, is_field := mod_field_from_name(parts[2])
			if !is_field {
				continue
			}
			mf = f
		}
		id_name := base.name_id(n.name)
		for &g, j in progs.nodes[prog.nodes.first:base.span_end(prog.nodes)] {
			if g.name != id_name {
				continue
			}
			x := Control_Target{node = prog.nodes.first + i32(j), mod = -1, slot = u8(slot), field = mf, op = t.op, scale = t.scale == 0 ? 1 : t.scale, offset = t.offset}
			if mf != .None {
				// a modulator's field: the first on that field
				for mi in g.mods.first ..< base.span_end(g.mods) {
					if int(progs.mods[mi].slot) == slot {
						x.mod = mi
						break
					}
				}
				if x.mod < 0 {
					continue
				}
			}
			x.base = control_target_value(progs, x)
			append(&progs.control_targets, x)
			count += 1
		}
	}
	return count
}

// A target's value now (a gain linear; a ratio as a ratio).
@(private = "file")
control_target_value :: proc(progs: ^Programs, t: Control_Target) -> f32 {
	if t.mod < 0 {
		return progs.nodes[t.node].values[t.slot]
	}
	m := &progs.mods[t.mod]
	#partial switch t.field {
	case .Exponent:
		return m.exponent
	case .Ratio:
		return f32(math.pow(2, f64(m.amount)))
	}
	return m.amount
}

@(private = "file")
compile_controls :: proc(progs: ^Programs, id: i32, desc: ^Program_Desc, findings: ^base.Findings) {
	progs.programs[id].controls.first = i32(len(progs.controls))
	for cd in desc.controls {
		row := Control_Row{name = base.name_id(cd.name), targets = {i32(len(progs.control_targets)), 0}, fixed = cd.fixed}
		for t in cd.targets {
			n := targets_add(progs, id, desc, strings.split(t.path, "/", context.temp_allocator), t)
			if n == 0 {
				base.report(findings, "unknown_option_target", .Warning, cd.path, "%s: %s reaches nothing in the row", cd.path, t.path)
			}
			row.targets.count += i32(n)
		}
		// a control named as a node's field: Param_Set finds the control first
		slash := strings.index_byte(cd.name, '/')
		if slash > 0 {
			same := len(cd.targets) == 1 && cd.targets[0].path == cd.name && cd.targets[0].op == .Set && (cd.targets[0].scale == 0 || cd.targets[0].scale == 1) && cd.targets[0].offset == 0
			for n in desc.nodes {
				if same || n.name != cd.name[:slash] {
					continue
				}
				if _, _, known := node_field_from_name(n.kind, cd.name[slash + 1:]); known {
					base.report(findings, "control_shadows_field", .Warning, cd.path, "%s: control %q is also a field of node %s (%s); a command by that name sets the control", cd.path, cd.name, n.name, n.path)
					base.report(findings, "control_shadows_field", .Warning, n.path, "%s: its field %s is shadowed by control %q (%s)", n.path, cd.name[slash + 1:], cd.name, cd.path)
				}
			}
		}
		append(&progs.controls, row)
		append(&progs.control_names, cd.name)
		progs.programs[id].controls.count += 1
	}
	// the values given, then the rest read back (a knob another one moved
	// shows where it left it)
	p := progs.programs[id]
	controls := progs.controls[p.controls.first:base.span_end(p.controls)]
	for &c, i in controls {
		if desc.controls[i].given {
			control_apply(progs, &c, desc.controls[i].value)
		}
	}
	for &c, i in controls {
		if !desc.controls[i].given && !c.fixed {
			c.value = control_read(progs, &c)
		}
		if c.fixed {
			c.value = desc.controls[i].value
		}
	}
}

// A control's value as its first target holds it (what a knob shows when
// the row set no value): x read back through the target's op from its base.
@(private = "file")
control_read :: proc(progs: ^Programs, c: ^Control_Row) -> f32 {
	if c.targets.count == 0 {
		return 0
	}
	t := progs.control_targets[c.targets.first]
	v := control_target_value(progs, t)
	gain := target_is_gain(progs, t)
	x: f32
	switch t.op {
	case .Set:
		x = gain ? f32(base.gain_to_db(base.Gain(v))) : v
	case .Mul:
		x = t.base != 0 ? v / t.base : 1
	case .Add:
		if gain {
			x = t.base > 0 && v > 0 ? f32(base.gain_to_db(base.Gain(v / t.base))) : 0
		} else {
			x = v - t.base
		}
	case .Octaves:
		x = t.base > 0 && v > 0 ? f32(math.log2(f64(v / t.base))) : 0
	}
	return (x - t.offset) / t.scale
}

// Whether a control's target is a field kept linear and written in dB (a
// Gain unit's): a control sets and reads it in dB.
@(private = "file")
target_is_gain :: proc(progs: ^Programs, t: Control_Target) -> bool {
	if t.mod >= 0 {
		return false
	}
	f := field_of_slot(progs.nodes[t.node].kind, int(t.slot))
	return f != nil && f.unit == .Gain
}

// Sets every target of c from value (the program's values; what follows
// from them is program_derive's).
control_apply :: proc(progs: ^Programs, c: ^Control_Row, value: f32) {
	c.value = value
	for t in progs.control_targets[c.targets.first:base.span_end(c.targets)] {
		x := value * t.scale + t.offset
		gain := target_is_gain(progs, t)
		v: f32
		switch t.op {
		case .Set:
			v = gain ? f32(base.db_to_gain(base.Db(x))) : x
		case .Mul:
			v = t.base * x
		case .Add:
			v = gain ? t.base * f32(base.db_to_gain(base.Db(x))) : t.base + x
		case .Octaves:
			v = t.base * f32(math.pow(2, f64(x)))
		}
		if t.mod < 0 {
			progs.nodes[t.node].values[t.slot] = v
			continue
		}
		m := &progs.mods[t.mod]
		d := Mod_Desc{kind = m.kind, amount = m.amount, exponent = m.exponent}
		mod_field_set(&d, t.field, v)
		m.kind, m.amount, m.exponent = d.kind, d.amount, d.exponent
	}
}

// The control of program (or of its pads' programs) named `name`.
control_of :: proc(progs: ^Programs, program: i32, name: u32) -> ^Control_Row {
	if program < 0 {
		return nil
	}
	p := progs.programs[program]
	for &c in progs.controls[p.controls.first:base.span_end(p.controls)] {
		if c.name == name {
			return &c
		}
	}
	return nil
}

// A knob turned: control `name` of program set to value, and what follows
// from it derived. False: it has no such control, or the value would change
// the program's shape (a mono node made stereo), and nothing changed.
control_set :: proc(progs: ^Programs, program: i32, name: u32, value: f32) -> bool {
	c := control_of(progs, program, name)
	if c == nil || c.fixed {
		return false
	}
	old := c.value
	control_apply(progs, c, value)
	if program_derive(progs, program) {
		control_apply(progs, c, old)
		program_derive(progs, program)
		return false
	}
	return true
}

// The control a path names in program: its own (`cutoff`), or one made for
// a field (`lp/frequency`, `lp/frequency/octaves`, `pads/kick/body/decay`:
// set as written, in the field's unit) reaching the field's nodes in the
// program and its layers' programs. -1: it names nothing there.
control_from_path :: proc(progs: ^Programs, program: i32, path: string) -> i32 {
	if program < 0 {
		return -1
	}
	p := progs.programs[program]
	for c, i in progs.controls[p.controls.first:base.span_end(p.controls)] {
		if c.name == base.name_id(path) {
			return p.controls.first + i32(i)
		}
	}
	parts := strings.split(path, "/", context.temp_allocator)
	if len(parts) < 2 {
		return -1
	}
	row := Control_Row{name = base.name_id(path), targets = {i32(len(progs.control_targets)), 0}}
	// the programs it reaches: a pad's (`pads/kick/...`), else the program
	// and every program its layers play (an SFZ's regions share theirs), once
	programs := make([dynamic]i32, context.temp_allocator)
	reach :: proc(progs: ^Programs, program: i32, pad: u32, out: ^[dynamic]i32) {
		p := progs.programs[program]
		if pad == 0 && !slice.contains(out[:], program) {
			append(out, program)
		}
		for pr in progs.layers[p.layers.first:base.span_end(p.layers)] {
			if pr.program >= 0 && pr.program != program && (pad == 0 || progs.pads[pr.row].pad == pad) {
				reach(progs, pr.program, 0, out)
			}
		}
	}
	if parts[0] == "pads" {
		if len(parts) < 4 {
			return -1
		}
		reach(progs, program, base.name_id(parts[1]), &programs)
		parts = parts[2:]
	} else {
		reach(progs, program, 0, &programs)
	}
	if len(parts) > 3 {
		return -1
	}
	mf := Mod_Field.None
	if len(parts) == 3 {
		f, is_field := mod_field_from_name(parts[2])
		if !is_field {
			return -1
		}
		mf = f
	}
	// one made for the path before (an earlier lane's or command's): that one
	for c, i in progs.controls[base.span_end(p.controls):] {
		if c.name != row.name || c.targets.count == 0 {
			continue
		}
		t := progs.control_targets[c.targets.first]
		for pi in programs {
			q := progs.programs[pi]
			if t.node >= q.nodes.first && t.node < base.span_end(q.nodes) {
				return base.span_end(p.controls) + i32(i)
			}
		}
	}
	name := base.name_id(parts[0])
	for pi in programs {
		p := progs.programs[pi]
		for &g, j in progs.nodes[p.nodes.first:base.span_end(p.nodes)] {
			field, slot, known := node_field_from_name(g.kind, parts[1])
			if g.name != name || !known || field.list > 0 {
				continue
			}
			x := Control_Target{node = p.nodes.first + i32(j), mod = -1, slot = u8(slot), field = mf, op = .Set, scale = 1}
			if mf != .None {
				for mi in g.mods.first ..< base.span_end(g.mods) {
					if int(progs.mods[mi].slot) == slot {
						x.mod = mi
						break
					}
				}
				if x.mod < 0 {
					continue
				}
			}
			x.base = control_target_value(progs, x)
			append(&progs.control_targets, x)
			row.targets.count += 1
		}
	}
	if row.targets.count == 0 {
		return -1
	}
	row.value = control_read(progs, &row)
	append(&progs.controls, row)
	append(&progs.control_names, strings.clone(path))
	return i32(len(progs.controls) - 1)
}

// Whether control c of program may move between lo and hi: it isn't read
// only at compile, and neither end changes the program's shape. Its value
// is put back.
control_moves :: proc(progs: ^Programs, program: i32, c: i32, lo, hi: f32) -> bool {
	row := &progs.controls[c]
	if row.fixed {
		return false
	}
	old := row.value
	moves := true
	for v in ([2]f32{lo, hi}) {
		control_apply(progs, row, v)
		moves &&= !program_derive(progs, program)
	}
	control_apply(progs, row, old)
	program_derive(progs, program)
	return moves
}

// The program a control moves: the one its first target is a node of (an
// option's, or a control made for a node's field; -1: it reaches nothing).
control_program :: proc(progs: ^Programs, c: i32) -> i32 {
	row := progs.controls[c]
	if row.targets.count == 0 {
		return -1
	}
	node := progs.control_targets[row.targets.first].node
	for p, i in progs.programs {
		if p.nodes.count > 0 && node >= p.nodes.first && node < base.span_end(p.nodes) {
			return i32(i)
		}
	}
	return -1
}

// The field a control reaches that an effect row reads only as its voice
// starts (`at_start`), or that sets the pace of its phase on the song clock
// (`pace`): no lane moves one in a row (nil: none).
control_pinned :: proc(progs: ^Programs, c: i32) -> ^Node_Field {
	row := progs.controls[c]
	for t in progs.control_targets[row.targets.first:base.span_end(row.targets)] {
		if t.mod >= 0 {
			continue
		}
		if f := field_of_slot(progs.nodes[t.node].kind, int(t.slot)); f != nil && (f.at_start || f.pace) {
			return f
		}
	}
	return nil
}

// A node's field (by the node's name; its pads' programs' too) set to
// value, and what follows derived. False: none, or its shape would change.
node_field_set :: proc(progs: ^Programs, program: i32, node: u32, field: string, value: f32) -> bool {
	if program < 0 {
		return false
	}
	Old :: struct {
		n: ^Graph_Node,
		slot: int,
		v: f32,
	}
	olds := make([dynamic]Old, context.temp_allocator)
	set :: proc(progs: ^Programs, program: i32, node: u32, field: string, value: f32, olds: ^[dynamic]Old) {
		p := progs.programs[program]
		for &n in progs.nodes[p.nodes.first:base.span_end(p.nodes)] {
			if n.name != node {
				continue
			}
			if f, slot, known := node_field_from_name(n.kind, field); known && f.list == 0 {
				append(olds, Old{&n, slot, n.values[slot]})
				n.values[slot] = f.unit == .Gain ? f32(base.db_to_gain(base.Db(value))) : value
			}
		}
		for pr in progs.layers[p.layers.first:base.span_end(p.layers)] {
			if pr.program >= 0 && pr.program != program {
				set(progs, pr.program, node, field, value, olds)
			}
		}
	}
	set(progs, program, node, field, value, &olds)
	if len(olds) == 0 {
		return false
	}
	if program_derive(progs, program) {
		#reverse for o in olds {
			o.n.values[o.slot] = o.v
		}
		program_derive(progs, program)
		return false
	}
	return true
}

// ---- what follows from the values --------------------------------------------------

// The field of a kind at a slot (a common one's, a kind's own, a list's).
field_of_slot :: proc(kind: Node_Kind, slot: int) -> ^Node_Field {
	if slot < len(COMMON_FIELDS) {
		return &COMMON_FIELDS[slot]
	}
	row := node_row(kind)
	for &f, i in row.fields {
		if slot >= row.slots[i] && slot < row.slots[i] + max(f.list, 1) {
			return &f
		}
	}
	return nil
}

// A modulator's op and coefficients from how it was written: on a level
// every one is a factor, and a -1..1 source there reads as 0..1.
mod_coefficients :: proc(m: ^Mod) {
	a := m.amount
	m.scaled, m.c0 = false, 0
	switch m.kind {
	case .Octaves:
		m.op, m.c1 = .Octaves, a
	case .Sweep:
		m.op, m.c1, m.scaled = .Add, f32(math.pow(2, f64(a))) - 1, true
	case .Index:
		m.op, m.c1, m.scaled = .Add, a, true
	case .Amount:
		if m.slot == FIELD_AMP {
			m.op, m.c0, m.c1 = .Mul, 1, a
		} else {
			m.op, m.c1 = .Add, a
		}
	case .Depth:
		if m.unipolar {
			m.op, m.c0, m.c1 = .Mul, 1 - a, a
		} else {
			m.op, m.c0, m.c1 = .Mul, 1 - a / 2, a / 2 // (m + 1) / 2
		}
	case .At_Most:
		m.op, m.c0 = .Cap, a
	}
}

// What follows from a program's values (its pads' programs' too), node
// after node: what each reads of two sides and writes both of, its level,
// whether it holds for the note (a steady kind, or a stateless one reading
// only what holds), its modulators' coefficients, its memory. True: a
// node's sides changed from what they were (its shape).
program_derive :: proc(progs: ^Programs, program: i32) -> (reshaped: bool) {
	prog := &progs.programs[program]
	nodes := progs.nodes[prog.nodes.first:base.span_end(prog.nodes)]
	memory: f64
	for &g in nodes {
		row := node_row(g.kind)
		was_stereo, was_sides := g.stereo, g.sides
		stereo := false
		steady := row.stateless
		for &x in progs.inputs[g.inputs.first:base.span_end(g.inputs)] {
			x.stereo = x.node >= 0 && nodes[x.node].stereo
			stereo ||= x.stereo
			steady &&= x.node >= 0 ? nodes[x.node].steady : x.buf != SOURCE_GATE
		}
		stereo &&= !row.one_side // a level of both sides is one
		g.mod_slots = 0
		for &m in progs.mods[g.mods.first:base.span_end(g.mods)] {
			// the note's velocity, accent and slide hold for it, as a steady node does
			m.steady = m.node >= 0 ? nodes[m.node].steady : m.source != SOURCE_GATE
			m.stereo = m.node >= 0 && nodes[m.node].sides
			m.unipolar = m.node < 0 || node_row(nodes[m.node].kind).unipolar
			f := field_of_slot(g.kind, int(m.slot))
			m.per_sample = f != nil && f.per_sample
			mod_coefficients(&m)
			g.mod_slots |= u64(1) << u64(m.slot)
			// a pan, or a modulator of two sides (an Lfo's spread), makes two
			stereo ||= m.slot == FIELD_PAN || (m.stereo && m.per_sample)
			steady &&= m.steady
		}
		g.steady = row.steady || steady
		// what writes both sides itself: a stereo kind, a fat oscillator, what
		// reads two sides (a filter, a mix of them)
		g.sides = row.stereo || (row.sides != nil && row.sides(&g.values)) || (row.inputs != 0 && stereo)
		g.stereo = stereo || g.sides || g.values[FIELD_PAN] != 0
		g.level = g.values[FIELD_GAIN] != 1 || g.values[FIELD_PAN] != 0 || g.mod_slots & (u64(1) << FIELD_AMP | u64(1) << FIELD_PAN) != 0
		// a side each where a modulator of two sides (an Lfo's spread) moves it
		g.split = false
		for m in progs.mods[g.mods.first:base.span_end(g.mods)] {
			g.split ||= g.stereo && m.stereo && m.per_sample
		}
		g.fill = false
		if row.keeps && row.memory != nil {
			memory = max(memory, row.memory(&g.values, row.slots))
		}
		reshaped ||= g.stereo != was_stereo || g.sides != was_sides
	}
	// a steady node a node that isn't reads (or the out): its sample spread;
	// a note's source such a node reads, or a modulator per sample: filled
	prog.sources = 0
	for g in nodes {
		for m in progs.mods[g.mods.first:base.span_end(g.mods)] {
			if m.node < 0 && !m.steady {
				prog.sources |= 1 << m.source
			}
		}
		if g.steady {
			continue
		}
		for x in progs.inputs[g.inputs.first:base.span_end(g.inputs)] {
			if x.node >= 0 {
				nodes[x.node].fill = true
			} else {
				prog.sources |= 1 << x.buf
			}
		}
	}
	if len(nodes) > 0 {
		nodes[prog.out].fill = true
	}
	prog.memory = f32(memory)
	prog.tempo = false
	for g in nodes {
		if sync := node_row(g.kind).sync; sync > 0 && g.values[sync] != 0 {
			prog.tempo = true
		}
	}
	prog.jump = len(nodes) > 0
	for g in nodes {
		prog.jump &&= node_row(g.kind).jump
	}
	for pr in progs.layers[prog.layers.first:base.span_end(prog.layers)] {
		if pr.program >= 0 && pr.program != program {
			reshaped ||= program_derive(progs, pr.program)
		}
	}
	return
}
