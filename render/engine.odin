package odawg_render

import "base:runtime"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
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

BLOCK :: 1024 // what a track processes at a time (any size gives the same samples)
// An engine's scratch (its tracks take turns with it): a track's block, its
// send, a discard (seeks, mutes), a choked note's.
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
	graph:     []f32, // the lanes' buffers of the largest call of device.graph_run
	fx:        []Fx_Run,
	fx_bytes:  []u8,
	fx_scratch: ^device.Fx_Scratch, // the one its effects share, a call at a time
	scratch:   []f32, // shared by the tracks: a discard (2 x BLOCK) at 4 x BLOCK, a choked note's at 6 x BLOCK
	// The routing: a run per node (song.nodes), the order they render in,
	// their blocks (2 x BLOCK each) and whether each holds sound, and per
	// edge (song.edges) its delay line (empty: none).
	nodes:     []Node_Run,
	order:     []i32,
	blocks:    []f32,
	dirty:     []bool,
	edges:     []Edge_Run,
	rings:     []f32,
	cursor:    i64, // the song sample of the next output
	// The key the node being rendered hears (its key edges summed; nil:
	// none), and its block.
	key_l, key_r: []f32,
	keys:      []f32, // 2 x BLOCK
	master:    Master_Run, // the song's master: its gain, chain, lookahead, what it measured
	no_master: bool, // an export's segment: the owner runs the master over the segments in order
	stem_gain: []f32, // per stem (stem_count): its placement's level, so a stem is what the master hears of it
	arena:     virtual.Arena,
}

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
	slots:     base.Span, // into voices
	next_note: i32, // into song.notes: the next to start
	stolen:    int, // notes that found no free slot (a finding)
	placement: i32, // its song's (song.node_placement; -1: a clip's): where it makes room
}

Fx_Run :: struct {
	device: i32, // into song.devices
	state:  base.Span, // into fx_bytes
}

// Sizes the engine for a song and puts it at sample 0.
engine_init :: proc(e: ^Engine, s: ^song.Song) -> bool {
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
	bytes_total, graph_total := 0, 0
	for t, ti in s.tracks {
		p := s.params[t.instrument]
		bytes_total += int(e.tracks[ti].slots.count) * device.voice_bytes(&p, &e.env)
		bufs := 0
		for prog in s.programs.programs {
			bufs = max(bufs, int(prog.bufs))
		}
		graph_total = max(graph_total, int(e.tracks[ti].slots.count) * bufs * 2 * device.NODE_CHUNK)
	}
	e.graph = make([]f32, graph_total)
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
		if pl := song.node_placement(s, k); pl >= 0 {
			run.origin = i64(math.round(s.placements[pl].at * RATE))
		}
		first := fi
		c := s.nodes[k].kind == .Master ? base.Span{} : song.node_chain(s, k)
		for d in s.chain[c.first:base.span_end(c)] {
			p := s.params[d]
			size := (device.effect_size(s.devices[d], &p) + 15) &~ 15
			e.fx[fi] = {d, {i32(bytes), i32(size)}}
			bytes += size
			fi += 1
			if lat := device.DEVICE_TABLE[s.devices[d]].effect_latency; lat != nil {
				run.latency += i64(lat(&p))
			}
		}
		run.chain = {i32(first), i32(fi - first)}
	}
	e.fx_bytes = make([]u8, bytes)
	e.fx_scratch = new(device.Fx_Scratch)
	master_run_init(&e.master, s, {})
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
	e.blocks = make([]f32, 2 * BLOCK * len(s.nodes))
	e.keys = make([]f32, 2 * BLOCK)
	e.dirty = make([]bool, len(s.nodes))
	e.scratch = make([]f32, SCRATCH)
	engine_seek(e, 0, false)
	return true
}

