package odawg_render

import "base:runtime"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import base "../base"
import device "../device"
import song "../song"

// The engine streams a song: any block of samples, in order, from wherever
// it was put. Its state is tables sized once from the song: per track a pool
// of voice slots (as many as the track ever has sounding at once, one for a
// mono device), a cursor into the track's notes, and the state bytes of its
// effect instances (its chain, and each send's own copy of the return's
// chain). Nothing is allocated while it plays, and the samples never depend
// on the block sizes it is asked for, so a render is the stream from 0 and
// a preview, a scrub and a final render hear the same song.

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
	fx:        []Fx_Run,
	fx_bytes:  []u8,
	sends:     []Send_Run,
	scratch:   []f32, // per track: its block (2 x BLOCK), its send (2 x BLOCK), a discard (2 x BLOCK)
	// The master: its chain's instances (into fx) and lookahead, what it has
	// measured, and a block of the mix going into it.
	master:    base.Span,
	master_latency: i64,
	stats:     Master_Stats,
	mix:       []f32, // 2 x BLOCK
	parts:     []f32, // a block per part (2 x BLOCK each): tracks sum into their part, parts into the mix, in table order
	part_dirty: []bool, // a part some track wrote to this block
	no_master: bool, // an export's segment: the owner runs the master over the segments in order
	arena:     virtual.Arena,
}

// What the master saw: the mix after its gain, before its chain, and the
// most its chain took off a block's peak.
Master_Stats :: struct {
	peak_before:    f32, // linear
	clipped_before: int, // samples past full scale
	reduction_db:   f32, // <= 0
}

Track_Run :: struct {
	cursor:    i64, // the song sample of its next output
	latency:   i64, // its chain's lookahead: its input runs this far ahead
	slots:     base.Span, // into voices
	next_note: i32, // into song.notes: the next to start
	chain:     base.Span, // into fx
	sends:     base.Span, // into sends
	stolen:    int, // notes that found no free slot (a finding)
	seed:      u64,
	// Dormancy: past `awake_until` (an input sample: every started note's
	// tail and the effects' tails are over) with no slot sounding, the track
	// is silent and does no work until its next note starts, where its
	// effects reset. Both edges come from the notes, never from where a block
	// falls, so the samples don't depend on block size.
	awake_until: i64,
	tail:      i64, // samples its effects (chain, returns) ring after their input
}

Send_Run :: struct {
	gain:  f32,
	chain: base.Span, // into fx
}

Fx_Run :: struct {
	device: i32, // into song.devices
	state:  base.Span, // into fx_bytes
}

