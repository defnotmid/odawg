package odawg_render

import "base:runtime"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
import common "deps:odecs/common"
import base "../base"
import device "../device"
import dsp "../dsp"
import song "../song"

// The engine streams a song: any block of samples, in order, from wherever
// it was put. It walks the song's routing (song.nodes, song.edges) in an
// order computed once, every node after everything feeding it: a track
// renders its voices and chain, a part, a return or a bus sums its inputs
// and runs its chain, the master sums its inputs and masters them. Its
// state is tables sized once from the song: per track a pool of voice
// slots (as many as the track ever has sounding at once, one for a mono
// device) and a cursor into its notes; per node its effect instances, a
// block, its lead and latency; per edge a delay line where paths of
// different latency meet. Nothing is allocated while it plays, and the
// samples never depend on the block sizes it is asked for, so a render is
// the stream from 0 and a preview, a scrub and a final render hear the
// same song.
//
// It renders a chunk at a time: every node its chunks' blocks in a row, each
// chunk once what feeds it has made it. On the caller's pool (a
// common.Work_Pool it lends: the engine owns no threads), a walk is one
// `run` of loops, each taking whatever node's next chunk is ready, so nodes
// run ahead of the slowest, up to RING chunks past the last one taken (handed
// on, in order, as it is made); a loop sleeps only when no node can go on. A
// node's sound is its own state over its inputs, so which thread runs it, and
// when, changes nothing: any pool, or none, gives the same stream.

BLOCK :: 1024 // what a track processes at a time (any size gives the same samples)
CHUNK_BLOCKS :: 8 // a node's blocks in a row before what it feeds reads them
CHUNK :: CHUNK_BLOCKS * BLOCK
RING :: 4 // a node's chunks held at once: how far it may run ahead of the last taken
MAX_LOOPS :: 33 // a walk's loops at most (a pool's map runs as many as it has threads)
// A worker's scratch: a track's block, its send, a discard (seeks, mutes), a
// choked note's.
SCRATCH :: 8 * BLOCK
// Samples a track stays awake past its tails' estimate (a reverb's last
// -60 dB).
DORMANT_MARGIN :: RATE / 10
SIDECHAIN_BLOCK :: 64 // the ducking gain steps on the song's own grid of these
MAX_POLYPHONY :: 256

Engine :: struct {
	song:      ^song.Song,
	env:       device.Voice_Env,
	tracks:    []Track_Run,
	voices:    []u8, // every track's slots, each its device's state size
	slot_at_byte: []int, // where each slot's state starts in voices
	slot_note: []i32, // the note a slot plays (-1: free)
	slot_at:   []i64, // samples of it played
	slot_choke: []i32, // samples left of a choked note's fade (0: not choked)
	slot_choke_len: []i32, // the fade's whole length
	fx:        []Fx_Run,
	fx_bytes:  []u8,
	// The routing: a run per node (song.nodes), the order they render in,
	// the buffer each holds for each chunk of the ring (-1: none, it wrote
	// nothing) and whether each block of it holds sound (CHUNK_BLOCKS a
	// chunk), and per edge (song.edges) its delay line (empty: none).
	nodes:     []Node_Run,
	order:     []i32,
	buffer_of: []i32, // per node and ring slot
	buffers:   Buffers,
	dirty:     []bool,
	edges:     []Edge_Run,
	rings:     []f32,
	cursor:    i64, // the song sample of the next output (a walk's first while it renders)
	ahead:     i64, // how far the nodes run ahead of it: the master's lookahead, primed at a seek
	pool:      ^common.Work_Pool, // the caller's (nil: the caller's thread alone)
	flow:      Flow,
	workers:   []Worker, // scratch, one a loop
	master:    Master_Run, // the song's master: its gain, chain, lookahead, what it measured
	no_master: bool, // its host runs the master itself, over what the engine gives in order
	stem_gain: []f32, // per stem (stem_count): its placement's level, so a stem is what the master hears of it
	lanes:     Lanes,
	// What it plays of the song's values a host may change while it plays
	// (song.command_apply, then engine_sync): its own copies, so an edit to
	// the song never races a render, each reaching here through `edits` at
	// the start of a walk; and its own copy of the instruments (a lane or an
	// edit writes them).
	mix:       Mix,
	programs:  device.Programs,
	edits:     Edits,
	arena:     virtual.Arena,
}

// The values a command changes, as the engine plays them: each device's
// params, each track's fader, pan and mute, each edge's gain, each
// placement's level, the pads' levels. A level a command moves glides there.
Mix :: struct {
	params:     []device.Params, // per song.devices
	tracks:     []Track_Mix,
	edges:      []Level, // per song.edges: linear
	placements: []Level, // per song.placements: linear
	pad_gains:  [dynamic]song.Pad_Gain,
}

Track_Mix :: struct {
	gain:  Level, // linear
	pan:   Level,
	muted: bool,
}

// A level gliding from `from` to `to` over GLIDE samples from node sample
// `at` (an edit's: no click), else held at `to`.
Level :: struct {
	from, to: f64,
	at:       i64,
}

GLIDE :: RATE / 100 // 10 ms

level_at :: #force_inline proc(l: Level, t: i64) -> f64 {
	if t >= l.at + GLIDE {
		return l.to
	}
	if t <= l.at {
		return l.from
	}
	return l.from + (l.to - l.from) * f64(t - l.at) / GLIDE
}

// Whether it moves over n samples from t.
level_moving :: #force_inline proc(l: Level, t: i64, n: int) -> bool {
	return l.from != l.to && t < l.at + GLIDE && t + i64(n) > l.at
}

// Edits waiting for the next walk: a host's thread adds them (engine_sync),
// the engine applies them before it renders on (no node runs then). What
// they carry is copied from the song when they are made.
Edits :: struct {
	mutex:   sync.Mutex,
	pending: [dynamic]Edit,
	arena:   virtual.Arena, // what they carry (programs, pad gains)
}

Edit_Kind :: enum u8 {
	Track, // ref's fader (dB), pan, mute
	Edge, // ref's gain (linear)
	Placement, // ref's level (dB)
	Params, // device ref's params
	Pad_Gains, // the whole table
	Program, // program ref's rows: its nodes, mods, inputs, controls
	Master, // the master's gain (dB)
}

Edit :: struct {
	kind:     Edit_Kind,
	ref:      i32,
	value:    f64,
	pan:      f64,
	muted:    bool,
	params:   device.Params,
	pads:     []song.Pad_Gain,
	program:  device.Program,
	nodes:    []device.Graph_Node,
	mods:     []device.Mod, // from mods_at in Programs.mods
	mods_at:  i32,
	inputs:   []device.Graph_Input, // from inputs_at
	inputs_at: i32,
	controls: []device.Control_Row,
}

// The song's automation rows (song.automation) by what reads them: an
// effect instance (per Fx_Run), a track (its fader, pan and controls), an
// edge (a send), a placement's node (its level). Spans into rows.
Lanes :: struct {
	rows:       []i32,
	fx:         []base.Span,
	tracks:     []base.Span,
	edges:      []base.Span,
	placements: []base.Span,
}

// What one node's run of a chunk uses besides its own rows, a worker's own:
// the chunk (its slot in the ring, its first song sample, its samples, and
// whether the master runs: a seek's walk stops before it), its voices' lanes
// (the largest call of device.graph_run), its effects' scratch, its track
// scratch, the key the node hears (its key edges summed; nil: none) and its
// block, and a temp allocator, emptied after each node.
Worker :: struct {
	slot:       int,
	at:         i64,
	frames:     int,
	master:     bool,
	graph:      []f32,
	fx_scratch: ^device.Fx_Scratch,
	scratch:    []f32, // a discard (2 x BLOCK) at 4 x BLOCK, a choked note's at 6 x BLOCK
	keys:       []f32, // 2 x BLOCK
	gains:      []f32, // BLOCK: a moving level's per sample
	key_l, key_r: []f32,
	temp:       virtual.Arena,
}

// A walk's chunks through the nodes: per node the nodes feeding it and fed
// by it (the edges that aren't a loop's), how many of the walk's chunks it
// has made, and whether its next is queued; the queue; per ring slot the
// nodes still to make its chunk; the chunks taken. A loop takes a queued node,
// makes its next chunk, queues whatever that let go on, and takes the next
// chunk in order once every node has made it.
Flow :: struct {
	sources:    []i32, // by sources_of
	sources_of: []base.Span,
	feeds:      []i32, // by feeds_of
	feeds_of:   []base.Span,
	made:       []i32, // per node: the walk's chunks it has made
	queued:     []i32, // per node: 1 from queued until its chunk is made
	queue:      []i32, // the nodes queued (a ring of len(nodes))
	head, tail: int, // under mutex
	mutex:      sync.Mutex,
	left:       [RING]i32, // per slot: the nodes still to make its chunk
	taken:      i32, // the walk's chunks handed on
	taking:     i32, // 1 while a loop hands one on
	chunks:     int, // the walk's
	frames:     int,
	master:     bool,
	out:        ^Walk_Out,
	progress:   sync.Futex, // bumped as anything moves on: idle loops wait on it
}

// The chunk buffers (2 x CHUNK each, the left then the right), shared: a
// node takes one for a chunk only when it may write in it, and every chunk's
// go back as the chunk is taken (everything has read it then), so what they
// hold is what sounds at once, never every node's. Slabs of BUFFER_SLAB,
// more only when more nodes than ever sound at once; the slabs' list has
// room for all there could be (RING a node), so it never moves.
Buffers :: struct {
	slabs: [dynamic][]f32, // the heap's
	free:  [dynamic]i32,
	mutex: sync.Mutex,
}

BUFFER_SLAB :: 16

// A node as the engine runs it. Its output runs `lead` samples ahead of the
// song cursor (what the lookahead of everything after it needs), its input
// `latency` more (its own chain's lookahead). An exact seek starts it `pre`
// samples early: its own effects' memory and that of everything after it.
Node_Run :: struct {
	chain:   base.Span, // into fx
	inputs:  base.Span, // into song.edges: what feeds it
	lead:    i64,
	latency: i64,
	pre:     i64,
	started: bool, // during an exact seek: rendering yet
	// Dormancy: past `awake_until` (an input sample) a node is silent and
	// does no work: a bus's or a return's chain once its input has been
	// silent for its tail, waking (reset) on the first sample of sound; a
	// track's once every started note's tail and its chain's are over and no
	// slot sounds, waking (its effects reset) where its next note starts. Both
	// edges come from the sound or the notes, never from where a block falls.
	awake_until: i64,
	tail:    i64,
	origin:  i64, // where its placement's clock starts (song samples): its effects run on its song's time
	placement: i32, // its placement (-1: none, a clip's): its song's tempo map is what its beats are on
}

// An edge whose paths' latencies differ: the source's output delayed to its
// destination's time (a ring per channel in `rings`).
Edge_Run :: struct {
	looped: bool, // it closes a loop: left out
	delay: i64,
	ring:  base.Span, // into rings: left, then right, each ring.count / 2 (a power of two)
	pos:   i64, // the source sample the ring's next write is
	sound: i64, // the source sample of the last sound written (the ring holds sound until it is read)
}

// What the master saw: the mix after its gain, before its chain, and the
// most its chain took off a block's peak.
Master_Stats :: struct {
	peak_before:    f32, // linear
	clipped_before: int, // samples past full scale
	reduction_db:   f32, // <= 0
}

Track_Run :: struct {
	cursor:    i64, // the song sample of its next output (its node's latency, tail and awake_until are its chain's)
	lane_cell: i64, // the automation cell its controls were last set for (-1: none yet)
	slots:     base.Span, // into voices
	next_note: i32, // into song.notes: the next to start
	stolen:    int, // notes that found no free slot (a finding)
	placement: i32, // its song's (song.node_placement; -1: a clip's): where it makes room
}

Fx_Run :: struct {
	device: i32, // into song.devices
	state:  base.Span, // into fx_bytes
}