engine_destroy :: proc(e: ^Engine) {
	virtual.arena_destroy(&e.arena)
	e^ = {}
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
	from := at
	if exact {
		most: i64
		for nd in e.nodes {
			most = max(most, nd.pre)
		}
		from = max(at - most, 0)
	}
	e.cursor = from
	for &nd in e.nodes {
		nd.started = false
	}
	if from == at {
		for k in 0 ..< len(e.nodes) {
			node_start(e, k)
		}
	} else {
		// the walk to `at`, each node joining at the block its start falls in
		for e.cursor < at {
			n := int(min(at - e.cursor, BLOCK))
			for k in 0 ..< len(e.nodes) {
				if !e.nodes[k].started && e.cursor + i64(n) > at - e.nodes[k].pre {
					node_start(e, k)
				}
			}
			walk_block(e, n, false)
		}
		// what needs no pre-roll joins at `at` itself
		for k in 0 ..< len(e.nodes) {
			if !e.nodes[k].started {
				node_start(e, k)
			}
		}
	}
	// the master takes the mix its latency ahead of what it puts out: prime
	// its lookahead with that much (its output then is its delay)
	master_run_reset(&e.master, at)
	for left := e.no_master ? 0 : i64(e.master.latency); left > 0; {
		n := int(min(left, BLOCK))
		walk_block(e, n, true)
		left -= i64(n)
	}
	e.cursor = at
	e.master.stats = {}
}

// Starts node `k` at the cursor: a track's notes chased there, a node's
// effects and its inputs' delay lines reset to its time.
@(private = "file")
node_start :: proc(e: ^Engine, k: int) {
	s := e.song
	nd := &e.nodes[k]
	nd.started = true
	e.dirty[k] = false
	NODE_RUNS[s.nodes[k].kind].start(e, k, e.cursor + nd.lead)
	for i in nd.inputs.first ..< base.span_end(nd.inputs) {
		x := &e.edges[i]
		slice.zero(e.rings[x.ring.first:base.span_end(x.ring)])
		x.pos = e.cursor + e.nodes[s.edges[i].from].lead
		x.sound = min(i64) / 2
	}
}

// The song's next `n` samples: every started node in order into its block
// (a track its voices and chain, a bus its inputs and chain), the master's
// last (mastered unless `no_master`; `master` false: only the nodes before
// it, a seek's walk). Returns the master's block.
@(private = "file")
walk_block :: proc(e: ^Engine, n: int, master := true) -> ([]f32, []f32) {
	s := e.song
	for k in e.order {
		nd := &e.nodes[k]
		l, r := node_block(e, int(k), n)
		if !nd.started {
			e.dirty[k] = false
			continue
		}
		kind := s.nodes[k].kind
		if kind == .Master && !master {
			continue
		}
		e.key_l, e.key_r = node_keys(e, int(k), n)
		e.dirty[k] = NODE_RUNS[kind].block(e, int(k), l, r)
	}
	e.cursor += i64(n)
	return node_block(e, int(song.master_node(s)), n)
}

