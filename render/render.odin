// render: a composed song into stereo samples. The engine (engine.odin)
// streams it, in any blocks, from anywhere; an export is that stream cut into
// time segments rendered side by side: each worker's engine seeks exactly to
// its segment's start (its notes chased, its effects' tails pre-rolled) and
// streams every track of it into a segment-sized buffer, and the owner takes
// the segments in order, runs the master over them as one stream, and hands
// them to a sink (a WAV being written, memory, a host's encoder). What an
// export holds is one wave of segments, never the song: a segment boundary is
// inaudible and the samples never depend on how many workers there were.
package odawg_render

import "base:runtime"
import "core:math"
import "core:os"
import "core:slice"
import "core:thread"
import base "../base"
import device "../device"
import song "../song"

RATE :: base.RATE

// Bytes an export's wave of segment buffers may take: fewer segments render
// at once when each is large (many stems), so an export of any length or any
// number of parts stays this small.
WAVE_BUDGET :: 64 * 1024 * 1024

Options :: struct {
	from:    f64, // song seconds
	to:      f64, // song seconds; <= from: the song's end and its tail
	threads: int, // 0: one per core
	segment: f64, // seconds a time segment covers (0: from the length and the cores); each costs a pre-roll
	stems:   bool, // hand each stem (stem_count: the parts, the returns, the buses; what the master sums) to the sink too
	mastering: Mastering, // a target's master in place of the song's (master_export)
}

// What an export hands on, a segment at a time and in order: `at` is the
// sample of l[0] counted from the range's start; stems (when asked) are one
// [2][]f32 per part.
Sink :: struct {
	data: rawptr,
	take: proc(data: rawptr, at: i64, l, r: []f32, stems: [][2][]f32),
}

// Seconds of sound past the last section: release tails and reverbs.
tail_from_song :: proc(s: ^song.Song) -> f64 {
	end := s.duration
	env := song.voice_env(s)
	for t in s.tracks {
		fx := chain_tail(s, t.chain)
		ret := 0.0
		for snd in s.sends[t.sends.first:base.span_end(t.sends)] {
			ret = max(ret, chain_tail(s, s.returns[snd.ret].chain))
		}
		p := s.params[t.instrument]
		for i in t.notes.first ..< base.span_end(t.notes) {
			n := note_from_row(s, int(i))
			end = max(end, n.time + device.note_tail(&p, n, &env) + fx + ret)
		}
	}
	return clamp(end - s.duration, 0, 12)
}

// Seconds an exact seek renders before its target: what the node that needs
// most needs (prerolls_from_song).
preroll_from_song :: proc(s: ^song.Song) -> f64 {
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
	return f64(most) / RATE
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
		memory := node_memory(s, int(k))
		own := memory > 0 ? i64(math.round(min(memory + 0.5, 8) * RATE)) : 0
		pre[k] = min(own + after, 12 * RATE)
	}
	return pre
}

// Seconds node k's chain rings after its input (the master's chain runs
// apart, in its Master_Run: none here).
node_memory :: proc(s: ^song.Song, k: int) -> f64 {
	return s.nodes[k].kind == .Master ? 0 : chain_tail(s, song.node_chain(s, k))
}

chain_tail :: proc(s: ^song.Song, c: base.Span) -> f64 {
	t := 0.0
	for d in s.chain[c.first:base.span_end(c)] {
		p := s.params[d]
		t += device.effect_tail(s.devices[d], &p)
	}
	return t
}

note_from_row :: proc(s: ^song.Song, i: int) -> device.Note {
	return song.note_of(s, i)
}