// Sizes the engine for a song and puts it at sample 0: rendering on the
// caller's thread or, lent, the caller's pool (a map of loops each walk), its
// master mastered as `mastering` says (none: the song's own). Don't render
// from a range the same pool is running.
engine_init :: proc(e: ^Engine, s: ^song.Song, pool: ^common.Work_Pool = nil, mastering := Mastering{}) -> bool {
	e.song = s
	e.env = song.voice_env(s)
	if len(s.nodes) == 0 {
		return false // its routing is built when it is composed (song_from_spec, mix_end)
	}
	if virtual.arena_init_growing(&e.arena) != nil {
		return false
	}
	context.allocator = virtual.arena_allocator(&e.arena)
	e.tracks = make([]Track_Run, len(s.tracks))
	slots_total, fx_total := 0, 0
	for t, ti in s.tracks {
		run := &e.tracks[ti]
		run.slots = {i32(slots_total), i32(polyphony_from_track(s, t))}
		slots_total += int(run.slots.count)
	}
	for nd, k in s.nodes {
		if nd.kind != .Master { // the master's chain runs in its Master_Run
			fx_total += int(song.node_chain(s, k).count)
		}
	}
	max_bufs := 0
	for prog in s.programs.programs {
		max_bufs = max(max_bufs, int(prog.bufs))
	}
	bytes_total, graph_total := 0, 0
	for t, ti in s.tracks {
		p := s.params[t.instrument]
		bytes_total += int(e.tracks[ti].slots.count) * device.voice_bytes(&p, &e.env)
		graph_total = max(graph_total, int(e.tracks[ti].slots.count) * max_bufs * 2 * device.NODE_CHUNK)
	}
	e.voices, _ = mem.make_aligned([]u8, bytes_total, 16)
	e.slot_at_byte = make([]int, slots_total)
	{
		at := 0
		for t, ti in s.tracks {
			p := s.params[t.instrument]
			size := device.voice_bytes(&p, &e.env)
			for k in e.tracks[ti].slots.first ..< base.span_end(e.tracks[ti].slots) {
				e.slot_at_byte[k] = at
				at += size
			}
		}
	}
	e.slot_note = make([]i32, slots_total)
	e.slot_at = make([]i64, slots_total)
	e.slot_choke = make([]i32, slots_total)
	e.slot_choke_len = make([]i32, slots_total)
	e.fx = make([]Fx_Run, fx_total)
	// each node's effect instances and their state bytes, 16-aligned each
	e.nodes = make([]Node_Run, len(s.nodes))
	bytes, fi := 0, 0
	for _, k in s.nodes {
		run := &e.nodes[k]
		run.placement = song.node_placement(s, k)
		if pl := run.placement; pl >= 0 {
			run.origin = i64(math.round(s.placements[pl].at * RATE))
		}
		first := fi
		c := s.nodes[k].kind == .Master ? base.Span{} : song.node_chain(s, k)
		for d in s.chain[c.first:base.span_end(c)] {
			p := song.params_largest(s, d) // its delay lines as long as a lane takes them
			size := (device.effect_size(s.devices[d], &p, &s.programs) + 15) &~ 15
			e.fx[fi] = {d, {i32(bytes), i32(size)}}
			bytes += size
			fi += 1
			if lat := device.DEVICE_TABLE[s.devices[d]].effect_latency; lat != nil {
				run.latency += i64(lat(&p))
			}
		}
		run.chain = {i32(first), i32(fi - first)}
	}
	e.fx_bytes, _ = mem.make_aligned([]u8, bytes, 16) // a row's voice is 16-aligned
	master_run_init(&e.master, s, mastering)
	for ti in 0 ..< len(s.tracks) {
		e.tracks[ti].placement = song.node_placement(s, ti)
	}
	e.stem_gain = make([]f32, stem_count(s))
	for &g, p in e.stem_gain {
		g = 1
		if pl := song.node_placement(s, len(s.tracks) + p); pl >= 0 {
			g = f32(base.db_to_gain(s.placements[pl].gain_db))
		}
	}
	// the order, each node's inputs (the edges are sorted by where they go)
	loops: [dynamic]int
	e.order, loops = song.graph_order(s)
	looped := make([]bool, len(s.edges), context.temp_allocator)
	for i in loops {
		looped[i] = true // reported when the routing was built
	}
	for x, i in s.edges {
		if looped[i] {
			continue
		}
		inputs := &e.nodes[x.to].inputs
		if inputs.count == 0 {
			inputs.first = i32(i)
		}
		inputs.count = i32(i) - inputs.first + 1
	}
	// leads (backwards: each after everything it feeds), then each edge's
	// delay, where its source runs further ahead than its destination needs;
	// the master's own lookahead is primed at a seek, not led
	// (the master's chain runs in its Master_Run: its node has no latency)
	at_input := proc(e: ^Engine, s: ^song.Song, k: i32) -> i64 {
		return e.nodes[k].lead + e.nodes[k].latency
	}
	#reverse for k in e.order {
		for x, i in s.edges {
			if x.from == k && !looped[i] {
				e.nodes[k].lead = max(e.nodes[k].lead, at_input(e, s, x.to))
			}
		}
	}
	e.edges = make([]Edge_Run, len(s.edges))
	ring_total := 0
	for x, i in s.edges {
		if looped[i] {
			e.edges[i].looped = true
			continue
		}
		if d := e.nodes[x.from].lead - at_input(e, s, x.to); d > 0 {
			size := 1
			for size < int(d) + BLOCK {
				size *= 2
			}
			e.edges[i] = {delay = d, ring = {i32(ring_total), i32(2 * size)}}
			ring_total += 2 * size
		}
	}
	e.rings = make([]f32, ring_total)
	// an exact seek's start per node, and how long its chain rings
	pres := prerolls_from_song(s, e.order, looped, context.temp_allocator)
	for &nd, k in e.nodes {
		nd.pre = pres[k]
		nd.tail = i64(math.ceil(node_memory(s, k).state * RATE)) + DORMANT_MARGIN
	}
	e.buffer_of = make([]i32, RING * len(s.nodes))
	slice.fill(e.buffer_of, -1)
	// at most a buffer per node and slot: room for every slab that could be,
	// so growing never moves what a reader is looking through
	most := RING * len(s.nodes)
	e.buffers.slabs = make([dynamic][]f32, 0, (most + BUFFER_SLAB - 1) / BUFFER_SLAB, runtime.heap_allocator())
	e.buffers.free = make([dynamic]i32, 0, most + BUFFER_SLAB, runtime.heap_allocator())
	for _ in 0 ..< (RING * min(len(s.nodes), 32) + BUFFER_SLAB - 1) / BUFFER_SLAB {
		buffers_grow(&e.buffers)
	}
	e.dirty = make([]bool, RING * CHUNK_BLOCKS * len(s.nodes))
	e.pool = pool
	// a worker a loop: as many as nodes can run at once, at most the most
	// threads a pool lends
	e.workers = make([]Worker, pool != nil ? clamp(len(s.nodes), 1, MAX_LOOPS) : 1)
	for &w in e.workers {
		w.graph = make([]f32, graph_total)
		w.fx_scratch = new(device.Fx_Scratch)
		w.scratch = make([]f32, SCRATCH)
		w.keys = make([]f32, 2 * BLOCK)
		w.gains = make([]f32, BLOCK)
		_ = virtual.arena_init_growing(&w.temp)
	}
	mix_init(e)
	// what a Row plays: the engine's own instruments
	for &w in e.workers {
		w.fx_scratch.env = &e.env
	}
	e.master.scratch.env = &e.env
	if len(s.placement_tempo) > 0 {
		e.master.scratch.tempo = &s.placement_tempo[0] // the song's own (a mix's first)
	}
	lanes_init(e)
	flow_init(e, looped)
	engine_seek(e, 0, false)
	return true
}

// The engine's copies of what an edit changes, and of the instruments.
@(private = "file")
mix_init :: proc(e: ^Engine) {
	s := e.song
	m := &e.mix
	m.params = slice.clone(s.params[:])
	m.tracks = make([]Track_Mix, len(s.tracks))
	for t, ti in s.tracks {
		g := base.db_to_gain(t.gain_db)
		m.tracks[ti] = {gain = {g, g, 0}, pan = {t.pan, t.pan, 0}, muted = t.muted}
	}
	m.edges = make([]Level, len(s.edges))
	for x, i in s.edges {
		m.edges[i] = {f64(x.gain), f64(x.gain), 0}
	}
	m.placements = make([]Level, len(s.placements))
	for pl, i in s.placements {
		g := base.db_to_gain(pl.gain_db)
		m.placements[i] = {g, g, 0}
	}
	m.pad_gains = slice.clone_to_dynamic(s.pad_gains[:])
	e.programs = s.programs
	e.programs.programs = slice.clone_to_dynamic(s.programs.programs[:])
	e.programs.nodes = slice.clone_to_dynamic(s.programs.nodes[:])
	e.programs.mods = slice.clone_to_dynamic(s.programs.mods[:])
	e.programs.inputs = slice.clone_to_dynamic(s.programs.inputs[:])
	e.programs.controls = slice.clone_to_dynamic(s.programs.controls[:])
	e.env.programs = &e.programs
	e.edits.pending = make([dynamic]Edit, runtime.heap_allocator())
	_ = virtual.arena_init_growing(&e.edits.arena)
}

// What `row` (applied to the song: song.command_apply) changed, copied from
// the song now (on the host's thread, which edits it) and queued for the
// engine's next walk. A level glides there over GLIDE; an effect's or an
// instrument's value steps there. A lane on the same value still wins.
engine_sync :: proc(e: ^Engine, row: song.Command_Row) {
	s := e.song
	sync.mutex_lock(&e.edits.mutex)
	defer sync.mutex_unlock(&e.edits.mutex)
	carry := virtual.arena_allocator(&e.edits.arena)
	push :: proc(e: ^Engine, x: Edit) {append(&e.edits.pending, x)}
	tracks_of :: proc(s: ^song.Song, path: string) -> []int {
		part, _ := song.part_from_path(s, path)
		out := make([dynamic]int, context.temp_allocator)
		for t, ti in s.tracks {
			if part >= 0 && int(t.part) == part {
				append(&out, ti)
			}
		}
		return out[:]
	}
	switch row.kind {
	case .None:
	case .Part_Gain_Set, .Part_Gain_Step, .Part_Pan_Set, .Part_Mute_Set:
		for ti in tracks_of(s, row.path) {
			t := s.tracks[ti]
			push(e, {kind = .Track, ref = i32(ti), value = t.gain_db, pan = t.pan, muted = t.muted})
		}
	case .Pad_Gain_Set, .Pad_Gain_Step:
		push(e, {kind = .Pad_Gains, pads = slice.clone(s.pad_gains[:], carry)})
	case .Param_Set:
		// the instrument's programs (its layers' and pads' too), whole
		done := make([dynamic]i32, context.temp_allocator)
		for ti in tracks_of(s, row.path) {
			reach :: proc(progs: ^device.Programs, program: i32, out: ^[dynamic]i32) {
				if program < 0 || slice.contains(out[:], program) {
					return
				}
				append(out, program)
				p := progs.programs[program]
				for pr in progs.layers[p.layers.first:base.span_end(p.layers)] {
					reach(progs, pr.program, out)
				}
			}
			reach(&s.programs, i32(s.params[s.tracks[ti].instrument][.Program]), &done)
		}
		for pi in done {
			push(e, program_edit(s, pi, carry))
		}
	case .Master_Gain_Set, .Master_Gain_Step:
		push(e, {kind = .Master, value = s.master_gain_db})
	case .Send_Set:
		for x, i in s.edges {
			if e.mix.edges[i].to != f64(x.gain) {
				push(e, {kind = .Edge, ref = i32(i), value = f64(x.gain)})
			}
		}
	case .Effect_Param_Set:
		for d in song.command_devices(s, row) {
			push(e, {kind = .Params, ref = d, params = s.params[d]})
		}
		// an effect row's option: its program, whole
		for pi in song.command_programs(s, song.command_rows(s, row)) {
			push(e, program_edit(s, pi, carry))
		}
	}
}