// How each kind of node runs: put at song sample `at` (its output's: a
// seek's start), and over its next block, whether it holds sound.
Node_Run_Row :: struct {
	start: proc(e: ^Engine, k: int, at: i64),
	block: proc(e: ^Engine, k: int, l, r: []f32) -> bool,
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
track_node_start :: proc(e: ^Engine, k: int, at: i64) {
	track_seek(e, k, at, false)
}

@(private = "file")
track_node_block :: proc(e: ^Engine, k: int, l, r: []f32) -> bool {
	if e.song.tracks[k].muted {
		track_skip(e, k, len(l))
		return false
	}
	return track_block(e, k, l, r)
}

// A node summing its inputs (a part, a return, a bus): its chain reset to
// its input's time, asleep until sound comes; a block of its inputs through
// its chain.
@(private = "file")
sum_start :: proc(e: ^Engine, k: int, at: i64) {
	nd := &e.nodes[k]
	for f in e.fx[nd.chain.first:base.span_end(nd.chain)] {
		reset_fx(e, k, f, at + nd.latency)
	}
	nd.awake_until = at + nd.latency
}

@(private = "file")
sum_block :: proc(e: ^Engine, k: int, l, r: []f32) -> bool {
	heard := node_inputs(e, k, l, r)
	return e.nodes[k].chain.count > 0 ? node_chain_run(e, k, l, r, heard) : heard
}

// A placement's: what its song plays, at its level, ducked, windowed.
@(private = "file")
song_block :: proc(e: ^Engine, k: int, l, r: []f32) -> bool {
	heard := node_inputs(e, k, l, r)
	if heard {
		placement_block(e, k, l, r)
	}
	return heard
}

// The master: the mix through its Master_Run (not an export segment's: its
// owner runs the master).
@(private = "file")
master_node_block :: proc(e: ^Engine, k: int, l, r: []f32) -> bool {
	node_inputs(e, k, l, r)
	if !e.no_master && master_run_active(&e.master) {
		master_run_block(&e.master, l, r)
	}
	return true
}

@(private = "file")
node_block :: #force_inline proc(e: ^Engine, k, n: int) -> ([]f32, []f32) {
	return e.blocks[2 * BLOCK * k:][:n], e.blocks[2 * BLOCK * k + BLOCK:][:n]
}

// A bus's or a return's chain over its block (its input summed in place):
// awake stretches run it, from the first sound after a silence (its effects
// reset there) to its tail after the last; asleep, the block stays silent.
// Whether it put out anything.
@(private = "file")
node_chain_run :: proc(e: ^Engine, k: int, l, r: []f32, heard: bool) -> (wrote: bool) {
	nd := &e.nodes[k]
	n := len(l)
	start := e.cursor + nd.lead + nd.latency // its input's song sample at l[0]
	if !heard && start >= nd.awake_until {
		return false // asleep, nothing coming: its block is the input's silence
	}
	sound :: #force_inline proc(l, r: []f32, j: int) -> bool {return l[j] != 0 || r[j] != 0}
	for i := 0; i < n; {
		if start + i64(i) >= nd.awake_until {
			// asleep: silent to the next sound, where it wakes fresh
			j := i
			for j < n && !sound(l, r, j) {
				j += 1
			}
			if j == n {
				break
			}
			for f in e.fx[nd.chain.first:base.span_end(nd.chain)] {
				reset_fx(e, k, f, start + i64(j))
			}
			nd.awake_until = start + i64(j) + 1 + nd.tail
			i = j
		}
		// awake: on until the input has been silent for its tail
		j := i
		for j < n && start + i64(j) < nd.awake_until {
			if sound(l, r, j) {
				nd.awake_until = start + i64(j) + 1 + nd.tail
			}
			j += 1
		}
		kl, kr := e.key_l, e.key_r
		if kl != nil {
			kl, kr = kl[i:j], kr[i:j]
		}
		run_fx(e, nd.chain, l[i:j], r[i:j], kl, kr)
		wrote = true
		i = j
	}
	return
}

// What a node's effects' sidechains hear: its key edges' sources summed
// (nil: it has none, so they hear the node itself).
@(private = "file")
node_keys :: proc(e: ^Engine, k, n: int) -> ([]f32, []f32) {
	s := e.song
	kl, kr := e.keys[:n], e.keys[BLOCK:][:n]
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
		if !e.dirty[x.from] {
			continue
		}
		sl, sr := node_block(e, int(x.from), n)
		for j in 0 ..< n {
			kl[j] += sl[j] * x.gain
			kr[j] += sr[j] * x.gain
		}
	}
	if !found {
		return nil, nil
	}
	return kl, kr
}