// Sizes the engine for a song and puts it at sample 0.
engine_init :: proc(e: ^Engine, s: ^song.Song) -> bool {
	e.song = s
	e.env.bank = s.bank
	if virtual.arena_init_growing(&e.arena) != nil {
		return false
	}
	context.allocator = virtual.arena_allocator(&e.arena)
	e.tracks = make([]Track_Run, len(s.tracks))
	slots_total, fx_total, sends_total := 0, int(s.master.count), 0
	for t, ti in s.tracks {
		run := &e.tracks[ti]
		run.slots = {i32(slots_total), i32(polyphony_from_track(s, t))}
		slots_total += int(run.slots.count)
		fx_total += int(t.chain.count)
		for snd in s.sends[t.sends.first:base.span_end(t.sends)] {
			fx_total += int(s.returns[snd.ret].chain.count)
		}
		sends_total += int(t.sends.count)
		run.seed = base.hash_combine(s.seed, base.hash_combine(base.hash_string(s.parts[t.part]), base.hash_string(t.variant)))
		ret := 0.0
		for snd in s.sends[t.sends.first:base.span_end(t.sends)] {
			ret = max(ret, chain_tail(s, s.returns[snd.ret].chain))
		}
		run.tail = i64(math.ceil((chain_tail(s, t.chain) + ret) * RATE)) + DORMANT_MARGIN
	}
	bytes_total := 0
	for t, ti in s.tracks {
		bytes_total += int(e.tracks[ti].slots.count) * device.voice_state_bytes(s.devices[t.instrument])
	}
	e.voices, _ = mem.make_aligned([]u8, bytes_total, 16)
	e.slot_at_byte = make([]int, slots_total)
	{
		at := 0
		for t, ti in s.tracks {
			size := device.voice_state_bytes(s.devices[t.instrument])
			for k in e.tracks[ti].slots.first ..< base.span_end(e.tracks[ti].slots) {
				e.slot_at_byte[k] = at
				at += size
			}
		}
	}
	e.slot_note = make([]i32, slots_total)
	e.slot_at = make([]i64, slots_total)
	e.slot_choke = make([]i32, slots_total)
	e.fx = make([]Fx_Run, fx_total)
	e.sends = make([]Send_Run, sends_total)
	// the effect instances and their state bytes, 16-aligned each
	bytes, fi, si := 0, 0, 0
	add :: proc(e: ^Engine, s: ^song.Song, c: base.Span, fi, bytes: ^int) -> base.Span {
		first := fi^
		for d in s.chain[c.first:base.span_end(c)] {
			p := s.params[d]
			size := (device.DEVICE_TABLE[s.devices[d]].effect_size(&p) + 15) &~ 15
			e.fx[fi^] = {d, {i32(bytes^), i32(size)}}
			bytes^ += size
			fi^ += 1
		}
		return {i32(first), i32(fi^ - first)}
	}
	for t, ti in s.tracks {
		run := &e.tracks[ti]
		run.chain = add(e, s, t.chain, &fi, &bytes)
		for d in s.chain[t.chain.first:base.span_end(t.chain)] {
			p := s.params[d]
			if lat := device.DEVICE_TABLE[s.devices[d]].effect_latency; lat != nil {
				run.latency += i64(lat(&p))
			}
		}
		run.sends = {i32(si), t.sends.count}
		for snd in s.sends[t.sends.first:base.span_end(t.sends)] {
			e.sends[si] = {snd.gain, add(e, s, s.returns[snd.ret].chain, &fi, &bytes)}
			si += 1
		}
	}
	e.master = add(e, s, s.master, &fi, &bytes)
	for d in s.chain[s.master.first:base.span_end(s.master)] {
		p := s.params[d]
		if lat := device.DEVICE_TABLE[s.devices[d]].effect_latency; lat != nil {
			e.master_latency += i64(lat(&p))
		}
	}
	e.fx_bytes = make([]u8, bytes)
	e.mix = make([]f32, 2 * BLOCK)
	e.parts = make([]f32, 2 * BLOCK * max(len(s.parts), 1))
	e.scratch = make([]f32, SCRATCH)
	e.part_dirty = make([]bool, max(len(s.parts), 1))
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
	kind := s.devices[t.instrument]
	if device.DEVICE_TABLE[kind].mono || t.notes.count == 0 {
		return 1
	}
	p := s.params[t.instrument]
	ends := make([dynamic]f64, context.temp_allocator)
	most := 0
	for i in t.notes.first ..< base.span_end(t.notes) {
		n := note_from_row(s, int(i))
		#reverse for end, k in ends {
			if end <= n.time {
				unordered_remove(&ends, k)
			}
		}
		append(&ends, n.time + device.note_tail(kind, &p, n))
		most = max(most, len(ends))
	}
	return clamp(most, 1, MAX_POLYPHONY)
}

// Puts every track at song sample `at`: notes sounding there are started
// and played up to it (chased), effects reset to that moment. Exact: the
// effects' tails are rendered first too (from `at` minus the pre-roll), so
// what follows is what a stream from 0 would play; a scrub can skip that.
engine_seek :: proc(e: ^Engine, at: i64, exact: bool) {
	for ti in 0 ..< len(e.tracks) {
		track_seek(e, ti, at, exact)
	}
	// the master takes the mix `master_latency` ahead of what it puts out:
	// prime its lookahead with that much (its output then is its delay)
	master_reset(e, at)
	for left := e.no_master ? 0 : e.master_latency; left > 0; {
		n := int(min(left, BLOCK))
		mix_block(e, n)
		left -= i64(n)
	}
	e.stats = {}
}

// Puts the master's chain at song sample `at`, its measurements cleared.
master_reset :: proc(e: ^Engine, at: i64) {
	for f in e.fx[e.master.first:base.span_end(e.master)] {
		reset_fx(e, f, at)
	}
	e.stats = {}
}

