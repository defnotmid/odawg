// render: a composed song into stereo samples. The engine (engine.odin)
// streams it, in any blocks, from anywhere, its nodes on as many threads as
// it is given; an export is that one stream from its range's start (an exact
// seek there), handed a stretch at a time to a sink (a WAV being written,
// memory, a host's encoder). What an export holds is one stretch, never the
// song, and the samples never depend on how many threads there were.
package odawg_render

import "core:math"
import common "deps:odecs/common"
import base "../base"
import device "../device"
import song "../song"

RATE :: base.RATE

Options :: struct {
	from:    base.Seconds, // song seconds
	to:      base.Seconds, // song seconds; <= from: the song's end and its tail
	pool:    ^common.Work_Pool, // the caller's threads (nil: the caller's alone)
	stems:   bool, // hand each stem (stem_count: the parts, the returns, the buses; what the master sums) to the sink too
	mastering: Mastering, // a target's master in place of the song's (master_export)
}

// What an export hands on, a stretch at a time and in order: `at` is the
// sample of l[0] counted from the range's start; stems (when asked) are one
// [2][]f32 per part.
Sink :: struct {
	data: rawptr,
	take: proc(data: rawptr, at: i64, l, r: []f32, stems: [][2][]f32),
}

// Seconds of sound past the last section: release tails and reverbs.
tail_from_song :: proc(s: ^song.Song) -> base.Seconds {
	end := s.duration
	env := song.voice_env(s)
	rings := rings_from_song(s, context.temp_allocator)
	for t, ti in s.tracks {
		p := s.params[t.instrument]
		for i in t.notes.first ..< base.span_end(t.notes) {
			n := note_from_row(s, int(i))
			end = max(end, n.time + device.note_tail(&p, n, &env) + rings[ti])
		}
	}
	return clamp(end - s.duration, 0, 12)
}

// Seconds each node (song.nodes) rings on after its input stops: its
// chain's tail and the longest of what it feeds' (sound, not keys; the
// master's chain runs apart: none here). A track's: its effects, then its
// part's or a bus's, a return it sends to, all the way down.
rings_from_song :: proc(s: ^song.Song, allocator := context.allocator) -> []base.Seconds {
	ring := make([]base.Seconds, len(s.nodes), allocator)
	if len(s.nodes) == 0 {
		return ring
	}
	order, loops := song.graph_order(s, context.temp_allocator)
	looped := make([]bool, len(s.edges), context.temp_allocator)
	for i in loops {
		looped[i] = true
	}
	#reverse for k in order {
		after: base.Seconds
		for x, i in s.edges {
			if x.from == k && x.kind == .Audio && !looped[i] {
				after = max(after, ring[x.to])
			}
		}
		ring[k] = base.Seconds(node_memory(s, int(k)).ring) + after
	}
	return ring
}

// Seconds an exact seek renders before its target: what the node that needs
// most needs (prerolls_from_song).
preroll_from_song :: proc(s: ^song.Song) -> base.Seconds {
	if len(s.nodes) == 0 {
		return 0
	}
	order, loops := song.graph_order(s, context.temp_allocator)
	looped := make([]bool, len(s.edges), context.temp_allocator)
	for i in loops {
		looped[i] = true
	}
	most: i64
	for p in prerolls_from_song(s, order, looped, context.temp_allocator) {
		most = max(most, p)
	}
	return base.seconds_from_samples(most)
}

// Samples an exact seek starts each node (song.nodes) early: its own
// effects' memory (half a second more, at most 8) and the most anything after
// it needs, at most 12 s; `order` the graph's, `looped` its dropped edges.
prerolls_from_song :: proc(s: ^song.Song, order: []i32, looped: []bool, allocator := context.allocator) -> []i64 {
	pre := make([]i64, len(s.nodes), allocator)
	#reverse for k in order {
		after: i64
		for x, i in s.edges {
			if x.from == k && !looped[i] {
				after = max(after, pre[x.to])
			}
		}
		memory := node_memory(s, int(k)).state
		own := memory > 0 ? i64(math.round(min(memory + 0.5, 8) * RATE)) : 0
		pre[k] = min(own + after, 12 * RATE)
	}
	return pre
}

// What node k's chain holds of its input (the master's chain runs apart, in
// its Master_Run: nothing here): its effects' rings and memories in a row.
node_memory :: proc(s: ^song.Song, k: int) -> device.Effect_Memory {
	return s.nodes[k].kind == .Master ? {} : chain_memory(s, song.node_chain(s, k))
}

