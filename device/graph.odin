package odawg_device

import dsp "../dsp"
import base "../base"
import "core:math"

// Instruments as data. The code holds node kinds, rows of a registry
// (NODES: the built-ins of nodes.odin register at init, a host registers
// its own the same way before reading specs); an instrument is a Program
// of nodes, compiled once per song from its row (spec reads rows and places
// them in Programs).
//
// A program's nodes are in an order where every node comes after what it
// reads (its inputs and the nodes moving its fields). A track plays it a
// chunk at a time for every voice playing it at once: node after node, one
// call of the kind's `process` per node per chunk with all those voices
// (its lanes), each a whole-slice stage over the chunk's samples. A voice's
// state is a header and then every node's state, at offsets fixed when the
// program was placed; a node writes its output into one of the lane's
// buffers, which the compiler hands out by liveness (a buffer is taken
// again once its last reader has run), so a lane's buffers stay few.
//
// Every node has gain_db, pan and amp before its kind's own fields. A
// modulator moves a field from its base by a source's value m (m^exponent):
// by octaves (b 2^(a m)), linearly in Hz between b and `a` octaves above it
// (Tone's FrequencyEnvelope: `sweep`), by `a` times b (Tone's FM: `index`),
// by `a` (`amount`), or as a gain (`depth`: b (1 - a + a m01), a -1..1
// source taken to 0..1 as Tone's AudioToGain); on amp every modulator is a
// factor (`amount`: 1 + a m, an accent's lift). A field a kind reads every
// sample moves every sample; the others take their value at the note's
// start. The sources are the program's nodes and the note's: velocity,
// accent, slide (1: it slid in) and gate (1 while it is held).
//
// A machine is a program of pads and no nodes: a note plays its pad's
// program (its pad by name, else the pad whose key is its pitch), at the
// pad's level, and a pad cuts the pads it chokes on the track.
//
// A mono program plays the whole track with one voice: a note that starts
// while the last one's gate is still open slides (no node restarts; with
// `portamento` the pitch glides there), any other restarts every node but
// those that keep their state (`keeps`: a slew's charge, a comb's line).

// The most nodes a program plays, and fields a node has.
MAX_NODES :: 32
MAX_FIELDS :: 24
// The samples a program runs at a time.
NODE_CHUNK :: 256
// A lane's first buffers: the note's sources.
RESERVED :: 5
SOURCE_VELOCITY :: 0
SOURCE_ACCENT :: 1
SOURCE_SLIDE :: 2
SOURCE_GATE :: 3
SOURCE_KEY :: 4 // the note's key, MIDI (60: C4)
RESERVED_NAMES := [RESERVED]string{"velocity", "accent", "slide", "gate", "key"}
MAX_BUFS :: RESERVED + MAX_NODES
// The most voices one call plays.
MAX_LANES :: 256

Span :: base.Span

// ---- the registry ------------------------------------------------------------------

Node_Kind :: distinct u16

Node_Field :: struct {
	name:       string,
	unit:       Unit,
	choices:    []string,
	default:    f32,
	per_sample: bool, // a modulator moves it every sample (else: at the note's start)
	list:       int, // a list of up to this many values, in consecutive slots (0: one)
}

// Every node's, before its kind's own: its level (linear in Programs; dB in
// a row), its pan, and its gain's modulators.
COMMON_FIELDS := []Node_Field{{name = "gain_db", unit = .Db, default = 1, per_sample = true}, {name = "pan", unit = .Number, per_sample = true}, {name = "amp", unit = .Number, default = 1, per_sample = true}}
FIELD_GAIN :: 0
FIELD_PAN :: 1
FIELD_AMP :: 2

// Writes the chunk of one node for every lane of the call: its output into
// node_out(c, lane) (left; right too for a stereo node), not adding.
Node_Process :: #type proc(c: ^Node_Call)
// Seconds the node sounds from a note's start (0: nothing past the gate).
Node_Tail :: #type proc(c: ^Node_Call, lane: ^Lane) -> f64

Node_Kind_Row :: struct {
	name:     string,
	fields:   []Node_Field, // after COMMON_FIELDS
	inputs:   int, // how many it reads (-1: one or more)
	unipolar: bool, // its output is 0..1 (an envelope), not -1..1
	steady:   bool, // its output holds for a whole note (a draw from the seed): what it moves moves once a chunk
	stateless: bool, // its output is a function of what it reads now (a map, a product): steady when they are
	stereo:   bool, // it writes two sides whatever it reads (else one, or as its inputs)
	keeps:    bool, // its state carries across a mono program's notes
	jump:     bool, // its output is a function of where the note is (a recording's position): a seek starts it there, nothing rendered
	state:    int, // bytes a voice keeps for it
	// a lane's note starting (a fresh voice's, or a mono slide's: a kind
	// that keeps its state reads lane.fresh for what a new voice resets),
	// before its chunk; nil: nothing to set
	start:    proc(c: ^Node_Call, lane: ^Lane),
	process:  Node_Process,
	tail:     Node_Tail,
	memory:   proc(values: ^[MAX_FIELDS]f32, slots: []int) -> f64, // seconds of earlier notes its kept state remembers
	// filled by register_node: each field's first slot in Graph_Node.values
	slots:    []int,
	count:    int,
}

Node_Registry :: struct {
	kinds: [dynamic]Node_Kind_Row,
}

NODES: Node_Registry

// Adds a kind (its fields kept, their slots laid out after the common
// ones); its id.
register_node :: proc(r: ^Node_Registry, row: Node_Kind_Row) -> Node_Kind {
	x := row
	x.fields = make([]Node_Field, len(row.fields))
	copy(x.fields, row.fields)
	slots := make([]int, len(row.fields))
	at := len(COMMON_FIELDS)
	for f, i in row.fields {
		slots[i] = at
		at += max(f.list, 1)
	}
	assert(at <= MAX_FIELDS, "a node kind has too many fields")
	x.slots, x.count = slots, at
	append(&r.kinds, x)
	return Node_Kind(len(r.kinds) - 1)
}