// The tracks' next `n` samples summed the one way every path sums them:
// each track into its part (in track order), the parts into the mix (in
// part order). The parts' blocks stay in e.parts for stems.
@(private = "file")
sum_block :: proc(e: ^Engine, n: int) -> ([]f32, []f32) {
	for p in 0 ..< len(e.song.parts) {
		if e.part_dirty[p] {
			slice.zero(e.parts[2 * BLOCK * p:][:2 * BLOCK])
			e.part_dirty[p] = false
		}
	}
	for ti in 0 ..< len(e.tracks) {
		if e.song.tracks[ti].muted {
			track_skip(e, ti, n)
			continue
		}
		p := int(e.song.tracks[ti].part)
		if track_stream(e, ti, e.parts[2 * BLOCK * p:][:n], e.parts[2 * BLOCK * p + BLOCK:][:n], {}) {
			e.part_dirty[p] = true
		}
	}
	ml, mr := e.mix[:n], e.mix[BLOCK:][:n]
	slice.zero(ml)
	slice.zero(mr)
	for p in 0 ..< len(e.song.parts) {
		if !e.part_dirty[p] {
			continue
		}
		pl, pr := e.parts[2 * BLOCK * p:][:n], e.parts[2 * BLOCK * p + BLOCK:][:n]
		for i in 0 ..< n {
			ml[i] += pl[i]
		}
		for i in 0 ..< n {
			mr[i] += pr[i]
		}
	}
	return ml, mr
}

// The mix's next `n` samples through the master.
@(private = "file")
mix_block :: proc(e: ^Engine, n: int) -> ([]f32, []f32) {
	ml, mr := sum_block(e, n)
	master_block(e, ml, mr)
	return ml, mr
}

// The master over a block of the mix: its gain, what it measures, its chain.
master_block :: proc(e: ^Engine, l, r: []f32) {
	g := f32(base.db_to_gain(e.song.master_gain_db))
	peak: f32
	for i in 0 ..< len(l) {
		l[i] *= g
		r[i] *= g
		a := max(abs(l[i]), abs(r[i]))
		peak = max(peak, a)
		if a > 1 {
			e.stats.clipped_before += 1
		}
	}
	e.stats.peak_before = max(e.stats.peak_before, peak)
	if e.master.count == 0 {
		return
	}
	run_fx(e, e.master, l, r)
	after: f32
	for i in 0 ..< len(l) {
		after = max(after, abs(l[i]), abs(r[i]))
	}
	if peak > 0 && after < peak {
		e.stats.reduction_db = min(e.stats.reduction_db, f32(base.gain_to_db(f64(after / peak))))
	}
}

track_seek :: proc(e: ^Engine, ti: int, at: i64, exact: bool) {
	// exact: from as far back as its own effects remember (none: its notes
	// chased are enough)
	if pre := min(at, i64(math.round(preroll_from_track(e.song, e.song.tracks[ti]) * RATE))); exact && pre > 0 {
		track_seek(e, ti, at - pre, false)
		discard := track_scratch(e, ti)[4 * BLOCK:][:2 * BLOCK]
		for left := pre; left > 0; {
			n := int(min(left, BLOCK))
			track_block(e, ti, discard[:n], discard[BLOCK:][:n])
			left -= i64(n)
		}
		return
	}
	s := e.song
	t := s.tracks[ti]
	run := &e.tracks[ti]
	run.cursor = at
	input := at + run.latency
	run.awake_until = input // dormant unless a note is still sounding
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
	kind := s.devices[t.instrument]
	p := s.params[t.instrument]
	mono := device.DEVICE_TABLE[kind].mono
	discard := track_scratch(e, ti)[4 * BLOCK:][:2 * BLOCK]
	for i := first; i < first + k; i += 1 {
		n := note_from_row(s, i)
		start := i64(math.round(n.time * RATE))
		if f64(input - start) >= device.note_tail(kind, &p, n) * RATE {
			continue
		}
		slot := start_note(e, ti, i32(i), mono, start)
		if device.DEVICE_TABLE[kind].jump {
			// started (its state set from the note), then where it is
			play_slot(e, ti, slot, discard[:0], discard[BLOCK:][:0])
			e.slot_at[slot] = input - start
			continue
		}
		for e.slot_at[slot] < input - start {
			m := int(min(input - start - e.slot_at[slot], BLOCK))
			slice.zero(discard[:2 * BLOCK])
			if !play_slot(e, ti, slot, discard[:m], discard[BLOCK:][:m]) {
				break
			}
		}
	}
}

@(private = "file")
reset_fx :: proc(e: ^Engine, f: Fx_Run, at: i64) {
	p := e.song.params[f.device]
	state := e.fx_bytes[f.state.first:base.span_end(f.state)]
	device.DEVICE_TABLE[e.song.devices[f.device]].effect_reset(state, &p, at)
}