// A node's input: its edges' sources summed in edge order, each at its gain
// (through its delay line where it has one). Whether any sound came in.
@(private = "file")
node_inputs :: proc(e: ^Engine, k: int, l, r: []f32) -> bool {
	s := e.song
	n := len(l)
	slice.zero(l)
	slice.zero(r)
	heard := false
	inputs := e.nodes[k].inputs
	for i in inputs.first ..< base.span_end(inputs) {
		x := s.edges[i]
		run := &e.edges[i]
		if x.kind != .Audio || run.looped {
			continue
		}
		sl, sr := node_block(e, int(x.from), n)
		if run.delay > 0 {
			// written at the source's time, read `delay` behind it
			size := i64(run.ring.count / 2)
			mask := size - 1
			rl := e.rings[run.ring.first:][:size]
			rr := e.rings[i64(run.ring.first) + size:][:size]
			if e.dirty[x.from] {
				run.sound = run.pos + i64(n) - 1
			}
			for j in 0 ..< n {
				t := run.pos + i64(j)
				rl[t & mask] = e.dirty[x.from] ? sl[j] : 0
				rr[t & mask] = e.dirty[x.from] ? sr[j] : 0
				l[j] += rl[(t - run.delay) & mask] * x.gain
				r[j] += rr[(t - run.delay) & mask] * x.gain
			}
			// heard while what it reads may still hold sound
			heard ||= run.pos - run.delay <= run.sound
			run.pos += i64(n)
			continue
		}
		if !e.dirty[x.from] {
			continue
		}
		for j in 0 ..< n {
			l[j] += sl[j] * x.gain
		}
		for j in 0 ..< n {
			r[j] += sr[j] * x.gain
		}
		heard = true
	}
	return heard
}