// Program pi as the song has it now (its nodes, the modulators and inputs
// they span, its controls), copied for the engine's next walk.
@(private = "file")
program_edit :: proc(s: ^song.Song, pi: i32, carry: mem.Allocator) -> Edit {
	p := s.programs.programs[pi]
	x := Edit{kind = .Program, ref = pi, program = p}
	x.nodes = slice.clone(s.programs.nodes[p.nodes.first:base.span_end(p.nodes)], carry)
	mods_first, mods_end := i32(len(s.programs.mods)), i32(0)
	inputs_first, inputs_end := i32(len(s.programs.inputs)), i32(0)
	for n in x.nodes {
		if n.mods.count > 0 {
			mods_first, mods_end = min(mods_first, n.mods.first), max(mods_end, base.span_end(n.mods))
		}
		if n.inputs.count > 0 {
			inputs_first, inputs_end = min(inputs_first, n.inputs.first), max(inputs_end, base.span_end(n.inputs))
		}
	}
	if mods_end > mods_first {
		x.mods, x.mods_at = slice.clone(s.programs.mods[mods_first:mods_end], carry), mods_first
	}
	if inputs_end > inputs_first {
		x.inputs, x.inputs_at = slice.clone(s.programs.inputs[inputs_first:inputs_end], carry), inputs_first
	}
	x.controls = slice.clone(s.programs.controls[p.controls.first:base.span_end(p.controls)], carry)
	return x
}

// The edits waiting, applied (at a walk's start: nothing renders).
@(private = "file")
edits_apply :: proc(e: ^Engine) {
	ed := &e.edits
	if !sync.mutex_try_lock(&ed.mutex) {
		return // a host adding one now: the next walk takes them
	}
	defer sync.mutex_unlock(&ed.mutex)
	if len(ed.pending) == 0 {
		return
	}
	glide :: proc(l: ^Level, to: f64, at: i64) {
		l^ = {level_at(l^, at), to, at}
	}
	m := &e.mix
	for x in ed.pending {
		switch x.kind {
		case .Track:
			at := e.cursor + e.ahead + e.nodes[x.ref].lead
			tm := &m.tracks[x.ref]
			glide(&tm.gain, base.db_to_gain(x.value), at)
			glide(&tm.pan, x.pan, at)
			tm.muted = x.muted
		case .Edge:
			glide(&m.edges[x.ref], x.value, e.cursor + e.ahead + e.nodes[e.song.edges[x.ref].to].lead)
		case .Placement:
			glide(&m.placements[x.ref], base.db_to_gain(x.value), e.cursor + e.ahead)
		case .Params:
			m.params[x.ref] = x.params
		case .Pad_Gains:
			clear(&m.pad_gains)
			append(&m.pad_gains, ..x.pads)
		case .Program:
			progs := &e.programs
			p := x.program
			progs.programs[x.ref] = p
			copy(progs.nodes[p.nodes.first:], x.nodes)
			copy(progs.mods[x.mods_at:], x.mods)
			copy(progs.inputs[x.inputs_at:], x.inputs)
			copy(progs.controls[p.controls.first:], x.controls)
			for &t in e.tracks {
				t.lane_cell = -1 // a lane on it sets it again
			}
		case .Master:
			if e.master.songs {
				e.master.gain_to = x.value
			}
		}
	}
	clear(&ed.pending)
	virtual.arena_free_all(&ed.arena)
}

// The lanes by what reads them (counted, then filled).
@(private = "file")
lanes_init :: proc(e: ^Engine) {
	s := e.song
	l := &e.lanes
	l.fx = make([]base.Span, len(e.fx))
	l.tracks = make([]base.Span, len(s.tracks))
	l.edges = make([]base.Span, len(s.edges))
	l.placements = make([]base.Span, len(s.placements))
	for &t in e.tracks {
		t.lane_cell = -1
	}
	if len(s.automation) == 0 {
		return
	}
	// each row's reader: its table and the slot in it
	Reader :: struct {
		table: ^[]base.Span,
		slot:  int,
	}
	readers := make([]Reader, len(s.automation), context.temp_allocator)
	controls := false
	for a, i in s.automation {
		r := Reader{slot = -1}
		switch a.kind {
		case .Track_Gain, .Track_Pan, .Control:
			r = {&l.tracks, int(a.kind == .Control ? a.track : a.ref)}
			controls ||= a.kind == .Control
		case .Param:
			for f, fi in e.fx {
				if f.device == a.ref {
					r = {&l.fx, fi}
				}
			}
		case .Effect_Control:
			// the effect row playing the program the control moves
			program := device.control_program(&s.programs, a.ref)
			for f, fi in e.fx {
				if device.DEVICE_TABLE[s.devices[f.device]].program && program >= 0 && i32(e.mix.params[f.device][.Program]) == program {
					r = {&l.fx, fi}
				}
			}
		case .Send:
			from, to := song.node_index(s, a.from), song.node_index(s, a.to)
			for x, xi in s.edges {
				if x.from == from && x.to == to && x.kind == .Audio {
					r = {&l.edges, xi}
				}
			}
		case .Placement_Gain:
			r = {&l.placements, int(a.ref)}
		}
		readers[i] = r
	}
	// sized, then filled: a table's spans in its slots' order
	count := 0
	for table in ([4]^[]base.Span{&l.fx, &l.tracks, &l.edges, &l.placements}) {
		for &sp, slot in table^ {
			sp.first = i32(count)
			for r in readers {
				if r.table == table && r.slot == slot {
					sp.count += 1
				}
			}
			count += int(sp.count)
		}
	}
	l.rows = make([]i32, count)
	filled := make([]i32, count, context.temp_allocator)
	for r, i in readers {
		if r.slot < 0 {
			continue
		}
		sp := r.table[r.slot]
		l.rows[sp.first + filled[sp.first]] = i32(i)
		filled[sp.first] += 1
	}
	_ = controls
}

// Track ti's controls set from its lanes for the cell song sample `at` is
// in (once a cell), and what follows from them derived.
@(private = "file")
track_lanes_apply :: proc(e: ^Engine, ti: int, at: i64) {
	s := e.song
	run := &e.tracks[ti]
	cell := song.automation_cell(at)
	if cell == run.lane_cell {
		return
	}
	run.lane_cell = cell
	moved := false
	for i in lane_rows(e, e.lanes.tracks[ti]) {
		a := s.automation[i]
		if a.kind == .Control {
			device.control_apply(&e.programs, &e.programs.controls[a.ref], song.automation_value(s, a, cell))
			moved = true
		}
	}
	if moved {
		device.program_derive(&e.programs, i32(s.params[s.tracks[ti].instrument][.Program]))
	}
}

// Whether track ti has a lane on its instrument.
@(private = "file")
track_has_controls :: proc(e: ^Engine, ti: int) -> bool {
	for i in lane_rows(e, e.lanes.tracks[ti]) {
		if e.song.automation[i].kind == .Control {
			return true
		}
	}
	return false
}

@(private = "file")
lane_rows :: #force_inline proc(e: ^Engine, sp: base.Span) -> []i32 {
	return e.lanes.rows[sp.first:base.span_end(sp)]
}

// Where a piece from song sample `at` that may run `n` samples ends (in
// samples from at): at the next cell's edge when lanes step in it.
@(private = "file")
cell_piece :: #force_inline proc(at: i64, n: int, stepped: bool) -> int {
	if !stepped {
		return n
	}
	return int(min(i64(n), song.automation_cell(at) + song.AUTOMATION_CELL - at))
}

// A moving level (a lane in dB, or the engine's `level` when lane < 0)
// over n samples from song sample `at`, linear, in w.gains.
@(private = "file")
lane_gains :: proc(e: ^Engine, w: ^Worker, lane: i32, level: Level, at: i64, n: int) -> []f32 {
	g := w.gains[:n]
	if lane < 0 {
		for i in 0 ..< n {
			g[i] = f32(level_at(level, at + i64(i)))
		}
		return g
	}
	a := e.song.automation[lane]
	for i in 0 ..< n {
		g[i] = f32(base.db_to_gain(f64(song.automation_value(e.song, a, at + i64(i)))))
	}
	return g
}

engine_destroy :: proc(e: ^Engine) {
	delete(e.edits.pending)
	virtual.arena_destroy(&e.edits.arena)
	for slab in e.buffers.slabs {
		delete(slab, runtime.heap_allocator())
	}
	delete(e.buffers.slabs)
	delete(e.buffers.free)
	for &w in e.workers {
		virtual.arena_destroy(&w.temp)
	}
	virtual.arena_destroy(&e.arena)
	e^ = {}
}

@(private = "file")
buffers_grow :: proc(b: ^Buffers) {
	first := i32(len(b.slabs) * BUFFER_SLAB)
	append(&b.slabs, make([]f32, BUFFER_SLAB * 2 * CHUNK, runtime.heap_allocator()))
	for i := i32(BUFFER_SLAB) - 1; i >= 0; i -= 1 {
		append(&b.free, first + i)
	}
}

// A buffer for node k's chunk in the worker's slot, unless it holds one.
@(private = "file")
buffer_take :: proc(e: ^Engine, w: ^Worker, k: int) {
	at := &e.buffer_of[k * RING + w.slot]
	if at^ >= 0 {
		return
	}
	b := &e.buffers
	sync.mutex_lock(&b.mutex)
	if len(b.free) == 0 {
		buffers_grow(b)
	}
	at^ = pop(&b.free)
	sync.mutex_unlock(&b.mutex)
}

// Every buffer of ring slot `slot` back: its chunk was taken.
@(private = "file")
buffers_give :: proc(e: ^Engine, slot: int) {
	b := &e.buffers
	sync.mutex_lock(&b.mutex)
	for k in 0 ..< len(e.nodes) {
		at := &e.buffer_of[k * RING + slot]
		if at^ >= 0 {
			append(&b.free, at^)
			at^ = -1
		}
	}
	sync.mutex_unlock(&b.mutex)
}

// Each node's sources and feeds (by the edges that aren't a loop's).
@(private = "file")
flow_init :: proc(e: ^Engine, looped: []bool) {
	s := e.song
	f := &e.flow
	n := len(s.nodes)
	f.made = make([]i32, n)
	f.queued = make([]i32, n)
	f.queue = make([]i32, n)
	f.sources_of = make([]base.Span, n)
	f.feeds_of = make([]base.Span, n)
	for x, i in s.edges {
		if !looped[i] {
			f.sources_of[x.to].count += 1
			f.feeds_of[x.from].count += 1
		}
	}
	spans :: proc(of: []base.Span) -> []i32 {
		at: i32
		for &sp in of {
			sp.first = at
			at += sp.count
			sp.count = 0
		}
		return make([]i32, at)
	}
	f.sources = spans(f.sources_of)
	f.feeds = spans(f.feeds_of)
	for x, i in s.edges {
		if !looped[i] {
			src := &f.sources_of[x.to]
			f.sources[src.first + src.count] = x.from
			src.count += 1
			fd := &f.feeds_of[x.from]
			f.feeds[fd.first + fd.count] = x.to
			fd.count += 1
		}
	}
}

// Whether node k's next chunk can be made: within the walk and the ring
// (RING past what has been taken), everything feeding it made it.
@(private = "file")
flow_ready :: proc(e: ^Engine, k: int) -> bool {
	f := &e.flow
	c := sync.atomic_load(&f.made[k])
	if int(c) >= f.chunks || c >= sync.atomic_load(&f.taken) + RING {
		return false
	}
	sp := f.sources_of[k]
	for src in f.sources[sp.first:base.span_end(sp)] {
		if sync.atomic_load(&f.made[src]) <= c {
			return false
		}
	}
	return true
}

// Claims node k's next chunk if it is ready and no one has it yet. Whoever
// finds it not ready lets it go and looks again, so a chunk made meanwhile
// (whose maker found it still claimed) is never missed.
@(private = "file")
flow_claim :: proc(e: ^Engine, k: int) -> bool {
	f := &e.flow
	for {
		if _, ok := sync.atomic_compare_exchange_strong(&f.queued[k], 0, 1); !ok {
			return false
		}
		if flow_ready(e, k) {
			return true
		}
		sync.atomic_store(&f.queued[k], 0)
		if !flow_ready(e, k) {
			return false
		}
	}
}

// Queues node k's next chunk if it can be claimed, waking a loop for it.
@(private = "file")
flow_try :: proc(e: ^Engine, k: int) {
	if flow_claim(e, k) {
		flow_push(e, k)
	}
}

@(private = "file")
flow_push :: proc(e: ^Engine, k: int) {
	f := &e.flow
	sync.mutex_lock(&f.mutex)
	f.queue[f.tail % len(f.queue)] = i32(k)
	f.tail += 1
	sync.mutex_unlock(&f.mutex)
	flow_moved(f)
}