@(private = "file")
track_scratch :: proc(e: ^Engine, ti: int) -> []f32 {
	return e.scratch[:SCRATCH]
}

// Streams the next len(l) samples of the mix into l and r (and each part's
// into stems, when given: one [2][]f32 per part, as long as l), all tracks
// on the caller's thread: for a preview playing, or a frame.
engine_process :: proc(e: ^Engine, l, r: []f32, stems: [][2][]f32 = nil) {
	slice.zero(l)
	slice.zero(r)
	for st in stems {
		slice.zero(st[0])
		slice.zero(st[1])
	}
	// stems are what goes into the master
	has_master := !e.no_master && (e.master.count > 0 || e.song.master_gain_db != 0)
	for done := 0; done < len(l); {
		n := min(len(l) - done, BLOCK)
		ml, mr := sum_block(e, n)
		for st, p in stems {
			if e.part_dirty[p] {
				copy(st[0][done:], e.parts[2 * BLOCK * p:][:n])
				copy(st[1][done:], e.parts[2 * BLOCK * p + BLOCK:][:n])
			}
		}
		if has_master {
			master_block(e, ml, mr)
		}
		copy(l[done:], ml)
		copy(r[done:], mr)
		done += n
	}
}

// Streams a track's next len(l) samples, adding them into l and r and into
// its part's stem (when given). An engine's tracks share its scratch: they
// stream one at a time (workers each run an engine of their own).
track_stream :: proc(e: ^Engine, ti: int, l, r: []f32, stem: [2][]f32) -> (wrote: bool) {
	sc := track_scratch(e, ti)
	for done := 0; done < len(l); {
		n := min(len(l) - done, BLOCK)
		bl, br := sc[:n], sc[BLOCK:][:n]
		if !track_block(e, ti, bl, br) {
			done += n
			continue
		}
		wrote = true
		for i in 0 ..< n {
			l[done + i] += bl[i]
		}
		for i in 0 ..< n {
			r[done + i] += br[i]
		}
		if stem[0] != nil {
			for i in 0 ..< n {
				stem[0][done + i] += bl[i]
			}
			for i in 0 ..< n {
				stem[1][done + i] += br[i]
			}
		}
		done += n
	}
	return
}