node_kind_from_name :: proc(name: string) -> (Node_Kind, bool) {
	for row, k in NODES.kinds {
		if row.name == name {
			return Node_Kind(k), true
		}
	}
	return 0, false
}

node_row :: #force_inline proc(kind: Node_Kind) -> ^Node_Kind_Row {return &NODES.kinds[kind]}

// A kind written with a choice that names another kind (a Filter of type
// "diode" is a Ladder): it is that kind, its values moved by their fields'
// names (node_desc_resolve).
Kind_By_Choice :: struct {
	kind:   Node_Kind,
	slot:   int,
	choice: f32,
	is:     Node_Kind,
}

KINDS_BY_CHOICE: [dynamic]Kind_By_Choice

// A desc's node as the kind it is (KINDS_BY_CHOICE): its values and its
// modulators' slots moved to the fields of that name (none there: dropped).
node_desc_resolve :: proc(n: ^Node_Desc) {
	for x in KINDS_BY_CHOICE {
		if n.kind != x.kind || n.values[x.slot] != x.choice {
			continue
		}
		from, to := node_row(x.kind), node_row(x.is)
		slot_in := proc(row: ^Node_Kind_Row, name: string) -> int {
			for f, i in COMMON_FIELDS {
				if f.name == name {
					return i
				}
			}
			for f, i in row.fields {
				if f.name == name {
					return row.slots[i]
				}
			}
			return -1
		}
		moved: [MAX_FIELDS]int
		for &m in moved {
			m = -1
		}
		for i in 0 ..< len(COMMON_FIELDS) {
			moved[i] = i
		}
		for f, i in from.fields {
			moved[from.slots[i]] = slot_in(to, f.name)
		}
		values := node_defaults(x.is)
		for slot in 0 ..< MAX_FIELDS {
			if moved[slot] >= 0 {
				values[moved[slot]] = n.values[slot]
			}
		}
		mods := make([dynamic]Mod_Desc, context.temp_allocator)
		for m in n.mods {
			if moved[m.slot] >= 0 {
				y := m
				y.slot = moved[m.slot]
				append(&mods, y)
			}
		}
		n.kind, n.values, n.mods = x.is, values, mods[:]
		return
	}
}

// A field by name: its row (a common one's or the kind's) and first slot.
node_field_from_name :: proc(kind: Node_Kind, name: string) -> (field: ^Node_Field, slot: int, ok: bool) {
	for &f, i in COMMON_FIELDS {
		if f.name == name {
			return &f, i, true
		}
	}
	row := node_row(kind)
	for &f, i in row.fields {
		if f.name == name {
			return &f, row.slots[i], true
		}
	}
	return nil, -1, false
}

// A node of `kind` with nothing set: its fields' defaults.
node_defaults :: proc(kind: Node_Kind) -> (v: [MAX_FIELDS]f32) {
	for f, i in COMMON_FIELDS {
		v[i] = f.default
	}
	row := node_row(kind)
	for f, i in row.fields {
		for k in 0 ..< max(f.list, 1) {
			v[row.slots[i] + k] = f.list > 0 ? 0 : f.default
		}
	}
	return
}

// ---- programs ----------------------------------------------------------------------

// How a modulator moves its field from its base b by its source's value m
// (m^exponent): the three ways, their coefficients fixed when the program
// is placed (a -1..1 source scaling a level is read as 0..1 there).
Mod_Op :: enum u8 {
	Add, // + k m, k = c1 (times b when `scaled`: an FM index, a sweep linear in Hz)
	Mul, // × (c0 + c1 m): a level, a depth
	Octaves, // × 2^(c1 m): a pitch, a cutoff
	Cap, // toward at most c0 by m: (1 - m) v + m min(v, c0) (an accent's shorter decay)
}

Mod :: struct {
	slot:       u8, // the field's
	source:     u8, // the lane buffer it reads
	node:       i16, // the node it reads (local; -1: a note's source)
	kind:       Mod_Kind, // as written: op and coefficients follow from it and amount (mod_coefficients)
	amount:     f32,
	unipolar:   bool, // its source is 0..1
	op:         Mod_Op,
	scaled:     bool, // Add: k is c1 times the field's base
	steady:     bool, // the source holds for the note: one factor or term a chunk
	per_sample: bool, // the field is read every sample (else at the note's start)
	exponent:   f32,
	c0, c1:     f32,
}

Graph_Input :: struct {
	buf:    u8,
	stereo: bool,
	node:   i16, // the node it reads (local; -1: a note's source)
}

Graph_Node :: struct {
	kind:      Node_Kind,
	name:      u32, // name_id of its name in the row (commands, controls find it by name)
	stereo:    bool, // its output has two sides
	sides:     bool, // its kind writes both (else the right is the left, copied before its pan)
	level:     bool, // it has a level to apply (a gain, a pan, what moves them)
	steady:    bool, // its output holds for the note: run one sample a chunk
	fill:      bool, // steady, and read as an input by a node that isn't: its one sample spread over the chunk
	buf:       u8, // the lane buffer it writes
	state:     i32, // bytes into the voice's state
	mod_slots: u64, // the slots its modulators move
	values:    [MAX_FIELDS]f32,
	mods:      Span, // into Programs.mods
	inputs:    Span, // into Programs.inputs
}

// What plays a note of a program with layers: the program a layer plays
// (-1: a named key of the program's own, the note playing its key), its
// level, its values where they differ from its program's, and `row`, its
// row of what its program's layer_mode reads: a pad (One, Programs.pads) or
// a region (All, Programs.regions).
Layer_Row :: struct {
	program: i32,
	gain:    f32,
	params:  Span, // into Programs.layer_params: its values where they differ from its program's
	row:     i32,
}

// A machine's pad (`program` its pad's), or a named key of a program's own
// (a Sampler's set's): by name or key, the first that answers.
Layer_Pad :: struct {
	pad:    u32, // name_id of its name
	key:    f32,
	chokes: Span, // into Programs.chokes: pad ids it cuts
}