chain_memory :: proc(s: ^song.Song, c: base.Span) -> (m: device.Effect_Memory) {
	for d in s.chain[c.first:base.span_end(c)] {
		e := song.effect_memory_largest(s, d) // as far as a lane takes it
		m.ring += e.ring
		m.state += e.state
	}
	return
}

note_from_row :: proc(s: ^song.Song, i: int) -> device.Note {
	return song.note_of(s, i)
}

// Streams [from, to) of the song to `sink` in order: one engine, the song as
// one stream, each chunk handed on as it is made, its nodes on the caller's
// pool. Returns what the master measured.
export_song :: proc(s: ^song.Song, opts: Options, sink: Sink) -> Master_Stats {
	first := base.samples_from_seconds(max(opts.from, 0))
	to := opts.to > opts.from ? opts.to : s.duration + tail_from_song(s)
	frames := max(0, int(base.samples_from_seconds(to)) - int(first))
	if frames == 0 || len(s.tracks) == 0 {
		return {}
	}
	e: Engine
	if !engine_init(&e, s, opts.pool, opts.mastering) {
		return {}
	}
	defer engine_destroy(&e)
	if first > 0 {
		engine_seek(&e, first, true)
	}
	engine_stream(&e, frames, sink, opts.stems)
	return e.master.stats
}

// ---- into memory -----------------------------------------------------------------------

// The rendered range in memory: the mix and (when asked) the stems (the
// parts in song.parts order, then the returns, then the buses: what the
// master sums). Only what was asked is held.
Output :: struct {
	from:        base.Seconds,
	frames:      int,
	left, right: []f32,
	stems:       [][2][]f32,
	slab:        []f32,
	stats:       Master_Stats,
}

output_from_song :: proc(s: ^song.Song, opts: Options, allocator := context.allocator) -> (out: Output) {
	first := base.samples_from_seconds(max(opts.from, 0))
	to := opts.to > opts.from ? opts.to : s.duration + tail_from_song(s)
	out.from = base.seconds_from_samples(first)
	out.frames = max(0, int(base.samples_from_seconds(to)) - int(first))
	parts := opts.stems ? stem_count(s) : 0
	out.slab = make([]f32, 2 * out.frames * (1 + parts), allocator)
	out.left, out.right = out.slab[:out.frames], out.slab[out.frames:][:out.frames]
	out.stems = make([][2][]f32, parts, allocator)
	for i in 0 ..< parts {
		at := 2 * out.frames * (1 + i)
		out.stems[i] = {out.slab[at:][:out.frames], out.slab[at + out.frames:][:out.frames]}
	}
	// the one receive buffer, sized from the song before a sample is made:
	// the master and the stems write into it as they make each chunk
	if out.frames == 0 || len(s.tracks) == 0 {
		return
	}
	e: Engine
	if !engine_init(&e, s, opts.pool, opts.mastering) {
		return
	}
	defer engine_destroy(&e)
	if first > 0 {
		engine_seek(&e, first, true)
	}
	engine_process(&e, out.left, out.right, out.stems)
	out.stats = e.master.stats
	return
}

// Exports [opts.from, opts.to) into buffers the caller holds: the mix into
// `mix`, the stems into `parts` (stem_count's order, part p first at p;
// shorter: the rest left out; none: no stems),
// each from the range's first sample and as long as it is (the song is cut
// there). Every core renders; each stretch is copied in once, in order.
export_into :: proc(s: ^song.Song, opts: Options, mix: [2][]f32, parts: [][2][]f32 = nil) -> Master_Stats {
	Into :: struct {
		mix:   [2][]f32,
		parts: [][2][]f32,
	}
	x := Into{mix, parts}
	o := opts
	o.stems = len(parts) > 0
	if o.to <= o.from {
		o.to = o.from + base.seconds_from_samples(i64(min(len(mix[0]), len(mix[1]))))
	}
	return export_song(s, o, {&x, proc(data: rawptr, at: i64, l, r: []f32, stems: [][2][]f32) {
		x := (^Into)(data)
		if int(at) >= len(x.mix[0]) {
			return
		}
		copy(x.mix[0][at:], l)
		copy(x.mix[1][at:], r)
		for st, p in stems {
			if p < len(x.parts) && int(at) < len(x.parts[p][0]) {
				copy(x.parts[p][0][at:], st[0])
				copy(x.parts[p][1][at:], st[1])
			}
		}
	}})
}

output_destroy :: proc(out: ^Output, allocator := context.allocator) {
	delete(out.slab, allocator)
	delete(out.stems, allocator)
	out^ = {}
}