@(private = "file")
flow_moved :: proc(f: ^Flow) {
	sync.atomic_add(&f.progress, 1)
	sync.futex_signal(&f.progress)
}

// A loop of a walk, on worker w, until every chunk is taken: the next chunk
// in order handed on once made, else a node's next chunk (what the last one
// made ready, kept here: its own next, else the first it feeds; the rest
// queued for other loops), else asleep until something is queued or can be
// taken.
@(private = "file")
flow_loop :: proc(e: ^Engine, w: ^Worker) {
	f := &e.flow
	context.temp_allocator = virtual.arena_allocator(&w.temp)
	k := -1
	for {
		seen := sync.atomic_load(&f.progress)
		if k < 0 && flow_take(e) {
			continue
		}
		if k < 0 {
			sync.mutex_lock(&f.mutex)
			if f.head < f.tail {
				k = int(f.queue[f.head % len(f.queue)])
				f.head += 1
			}
			sync.mutex_unlock(&f.mutex)
		}
		if k >= 0 {
			c := int(sync.atomic_load(&f.made[k]))
			flow_chunk(e, w, c)
			node_chunk(e, w, k)
			temp_reset(w)
			sync.atomic_add(&f.made[k], 1)
			sync.atomic_store(&f.queued[k], 0)
			done := sync.atomic_sub(&f.left[c % RING], 1) == 1
			next := flow_claim(e, k) ? k : -1
			fd := f.feeds_of[k]
			for d in f.feeds[fd.first:base.span_end(fd)] {
				if flow_claim(e, int(d)) {
					if next < 0 {
						next = int(d)
					} else {
						flow_push(e, int(d))
					}
				}
			}
			if done {
				flow_moved(f) // the chunk can be taken
			}
			k = next
			continue
		}
		if int(sync.atomic_load(&f.taken)) >= f.chunks {
			sync.futex_broadcast(&f.progress)
			return
		}
		sync.futex_wait(&f.progress, u32(seen))
	}
}

// Hands on the next chunk if every node has made it (one loop at a time, so
// in order); its ring slot is then free for the chunk RING on.
@(private = "file")
flow_take :: proc(e: ^Engine) -> bool {
	f := &e.flow
	c := int(sync.atomic_load(&f.taken))
	if c >= f.chunks || sync.atomic_load(&f.left[c % RING]) != 0 {
		return false
	}
	if _, ok := sync.atomic_compare_exchange_strong(&f.taking, 0, 1); !ok {
		return false
	}
	defer sync.atomic_store(&f.taking, 0)
	if int(sync.atomic_load(&f.taken)) != c {
		return false
	}
	take(e, c, f.out)
	buffers_give(e, c % RING)
	if c + RING < f.chunks {
		sync.atomic_store(&f.left[c % RING], i32(len(e.nodes)))
	}
	sync.atomic_add(&f.taken, 1)
	for k in e.order {
		flow_try(e, int(k))
	}
	flow_moved(f)
	return true
}

// A worker's temp memory emptied, when a node used it (emptying zeroes it).
@(private = "file")
temp_reset :: #force_inline proc(w: ^Worker) {
	if w.temp.total_used > 0 {
		free_all(virtual.arena_allocator(&w.temp))
	}
}

// Chunk c of the walk, as a worker runs it.
@(private = "file")
flow_chunk :: proc(e: ^Engine, w: ^Worker, c: int) {
	w.slot = c % RING
	w.at = e.cursor + e.ahead + i64(c * CHUNK)
	w.frames = min(CHUNK, e.flow.frames - c * CHUNK)
	w.master = e.flow.master
}

// A walk's loops, a range of the pool's map each: the first of its range's
// worker (the rest are other loops' to run, should the pool run them apart).
@(private = "file")
flow_range :: proc(data: rawptr, first, end: int) {
	e := (^Engine)(data)
	flow_loop(e, &e.workers[first])
}

// How many of a track's notes ever sound at once (one for a mono device).
@(private = "file")
polyphony_from_track :: proc(s: ^song.Song, t: song.Track) -> int {
	p := s.params[t.instrument]
	env := song.voice_env(s)
	if device.voice_mono(&p, &env) || t.notes.count == 0 {
		return 1
	}
	ends := make([dynamic]f64, context.temp_allocator)
	most := 0
	program := i32(p[.Program])
	layered := program >= 0 && s.programs.programs[program].layer_mode == .All
	for i in t.notes.first ..< base.span_end(t.notes) {
		n := note_from_row(s, int(i))
		#reverse for end, k in ends {
			if end <= n.time {
				unordered_remove(&ends, k)
			}
		}
		// a layered note: a voice per layer it may start
		voices := 1
		if layered {
			layers: [device.MAX_LAYERS]i32
			voices = device.graph_layers(&s.programs, program, n, -1, layers[:])
		}
		for _ in 0 ..< voices {
			append(&ends, n.time + device.note_tail(&p, n, &env))
		}
		most = max(most, len(ends))
	}
	return clamp(most, 1, MAX_POLYPHONY)
}

// Puts the song at sample `at`: every track's notes sounding there are
// started and played up to it (chased), every node's effects reset to that
// moment. Exact: each node starts as far back as its effects' memory and
// that of everything after it need (a return as long as its reverb rings,
// the tracks feeding it that much earlier), and the song is walked from
// there, so what follows is what a stream from 0 would play; a scrub can
// skip that.
engine_seek :: proc(e: ^Engine, at: i64, exact: bool) {
	w := &e.workers[0]
	context.temp_allocator = virtual.arena_allocator(&w.temp)
	defer free_all(context.temp_allocator)
	from := at
	if exact {
		most: i64
		for nd in e.nodes {
			most = max(most, nd.pre)
		}
		from = max(at - most, 0)
	}
	e.cursor, e.ahead = from, 0
	for &nd in e.nodes {
		nd.started = false
	}
	if from == at {
		for k in 0 ..< len(e.nodes) {
			node_start(e, w, k)
		}
	} else {
		// the walk to `at`, each node joining at the block its start falls in
		for e.cursor < at {
			n := int(min(at - e.cursor, BLOCK))
			for k in 0 ..< len(e.nodes) {
				if !e.nodes[k].started && e.cursor + i64(n) > at - e.nodes[k].pre {
					node_start(e, w, k)
				}
			}
			walk(e, n, false, nil)
		}
		// what needs no pre-roll joins at `at` itself
		for k in 0 ..< len(e.nodes) {
			if !e.nodes[k].started {
				node_start(e, w, k)
			}
		}
	}
	// the master takes the mix its latency ahead of what it puts out: prime
	// its lookahead with that much (its output then is its delay)
	master_run_reset(&e.master, at)
	for left := e.no_master ? 0 : i64(e.master.latency); left > 0; {
		n := int(min(left, BLOCK))
		walk(e, n, true, nil)
		left -= i64(n)
	}
	// the nodes now run its lookahead ahead of the output
	e.cursor, e.ahead = at, e.no_master ? 0 : i64(e.master.latency)
	e.master.stats = {}
}

// Starts node `k` at the cursor: a track's notes chased there, a node's
// effects and its inputs' delay lines reset to its time.
@(private = "file")
node_start :: proc(e: ^Engine, w: ^Worker, k: int) {
	s := e.song
	nd := &e.nodes[k]
	nd.started = true
	slice.zero(e.dirty[RING * CHUNK_BLOCKS * k:][:RING * CHUNK_BLOCKS])
	NODE_RUNS[s.nodes[k].kind].start(e, w, k, e.cursor + nd.lead)
	for i in nd.inputs.first ..< base.span_end(nd.inputs) {
		x := &e.edges[i]
		slice.zero(e.rings[x.ring.first:base.span_end(x.ring)])
		x.pos = e.cursor + e.nodes[s.edges[i].from].lead
		x.sound = min(i64) / 2
	}
}

// Where a walk hands each chunk as it is made: into the mix (and the stems,
// when given) from the walk's first sample, or, with a sink, to it in order
// (the mix as the master made it, the stems through `scratch`: a chunk each).
Walk_Out :: struct {
	l, r:    []f32,
	stems:   [][2][]f32,
	sink:    Sink,
	at:      i64, // the sink's `at` of the walk's first sample
	scratch: [][2][]f32,
}

// The song's next `n` samples, in chunks: every started node makes each, a
// chunk once what feeds it has (a track its voices and chain, a bus its
// inputs and chain), the master's last (mastered unless `no_master`;
// `master` false: only the nodes before it, a seek's walk), each chunk handed
// to `out` as the last node makes it. On the caller's pool, one map of loops.
@(private = "file")
walk :: proc(e: ^Engine, n: int, master: bool, out: ^Walk_Out) {
	edits_apply(e)
	f := &e.flow
	chunks := (n + CHUNK - 1) / CHUNK
	f.chunks, f.frames, f.master, f.out = chunks, n, master, out
	if e.pool == nil || len(e.workers) == 1 {
		w := &e.workers[0]
		context.temp_allocator = virtual.arena_allocator(&w.temp)
		for c in 0 ..< chunks {
			flow_chunk(e, w, c)
			for k in e.order {
				node_chunk(e, w, int(k))
				temp_reset(w)
			}
			take(e, c, out)
			buffers_give(e, c % RING)
		}
		e.cursor += i64(n)
		return
	}
	f.taken, f.taking, f.head, f.tail = 0, 0, 0, 0
	for c in 0 ..< RING {
		f.left[c] = c < chunks ? i32(len(e.nodes)) : 0
	}
	slice.zero(f.made)
	slice.zero(f.queued)
	for k in e.order {
		flow_try(e, int(k))
	}
	e.pool.run(e.pool, len(e.workers), flow_range, e)
	e.cursor += i64(n)
}

// Chunk c of the walk to `out`: the master's, and each stem's at its
// placement's level (silence where it made none).
@(private = "file")
take :: proc(e: ^Engine, c: int, out: ^Walk_Out) {
	if out == nil {
		return
	}
	slot := c % RING
	at := c * CHUNK
	n := min(CHUNK, e.flow.frames - at)
	ml, mr := chunk_of(e, slot, int(song.master_node(e.song)), n)
	stems := out.stems
	o := at
	if out.sink.take != nil {
		stems, o = out.scratch, 0
	} else {
		copy(out.l[at:], ml)
		copy(out.r[at:], mr)
	}
	first := len(e.song.tracks)
	for st, p in stems {
		g := e.stem_gain[p]
		for j := 0; j * BLOCK < n; j += 1 {
			m := min(BLOCK, n - j * BLOCK)
			b := o + j * BLOCK
			if e.dirty[((first + p) * RING + slot) * CHUNK_BLOCKS + j] {
				sl, sr := slot_block(e, slot, first + p, j, m)
				for i in 0 ..< m {
					st[0][b + i] = sl[i] * g
					st[1][b + i] = sr[i] * g
				}
			} else {
				slice.zero(st[0][b:][:m])
				slice.zero(st[1][b:][:m])
			}
		}
	}
	if out.sink.take != nil {
		views := make([][2][]f32, len(stems), context.temp_allocator)
		for st, p in stems {
			views[p] = {st[0][:n], st[1][:n]}
		}
		out.sink.take(out.sink.data, out.at + i64(at), ml, mr, views)
	}
}

// Node k over a worker's chunk, a block at a time. A node that may not write
// in it (node_may_write) takes no buffer and runs only what moves on all the
// same: a track's clock, a delay line's ring, a muted track's unheard play.
@(private = "file")
node_chunk :: proc(e: ^Engine, w: ^Worker, k: int) {
	nd := &e.nodes[k]
	kind := e.song.nodes[k].kind
	n := w.frames
	dirty := e.dirty[(k * RING + w.slot) * CHUNK_BLOCKS:][:CHUNK_BLOCKS]
	if !nd.started {
		slice.zero(dirty)
		return
	}
	if kind == .Master && !w.master {
		return
	}
	if !node_may_write(e, w, k) {
		slice.zero(dirty)
		switch {
		case kind == .Track && e.mix.tracks[k].muted:
			track_skip(e, w, k, n)
		case kind == .Track:
			e.tracks[k].cursor += i64(n)
		case:
			for j := 0; j * BLOCK < n; j += 1 {
				node_inputs(e, w, k, j, nil, nil) // its delay lines' rings, silence written
			}
		}
		return
	}
	buffer_take(e, w, k)
	for j := 0; j * BLOCK < n; j += 1 {
		m := min(BLOCK, n - j * BLOCK)
		l, r := node_block(e, w, k, j, m)
		w.key_l, w.key_r = node_keys(e, w, k, j, m)
		dirty[j] = NODE_RUNS[kind].block(e, w, k, j, l, r)
	}
}