// An SFZ instrument's region: every one whose conditions a note meets
// sounds, each a voice, and how its voices stop.
Layer_Region :: struct {
	lo_key, hi_key:         u8,
	lo_vel, hi_vel:         u8,
	lo_rand, hi_rand:       f32, // the note's draw 0..1 in [lo, hi)
	seq_length:             u16, // a round robin: it plays when round % length + 1 == position
	seq_position:           u16,
	trigger:                Layer_Trigger,
	sw_last_lo, sw_last_hi: u8, // 1 + the keys the last keyswitch must be within (sw_last; 0: any)
	group:                  i32, // its voices' group (off_by and polyphony count by it)
	off_by:                 i32, // a group whose start cuts its voices (0: none)
	off_mode:               Layer_Off,
	off_time:               f32, // seconds (off_mode Time)
	polyphony:              u16, // voices of its group at most (0: any)
	note_polyphony:         u16, // voices of its group on one key at most (0: any)
	rt_decay:               f32, // dB a second its release note loses for how long the note was held
}

// A value of a layer's program that its layer plays otherwise (regions of
// one shape share a program; their zones, tunings, levels, times differ).
Layer_Param :: struct {
	node:  u16, // local
	slot:  u8,
	value: f32,
}

// Which notes a region answers: SFZ's trigger.
Layer_Trigger :: enum u8 {
	Attack, // a note's start
	Release, // its end (a release note)
	First, // a start with no other note held
	Legato, // a start while another is held
}

// Whether a note is one a trigger answers.
LAYER_TRIGGERS := [Layer_Trigger]proc(n: Note) -> bool {
	.Attack  = proc(n: Note) -> bool {return n.kind == .Attack},
	.Release = proc(n: Note) -> bool {return n.kind == .Release},
	.First   = proc(n: Note) -> bool {return n.kind == .Attack && !n.legato},
	.Legato  = proc(n: Note) -> bool {return n.kind == .Attack && n.legato},
}

// How a voice cut by off_by stops.
Layer_Off :: enum u8 {
	Fast, // a few milliseconds
	Normal, // its release, as if its note ended
	Time, // a fade over off_time
}

// How a note picks its layers.
Layer_Mode :: enum u8 {
	One, // the first that answers (a machine's pad)
	All, // every one that answers (an SFZ instrument's regions)
}

Program :: struct {
	nodes:      Span, // into Programs.nodes, in running order
	out:        i32, // local
	layers:     Span, // into Programs.layers
	layer_mode: Layer_Mode,
	// 1 + the keys that switch a layered instrument's regions rather than
	// sound (SFZ's sw_lokey..sw_hikey; 0: none), and the switch before any
	// is played (sw_default)
	sw_lo, sw_hi, sw_default: u8,
	release_layers: bool, // some layer answers a note's end (a release note is made for each)
	length:     f32, // a one-shot's seconds (0: the gate and its nodes' tails)
	note:       f32, // the pitch a note without one plays (0: 60)
	mono:       bool, // one voice for the track
	portamento: f32, // seconds a mono slide glides over (0: it jumps)
	velocity:   bool, // the out is scaled by the note's velocity
	bufs:       i32, // lane buffers it uses (the reserved ones too)
	state:      i32, // bytes a voice takes
	memory:     f32, // seconds of earlier notes a mono voice's state remembers (a seek chases them)
	controls:   Span, // into Programs.controls: its knobs
	sources:    u8, // the note's sources something reads every sample of (else only the first)
	jump:       bool, // every node jumps (a clip): a seek starts its notes where they are
	one_shot:   bool, // its notes play to their end whatever the gate (an SFZ region's loop_mode=one_shot)
}

Programs :: struct {
	programs: [dynamic]Program,
	nodes:    [dynamic]Graph_Node,
	mods:     [dynamic]Mod,
	inputs:   [dynamic]Graph_Input,
	layers:   [dynamic]Layer_Row,
	pads:     [dynamic]Layer_Pad, // the One layers' rows
	regions:  [dynamic]Layer_Region, // the All layers' rows
	layer_params: [dynamic]Layer_Param,
	chokes:   [dynamic]u32,
	tables:          [dynamic]f32, // Curve nodes' tables, CURVE_POINTS each
	controls:        [dynamic]Control_Row,
	control_names:   [dynamic]string, // each control's name (as controls)
	control_targets: [dynamic]Control_Target,
}


// ---- what a kind's process sees ----------------------------------------------------

// One voice of a call: its note (pitch resolved), where the chunk is in it,
// its buffers.
Lane :: struct {
	state:    [^]u8,
	note:     Note,
	key:      f32, // the key a Sampler's zones answer
	hz:       f64, // the note's pitch in Hz
	glide:    []f64, // a gliding mono note's Hz per sample (nil: hz)
	seed:     u64,
	gate:     i64, // samples
	at:       i64, // the chunk's first sample, from the note's start
	release:  int, // where the gate closes in the chunk (-1: not in it)
	starting: bool, // the note starts in this chunk and doesn't slide: nodes take their values
	fresh:    bool, // the voice's state was zeroed for it (a kept state starts here)
	silent:   u64, // the nodes (local) whose output is over for this whole chunk
	bufs:     []f32, // [bufs][2][NODE_CHUNK]
	params:   []Layer_Param, // its layer's values (node_values)
	values:   [MAX_FIELDS]f32, // a node's values with its layer's, while one is read
}

Node_Call :: struct {
	progs:  ^Programs,
	env:    ^Voice_Env,
	node:   ^Graph_Node,
	local:  u16, // the node's index in its program
	frames: int,
	lanes:  []Lane,
}

lane_buf :: #force_inline proc "contextless" (lane: ^Lane, buf: u8, side: int, frames: int) -> []f32 {
	at := (int(buf) * 2 + side) * NODE_CHUNK
	return lane.bufs[at:at + frames]
}

// The node's output sides (r is written only by a stereo node).
node_out :: #force_inline proc "contextless" (c: ^Node_Call, lane: ^Lane) -> (l, r: []f32) {
	return lane_buf(lane, c.node.buf, 0, c.frames), lane_buf(lane, c.node.buf, 1, c.frames)
}