// Moves a muted track on by `n` samples without hearing it (its state
// moves as if it played).
track_skip :: proc(e: ^Engine, ti: int, n: int) {
	discard := track_scratch(e, ti)[4 * BLOCK:][:2 * BLOCK]
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
start_note :: proc(e: ^Engine, ti: int, ni: i32, mono: bool, start: i64) -> int {
	run := &e.tracks[ti]
	{
		t := e.song.tracks[ti]
		p := e.song.params[t.instrument]
		tail := i64(math.ceil(device.note_tail(e.song.devices[t.instrument], &p, note_from_row(e.song, int(ni))) * RATE))
		run.awake_until = max(run.awake_until, start + tail + run.tail)
	}
	first := int(run.slots.first)
	slot := first
	if !mono {
		slot = -1
		oldest := first
		for k in first ..< int(base.span_end(run.slots)) {
			if e.slot_note[k] < 0 {
				slot = k
				break
			}
			if e.slot_at[k] > e.slot_at[oldest] {
				oldest = k
			}
		}
		if slot < 0 {
			slot = oldest
			run.stolen += 1
		}
	}
	// a pad that chokes others on the track cuts them (5 ms)
	if chokes := device.PAD_CHOKES[e.song.notes.pad[ni]]; chokes != {} {
		for k in first ..< int(base.span_end(run.slots)) {
			if k != slot && e.slot_note[k] >= 0 && e.slot_choke[k] == 0 && e.song.notes.pad[e.slot_note[k]] in chokes {
				e.slot_choke[k] = device.CHOKE_SAMPLES
			}
		}
	}
	if !mono || e.slot_note[slot] < 0 {
		mem.zero(&e.voices[e.slot_at_byte[slot]], device.voice_state_bytes(e.song.devices[e.song.tracks[ti].instrument]))
	}
	e.slot_note[slot] = ni
	e.slot_at[slot] = 0
	e.slot_choke[slot] = 0
	return slot
}

// Plays a slot's note for len(l) more samples; false once it is done.
@(private = "file")
play_slot :: proc(e: ^Engine, ti: int, slot: int, l, r: []f32) -> bool {
	s := e.song
	t := s.tracks[ti]
	ni := e.slot_note[slot]
	n := note_from_row(s, int(ni))
	kind := s.devices[t.instrument]
	p := s.params[t.instrument]
	seed := base.hash_combine(e.tracks[ti].seed, base.hash_combine(u64(n.time * RATE + 0.5), u64(n.pitch * 100) ~ u64(n.pad) << 40))
	voice := device.DEVICE_TABLE[kind].voice
	// a drum pad at a level of its own (Pad_Gain_Set)
	level := f32(1)
	if n.pad != .None && t.pad_gain_db[n.pad] != 0 {
		level = f32(base.db_to_gain(f64(t.pad_gain_db[n.pad])))
	}
	sc := track_scratch(e, ti)[6 * BLOCK:]
	if e.slot_choke[slot] == 0 {
		alive: bool
		if level == 1 {
			alive = voice(slot_state(e, slot), &p, n, seed, e.slot_at[slot], &e.env, l, r)
		} else {
			vl, vr := sc[:len(l)], sc[BLOCK:][:len(l)]
			slice.zero(vl)
			slice.zero(vr)
			alive = voice(slot_state(e, slot), &p, n, seed, e.slot_at[slot], &e.env, vl, vr)
			for i in 0 ..< len(l) {
				l[i] += vl[i] * level
				r[i] += vr[i] * level
			}
		}
		e.slot_at[slot] += i64(len(l))
		if !alive {
			e.slot_note[slot] = -1
		}
		return alive
	}
	// choked: what is left of its fade, then it stops
	m := min(len(l), int(e.slot_choke[slot]))
	cl, cr := sc[:m], sc[BLOCK:][:m]
	slice.zero(cl)
	slice.zero(cr)
	voice(slot_state(e, slot), &p, n, seed, e.slot_at[slot], &e.env, cl, cr)
	left := e.slot_choke[slot]
	for i in 0 ..< m {
		g := level * f32(left - i32(i)) / f32(device.CHOKE_SAMPLES)
		l[i] += cl[i] * g
		r[i] += cr[i] * g
	}
	e.slot_at[slot] += i64(m)
	e.slot_choke[slot] -= i32(m)
	if e.slot_choke[slot] <= 0 {
		e.slot_note[slot] = -1
		e.slot_choke[slot] = 0
		return false
	}
	return true
}

// One block of a track, in segments: awake, its voices (split where notes
// start, so every note begins on its own sample) then the sidechains, the
// window and room dips, level and pan, the effect chain and the sends;
// dormant, nothing (the block stays zero) until the next note wakes it with
// its effects reset. The input runs `latency` samples ahead of the output, so
// lookahead effects line up. False when the whole block was dormant.
@(private = "file")
track_block :: proc(e: ^Engine, ti: int, l, r: []f32) -> (wrote: bool) {
	s := e.song
	t := s.tracks[ti]
	run := &e.tracks[ti]
	n := len(l)
	input := run.cursor + run.latency
	slice.zero(l)
	slice.zero(r)
	mono := device.DEVICE_TABLE[s.devices[t.instrument]].mono
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
		if at >= run.awake_until && !sounding(e, run) {
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
			limit := sounding(e, run) ? i64(n) : clamp(run.awake_until - input, i64(pos), i64(n))
			next := clamp(next_start(s, run, end) - input, i64(pos), limit)
			if int(next) > pos {
				for k in run.slots.first ..< base.span_end(run.slots) {
					if e.slot_note[k] >= 0 {
						play_slot(e, ti, int(k), l[pos:next], r[pos:next])
					}
				}
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
			finish_segment(e, ti, input + i64(from), l[from:pos], r[from:pos])
			wrote = true
		}
	}
	run.cursor += i64(n)
	return
}

// What follows the voices on an awake stretch of a track (`at`: the song
// sample of l[0]).
@(private = "file")
finish_segment :: proc(e: ^Engine, ti: int, at: i64, l, r: []f32) {
	s := e.song
	t := s.tracks[ti]
	run := &e.tracks[ti]
	n := len(l)
	for sc in s.sidechains[t.sidechains.first:base.span_end(t.sidechains)] {
		if rule := SIDECHAIN_TABLE[sc.mode]; rule != nil {
			rule(s, sc, at, l, r)
		}
	}
	if t.window.stop > t.window.start {
		apply_window(t.window, at, l, r)
	}
	if t.room != 0 && len(s.room) > 0 {
		make_room(s, t.room, at, l, r)
	}
	gain := base.db_to_gain(t.gain_db)
	pl, pr := song.PAN_LAW_TABLE[t.pan_law](t.pan)
	gl, gr := f32(gain * pl), f32(gain * pr)
	for i in 0 ..< n {
		l[i] *= gl
	}
	for i in 0 ..< n {
		r[i] *= gr
	}
	run_fx(e, run.chain, l, r)
	if run.sends.count == 0 {
		return
	}
	sc := track_scratch(e, ti)
	sl, sr := sc[2 * BLOCK:][:n], sc[3 * BLOCK:][:n]
	for snd in e.sends[run.sends.first:base.span_end(run.sends)] {
		for i in 0 ..< n {
			sl[i] = l[i] * snd.gain
		}
		for i in 0 ..< n {
			sr[i] = r[i] * snd.gain
		}
		run_fx(e, snd.chain, sl, sr)
		for i in 0 ..< n {
			l[i] += sl[i]
		}
		for i in 0 ..< n {
			r[i] += sr[i]
		}
	}
}

// A track's effects (its chain and its returns' copies) put at `at`.
@(private = "file")
reset_track_fx :: proc(e: ^Engine, ti: int, at: i64) {
	run := &e.tracks[ti]
	for f in e.fx[run.chain.first:base.span_end(run.chain)] {
		reset_fx(e, f, at)
	}
	for snd in e.sends[run.sends.first:base.span_end(run.sends)] {
		for f in e.fx[snd.chain.first:base.span_end(snd.chain)] {
			reset_fx(e, f, at)
		}
	}
}

// The track's window: silent outside it, its fades at its edges (onimite's
// track envelope: each fade at least 3 ms).
@(private = "file")
apply_window :: proc(w: song.Window, at: i64, l, r: []f32) {
	a := i64(math.round(w.start * RATE))
	b := i64(math.round(w.stop * RATE))
	length := b - a
	fi := max(i64(math.round(w.fade_in * RATE)), device.DECLICK)
	fo := max(i64(math.round(w.fade_out * RATE)), device.DECLICK)
	fade :: proc(k, n: i64, curve: device.Curve) -> f32 {
		if n <= 0 || k >= n {
			return 1
		}
		t := f32(max(k, 0)) / f32(n)
		return curve == .Equal_Power ? math.sin(t * math.PI / 2) : t
	}
	for i in 0 ..< len(l) {
		k := at + i64(i) - a
		g: f32 = 0
		if k >= 0 && k < length {
			g = fade(k, fi, w.curve) * fade(length - 1 - k, fo, w.curve)
		}
		l[i] *= g
		r[i] *= g
	}
}

@(private = "file")
run_fx :: proc(e: ^Engine, c: base.Span, l, r: []f32) {
	for f in e.fx[c.first:base.span_end(c)] {
		p := e.song.params[f.device]
		state := e.fx_bytes[f.state.first:base.span_end(f.state)]
		device.DEVICE_TABLE[e.song.devices[f.device]].effect(state, &p, l, r, nil, nil)
	}
}

// How each sidechain mode ducks a block (`at`: the song sample of l[0]).
SIDECHAIN_TABLE := [song.Sidechain_Mode]proc(s: ^song.Song, sc: song.Sidechain, at: i64, l, r: []f32) {
	.None  = nil,
	.Hits  = duck,
	.Spans = duck_spans,
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
		if s.tracks[n.track].part != sc.part || (sc.pad != .None && n.pad != sc.pad) || (sc.pitch >= 0 && math.abs(n.pitch - sc.pitch) > 0.01) {
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

// Dips the block by `db` inside the song's room spans, with 150 ms ramps.
@(private = "file")
make_room :: proc(s: ^song.Song, db: f64, at: i64, l, r: []f32) {
	RAMP :: 0.15
	low := f32(base.db_to_gain(db))
	for span in s.room {
		i0 := max(0, int(math.floor((span[0] - RAMP) * RATE)) - int(at))
		i1 := min(len(l), int(math.ceil((span[1] + RAMP) * RATE)) - int(at) + 1)
		for i in i0 ..< i1 {
			t := f64(at + i64(i)) / RATE
			depth := clamp(min(t - (span[0] - RAMP), (span[1] + RAMP) - t) / RAMP, 0, 1)
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