// Whether node k may write in the worker's chunk: the master always; a
// track (not muted) while a voice sounds, its tails are awake, or a note
// starts in it; a summing node while a source has sound in it, a delay line
// may read sound, or its chain is awake.
@(private = "file")
node_may_write :: proc(e: ^Engine, w: ^Worker, k: int) -> bool {
	s := e.song
	nd := &e.nodes[k]
	n := i64(w.frames)
	switch s.nodes[k].kind {
	case .Master:
		return true
	case .Track:
		if e.mix.tracks[k].muted {
			return false
		}
		// as track_block sleeps: awake at its start, a voice sounding, or a
		// note starting in it
		run := &e.tracks[k]
		input := run.cursor + nd.latency
		if input < nd.awake_until {
			return true
		}
		for slot in run.slots.first ..< base.span_end(run.slots) {
			if e.slot_note[slot] >= 0 {
				return true
			}
		}
		end := base.span_end(s.tracks[k].notes)
		return run.next_note < end && i64(math.round(s.notes.time[run.next_note] * RATE)) < input + n
	case .Part, .Return, .Bus, .Song:
		if nd.chain.count > 0 && w.at + nd.lead + nd.latency < nd.awake_until {
			return true
		}
		for i in nd.inputs.first ..< base.span_end(nd.inputs) {
			x := s.edges[i]
			run := &e.edges[i]
			if x.kind != .Audio || run.looped {
				continue
			}
			for j := 0; j * BLOCK < int(n); j += 1 {
				if dirty_at(e, w, int(x.from), j) {
					return true
				}
			}
			if run.delay > 0 && run.pos - run.delay <= run.sound {
				return true
			}
		}
	}
	return false
}

// How each kind of node runs: put at song sample `at` (its output's: a
// seek's start), and over its next block, whether it holds sound.
// A block is the j-th of the chunk (its song sample: block_at).
Node_Run_Row :: struct {
	start: proc(e: ^Engine, w: ^Worker, k: int, at: i64),
	block: proc(e: ^Engine, w: ^Worker, k: int, j: int, l, r: []f32) -> bool,
}

NODE_RUNS := [song.Node_Kind]Node_Run_Row {
	.Track  = {track_node_start, track_node_block},
	.Part   = {sum_start, sum_block},
	.Return = {sum_start, sum_block},
	.Bus    = {sum_start, sum_block},
	.Song   = {sum_start, song_block},
	.Master = {sum_start, master_node_block},
}

// A track: its notes chased to `at`, its chain reset there; a block of its
// voices and chain (muted: played unheard).
@(private = "file")
track_node_start :: proc(e: ^Engine, w: ^Worker, k: int, at: i64) {
	track_seek(e, w, k, at, false)
}

@(private = "file")
track_node_block :: proc(e: ^Engine, w: ^Worker, k: int, j: int, l, r: []f32) -> bool {
	if e.mix.tracks[k].muted {
		track_skip(e, w, k, len(l))
		return false
	}
	return track_block(e, w, k, l, r)
}

// A node summing its inputs (a part, a return, a bus): its chain reset to
// its input's time, asleep until sound comes; a block of its inputs through
// its chain.
@(private = "file")
sum_start :: proc(e: ^Engine, w: ^Worker, k: int, at: i64) {
	nd := &e.nodes[k]
	for f in e.fx[nd.chain.first:base.span_end(nd.chain)] {
		reset_fx(e, k, f, at + nd.latency)
	}
	nd.awake_until = at + nd.latency
}

@(private = "file")
sum_block :: proc(e: ^Engine, w: ^Worker, k: int, j: int, l, r: []f32) -> bool {
	heard := node_inputs(e, w, k, j, l, r)
	return e.nodes[k].chain.count > 0 ? node_chain_run(e, w, k, j, l, r, heard) : heard
}

// A placement's: what its song plays, at its level, ducked, windowed.
@(private = "file")
song_block :: proc(e: ^Engine, w: ^Worker, k: int, j: int, l, r: []f32) -> bool {
	heard := node_inputs(e, w, k, j, l, r)
	if heard {
		placement_block(e, w, k, j, l, r)
	}
	return heard
}

// The master: the mix through its Master_Run (unless its host runs the
// master itself: no_master).
@(private = "file")
master_node_block :: proc(e: ^Engine, w: ^Worker, k: int, j: int, l, r: []f32) -> bool {
	if !node_inputs(e, w, k, j, l, r) {
		slice.zero(l)
		slice.zero(r)
	}
	if !e.no_master && master_run_active(&e.master) {
		master_run_block(&e.master, l, r)
	}
	return true
}

// Block j of node k's chunk in ring slot `slot`, n samples of it (its
// buffer's: it holds one where it wrote).
@(private = "file")
slot_block :: #force_inline proc(e: ^Engine, slot, k, j, n: int) -> ([]f32, []f32) {
	b := int(e.buffer_of[k * RING + slot])
	buf := e.buffers.slabs[b / BUFFER_SLAB][(b % BUFFER_SLAB) * 2 * CHUNK:][:2 * CHUNK]
	return buf[j * BLOCK:][:n], buf[CHUNK + j * BLOCK:][:n]
}

// Block j of node k's chunk, the one the worker runs.
@(private = "file")
node_block :: #force_inline proc(e: ^Engine, w: ^Worker, k, j, n: int) -> ([]f32, []f32) {
	return slot_block(e, w.slot, k, j, n)
}

// Node k's chunk in ring slot `slot`, its first n samples.
@(private = "file")
chunk_of :: #force_inline proc(e: ^Engine, slot, k, n: int) -> ([]f32, []f32) {
	return slot_block(e, slot, k, 0, n)
}

// The song sample block j of the worker's chunk starts at.
@(private = "file")
block_at :: #force_inline proc(w: ^Worker, j: int) -> i64 {
	return w.at + i64(j * BLOCK)
}

@(private = "file")
dirty_at :: #force_inline proc(e: ^Engine, w: ^Worker, k, j: int) -> bool {
	return e.dirty[(k * RING + w.slot) * CHUNK_BLOCKS + j]
}

// A bus's or a return's chain over its block (its input summed in place):
// awake stretches run it, from the first sound after a silence (its effects
// reset there) to its tail after the last; asleep, the block stays silent.
// Whether it put out anything.
@(private = "file")
node_chain_run :: proc(e: ^Engine, w: ^Worker, k: int, j: int, l, r: []f32, heard: bool) -> (wrote: bool) {
	nd := &e.nodes[k]
	n := len(l)
	start := block_at(w, j) + nd.lead + nd.latency // its input's song sample at l[0]
	if !heard && start >= nd.awake_until {
		return false // asleep, nothing coming: its block untouched
	}
	if !heard {
		// awake, its tail over silence
		slice.zero(l)
		slice.zero(r)
	}
	sound :: #force_inline proc(l, r: []f32, j: int) -> bool {return l[j] != 0 || r[j] != 0}
	for i := 0; i < n; {
		if start + i64(i) >= nd.awake_until {
			// asleep: silent to the next sound, where it wakes fresh
			x := i
			for x < n && !sound(l, r, x) {
				x += 1
			}
			if x == n {
				break
			}
			for f in e.fx[nd.chain.first:base.span_end(nd.chain)] {
				reset_fx(e, k, f, start + i64(x))
			}
			nd.awake_until = start + i64(x) + 1 + nd.tail
			i = x
		}
		// awake: on until the input has been silent for its tail
		x := i
		for x < n && start + i64(x) < nd.awake_until {
			if sound(l, r, x) {
				nd.awake_until = start + i64(x) + 1 + nd.tail
			}
			x += 1
		}
		kl, kr := w.key_l, w.key_r
		if kl != nil {
			kl, kr = kl[i:x], kr[i:x]
		}
		w.fx_scratch.tempo = node_tempo(e, k)
		run_fx(e, w, nd.chain, start + i64(i), l[i:x], r[i:x], kl, kr)
		wrote = true
		i = x
	}
	return
}

// What a node's effects' sidechains hear: its key edges' sources summed
// (nil: it has none, so they hear the node itself).
@(private = "file")
node_keys :: proc(e: ^Engine, w: ^Worker, k, j, n: int) -> ([]f32, []f32) {
	s := e.song
	kl, kr := w.keys[:n], w.keys[BLOCK:][:n]
	found := false
	inputs := e.nodes[k].inputs
	for i in inputs.first ..< base.span_end(inputs) {
		x := s.edges[i]
		if x.kind != .Key || e.edges[i].looped {
			continue
		}
		if !found {
			slice.zero(kl)
			slice.zero(kr)
			found = true
		}
		if !dirty_at(e, w, int(x.from), j) {
			continue
		}
		sl, sr := node_block(e, w, int(x.from), j, n)
		g := f32(e.mix.edges[i].to)
		for i in 0 ..< n {
			kl[i] += sl[i] * g
			kr[i] += sr[i] * g
		}
	}
	if !found {
		return nil, nil
	}
	return kl, kr
}

// A node's input: its edges' sources summed in edge order, each at its gain
// (through its delay line where it has one). Whether any sound came in: only
// then is its block written (cleared by the first source that sounds), so a
// silent node touches nothing.
@(private = "file")
node_inputs :: proc(e: ^Engine, w: ^Worker, k: int, j: int, l, r: []f32) -> (heard: bool) {
	s := e.song
	n := min(BLOCK, w.frames - j * BLOCK)
	first :: #force_inline proc(heard: ^bool, l, r: []f32) {
		if !heard^ {
			slice.zero(l)
			slice.zero(r)
			heard^ = true
		}
	}
	inputs := e.nodes[k].inputs
	for i in inputs.first ..< base.span_end(inputs) {
		x := s.edges[i]
		run := &e.edges[i]
		if x.kind != .Audio || run.looped {
			continue
		}
		// a send a lane or an edit moves: its level per sample, at this node's input time
		gains: []f32
		edge_at := block_at(w, j) + e.nodes[k].lead + e.nodes[k].latency
		level := e.mix.edges[i]
		x.gain = f32(level.to)
		if lanes := lane_rows(e, e.lanes.edges[i]); len(lanes) > 0 {
			gains = lane_gains(e, w, lanes[0], {}, edge_at, n)
		} else if level_moving(level, edge_at, n) {
			gains = lane_gains(e, w, -1, level, edge_at, n)
		}
		sounds := dirty_at(e, w, int(x.from), j)
		sl, sr: []f32
		if sounds {
			sl, sr = node_block(e, w, int(x.from), j, n)
		}
		if run.delay > 0 {
			// written at the source's time, read `delay` behind it
			size := i64(run.ring.count / 2)
			mask := size - 1
			rl := e.rings[run.ring.first:][:size]
			rr := e.rings[i64(run.ring.first) + size:][:size]
			if sounds {
				run.sound = run.pos + i64(n) - 1
			}
			// the ring is written whatever comes (what it holds is its
			// source's past), read only while what it reads may hold sound (a
			// ring at least delay + BLOCK long: no write here reaches a read)
			for i in 0 ..< n {
				t := run.pos + i64(i)
				rl[t & mask] = sounds ? sl[i] : 0
				rr[t & mask] = sounds ? sr[i] : 0
			}
			if run.pos - run.delay <= run.sound {
				first(&heard, l, r)
				for i in 0 ..< n {
					t := run.pos + i64(i) - run.delay
					g := gains != nil ? gains[i] : x.gain
					l[i] += rl[t & mask] * g
					r[i] += rr[t & mask] * g
				}
			}
			run.pos += i64(n)
			continue
		}
		if !sounds {
			continue
		}
		first(&heard, l, r)
		if gains != nil {
			for i in 0 ..< n {
				l[i] += sl[i] * gains[i]
				r[i] += sr[i] * gains[i]
			}
			continue
		}
		for i in 0 ..< n {
			l[i] += sl[i] * x.gain
		}
		for i in 0 ..< n {
			r[i] += sr[i] * x.gain
		}
	}
	return
}