// Input i's sides (a mono one is its left twice).
node_input :: #force_inline proc(c: ^Node_Call, lane: ^Lane, i: int) -> (l, r: []f32) {
	x := c.progs.inputs[c.node.inputs.first + i32(i)]
	l = lane_buf(lane, x.buf, 0, c.frames)
	r = x.stereo ? lane_buf(lane, x.buf, 1, c.frames) : l
	return
}

node_state :: #force_inline proc "contextless" (c: ^Node_Call, lane: ^Lane, $T: typeid) -> ^T {
	return (^T)(&lane.state[c.node.state])
}

// A kind's field's first slot.
slot_of :: #force_inline proc(c: ^Node_Call, field: int) -> int {return node_row(c.node.kind).slots[field]}

// The node's values as a lane's voice plays them: its program's, but where
// the voice's layer gives its own (a region sharing its shape's program).
node_values :: #force_inline proc(c: ^Node_Call, lane: ^Lane) -> ^[MAX_FIELDS]f32 {
	if len(lane.params) == 0 {
		return &c.node.values
	}
	return node_values_layered(c, lane)
}

@(private = "file")
node_values_layered :: proc(c: ^Node_Call, lane: ^Lane) -> ^[MAX_FIELDS]f32 {
	lane.values = c.node.values
	for p in lane.params {
		if p.node == c.local {
			lane.values[p.slot] = p.value
		}
	}
	return &lane.values
}

// A field over the chunk from base b, moved by its modulators in their
// order: while every one so far holds for the chunk (a steady source, one
// whose output is over: m = 0) the field is one value (`v`, out untouched);
// from the first that moves within it, out holds it per sample (`varies`).
node_curve :: proc(c: ^Node_Call, lane: ^Lane, slot: int, b: f32, out: []f32) -> (varies: bool, v: f32) {
	v = b
	if c.node.mod_slots & (u64(1) << u64(slot)) == 0 {
		return
	}
	value :: #force_inline proc "contextless" (src: []f32, i: int, e: f32) -> f32 {
		x := src[i]
		if e == 1 {
			return x
		}
		if e == 2 {
			return x * abs(x)
		}
		return x >= 0 ? math.pow(x, e) : -math.pow(-x, e)
	}
	n := len(out)
	// per-sample octaves add up first: one exp2 a sample for a run of them
	octaves: [NODE_CHUNK]f32 = ---
	pending := false
	flush :: #force_inline proc "contextless" (out: []f32, octaves: []f32, pending: ^bool) {
		if pending^ {
			for i in 0 ..< len(out) {
				out[i] *= dsp.exp2_fast(octaves[i])
			}
			pending^ = false
		}
	}
	defer flush(out, octaves[:n], &pending)
	for &m in c.progs.mods[c.node.mods.first:base.span_end(c.node.mods)] {
		if int(m.slot) != slot {
			continue
		}
		k := m.scaled ? m.c1 * b : m.c1
		over := m.node >= 0 && lane.silent & (u64(1) << u64(m.node)) != 0
		if over || m.steady {
			// one value for the chunk: one term or factor
			x := over ? 0 : value(lane_buf(lane, m.source, 0, 1), 0, m.exponent)
			add, mul: f32 = 0, 1
			switch m.op {
			case .Add:
				add = k * x
			case .Mul:
				mul = m.c0 + m.c1 * x
			case .Octaves:
				mul = x == 0 ? 1 : dsp.exp2_fast(m.c1 * x)
			case .Cap:
				if !varies {
					v += x * (min(v, m.c0) - v)
				} else if x != 0 {
					flush(out, octaves[:n], &pending)
					for i in 0 ..< n {
						out[i] += x * (min(out[i], m.c0) - out[i])
					}
				}
				continue
			}
			if !varies {
				v = v * mul + add
			} else if mul != 1 || add != 0 {
				if add != 0 {
					flush(out, octaves[:n], &pending)
				}
				for i in 0 ..< n {
					out[i] = out[i] * mul + add
				}
			}
			continue
		}
		if !varies {
			for i in 0 ..< n {
				out[i] = v
			}
			varies = true
		}
		src := lane_buf(lane, m.source, 0, n)
		if m.op != .Octaves && m.op != .Mul {
			flush(out, octaves[:n], &pending)
		}
		switch m.op {
		case .Add:
			for i in 0 ..< n {
				out[i] += k * value(src, i, m.exponent)
			}
		case .Mul:
			for i in 0 ..< n {
				out[i] *= m.c0 + m.c1 * value(src, i, m.exponent)
			}
		case .Octaves:
			if !pending {
				for i in 0 ..< n {
					octaves[i] = m.c1 * value(src, i, m.exponent)
				}
				pending = true
			} else {
				for i in 0 ..< n {
					octaves[i] += m.c1 * value(src, i, m.exponent)
				}
			}
		case .Cap:
			for i in 0 ..< n {
				x := value(src, i, m.exponent)
				out[i] += x * (min(out[i], m.c0) - out[i])
			}
		}
	}
	return
}

// A field's value now: its base moved by its modulators at the chunk's
// first sample (a field read at the note's start).
node_value :: proc(c: ^Node_Call, lane: ^Lane, slot: int) -> f32 {
	b := node_values(c, lane)[slot]
	if len(lane.bufs) == 0 { // a tail's question: no sources playing
		return b
	}
	one: [1]f32
	varies, v := node_curve(c, lane, slot, b, one[:])
	return varies ? one[0] : v
}

// ---- playing a program -------------------------------------------------------------

Graph_Header :: struct #align (16) {
	program:  i32, // what plays: the program's own, or its pad's or layer's
	layer:    i32, // the layer it plays (into Programs.layers; -1: none)
	gain:     f32, // the pad's or layer's level
	total:    i64, // samples the note sounds
	pitch:    f32,
	key:      f32,
	started:  bool, // a mono voice has played a note
	starting: bool, // the note's nodes take their values in its first chunk
	fresh:    bool, // the state was zeroed for this note
	slide:    bool,
	gate:     i64, // this note's
	pos:      i64, // samples of it played
	from_hz:  f64, // a glide's pitch now (log2 Hz)
	glide_k:  f64,
	ends:     [MAX_NODES]i32, // the sample each node's output is over at (graph_ends)
}