// A placement's node over a block of what its song plays: its level, its
// duck under the voice, its window (`at`: the song sample of l[0]).
@(private = "file")
placement_block :: proc(e: ^Engine, k: int, l, r: []f32) {
	s := e.song
	pl := s.placements[s.nodes[k].ref]
	at := e.cursor + e.nodes[k].lead
	if g := f32(base.db_to_gain(pl.gain_db)); g != 1 {
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
track_seek :: proc(e: ^Engine, ti: int, at: i64, exact: bool) {
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
	reset_track_fx(e, ti, input)
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
		chase_to(e, ti, start, jump)
		if over {
			// its sound is over by `input`, what it cut is still cut
			note_cuts(e, ti, i32(i), n)
			continue
		}
		start_note(e, ti, i32(i), mono, start)
	}
	chase_to(e, ti, input, jump)
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
	if e.song.programs.programs[program].layer_mode == .All {
		layers: [device.MAX_LAYERS]i32
		rand := f32(base.hash_unit(e.song.notes.seed[ni] ~ 0x5ead))
		for l in layers[:device.graph_layers(&e.song.programs, program, n, rand, layers[:])] {
			layer_cuts(e, run, ni, l, n)
		}
		return
	}
	if chokes := device.graph_chokes(&e.song.programs, program, n); len(chokes) > 0 {
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
chase_to :: proc(e: ^Engine, ti: int, at: i64, jump: bool) {
	s := e.song
	run := &e.tracks[ti]
	discard := e.scratch[4 * BLOCK:][:2 * BLOCK]
	for k in run.slots.first ..< base.span_end(run.slots) {
		slot := int(k)
		if e.slot_note[slot] < 0 {
			continue
		}
		target := at - i64(math.round(s.notes.time[e.slot_note[slot]] * RATE))
		if jump {
			if e.slot_at[slot] == 0 {
				play_slot(e, ti, slot, discard[:0], discard[BLOCK:][:0]) // its state set from the note
			}
			e.slot_at[slot] = max(e.slot_at[slot], target)
			continue
		}
		for e.slot_note[slot] >= 0 && e.slot_at[slot] < target {
			m := int(min(target - e.slot_at[slot], BLOCK))
			slice.zero(discard[:2 * BLOCK])
			if !play_slot(e, ti, slot, discard[:m], discard[BLOCK:][:m]) {
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
	p := e.song.params[f.device]
	state := e.fx_bytes[f.state.first:base.span_end(f.state)]
	device.effect_reset(e.song.devices[f.device], state, &p, at - e.nodes[k].origin)
}

// Streams the next len(l) samples of the mix into l and r (and into stems,
// when given: one [2][]f32 per stem (stem_count: the parts, then the
// returns, then the buses), as long as l, what goes into the master), on
// the caller's thread: for a preview playing, or a frame.
engine_process :: proc(e: ^Engine, l, r: []f32, stems: [][2][]f32 = nil) {
	first := len(e.song.tracks)
	for done := 0; done < len(l); {
		n := min(len(l) - done, BLOCK)
		ml, mr := walk_block(e, n)
		for st, p in stems {
			if e.dirty[first + p] {
				sl, sr := node_block(e, first + p, n)
				g := e.stem_gain[p]
				for i in 0 ..< n {
					st[0][done + i] = sl[i] * g
					st[1][done + i] = sr[i] * g
				}
			} else {
				slice.zero(st[0][done:][:n])
				slice.zero(st[1][done:][:n])
			}
		}
		copy(l[done:], ml)
		copy(r[done:], mr)
		done += n
	}
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
track_skip :: proc(e: ^Engine, ti: int, n: int) {
	discard := e.scratch[4 * BLOCK:][:2 * BLOCK]
	for done := 0; done < n; {
		m := min(n - done, BLOCK)
		track_block(e, ti, discard[:m], discard[BLOCK:][:m])
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
start_note :: proc(e: ^Engine, ti: int, ni: i32, mono: bool, start: i64) -> []int {
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
	layered := program >= 0 && e.song.programs.programs[program].layer_mode == .All
	if layered {
		rand := f32(base.hash_unit(e.song.notes.seed[ni] ~ 0x5ead))
		count = device.graph_layers(&e.song.programs, program, n, rand, layers[:])
	}
	slots := make([]int, count, context.temp_allocator)
	for li in 0 ..< count {
		layer := layered ? layers[li] : -1
		slot := slot_free(e, run, mono)
		if layered {
			layer_cuts(e, run, ni, layer, n)
		} else {
			// a pad that chokes others on the track cuts them (5 ms)
			if chokes := device.graph_chokes(&e.song.programs, program, n); len(chokes) > 0 {
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
	progs := &e.song.programs
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
play_slot :: proc(e: ^Engine, ti: int, slot: int, l, r: []f32) -> bool {
	return play_graph(e, slot, pad_level(e.song, ti, e.song.notes.pad[e.slot_note[slot]]), l, r)
}

// A pad's level on track `ti` (Pad_Gain_Set; 1: its own).
@(private = "file")
pad_level :: proc(s: ^song.Song, ti: int, pad: u32) -> f32 {
	if pad != 0 {
		for g in s.pad_gains {
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
play_graph :: proc(e: ^Engine, slot: int, level: f32, l, r: []f32) -> bool {
	s := e.song
	state := slot_state(e, slot)
	n := note_from_row(s, int(e.slot_note[slot]))
	v := [1]device.Graph_Voice{{state = state, note = n, seed = s.notes.seed[e.slot_note[slot]], at = e.slot_at[slot], gain = level}}
	play := device.graph_playing(state)
	m := len(l)
	if e.slot_choke[slot] != 0 {
		m = min(m, int(e.slot_choke[slot]))
	}
	sc := e.scratch[6 * BLOCK:]
	cl, cr := sc[:m], sc[BLOCK:][:m]
	choked := e.slot_choke[slot] != 0
	if choked {
		slice.zero(cl)
		slice.zero(cr)
		v[0].out_l, v[0].out_r = cl, cr
	} else {
		v[0].out_l, v[0].out_r = l[:m], r[:m]
	}
	device.graph_run(&s.programs, &e.env, play, v[:], m, e.graph)
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
play_graphs :: proc(e: ^Engine, ti: int, l, r: []f32) {
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
			play_graph(e, k, pad_level(s, ti, s.notes.pad[e.slot_note[k]]), l, r)
			continue
		}
		n := note_from_row(s, int(e.slot_note[k]))
		state := slot_state(e, k)
		voices[count] = {state = state, note = n, seed = s.notes.seed[e.slot_note[k]], at = e.slot_at[k], out_l = l, out_r = r, gain = pad_level(s, ti, n.pad)}
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
		device.graph_run(&s.programs, &e.env, plays[i], group[:g], len(l), e.graph)
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
track_block :: proc(e: ^Engine, ti: int, l, r: []f32) -> (wrote: bool) {
	s := e.song
	t := s.tracks[ti]
	run := &e.tracks[ti]
	n := len(l)
	nd := &e.nodes[ti]
	input := run.cursor + nd.latency
	slice.zero(l)
	slice.zero(r)
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
			reset_track_fx(e, ti, input + i64(pos))
		}
		// awake: voices to where it may sleep again (notes extend that)
		from := pos
		for pos < n {
			limit := sounding(e, run) ? i64(n) : clamp(nd.awake_until - input, i64(pos), i64(n))
			next := clamp(next_start(s, run, end) - input, i64(pos), limit)
			if int(next) > pos {
				play_graphs(e, ti, l[pos:next], r[pos:next])
				pos = int(next)
			}
			if run.next_note < end && next_start(s, run, end) == input + i64(pos) && pos < n {
				start_note(e, ti, run.next_note, mono, input + i64(pos))
				run.next_note += 1
				continue
			}
			if i64(pos) >= limit {
				break
			}
		}
		if pos > from {
			kl, kr := e.key_l, e.key_r
			if kl != nil {
				kl, kr = kl[from:pos], kr[from:pos]
			}
			finish_segment(e, ti, input + i64(from), l[from:pos], r[from:pos], kl, kr)
			wrote = true
		}
	}
	run.cursor += i64(n)
	return
}

// What follows the voices on an awake stretch of a track (`at`: the song
// sample of l[0]), a channel strip's order: its insert ducks (the bass
// under the kick), its effect chain, then its fader: gain and pan, its
// fader ducks (a clip under the voice), its room dip.
@(private = "file")
finish_segment :: proc(e: ^Engine, ti: int, at: i64, l, r: []f32, key_l, key_r: []f32) {
	s := e.song
	t := s.tracks[ti]
	n := len(l)
	ducks := s.sidechains[t.sidechains.first:base.span_end(t.sidechains)]
	for sc in ducks {
		if row := SIDECHAIN_TABLE[sc.mode]; row.duck != nil && !row.fader {
			row.duck(s, sc, at, l, r)
		}
	}
	run_fx(e, e.nodes[ti].chain, l, r, key_l, key_r)
	gain := base.db_to_gain(t.gain_db)
	pl, pr := song.PAN_LAW_TABLE[t.pan_law](t.pan)
	gl, gr := f32(gain * pl), f32(gain * pr)
	for i in 0 ..< n {
		l[i] *= gl
	}
	for i in 0 ..< n {
		r[i] *= gr
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
reset_track_fx :: proc(e: ^Engine, ti: int, at: i64) {
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

@(private = "file")
run_fx :: proc(e: ^Engine, c: base.Span, l, r: []f32, key_l: []f32 = nil, key_r: []f32 = nil) {
	for f in e.fx[c.first:base.span_end(c)] {
		p := e.song.params[f.device]
		state := e.fx_bytes[f.state.first:base.span_end(f.state)]
		device.DEVICE_TABLE[e.song.devices[f.device]].effect(state, &p, l, r, key_l, key_r, e.fx_scratch)
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
		n := s.notes[i]
		if n.time > to_t {
			break
		}
		if s.tracks[n.track].part != sc.part || (sc.pad != 0 && n.pad != sc.pad) || (sc.pitch >= 0 && math.abs(n.pitch - sc.pitch) > 0.01) {
			continue
		}
		j0 := i64(math.floor(n.time * RATE / B))
		for k in max(j0, k0) ..= min(k1, j0 + i64(0.5 * RATE / B)) {
			dt := max(f64(k * B) / RATE - n.time, 0)
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