// A placement's node over a block of what its song plays: its level, its
// duck under the voice, its window (`at`: the song sample of l[0]).
@(private = "file")
placement_block :: proc(e: ^Engine, w: ^Worker, k: int, j: int, l, r: []f32) {
	s := e.song
	pl := s.placements[s.nodes[k].ref]
	at := block_at(w, j) + e.nodes[k].lead
	if lanes := lane_rows(e, e.lanes.placements[s.nodes[k].ref]); len(lanes) > 0 {
		// its level moving (a song's `master/gain_db`), from where it is placed
		g := lane_gains(e, w, lanes[0], {}, at, len(l))
		for i in 0 ..< len(l) {
			l[i] *= g[i]
			r[i] *= g[i]
		}
	}
	if level := e.mix.placements[s.nodes[k].ref]; level_moving(level, at, len(l)) {
		g := lane_gains(e, w, -1, level, at, len(l))
		for i in 0 ..< len(l) {
			l[i] *= g[i]
			r[i] *= g[i]
		}
	} else if g := f32(level.to); g != 1 {
		for i in 0 ..< len(l) {
			l[i] *= g
			r[i] *= g
		}
	}
	if row := SIDECHAIN_TABLE[pl.duck.mode]; row.duck != nil {
		row.duck(s, pl.duck, at, l, r)
	}
	if pl.window.stop > pl.window.start {
		apply_window(pl.window, e.nodes[k].origin, at, l, r)
	}
}

// Puts track `ti`'s output at song sample `at` (its node's time): the notes
// sounding there started and played up to it, its chain reset.
track_seek :: proc(e: ^Engine, w: ^Worker, ti: int, at: i64, exact: bool) {
	s := e.song
	t := s.tracks[ti]
	run := &e.tracks[ti]
	run.cursor = at
	nd := &e.nodes[ti]
	input := at + nd.latency
	nd.awake_until = input // dormant unless a note is still sounding
	for k in run.slots.first ..< base.span_end(run.slots) {
		e.slot_note[k] = -1
		e.slot_choke[k] = 0
	}
	reset_track_fx(e, w, ti, input)
	// the first note starting at or after the input's time
	first, count := int(t.notes.first), int(t.notes.count)
	k, _ := slice.binary_search_by(s.notes.time[first:first + count], f64(input) / RATE, proc(x, target: f64) -> slice.Ordering {
		return x < target - 0.5 / RATE ? .Less : .Greater
	})
	run.next_note = i32(first + k)
	// chase what is still sounding: earlier notes whose tails reach `input`
	p := s.params[t.instrument]
	mono := device.voice_mono(&p, &e.env)
	// a voice that remembers earlier notes (a mono program's slew) replays
	// those within its memory, from a fresh state, as it would have played them
	memory := i64(math.ceil(device.voice_memory(&p, &e.env) * RATE))
	// in time order: every voice sounding played up to the next note's start,
	// then that note started (so what it cuts or slides into is cut or slid
	// into where it was), then all of them up to `input`
	jump := device.voice_jump(&p, &e.env)
	for i := first; i < first + k; i += 1 {
		n := note_from_row(s, i)
		start := i64(math.round(n.time * RATE))
		over := f64(input - start) >= device.note_tail(&p, n, &e.env) * RATE && input - start > memory
		if over && !sounding_any(e, ti) {
			continue
		}
		chase_to(e, w, ti, start, jump)
		if over {
			// its sound is over by `input`, what it cut is still cut
			note_cuts(e, ti, i32(i), n)
			continue
		}
		start_note(e, w, ti, i32(i), mono, start)
	}
	chase_to(e, w, ti, input, jump)
}

@(private = "file")
sounding_any :: proc(e: ^Engine, ti: int) -> bool {
	run := &e.tracks[ti]
	for k in run.slots.first ..< base.span_end(run.slots) {
		if e.slot_note[k] >= 0 {
			return true
		}
	}
	return false
}

// What a note does to the voices sounding when it starts, without
// sounding itself (a seek passing a note that is over by where it lands):
// its pad's chokes, its layers' off_by cuts and polyphony.
@(private = "file")
note_cuts :: proc(e: ^Engine, ti: int, ni: i32, n: device.Note) {
	run := &e.tracks[ti]
	t := e.song.tracks[ti]
	p := e.song.params[t.instrument]
	program := i32(p[.Program])
	if program < 0 || n.kind == .Keyswitch {
		return
	}
	if e.programs.programs[program].layer_mode == .All {
		layers: [device.MAX_LAYERS]i32
		rand := f32(base.hash_unit(e.song.notes.seed[ni] ~ 0x5ead))
		for l in layers[:device.graph_layers(&e.programs, program, n, rand, layers[:])] {
			layer_cuts(e, run, ni, l, n)
		}
		return
	}
	if chokes := device.graph_chokes(&e.programs, program, n); len(chokes) > 0 {
		for k in run.slots.first ..< base.span_end(run.slots) {
			if e.slot_note[k] >= 0 && e.slot_choke[k] == 0 && slice.contains(chokes, e.song.notes.pad[e.slot_note[k]]) {
				slot_cut(e, int(k), device.CHOKE_SAMPLES)
			}
		}
	}
}

// Every voice of the track sounding played up to song sample `at` (a
// seek's chase; a voice that jumps is put there).
@(private = "file")
chase_to :: proc(e: ^Engine, w: ^Worker, ti: int, at: i64, jump: bool) {
	s := e.song
	run := &e.tracks[ti]
	discard := w.scratch[4 * BLOCK:][:2 * BLOCK]
	stepped := track_has_controls(e, ti)
	defer run.lane_cell = -1 // set again where it plays on
	for k in run.slots.first ..< base.span_end(run.slots) {
		slot := int(k)
		if e.slot_note[slot] < 0 {
			continue
		}
		target := at - i64(math.round(s.notes.time[e.slot_note[slot]] * RATE))
		if jump {
			if e.slot_at[slot] == 0 {
				play_slot(e, w, ti, slot, discard[:0], discard[BLOCK:][:0]) // its state set from the note
			}
			e.slot_at[slot] = max(e.slot_at[slot], target)
			continue
		}
		started := i64(math.round(s.notes.time[e.slot_note[slot]] * RATE))
		for e.slot_note[slot] >= 0 && e.slot_at[slot] < target {
			m := int(min(target - e.slot_at[slot], BLOCK))
			if stepped {
				t := started + e.slot_at[slot]
				run.lane_cell = -1
				track_lanes_apply(e, ti, t)
				m = cell_piece(t, m, true)
			}
			slice.zero(discard[:2 * BLOCK])
			if !play_slot(e, w, ti, slot, discard[:m], discard[BLOCK:][:m]) {
				break
			}
		}
	}
}

// An effect put at song sample `at` of node k's chain: at its own song's
// sample (the node's origin off), so a placed song's reverb wobbles and its
// LFOs swing as they do alone.
@(private = "file")
reset_fx :: proc(e: ^Engine, k: int, f: Fx_Run, at: i64) {
	p := e.mix.params[f.device]
	state := e.fx_bytes[f.state.first:base.span_end(f.state)]
	device.effect_reset(e.song.devices[f.device], state, &p, at - e.nodes[k].origin)
}

// Streams the next len(l) samples of the mix into l and r (and into stems,
// when given: one [2][]f32 per stem (stem_count: the parts, then the
// returns, then the buses), as long as l, what goes into the master), on
// the caller's thread: for a preview playing, or a frame.
engine_process :: proc(e: ^Engine, l, r: []f32, stems: [][2][]f32 = nil) {
	out := Walk_Out{l = l, r = r, stems = stems}
	walk(e, len(l), true, &out)
}

// The next `frames` samples handed to `sink` a chunk at a time, in order (its
// `at` counted from where they start), with each stem when `stems`: an
// export's. The sink is called on whichever thread makes the chunk, one call
// at a time.
engine_stream :: proc(e: ^Engine, frames: int, sink: Sink, stems: bool) {
	heap := runtime.heap_allocator()
	parts := stems ? stem_count(e.song) : 0
	slab := make([]f32, 2 * CHUNK * parts, heap)
	defer delete(slab, heap)
	scratch := make([][2][]f32, parts, heap)
	defer delete(scratch, heap)
	for p in 0 ..< parts {
		scratch[p] = {slab[2 * CHUNK * p:][:CHUNK], slab[2 * CHUNK * p + CHUNK:][:CHUNK]}
	}
	out := Walk_Out{sink = sink, scratch = scratch}
	walk(e, frames, true, &out)
}

// Stem `p`'s name, for a file: a part's own ("drums"), a return's or a
// bus's with its kind ("return-hall", "bus-glue").
stem_name :: proc(s: ^song.Song, p: int, allocator := context.temp_allocator) -> string {
	switch {
	case p < len(s.parts):
		return s.parts[p]
	case p < len(s.parts) + len(s.returns):
		return strings.concatenate({"return-", s.returns[p - len(s.parts)].name}, allocator)
	}
	return strings.concatenate({"bus-", s.buses[p - len(s.parts) - len(s.returns)].name}, allocator)
}

// The stems an export gives: the parts first, so part p is stem p, then the
// returns, then the buses (each at its placement's level).
stem_count :: proc(s: ^song.Song) -> int {
	return len(s.parts) + len(s.returns) + len(s.buses)
}

// Moves a muted track on by `n` samples without hearing it (its state
// moves as if it played).
track_skip :: proc(e: ^Engine, w: ^Worker, ti: int, n: int) {
	discard := w.scratch[4 * BLOCK:][:2 * BLOCK]
	for done := 0; done < n; {
		m := min(n - done, BLOCK)
		track_block(e, w, ti, discard[:m], discard[BLOCK:][:m])
		done += m
	}
}

// A slot's state, as its voice sees it (it uses only its own bytes of it).
@(private = "file")
slot_state :: #force_inline proc(e: ^Engine, slot: int) -> ^device.Voice_State {
	return (^device.Voice_State)(&e.voices[e.slot_at_byte[slot]])
}

// A slot for note `ni`: the mono device's one (its state kept: the voice
// tells a slide from a new attack), else a free one (zeroed), else the
// oldest (counted as stolen).
@(private = "file")
start_note :: proc(e: ^Engine, w: ^Worker, ti: int, ni: i32, mono: bool, start: i64) -> []int {
	run := &e.tracks[ti]
	t := e.song.tracks[ti]
	p := e.song.params[t.instrument]
	n := note_from_row(e.song, int(ni))
	if n.kind == .Keyswitch {
		return nil // it switches the regions later notes play; it doesn't sound
	}
	tail := i64(math.ceil(device.note_tail(&p, n, &e.env) * RATE))
	nd := &e.nodes[ti]
	nd.awake_until = max(nd.awake_until, start + tail + nd.tail)
	// a layered program's note: a voice per layer it starts (its regions)
	program := i32(p[.Program])
	layers: [device.MAX_LAYERS]i32
	count := 1
	layered := program >= 0 && e.programs.programs[program].layer_mode == .All
	if layered {
		rand := f32(base.hash_unit(e.song.notes.seed[ni] ~ 0x5ead))
		count = device.graph_layers(&e.programs, program, n, rand, layers[:])
	}
	slots := make([]int, count, context.temp_allocator)
	for li in 0 ..< count {
		layer := layered ? layers[li] : -1
		slot := slot_free(e, run, mono)
		if layered {
			layer_cuts(e, run, ni, layer, n)
		} else {
			// a pad that chokes others on the track cuts them (5 ms)
			if chokes := device.graph_chokes(&e.programs, program, n); len(chokes) > 0 {
				for k in run.slots.first ..< base.span_end(run.slots) {
					if int(k) != slot && e.slot_note[k] >= 0 && e.slot_choke[k] == 0 && slice.contains(chokes, e.song.notes.pad[e.slot_note[k]]) {
						slot_cut(e, int(k), device.CHOKE_SAMPLES)
					}
				}
			}
		}
		// a mono voice still sounding keeps what it holds into the next note (a
		// slide, a slew's charge); one that has fallen silent, or any other,
		// starts from nothing
		fresh := !mono || e.slot_note[slot] < 0
		if fresh {
			mem.zero(&e.voices[e.slot_at_byte[slot]], device.voice_bytes(&p, &e.env))
		}
		e.slot_note[slot] = ni
		e.slot_at[slot] = 0
		e.slot_choke[slot] = 0
		if _, ok := device.graph_start(slot_state(e, slot), &p, n, &e.env, fresh, layer); !ok {
			e.slot_note[slot] = -1
		}
		slots[li] = slot
	}
	return slots
}