GRAPH_HEADER :: (size_of(Graph_Header) + 15) &~ 15

graph_program :: proc(p: ^Params, env: ^Voice_Env) -> i32 {
	k := i32(p[.Program])
	if env == nil || env.programs == nil || k < 0 || int(k) >= len(env.programs.programs) {
		return -1
	}
	return k
}

// The program a note of program `index` plays (a machine's: its pad's), the
// pad's level, the key a Sampler answers and the pitch it plays at: a
// machine's pad plays its program's note, a named key of the program's own
// that key, a pitched note its pitch. False: nothing plays it.
@(private = "file")
graph_resolve :: proc(progs: ^Programs, index: i32, n: Note) -> (play: i32, gain, key, pitch: f32, ok: bool) {
	prog := &progs.programs[index]
	play, gain = index, 1
	for pr in progs.layers[prog.layers.first:base.span_end(prog.layers)] {
		if prog.layer_mode != .One {
			break
		}
		pad := progs.pads[pr.row]
		if (n.pad != 0 && pad.pad == n.pad) || (n.pad == 0 && n.pitch > 0 && pad.key == math.round(n.pitch)) {
			gain = pr.gain
			if pr.program >= 0 {
				play = pr.program
				note := progs.programs[play].note
				pitch = n.pitch > 0 && n.pad != 0 ? n.pitch : (note > 0 ? note : 60)
				return play, gain, pitch, pitch, true
			}
			pitch = n.pitch > 0 ? n.pitch : pad.key
			return play, gain, pad.key, pitch, true
		}
	}
	if prog.nodes.count == 0 || n.pad != 0 {
		return
	}
	pitch = n.pitch > 0 ? n.pitch : (prog.note > 0 ? prog.note : 60)
	return play, gain, pitch, pitch, true
}

// The program a note of program `index` plays and the key a Sampler there
// answers. False: nothing plays it.
graph_note :: proc(progs: ^Programs, index: i32, n: Note) -> (play: i32, key: f32, ok: bool) {
	if index < 0 || int(index) >= len(progs.programs) {
		return
	}
	play, _, key, _, ok = graph_resolve(progs, index, n)
	return
}

// The pads a note's pad cuts on its track.
graph_chokes :: proc(progs: ^Programs, index: i32, n: Note) -> []u32 {
	if index < 0 || int(index) >= len(progs.programs) || n.pad == 0 {
		return nil
	}
	prog := &progs.programs[index]
	if prog.layer_mode != .One {
		return nil
	}
	for pr in progs.layers[prog.layers.first:base.span_end(prog.layers)] {
		if pad := progs.pads[pr.row]; pad.pad == n.pad {
			return progs.chokes[pad.chokes.first:base.span_end(pad.chokes)]
		}
	}
	return nil
}

// Seconds a note sounds: a one-shot's length, else the longest of the gate
// and its nodes' tails.
tail_graph :: proc(p: ^Params, n: Note, env: ^Voice_Env) -> f64 {
	index := graph_program(p, env)
	if index < 0 {
		return 0
	}
	if env.programs.programs[index].layer_mode == .All {
		// the longest of the layers it may play (whichever its draw picks)
		layers: [MAX_LAYERS]i32
		longest: f64
		for l in layers[:graph_layers(env.programs, index, n, -1, layers[:])] {
			longest = max(longest, tail_of(env, env.programs.layers[l].program, n, n.pitch, n.pitch, l))
		}
		return longest
	}
	play, _, key, pitch, ok := graph_resolve(env.programs, index, n)
	if !ok {
		return 0
	}
	return tail_of(env, play, n, key, pitch)
}

@(private = "file")
tail_of :: proc(env: ^Voice_Env, play: i32, n: Note, key, pitch: f32, layer: i32 = -1) -> f64 {
	prog := &env.programs.programs[play]
	if prog.length > 0 {
		return f64(prog.length)
	}
	heard: [MAX_NODES]f64
	if prog.one_shot {
		// to its end whatever the gate: as long as it is heard with the gate held
		m := n
		m.duration = ONE_SHOT_GATE
		graph_heard(env, prog, m, key, pitch, &heard, layer)
		tail := heard[prog.out]
		return math.is_inf(tail) || tail >= ONE_SHOT_GATE ? 30 : tail
	}
	graph_heard(env, prog, n, key, pitch, &heard, layer)
	tail := heard[prog.out]
	if math.is_inf(tail) {
		tail = max(n.duration, 0) // nothing ends it: it is cut at the gate
	}
	return max(tail, max(n.duration, 0))
}

// How long each node of a program is heard for a note (seconds; INF: for
// ever), in running order: its own tail, else as long as what it reads (a
// source with neither: for ever), cut to the shortest envelope its level
// is multiplied by (amp: a 0..1 node with a tail, at full depth).
@(private = "file")
graph_heard :: proc(env: ^Voice_Env, prog: ^Program, n: Note, key, pitch: f32, heard: ^[MAX_NODES]f64, layer: i32 = -1) {
	lanes := [1]Lane{{note = n, key = key, hz = base.midi_to_hz(f64(pitch)), gate = gate_sample(n), params = layer_params(env.programs, layer)}}
	lanes[0].note.pitch = pitch
	c := Node_Call{progs = env.programs, env = env, lanes = lanes[:]}
	progs := env.programs
	nodes := progs.nodes[prog.nodes.first:base.span_end(prog.nodes)]
	for &node, k in nodes {
		row := node_row(node.kind)
		h := math.INF_F64
		if row.tail != nil {
			c.node, c.local = &node, u16(k)
			h = row.tail(&c, &lanes[0])
		} else if node.inputs.count > 0 {
			h = 0
			for x in progs.inputs[node.inputs.first:base.span_end(node.inputs)] {
				h = max(h, x.node >= 0 ? heard[x.node] : math.INF_F64)
			}
		}
		for m in progs.mods[node.mods.first:base.span_end(node.mods)] {
			if int(m.slot) == FIELD_AMP && m.op == .Mul && m.c0 == 0 && m.c1 == 1 && m.node >= 0 && node_row(nodes[m.node].kind).unipolar && node_row(nodes[m.node].kind).tail != nil {
				h = min(h, heard[m.node])
			}
		}
		heard[k] = h
	}
}