// Streams [from, to) of the song to `sink`, segment by segment in order.
// Returns what the master measured.
export_song :: proc(s: ^song.Song, opts: Options, sink: Sink) -> Master_Stats {
	heap := runtime.heap_allocator()
	first := i64(math.round(max(opts.from, 0) * RATE))
	to := opts.to > opts.from ? opts.to : s.duration + tail_from_song(s)
	frames := max(0, int(math.round(to * RATE)) - int(first))
	if frames == 0 || len(s.tracks) == 0 {
		return {}
	}
	workers := opts.threads > 0 ? opts.threads : max(1, os.get_processor_core_count())
	// segments: long enough that the pre-roll is a small part, short enough
	// that every core has one
	seconds := opts.segment
	if seconds <= 0 {
		seconds = clamp(f64(frames) / RATE / f64(workers), 4, 30)
	}
	segment := int(math.round(seconds * RATE))
	// the master streams in the owner, over the segments in order
	master: Master_Run
	master_run_init(&master, s, opts.mastering, heap)
	defer master_run_destroy(&master, heap)
	master_run_reset(&master, first)
	has_master := master_run_active(&master)
	lm := master.latency
	total := frames + lm // the master looks this far ahead
	segments := (total + segment - 1) / segment
	parts := opts.stems ? stem_count(s) : 0
	// a wave's buffers: per job its mix (2 x segment) and stems, one slab,
	// as many jobs at once as the cores and the budget allow
	per_job := 2 * segment * (1 + parts)
	wave := clamp(min(workers, segments), 1, max(1, WAVE_BUDGET / (per_job * size_of(f32))))
	slab := make([]f32, per_job * wave, heap)
	defer delete(slab, heap)
	jobs := make([]Job, wave, heap)
	defer delete(jobs, heap)
	primed := 0 // master output samples dropped so far (its lookahead filling)
	stems_view := make([][2][]f32, parts, heap)
	defer delete(stems_view, heap)
	for g0 := 0; g0 < segments; g0 += wave {
		count := min(wave, segments - g0)
		for k in 0 ..< count {
			from := (g0 + k) * segment
			buf := slab[per_job * k:][:per_job]
			slice.zero(buf)
			jobs[k] = {song = s, at = first + i64(from), frames = min(segment, total - from), buf = buf, parts = parts, segment = segment}
		}
		if count == 1 || workers == 1 {
			for k in 0 ..< count {
				run_job(&jobs[k])
			}
		} else {
			pool: thread.Pool
			thread.pool_init(&pool, heap, count)
			for k in 0 ..< count {
				thread.pool_add_task(&pool, heap, proc(t: thread.Task) {run_job((^Job)(t.data))}, &jobs[k])
			}
			thread.pool_start(&pool)
			thread.pool_finish(&pool)
			thread.pool_destroy(&pool)
		}
		// in order: the master, then the sink
		for k in 0 ..< count {
			j := &jobs[k]
			l, r := j.buf[:j.frames], j.buf[segment:][:j.frames]
			for p in 0 ..< parts {
				at := 2 * segment * (1 + p)
				stems_view[p] = {j.buf[at:][:j.frames], j.buf[at + segment:][:j.frames]}
			}
			// the master's output lags its input by its lookahead: its output
			// sample t belongs to song sample t - lm, so stems (its input)
			// line up with the mix (its output) by dropping lm from each
			out_at := j.at
			skip := 0
			if has_master {
				for b := 0; b < j.frames; b += BLOCK {
					m := min(BLOCK, j.frames - b)
					master_run_block(&master, l[b:][:m], r[b:][:m])
				}
				skip = min(lm - primed, j.frames)
				primed += skip
			}
			ml, mr := l[skip:], r[skip:]
			mix_at := out_at + i64(skip) - i64(lm) // the song sample of ml[0]
			keep := int(min(i64(len(ml)), first + i64(frames) - mix_at))
			if keep <= 0 {
				continue
			}
			// stems for the same song samples: the input at mix_at
			for p in 0 ..< parts {
				off := int(mix_at - out_at)
				lo := max(off, 0)
				stems_view[p] = {stems_view[p][0][lo:][:min(keep, j.frames - lo)], stems_view[p][1][lo:][:min(keep, j.frames - lo)]}
			}
			sink.take(sink.data, mix_at - first, ml[:keep], mr[:keep], stems_view[:])
		}
	}
	return master.stats
}

// One segment: its own engine, sought exactly to the segment's start, every
// track streamed into the job's buffer (the master runs in the owner).
@(private = "file")
Job :: struct {
	song:    ^song.Song,
	at:      i64,
	frames:  int,
	buf:     []f32,
	parts:   int,
	segment: int,
}

@(private = "file")
run_job :: proc(j: ^Job) {
	scratch: virtual_scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	e: Engine
	engine_init(&e, j.song)
	defer engine_destroy(&e)
	e.no_master = true
	engine_seek(&e, j.at, true)
	stems := make([][2][]f32, j.parts, context.temp_allocator)
	for p in 0 ..< j.parts {
		at := 2 * j.segment * (1 + p)
		stems[p] = {j.buf[at:][:j.frames], j.buf[at + j.segment:][:j.frames]}
	}
	engine_process(&e, j.buf[:j.frames], j.buf[j.segment:][:j.frames], j.parts > 0 ? stems : nil)
}

// ---- into memory -----------------------------------------------------------------------

// The rendered range in memory: the mix and (when asked) the stems (the
// parts in song.parts order, then the returns, then the buses: what the
// master sums). Only what was asked is held.
Output :: struct {
	from:        f64,
	frames:      int,
	left, right: []f32,
	stems:       [][2][]f32,
	slab:        []f32,
	stats:       Master_Stats,
}

output_from_song :: proc(s: ^song.Song, opts: Options, allocator := context.allocator) -> (out: Output) {
	first := i64(math.round(max(opts.from, 0) * RATE))
	to := opts.to > opts.from ? opts.to : s.duration + tail_from_song(s)
	out.from = f64(first) / RATE
	out.frames = max(0, int(math.round(to * RATE)) - int(first))
	parts := opts.stems ? stem_count(s) : 0
	out.slab = make([]f32, 2 * out.frames * (1 + parts), allocator)
	out.left, out.right = out.slab[:out.frames], out.slab[out.frames:][:out.frames]
	out.stems = make([][2][]f32, parts, allocator)
	for i in 0 ..< parts {
		at := 2 * out.frames * (1 + i)
		out.stems[i] = {out.slab[at:][:out.frames], out.slab[at + out.frames:][:out.frames]}
	}
	o := opts
	o.to = to
	out.stats = export_song(s, o, {&out, proc(data: rawptr, at: i64, l, r: []f32, stems: [][2][]f32) {
		out := (^Output)(data)
		copy(out.left[at:], l)
		copy(out.right[at:], r)
		for st, p in stems {
			copy(out.stems[p][0][at:], st[0])
			copy(out.stems[p][1][at:], st[1])
		}
	}})
	return
}

// Exports [opts.from, opts.to) into buffers the caller holds: the mix into
// `mix`, the stems into `parts` (stem_count's order, part p first at p;
// shorter: the rest left out; none: no stems),
// each from the range's first sample and as long as it is (the song is cut
// there). Every core renders; each segment is copied in once, in order.
export_into :: proc(s: ^song.Song, opts: Options, mix: [2][]f32, parts: [][2][]f32 = nil) -> Master_Stats {
	Into :: struct {
		mix:   [2][]f32,
		parts: [][2][]f32,
	}
	x := Into{mix, parts}
	o := opts
	o.stems = len(parts) > 0
	if o.to <= o.from {
		o.to = o.from + f64(min(len(mix[0]), len(mix[1]))) / RATE
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