// A slot for a new voice: a free one, else the one playing longest (a
// stolen note: a finding); a mono track's one.
@(private = "file")
slot_free :: proc(e: ^Engine, run: ^Track_Run, mono: bool) -> int {
	first := int(run.slots.first)
	if mono {
		return first
	}
	oldest := first
	for k in first ..< int(base.span_end(run.slots)) {
		if e.slot_note[k] < 0 {
			return k
		}
		if e.slot_at[k] > e.slot_at[oldest] {
			oldest = k
		}
	}
	run.stolen += 1
	return oldest
}

// Fades slot k out over `samples` (a choke, an off_by cut).
@(private = "file")
slot_cut :: proc(e: ^Engine, k: int, samples: i32) {
	if e.slot_choke[k] != 0 {
		return
	}
	e.slot_choke[k] = max(samples, 1)
	e.slot_choke_len[k] = max(samples, 1)
}

// What starting a voice of `layer` does to the track's other voices (not
// its own note's): those whose off_by is its group stop by their off_mode;
// past its group's polyphony, or note_polyphony on its key, the oldest of
// them stops.
@(private = "file")
layer_cuts :: proc(e: ^Engine, run: ^Track_Run, ni: i32, layer: i32, n: device.Note) {
	progs := &e.programs
	l := progs.regions[progs.layers[layer].row]
	group_count, key_count := 0, 0
	oldest_group, oldest_key := -1, -1
	key := math.round(n.pitch)
	for k in run.slots.first ..< base.span_end(run.slots) {
		if e.slot_note[k] < 0 || e.slot_note[k] == ni || e.slot_choke[k] != 0 {
			continue
		}
		other := device.graph_layer(slot_state(e, int(k)))
		if other < 0 {
			continue
		}
		o := progs.regions[progs.layers[other].row]
		if o.off_by != 0 && o.off_by == l.group {
			switch o.off_mode {
			case .Fast:
				slot_cut(e, int(k), device.CHOKE_SAMPLES)
			case .Normal:
				device.graph_release_now(slot_state(e, int(k)))
			case .Time:
				slot_cut(e, int(k), i32(max(o.off_time, 0) * RATE))
			}
			continue
		}
		if o.group != l.group {
			continue
		}
		group_count += 1
		if oldest_group < 0 || e.slot_at[k] > e.slot_at[oldest_group] {
			oldest_group = int(k)
		}
		if math.round(e.song.notes.pitch[e.slot_note[k]]) == key {
			key_count += 1
			if oldest_key < 0 || e.slot_at[k] > e.slot_at[oldest_key] {
				oldest_key = int(k)
			}
		}
	}
	if l.polyphony > 0 && group_count >= int(l.polyphony) && oldest_group >= 0 {
		slot_cut(e, oldest_group, device.CHOKE_SAMPLES)
	}
	if l.note_polyphony > 0 && key_count >= int(l.note_polyphony) && oldest_key >= 0 && oldest_key != oldest_group {
		device.graph_release_now(slot_state(e, oldest_key))
	}
}

// Plays a slot's note for len(l) more samples, alone (a seek's chase); false
// once it is done.
@(private = "file")
play_slot :: proc(e: ^Engine, w: ^Worker, ti: int, slot: int, l, r: []f32) -> bool {
	return play_graph(e, w, ti, slot, pad_level(e, ti, e.song.notes.pad[e.slot_note[slot]]), l, r)
}

// The song's tempo map node k's beats are on (nil: none, a clip's: 120 bpm).
@(private = "file")
node_tempo :: proc(e: ^Engine, k: int) -> ^song.Tempo_Map {
	pl := e.nodes[k].placement
	return pl >= 0 && int(pl) < len(e.song.placement_tempo) ? &e.song.placement_tempo[pl] : nil
}

// What a voice of track ti playing program `play` reads of its song's
// tempo, where its program reads it: its map, its note's start in its
// song's seconds, the beat that is.
@(private = "file")
voice_tempo :: proc(e: ^Engine, ti: int, play: i32, v: ^device.Graph_Voice) {
	if play < 0 || !e.programs.programs[play].tempo {
		return
	}
	v.tempo = node_tempo(e, ti)
	v.seconds = v.note.time - f64(e.nodes[ti].origin) / RATE
	v.beat0 = device.song_beat(v.tempo, v.seconds)
}

// A pad's level on track `ti` (Pad_Gain_Set; 1: its own).
@(private = "file")
pad_level :: proc(e: ^Engine, ti: int, pad: u32) -> f32 {
	if pad != 0 {
		for g in e.mix.pad_gains {
			if g.track == i32(ti) && g.pad == pad && g.db != 0 {
				return f32(base.db_to_gain(f64(g.db)))
			}
		}
	}
	return 1
}

// A slot playing a program, alone (a seek's chase, a choked note's fade):
// as play_slot.
@(private = "file")
play_graph :: proc(e: ^Engine, w: ^Worker, ti, slot: int, level: f32, l, r: []f32) -> bool {
	s := e.song
	state := slot_state(e, slot)
	n := note_from_row(s, int(e.slot_note[slot]))
	v := [1]device.Graph_Voice{{state = state, note = n, seed = s.notes.seed[e.slot_note[slot]], at = e.slot_at[slot], gain = level}}
	voice_tempo(e, ti, device.graph_playing(state), &v[0])
	play := device.graph_playing(state)
	m := len(l)
	if e.slot_choke[slot] != 0 {
		m = min(m, int(e.slot_choke[slot]))
	}
	sc := w.scratch[6 * BLOCK:]
	cl, cr := sc[:m], sc[BLOCK:][:m]
	choked := e.slot_choke[slot] != 0
	if choked {
		slice.zero(cl)
		slice.zero(cr)
		v[0].out_l, v[0].out_r = cl, cr
	} else {
		v[0].out_l, v[0].out_r = l[:m], r[:m]
	}
	device.graph_run(&e.programs, &e.env, play, v[:], m, w.graph)
	e.slot_at[slot] = v[0].at
	if choked {
		left, length := i64(e.slot_choke[slot]), i64(max(e.slot_choke_len[slot], 1))
		for i in 0 ..< m {
			g := dsp.fade_gain(left - i64(i), length, .Linear)
			l[i] += cl[i] * g
			r[i] += cr[i] * g
		}
		e.slot_choke[slot] -= i32(m)
		if e.slot_choke[slot] <= 0 {
			e.slot_note[slot], e.slot_choke[slot] = -1, 0
			return false
		}
	}
	if v[0].done {
		e.slot_note[slot] = -1
		return false
	}
	return true
}

// The voices of a Voice track over one stretch: those not choked, all
// playing one program, in one call of device.graph_run (one process per
// node per chunk for all of them); the choked alone, fading.
@(private = "file")
play_graphs :: proc(e: ^Engine, w: ^Worker, ti: int, l, r: []f32) {
	s := e.song
	run := &e.tracks[ti]
	// the sounding voices in the order they are summed: by program, then by
	// note; never by slot (which slots are free depends on where blocks fell,
	// and float sums are only the same in the same order)
	Sounding :: struct {
		play: i32,
		note: i32,
		slot: int,
	}
	sounding: [device.MAX_LANES]Sounding
	n_sounding := 0
	for k in run.slots.first ..< base.span_end(run.slots) {
		if e.slot_note[k] >= 0 {
			sounding[n_sounding] = {device.graph_playing(slot_state(e, int(k))), e.slot_note[k], int(k)}
			n_sounding += 1
		}
	}
	slice.sort_by(sounding[:n_sounding], proc(a, b: Sounding) -> bool {
		return a.play < b.play || (a.play == b.play && a.note < b.note)
	})
	voices: [device.MAX_LANES]device.Graph_Voice
	slots: [device.MAX_LANES]int
	plays: [device.MAX_LANES]i32
	count := 0
	for x in sounding[:n_sounding] {
		k := x.slot
		if e.slot_choke[k] != 0 {
			play_graph(e, w, ti, k, pad_level(e, ti, s.notes.pad[e.slot_note[k]]), l, r)
			continue
		}
		n := note_from_row(s, int(e.slot_note[k]))
		state := slot_state(e, k)
		voices[count] = {state = state, note = n, seed = s.notes.seed[e.slot_note[k]], at = e.slot_at[k], out_l = l, out_r = r, gain = pad_level(e, ti, n.pad)}
		voice_tempo(e, ti, x.play, &voices[count])
		slots[count], plays[count] = k, x.play
		count += 1
	}
	// a call per program the voices play (a machine's pads: one each)
	done: [device.MAX_LANES]bool
	group: [device.MAX_LANES]device.Graph_Voice
	which: [device.MAX_LANES]int
	for i in 0 ..< count {
		if done[i] {
			continue
		}
		g := 0
		for j in i ..< count {
			if !done[j] && plays[j] == plays[i] {
				group[g], which[g] = voices[j], j
				done[j] = true
				g += 1
			}
		}
		device.graph_run(&e.programs, &e.env, plays[i], group[:g], len(l), w.graph)
		for k in 0 ..< g {
			slot := slots[which[k]]
			e.slot_at[slot] = group[k].at
			if group[k].done {
				e.slot_note[slot] = -1
			}
		}
	}
}


// One block of a track, in segments: awake, its voices (split where notes
// start, so every note begins on its own sample) then its strip
// (finish_segment) and the sends;
// dormant, nothing (the block stays zero) until the next note wakes it with
// its effects reset. The input runs `latency` samples ahead of the output, so
// lookahead effects line up. False when the whole block was dormant.
@(private = "file")
track_block :: proc(e: ^Engine, w: ^Worker, ti: int, l, r: []f32) -> (wrote: bool) {
	s := e.song
	t := s.tracks[ti]
	run := &e.tracks[ti]
	n := len(l)
	nd := &e.nodes[ti]
	input := run.cursor + nd.latency
	// its block is written only where it plays (and the gaps between, once
	// it has): a dormant block is left untouched
	clean := 0
	clear_to :: #force_inline proc(clean: ^int, to: int, l, r: []f32) {
		if to > clean^ {
			slice.zero(l[clean^:to])
			slice.zero(r[clean^:to])
			clean^ = to
		}
	}
	p := s.params[t.instrument]
	mono := device.voice_mono(&p, &e.env)
	end := base.span_end(t.notes)
	next_start :: proc(s: ^song.Song, run: ^Track_Run, end: i32) -> i64 {
		return run.next_note < end ? i64(math.round(s.notes.time[run.next_note] * RATE)) : max(i64)
	}
	sounding :: proc(e: ^Engine, run: ^Track_Run) -> bool {
		for k in run.slots.first ..< base.span_end(run.slots) {
			if e.slot_note[k] >= 0 {
				return true
			}
		}
		return false
	}
	stepped := track_has_controls(e, ti)
	pos := 0
	for pos < n {
		at := input + i64(pos)
		if at >= nd.awake_until && !sounding(e, run) {
			// dormant to the next note; it wakes there, its effects fresh
			wake := next_start(s, run, end)
			if wake >= input + i64(n) {
				break
			}
			pos = int(max(wake - input, i64(pos)))
			reset_track_fx(e, w, ti, input + i64(pos))
		}
		// awake: voices to where it may sleep again (notes extend that)
		from := pos
		for pos < n {
			if stepped {
				track_lanes_apply(e, ti, input + i64(pos))
			}
			limit := sounding(e, run) ? i64(n) : clamp(nd.awake_until - input, i64(pos), i64(n))
			next := clamp(next_start(s, run, end) - input, i64(pos), limit)
			next = i64(pos + cell_piece(input + i64(pos), int(next) - pos, stepped))
			if int(next) > pos {
				clear_to(&clean, int(next), l, r)
				play_graphs(e, w, ti, l[pos:next], r[pos:next])
				pos = int(next)
			}
			if run.next_note < end && next_start(s, run, end) == input + i64(pos) && pos < n {
				start_note(e, w, ti, run.next_note, mono, input + i64(pos))
				run.next_note += 1
				continue
			}
			if i64(pos) >= limit {
				break
			}
		}
		if pos > from {
			kl, kr := w.key_l, w.key_r
			if kl != nil {
				kl, kr = kl[from:pos], kr[from:pos]
			}
			finish_segment(e, w, ti, input + i64(from), l[from:pos], r[from:pos], kl, kr)
			wrote = true
		}
	}
	if wrote {
		clear_to(&clean, n, l, r)
	}
	run.cursor += i64(n)
	return
}