// The sample each node's output is over at, for a note: what it is heard
// for, as long as a node still reading it needs it (a field read at the
// note's start needs its first sample only). From there it is silence and
// isn't run. A mono program's nodes carry on into the next note: never over.
@(private = "file")
graph_ends :: proc(env: ^Voice_Env, prog: ^Program, n: Note, key, pitch: f32, ends: ^[MAX_NODES]i32, layer: i32 = -1) {
	progs := env.programs
	nodes := progs.nodes[prog.nodes.first:base.span_end(prog.nodes)]
	if prog.mono {
		for k in 0 ..< len(nodes) {
			ends[k] = max(i32)
		}
		return
	}
	heard: [MAX_NODES]f64
	graph_heard(env, prog, n, key, pitch, &heard, layer)
	gate := max(n.duration, 0)
	need: [MAX_NODES]f64
	need[prog.out] = math.INF_F64
	#reverse for &node, r in nodes {
		h := heard[r]
		if math.is_inf(h) && r == int(prog.out) {
			h = gate
		}
		e := min(need[r], h)
		need[r] = e
		for x in progs.inputs[node.inputs.first:base.span_end(node.inputs)] {
			if x.node >= 0 {
				need[x.node] = max(need[x.node], e)
			}
		}
		for m in progs.mods[node.mods.first:base.span_end(node.mods)] {
			if m.node >= 0 {
				need[m.node] = max(need[m.node], m.per_sample ? e : min(e, 1.0 / RATE))
			}
		}
	}
	for k in 0 ..< len(nodes) {
		e := min(need[k], heard[k])
		ends[k] = math.is_inf(e) || e * RATE >= f64(max(i32)) ? max(i32) : i32(math.ceil(e * RATE))
	}
}

voice_bytes_graph :: proc(p: ^Params, env: ^Voice_Env) -> int {
	index := graph_program(p, env)
	return index >= 0 ? int(env.programs.programs[index].state) : GRAPH_HEADER
}

// One voice for the whole track (a mono program): a new note goes to the
// playing voice (its state kept), which reads from it whether the last gate
// was still open (a slide, legato) or not (a new attack).
voice_mono :: proc(p: ^Params, env: ^Voice_Env) -> bool {
	index := graph_program(p, env)
	return index >= 0 && env.programs.programs[index].mono
}

// Seconds of earlier notes a seek replays for a voice's state (a mono
// program's memory; 0: it forgets them).
// Whether a seek starts a voice's notes where they are, nothing rendered
// (a clip's program).
voice_jump :: proc(p: ^Params, env: ^Voice_Env) -> bool {
	index := graph_program(p, env)
	return index >= 0 && env.programs.programs[index].jump
}

voice_memory :: proc(p: ^Params, env: ^Voice_Env) -> f64 {
	index := graph_program(p, env)
	return index >= 0 ? f64(env.programs.programs[index].memory) : 0
}

// Samples a slide's last gate must still have to run when the next note
// starts.
SLIDE_SLACK :: 24

// A note starting on a voice (`fresh`: its state zeroed for it): which
// program plays it (into the header), its sound's length, whether a mono
// voice slides into it. False: nothing plays it.
graph_start :: proc(s: ^Voice_State, p: ^Params, n: Note, env: ^Voice_Env, fresh: bool, layer: i32 = -1) -> (play: i32, ok: bool) {
	h := (^Graph_Header)(s)
	index := graph_program(p, env)
	if index < 0 {
		h.total = 0
		return -1, false
	}
	gain, key, pitch: f32
	n := n
	if layer >= 0 {
		// one of a layered note's regions: its program at the note's pitch
		l := env.programs.layers[layer]
		play, gain, key, pitch, ok = l.program, l.gain * (n.level > 0 ? n.level : 1), n.pitch, n.pitch, l.program >= 0
		if n.kind == .Release {
			// a note's end: its gate already closed, quieter the longer it was held
			gain *= f32(base.db_to_gain(-f64(env.programs.regions[l.row].rt_decay) * n.duration))
			n.duration = 0
		}
		if play >= 0 && env.programs.programs[play].one_shot {
			n.duration = ONE_SHOT_GATE // the gate never closes: it plays to its end
		}
	} else {
		play, gain, key, pitch, ok = graph_resolve(env.programs, index, n)
	}
	h.layer = layer
	if !ok {
		h.total = 0
		return -1, false
	}
	prog := &env.programs.programs[play]
	// the last note's gate still open (a mono voice): a slide
	h.slide = prog.mono && h.started && h.program == play && h.gate - h.pos > SLIDE_SLACK
	h.program, h.gain, h.key, h.pitch = play, gain, key, pitch
	h.total = i64(math.ceil((layer >= 0 ? tail_of(env, play, n, key, pitch, layer) : tail_graph(p, n, env)) * RATE))
	graph_ends(env, prog, n, key, pitch, &h.ends, layer)
	h.gate, h.pos = gate_sample(n), 0
	h.starting, h.fresh = !h.slide, fresh
	target := math.log2(base.midi_to_hz(f64(pitch)))
	if !h.slide || prog.portamento <= 0 {
		h.from_hz = target
	}
	h.glide_k = prog.portamento > 0 ? 1 - math.exp(-3 / (f64(prog.portamento) * RATE)) : 1
	h.started = true
	return play, true
}

graph_playing :: proc(s: ^Voice_State) -> i32 {return (^Graph_Header)(s).program}

// A voice playing a program: its state (its header first), its note, its
// seed, the samples of it played, where its sound goes and at what level.
Graph_Voice :: struct {
	state:        ^Voice_State,
	note:         Note,
	seed:         u64,
	at:           i64,
	out_l, out_r: []f32, // added into
	gain:         f32,
	done:         bool, // set: its sound is over
}

// Floats a call of graph_run needs for `lanes` voices of a program.
graph_scratch :: proc(prog: ^Program, lanes: int) -> int {
	return lanes * int(prog.bufs) * 2 * NODE_CHUNK
}