// What follows the voices on an awake stretch of a track (`at`: the song
// sample of l[0]), a channel strip's order: its insert ducks (the bass
// under the kick), its effect chain, then its fader: gain and pan, its
// fader ducks (a clip under the voice), its room dip.
@(private = "file")
finish_segment :: proc(e: ^Engine, w: ^Worker, ti: int, at: i64, l, r: []f32, key_l, key_r: []f32) {
	s := e.song
	t := s.tracks[ti]
	n := len(l)
	ducks := s.sidechains[t.sidechains.first:base.span_end(t.sidechains)]
	for sc in ducks {
		if row := SIDECHAIN_TABLE[sc.mode]; row.duck != nil && !row.fader {
			row.duck(s, sc, at, l, r)
		}
	}
	w.fx_scratch.tempo = node_tempo(e, ti)
	run_fx(e, w, e.nodes[ti].chain, at, l, r, key_l, key_r)
	gain_lane, pan_lane := i32(-1), i32(-1)
	for i in lane_rows(e, e.lanes.tracks[ti]) {
		#partial switch s.automation[i].kind {
		case .Track_Gain:
			gain_lane = i
		case .Track_Pan:
			pan_lane = i
		}
	}
	tm := e.mix.tracks[ti]
	if gain_lane < 0 && pan_lane < 0 && !level_moving(tm.gain, at, n) && !level_moving(tm.pan, at, n) {
		gain := tm.gain.to
		pl, pr := song.PAN_LAW_TABLE[t.pan_law](tm.pan.to)
		gl, gr := f32(gain * pl), f32(gain * pr)
		for i in 0 ..< n {
			l[i] *= gl
		}
		for i in 0 ..< n {
			r[i] *= gr
		}
	} else {
		// moving: the fader's gain and the pan's law per sample
		for start := 0; start < n; start += BLOCK {
			m := min(BLOCK, n - start)
			g := lane_gains(e, w, gain_lane, tm.gain, at + i64(start), m)
			if gain_lane >= 0 {
				// a part's gain_db lane rides on its level (its gain_db, a live
				// edit's glide): the trim, and the automation over it
				for i in 0 ..< m {
					g[i] = f32(level_at(tm.gain, at + i64(start + i)) * f64(g[i]))
				}
			}
			for i in 0 ..< m {
				pan := level_at(tm.pan, at + i64(start + i))
				if pan_lane >= 0 {
					pan = f64(clamp(song.automation_value(s, s.automation[pan_lane], at + i64(start + i)), -1, 1))
				}
				pl, pr := song.PAN_LAW_TABLE[t.pan_law](pan)
				l[start + i] *= g[i] * f32(pl)
				r[start + i] *= g[i] * f32(pr)
			}
		}
	}
	for sc in ducks {
		if row := SIDECHAIN_TABLE[sc.mode]; row.duck != nil && row.fader {
			row.duck(s, sc, at, l, r)
		}
	}
	if t.room != 0 {
		make_room(s, t.room, e.tracks[ti].placement, at, l, r)
	}
}

// A track's chain put at `at`.
@(private = "file")
reset_track_fx :: proc(e: ^Engine, w: ^Worker, ti: int, at: i64) {
	for f in e.fx[e.nodes[ti].chain.first:base.span_end(e.nodes[ti].chain)] {
		reset_fx(e, ti, f, at)
	}
}

// A placed song's window over a block of it: silent outside, its fades at
// its edges (onimite's track envelope), each edge's at least a declick where
// it cuts into the song (dsp.edge_fade): a start after the song's own
// (`origin`) does, an end may.
@(private = "file")
apply_window :: proc(w: song.Window, origin: i64, at: i64, l, r: []f32) {
	a := i64(math.round(w.start * RATE))
	b := i64(math.round(w.stop * RATE))
	length := b - a
	fi := dsp.edge_fade(i64(math.round(w.fade_in * RATE)), a > origin)
	fo := dsp.edge_fade(i64(math.round(w.fade_out * RATE)), true)
	for i in 0 ..< len(l) {
		k := at + i64(i) - a
		g: f32 = 0
		if k >= 0 && k < length {
			g = dsp.fade_gain(k, fi, w.curve) * dsp.fade_gain(length - 1 - k, fo, w.curve)
		}
		l[i] *= g
		r[i] *= g
	}
}

// A chain over a block from song sample `at`; an effect a lane moves runs a
// cell at a time, its params the lanes' values for the cell (an effect
// row's options: its controls set, what follows from them derived).
@(private = "file")
run_fx :: proc(e: ^Engine, w: ^Worker, c: base.Span, at: i64, l, r: []f32, key_l: []f32 = nil, key_r: []f32 = nil) {
	s := e.song
	piece :: #force_inline proc(k: []f32, a, b: int) -> []f32 {return k != nil ? k[a:b] : nil}
	for f, i in e.fx[c.first:base.span_end(c)] {
		lanes := lane_rows(e, e.lanes.fx[int(c.first) + i])
		p := e.mix.params[f.device]
		state := e.fx_bytes[f.state.first:base.span_end(f.state)]
		effect := device.DEVICE_TABLE[s.devices[f.device]].effect
		for a := 0; a < len(l); {
			t := at + i64(a)
			b := a + cell_piece(t, len(l) - a, len(lanes) > 0)
			controls := false
			for li in lanes {
				row := s.automation[li]
				v := song.automation_cell_value(s, row, t)
				#partial switch row.kind {
				case .Param:
					p[row.param] = v
				case .Effect_Control:
					device.control_apply(&e.programs, &e.programs.controls[row.ref], v)
					controls = true
				}
			}
			if controls {
				device.program_derive(&e.programs, i32(p[.Program]))
			}
			effect(state, &p, l[a:b], r[a:b], piece(key_l, a, b), piece(key_r, a, b), w.fx_scratch)
			a = b
		}
	}
}

// How each sidechain mode ducks a block (`at`: the song sample of l[0]),
// and where in a track's strip: an insert before its effects (a pumping
// bass), or with its fader after them (under the voice).
Sidechain_Row :: struct {
	duck:  proc(s: ^song.Song, sc: song.Sidechain, at: i64, l, r: []f32),
	fader: bool,
}

SIDECHAIN_TABLE := [song.Sidechain_Mode]Sidechain_Row {
	.None  = {},
	.Hits  = {duck, false},
	.Spans = {duck_spans, true},
}

// Dips the block under the voice tracks' spans (onimite's duck_envelope,
// fframes' duck_under_voice): spans closer than `merge` merge; the gain
// falls to `depth` dB over `attack` before a span and comes back over
// `release` after `hold`, per sample on the song's clock.
@(private = "file")
duck_spans :: proc(s: ^song.Song, sc: song.Sidechain, at: i64, l, r: []f32) {
	if len(s.voices) == 0 {
		return
	}
	n := i64(len(l))
	attack := i64(math.round(sc.attack * RATE))
	hold := i64(math.round(sc.hold * RATE))
	release := i64(math.round(sc.release * RATE))
	gap := i64(math.round(sc.merge * RATE))
	depth := f32(base.db_to_gain(sc.depth))
	weight := make([]f32, n, context.temp_allocator)
	region :: proc(a, b, at, n, attack, hold, release: i64, weight: []f32) {
		lo := max(a - attack, at)
		hi := min(b + hold + release, at + n)
		for t in lo ..< hi {
			w: f32 = 1
			switch {
			case t < a:
				w = f32(t - (a - attack)) / f32(max(attack, 1))
			case t >= b + hold:
				w = 1 - f32(t - (b + hold)) / f32(max(release, 1))
			}
			weight[t - at] = max(weight[t - at], w)
		}
	}
	// merged as they come (the spans are sorted by start)
	a := i64(math.round(s.voices[0][0] * RATE))
	b := i64(math.round(s.voices[0][1] * RATE))
	for v in s.voices[1:] {
		va, vb := i64(math.round(v[0] * RATE)), i64(math.round(v[1] * RATE))
		if va - b < gap {
			b = max(b, vb)
			continue
		}
		region(a, b, at, n, attack, hold, release, weight)
		a, b = va, vb
	}
	region(a, b, at, n, attack, hold, release, weight)
	for i in 0 ..< len(l) {
		g := 1 + (depth - 1) * weight[i]
		l[i] *= g
		r[i] *= g
	}
}

// Dips the block by `depth` at each of the source's hits, recovering with
// time constant `release` (synth.lua's sidechain: a gain per 64-sample block
// of the song's own grid, up to 0.5 s after each hit). `at`: the song sample
// of l[0].
@(private = "file")
duck :: proc(s: ^song.Song, sc: song.Sidechain, at: i64, l, r: []f32) {
	B :: SIDECHAIN_BLOCK
	k0 := at / B
	k1 := (at + i64(len(l)) - 1) / B
	g := make([]f32, int(k1 - k0 + 1), context.temp_allocator)
	slice.fill(g, 1)
	window := 0.5 + f64(B) / RATE
	from_t := f64(k0 * B) / RATE - window
	to_t := f64((k1 + 1) * B) / RATE
	// the first note at or after from_t, by the time index
	lo, hi := 0, len(s.by_time)
	for lo < hi {
		mid := (lo + hi) / 2
		if s.notes.time[s.by_time[mid]] < from_t {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	for idx in lo ..< len(s.by_time) {
		i := s.by_time[idx]
		nt := s.notes.time[i]
		if nt > to_t {
			break
		}
		if s.tracks[s.notes.track[i]].part != sc.part || (sc.pad != 0 && s.notes.pad[i] != sc.pad) || (sc.pitch >= 0 && math.abs(s.notes.pitch[i] - sc.pitch) > 0.01) {
			continue
		}
		j0 := i64(math.floor(nt * RATE / B))
		for k in max(j0, k0) ..= min(k1, j0 + i64(0.5 * RATE / B)) {
			dt := max(f64(k * B) / RATE - nt, 0)
			g[k - k0] = min(g[k - k0], f32(1 - sc.depth * math.exp(-dt / sc.release)))
		}
	}
	for i in 0 ..< len(l) {
		l[i] *= g[(at + i64(i)) / B - k0]
	}
	for i in 0 ..< len(r) {
		r[i] *= g[(at + i64(i)) / B - k0]
	}
}

// Dips the block by `db` inside its placement's room spans, with 150 ms
// ramps.
@(private = "file")
make_room :: proc(s: ^song.Song, db: f64, placement: i32, at: i64, l, r: []f32) {
	RAMP :: 0.15
	low := f32(base.db_to_gain(db))
	for span in s.room {
		if span.placement != placement {
			continue
		}
		i0 := max(0, int(math.floor((span.start - RAMP) * RATE)) - int(at))
		i1 := min(len(l), int(math.ceil((span.stop + RAMP) * RATE)) - int(at) + 1)
		for i in i0 ..< i1 {
			t := f64(at + i64(i)) / RATE
			depth := clamp(min(t - (span.start - RAMP), (span.stop + RAMP) - t) / RAMP, 0, 1)
			g := 1 + (low - 1) * f32(depth)
			l[i] *= g
			r[i] *= g
		}
	}
}

// A worker's temp allocator: the voices and effects may use
// context.temp_allocator, and a pool thread would otherwise share its
// creator's.
virtual_scratch :: virtual.Arena

scratch_begin :: proc(a: ^virtual.Arena) -> runtime.Allocator {
	_ = virtual.arena_init_growing(a)
	return virtual.arena_allocator(a)
}

scratch_end :: proc(a: ^virtual.Arena) {virtual.arena_destroy(a)}