// Plays `frames` more samples of voices that all play program `play`
// (their headers': graph_start), adding into their outs; `scratch` holds
// graph_scratch floats for them.
graph_run :: proc(progs: ^Programs, env: ^Voice_Env, play: i32, voices: []Graph_Voice, frames: int, scratch: []f32) {
	prog := &progs.programs[play]
	nodes := progs.nodes[prog.nodes.first:base.span_end(prog.nodes)]
	lanes_buf: [MAX_LANES]Lane = --- // each set whole as its voice is taken
	which: [MAX_LANES]i32 = --- // the voice of each lane
	glide: [NODE_CHUNK]f64 = --- // a mono program's one voice's
	per_lane := int(prog.bufs) * 2 * NODE_CHUNK
	for off := 0; off < frames; off += NODE_CHUNK {
		n := min(NODE_CHUNK, frames - off)
		count := 0
		for &v, k in voices {
			h := (^Graph_Header)(v.state)
			at := v.at + i64(off)
			if v.done || at >= h.total {
				v.done = true
				continue
			}
			lane := &lanes_buf[count]
			lane^ = {
				state = ([^]u8)(v.state), note = v.note, key = h.key, seed = v.seed, gate = h.gate, at = at,
				release = release_at(h.gate, at, n), starting = h.starting && at == 0, fresh = h.fresh && at == 0,
				bufs = scratch[count * per_lane:][:per_lane], params = layer_params(progs, h.layer),
			}
			lane.note.pitch = h.pitch
			lane.hz = base.midi_to_hz(f64(h.pitch))
			if prog.mono && prog.portamento > 0 && count == 0 {
				target := math.log2(lane.hz)
				g := glide[:n]
				for i in 0 ..< n {
					h.from_hz += (target - h.from_hz) * h.glide_k
					g[i] = f64(dsp.exp2_fast(f32(h.from_hz)))
				}
				lane.glide = g
			}
			// the note's sources
			sources := [RESERVED]f32{v.note.velocity, v.note.accent, h.slide ? 1 : 0, 0, h.pitch}
			for s in 0 ..< RESERVED {
				b := lane_buf(lane, u8(s), 0, prog.sources & (1 << u8(s)) != 0 ? n : 1)
				if s == SOURCE_GATE {
					for i in 0 ..< len(b) {
						b[i] = at + i64(i) < h.gate ? 1 : 0
					}
				} else {
					for i in 0 ..< len(b) {
						b[i] = sources[s]
					}
				}
			}
			// the nodes whose output is over for this whole chunk
			for e, j in h.ends[:len(nodes)] {
				if i64(e) <= at {
					lane.silent |= u64(1) << u64(j)
				}
			}
			which[count] = i32(k)
			count += 1
		}
		if count == 0 {
			break
		}
		lanes := lanes_buf[:count]
		c := Node_Call{progs = progs, env = env, frames = n, lanes = lanes}
		for &node, j in nodes {
			c.node, c.local = &node, u16(j)
			bit := u64(1) << u64(j)
			heard := false
			for &lane in lanes {
				heard ||= lane.silent & bit == 0
			}
			if !heard {
				// over for every voice: silence, nothing run
				for &lane in lanes {
					ol, or := node_out(&c, &lane)
					slice_zero(ol)
					if node.stereo {
						slice_zero(or)
					}
				}
				continue
			}
			if node.steady {
				// one sample for the chunk, spread over it if a reader needs it
				c.frames = 1
				node_starts(&c)
				node_row(node.kind).process(&c)
				for &lane in lanes {
					ol, or := node_out(&c, &lane)
					if node.stereo && !node.sides {
						or[0] = ol[0]
					}
					if node.level {
						node_level(&c, &lane, ol, or)
					}
				}
				c.frames = n
				for &lane, k in lanes {
					ol, or := node_out(&c, &lane)
					end := int(clamp(i64((^Graph_Header)(voices[which[k]].state).ends[j]) - lane.at, 0, i64(n)))
					if !node.fill {
						if end == 0 {
							ol[0], or[0] = 0, 0
						}
						continue
					}
					for i in 1 ..< end {
						ol[i] = ol[0]
					}
					slice_zero(ol[end:])
					if node.stereo {
						for i in 1 ..< end {
							or[i] = or[0]
						}
						slice_zero(or[end:])
					}
				}
				continue
			}
			node_starts(&c)
			node_row(node.kind).process(&c)
			for &lane, k in lanes {
				ol, or := node_out(&c, &lane)
				if node.stereo && !node.sides {
					copy(or, ol)
				}
				if node.level {
					node_level(&c, &lane, ol, or)
				}
				// over within the chunk (or before it, for this voice): silence
				// from that sample, wherever the chunk falls
				end := (^Graph_Header)(voices[which[k]].state).ends[j]
				if i64(end) < lane.at + i64(n) {
					from := int(clamp(i64(end) - lane.at, 0, i64(n)))
					slice_zero(ol[from:])
					if node.stereo {
						slice_zero(or[from:])
					}
				}
			}
		}
		out := &nodes[prog.out]
		for &lane, k in lanes {
			v := &voices[which[k]]
			h := (^Graph_Header)(v.state)
			ol, or := lane_buf(&lane, out.buf, 0, n), lane_buf(&lane, out.buf, out.stereo ? 1 : 0, n)
			g := v.gain * h.gain * (prog.velocity ? v.note.velocity : 1)
			m := int(clamp(h.total - lane.at, 0, i64(n)))
			// the voice into its out: lengths checked once, here
			dl, dr, sl, sr := v.out_l[off:][:m], v.out_r[off:][:m], ol[:m], or[:m]
			#no_bounds_check for i in 0 ..< m {
				dl[i] += sl[i] * g
				dr[i] += sr[i] * g
			}
			h.starting, h.fresh = false, false
			h.pos = lane.at + i64(n)
		}
	}
	for &v in voices {
		h := (^Graph_Header)(v.state)
		v.at += i64(frames)
		v.done = v.done || v.at >= h.total
	}
}

// The sample in a chunk of c from note sample `at` where the gate closes.
@(private = "file")
release_at :: #force_inline proc "contextless" (gate, at: i64, c: int) -> int {
	d := gate - at
	return d >= 0 && d < i64(c) ? int(d) : -1
}

// A node's level, its amp modulators and its pan, over its chunk.
@(private = "file")
node_level :: proc(c: ^Node_Call, lane: ^Lane, l, r: []f32) {
	n := len(l)
	node := c.node
	values := node_values(c, lane)
	gain_db, pan_base := values[FIELD_GAIN], values[FIELD_PAN]
	gain: [NODE_CHUNK]f32 = --- // node_curve's, read where it varies
	if varies, g := node_curve(c, lane, FIELD_AMP, 1, gain[:n]); varies {
		g = gain_db
		for i in 0 ..< n {
			l[i] *= gain[i] * g
		}
		if node.stereo {
			for i in 0 ..< n {
				r[i] *= gain[i] * g
			}
		}
	} else if g *= gain_db; g != 1 {
		for i in 0 ..< n {
			l[i] *= g
		}
		if node.stereo {
			for i in 0 ..< n {
				r[i] *= g
			}
		}
	}
	pan: [NODE_CHUNK]f32 = ---
	if varies, p := node_curve(c, lane, FIELD_PAN, pan_base, pan[:n]); varies {
		for i in 0 ..< n {
			q := clamp(pan[i], -1, 1)
			l[i] *= 1 - q
			r[i] *= 1 + q
		}
	} else if p != 0 {
		p = clamp(p, -1, 1)
		for i in 0 ..< n {
			l[i] *= 1 - p
			r[i] *= 1 + p
		}
	}
}

slice_zero :: #force_inline proc "contextless" (x: []f32) {
	for i in 0 ..< len(x) {
		x[i] = 0
	}
}

// The node's start for each lane whose note starts in this chunk.
@(private = "file")
node_starts :: proc(c: ^Node_Call) {
	if start := node_row(c.node.kind).start; start != nil {
		for &lane in c.lanes {
			if lane.starting || lane.fresh {
				start(c, &lane)
			}
		}
	}
}

// One voice (a single note on its own): plays its next len(l) samples, adding
// into l and r, `at` how many earlier calls played (0 starts it); false once
// it is silent for good. What tests and a
// host's one-shots call.
voice_graph :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	if at == 0 {
		if _, ok := graph_start(s, p, n, env, true); !ok {
			return false
		}
	}
	h := (^Graph_Header)(s)
	if graph_program(p, env) < 0 || h.total == 0 {
		return false
	}
	prog := &env.programs.programs[h.program]
	scratch: [MAX_BUFS * 2 * NODE_CHUNK]f32 = ---
	v := [1]Graph_Voice{{state = s, note = n, seed = seed, at = at, gain = 1}}
	frames := min(len(l), len(r))
	for done := 0; done < frames; done += NODE_CHUNK * 8 {
		m := min(NODE_CHUNK * 8, frames - done)
		v[0].out_l, v[0].out_r = l[done:][:m], r[done:][:m]
		graph_run(env.programs, env, h.program, v[:], m, scratch[:graph_scratch(prog, 1)])
	}
	return !v[0].done
}

// ---- layers ------------------------------------------------------------------------

// A one-shot's gate (seconds): longer than anything it plays.
ONE_SHOT_GATE :: 3600

// The most layers one note starts.
MAX_LAYERS :: 64

// The layers (into Programs.layers) a note of program `index` starts, into
// out (a program whose layer_mode is All: every region whose conditions it
// meets; One: none, graph_resolve picks). `rand` is the note's draw 0..1
// (-1: any, for an estimate).
graph_layers :: proc(progs: ^Programs, index: i32, n: Note, rand: f32, out: []i32) -> int {
	prog := &progs.programs[index]
	if prog.layer_mode != .All || n.kind == .Keyswitch {
		return 0
	}
	key := int(math.round(n.pitch))
	velocity := velocity_midi(n.velocity)
	count := 0
	for layer, i in progs.layers[prog.layers.first:base.span_end(prog.layers)] {
		if count == len(out) {
			break
		}
		l := progs.regions[layer.row]
		if key < int(l.lo_key) || key > int(l.hi_key) || velocity < int(l.lo_vel) || velocity > int(l.hi_vel) || !LAYER_TRIGGERS[l.trigger](n) {
			continue
		}
		if rand >= 0 && (rand < l.lo_rand || rand >= l.hi_rand) {
			continue
		}
		if l.seq_length > 1 && rand >= 0 && int(n.round) % int(l.seq_length) + 1 != int(l.seq_position) {
			continue
		}
		if l.sw_last_lo != 0 && (n.keyswitch < l.sw_last_lo || n.keyswitch > l.sw_last_hi) {
			continue
		}
		out[count] = prog.layers.first + i32(i)
		count += 1
	}
	return count
}

// A layer's values where they differ from its program's (none: -1).
layer_params :: proc(progs: ^Programs, layer: i32) -> []Layer_Param {
	if layer < 0 || int(layer) >= len(progs.layers) {
		return nil
	}
	sp := progs.layers[layer].params
	return progs.layer_params[sp.first:base.span_end(sp)]
}

// A node's value (local `node` of the layer's program) as the layer plays it.
layer_value :: proc(progs: ^Programs, layer: i32, program: i32, node: int, slot: int) -> f32 {
	for p in layer_params(progs, layer) {
		if int(p.node) == node && int(p.slot) == slot {
			return p.value
		}
	}
	prog := progs.programs[program]
	return progs.nodes[prog.nodes.first + i32(node)].values[slot]
}

// The layer a voice plays (-1: none).
graph_layer :: proc(s: ^Voice_State) -> i32 {return (^Graph_Header)(s).layer}

// Has the voice's note let go now (its gate ends at the sample it has
// reached: an SFZ off_mode normal, a group's polyphony), so it releases.
graph_release_now :: proc(s: ^Voice_State) {
	h := (^Graph_Header)(s)
	h.gate = min(h.gate, h.pos)
}
