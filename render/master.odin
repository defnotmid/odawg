package odawg_render

import "core:math"
import "core:mem"
import "core:os"
import analyze "../analyze"
import base "../base"
import device "../device"
import song "../song"

// Delivery targets as rows: the loudness a finished mix is brought to and
// the true-peak ceiling the limiter holds.
Master :: enum u8 {
	None,
	Streaming,
	Podcast,
	Broadcast,
}

Master_Row :: struct {
	name:    string,
	lufs:    f64,
	ceiling: f64, // dBTP
}

MASTER_TABLE := [Master]Master_Row {
	.None      = {"none", 0, 0},
	.Streaming = {"streaming", -14, -1},
	.Podcast   = {"podcast", -16, -1},
	.Broadcast = {"broadcast", -23, -1}, // EBU R128
}

// The master a delivery target sets, in place of the song's (on): its gain
// and, `limit`, a true-peak limiter at `ceiling_db`. An export's option: the
// song is left as it is.
Mastering :: struct {
	on:         bool,
	gain_db:    f64,
	limit:      bool,
	ceiling_db: f64,
}

// A master as it runs over the mix in order: its gain, its chain, its
// lookahead, what it measured. Its rows are the song's (`song` set: read
// through, so a command changing the master's gain or an effect's value is
// what the next block runs) or its own (a target's: Mastering). An
// engine's master, and an export owner's.
Master_Run :: struct {
	song:      ^song.Song, // nil: its own rows
	devices:   []i32, // into song.devices (and params)
	own_kinds: []device.Device_Kind,
	own:       []device.Params,
	own_gain:  f64,
	states:    [][]u8,
	scratch:   ^device.Fx_Scratch,
	latency:   int,
	stats:     Master_Stats,
}

master_run_init :: proc(m: ^Master_Run, s: ^song.Song, mastering: Mastering, allocator := context.allocator) {
	context.allocator = allocator
	if mastering.on {
		m.own_gain = mastering.gain_db
		if mastering.limit {
			p := device.params_from_kind(.Limiter)
			p[.Threshold] = f32(mastering.ceiling_db)
			m.own_kinds = make([]device.Device_Kind, 1)
			m.own = make([]device.Params, 1)
			m.own_kinds[0], m.own[0] = .Limiter, p
		}
	} else {
		m.song = s
		m.devices = make([]i32, s.master.count)
		copy(m.devices, s.chain[s.master.first:base.span_end(s.master)])
	}
	m.scratch = new(device.Fx_Scratch)
	m.states = make([][]u8, master_run_rows(m))
	for i in 0 ..< len(m.states) {
		kind, p := master_run_row(m, i)
		row := device.DEVICE_TABLE[kind]
		m.states[i], _ = mem.make_aligned([]u8, (device.effect_size(kind, &p) + 15) &~ 15, 16)
		if row.effect_latency != nil {
			m.latency += row.effect_latency(&p)
		}
	}
}

master_run_destroy :: proc(m: ^Master_Run, allocator := context.allocator) {
	context.allocator = allocator
	for st in m.states {
		mem.free_bytes(st)
	}
	delete(m.states)
	free(m.scratch)
	delete(m.devices)
	delete(m.own_kinds)
	delete(m.own)
	m^ = {}
}

@(private = "file")
master_run_rows :: proc(m: ^Master_Run) -> int {
	return m.song != nil ? len(m.devices) : len(m.own_kinds)
}

// Row i: its kind and its values now.
@(private = "file")
master_run_row :: proc(m: ^Master_Run, i: int) -> (device.Device_Kind, device.Params) {
	if m.song != nil {
		d := m.devices[i]
		return m.song.devices[d], m.song.params[d]
	}
	return m.own_kinds[i], m.own[i]
}

@(private = "file")
master_run_gain :: proc(m: ^Master_Run) -> f64 {
	return m.song != nil ? m.song.master_gain_db : m.own_gain
}

// Whether it does anything to the mix.
master_run_active :: proc(m: ^Master_Run) -> bool {
	return master_run_rows(m) > 0 || master_run_gain(m) != 0
}

// Its chain put at song sample `at`, its measurements cleared.
master_run_reset :: proc(m: ^Master_Run, at: i64) {
	for i in 0 ..< len(m.states) {
		kind, p := master_run_row(m, i)
		device.effect_reset(kind, m.states[i], &p, at)
	}
	m.stats = {}
}

// A block of the mix through it: its gain, what it measures, its chain.
master_run_block :: proc(m: ^Master_Run, l, r: []f32) {
	g := f32(base.db_to_gain(master_run_gain(m)))
	peak: f32
	for i in 0 ..< len(l) {
		l[i] *= g
		r[i] *= g
		a := max(abs(l[i]), abs(r[i]))
		peak = max(peak, a)
		if a > 1 {
			m.stats.clipped_before += 1
		}
	}
	m.stats.peak_before = max(m.stats.peak_before, peak)
	if len(m.states) == 0 {
		return
	}
	for i in 0 ..< len(m.states) {
		kind, p := master_run_row(m, i)
		device.DEVICE_TABLE[kind].effect(m.states[i], &p, l, r, nil, nil, m.scratch)
	}
	after: f32
	for i in 0 ..< len(l) {
		after = max(after, abs(l[i]), abs(r[i]))
	}
	if peak > 0 && after < peak {
		m.stats.reduction_db = min(m.stats.reduction_db, f32(base.gain_to_db(f64(after / peak))))
	}
}

master_from_name :: proc(name: string) -> (Master, bool) {
	for row, m in MASTER_TABLE {
		if row.name == name {
			return m, true
		}
	}
	return .None, false
}

// Exports the song mastered to a target, streaming: a pass measures it (a
// meter, nothing kept), the master gets the gain that reaches the loudness
// and a true-peak limiter at the ceiling, and passes measure again (the
// limiter takes a little loudness) until within 0.3 LU, at most three; the
// last goes to the sink. Rendering again is cheap; holding the song is not.
// The target's master is the export's (Options.mastering): the song is left
// as it is.
master_export :: proc(s: ^song.Song, opts: Options, m: Master, sink: Sink) -> analyze.Loudness {
	measure :: proc(s: ^song.Song, opts: Options, also: Sink) -> analyze.Loudness {
		Measured :: struct {
			meter: analyze.Meter,
			also:  Sink,
		}
		x: Measured
		x.also = also
		analyze.meter_init(&x.meter, RATE, context.temp_allocator)
		export_song(s, opts, {&x, proc(data: rawptr, at: i64, l, r: []f32, stems: [][2][]f32) {
			x := (^Measured)(data)
			analyze.meter_push(&x.meter, l, r)
			if x.also.take != nil {
				x.also.take(x.also.data, at, l, r, stems)
			}
		}})
		return analyze.loudness_from_meter(&x.meter, context.temp_allocator)
	}
	if m == .None {
		return measure(s, opts, sink)
	}
	row := MASTER_TABLE[m]
	o := opts
	o.stems = false // measuring passes need the mix only
	o.mastering = {on = true} // the mix as it is, no master
	before := measure(s, o, {})
	if math.is_inf(before.integrated) || before.integrated < -150 {
		final := opts
		final.mastering = o.mastering
		return measure(s, final, sink)
	}
	// its gain, then the limiter at the ceiling
	o.mastering = {on = true, gain_db = row.lufs - before.integrated, limit = true, ceiling_db = row.ceiling}
	for pass in 0 ..< 3 {
		got := measure(s, o, {})
		miss := row.lufs - got.integrated
		if math.abs(miss) < 0.3 || pass == 2 {
			break
		}
		o.mastering.gain_db += miss
	}
	final := opts
	final.mastering = o.mastering
	return measure(s, final, sink)
}

// ---- WAV, written as it comes ------------------------------------------------------------

// A stereo WAV at RATE being written: 16-bit PCM (dithered with seeded
// triangular noise, carried across pieces) or 32-bit float; the sizes in its
// header are written when it closes.
Wav_Writer :: struct {
	file:   ^os.File,
	float:  bool,
	frames: i64,
	rng:    base.Rng,
	ok:     bool,
}

wav_open :: proc(w: ^Wav_Writer, path: string, float := false) -> bool {
	f, err := os.create(path)
	if err != nil {
		return false
	}
	w^ = {file = f, float = float, rng = base.rng_init(0x6f646177), ok = true}
	header: [44]u8
	wav_header(header[:], 0, float)
	_, werr := os.write(f, header[:])
	w.ok = werr == nil
	return w.ok
}

wav_push :: proc(w: ^Wav_Writer, l, r: []f32) {
	if !w.ok {
		return
	}
	n := min(len(l), len(r))
	bytes := make([]u8, n * (w.float ? 8 : 4), context.temp_allocator)
	at := 0
	for i in 0 ..< n {
		if w.float {
			put32(bytes, at, transmute(u32)l[i])
			put32(bytes, at + 4, transmute(u32)r[i])
			at += 8
			continue
		}
		for v in ([2]f32{l[i], r[i]}) {
			dither := (base.rng_unit(&w.rng) - base.rng_unit(&w.rng)) / 32768
			put16(bytes, at, transmute(u16)i16(clamp(math.round((f64(v) + dither) * 32767), -32768, 32767)))
			at += 2
		}
	}
	_, err := os.write(w.file, bytes)
	w.ok = err == nil
	w.frames += i64(n)
}

wav_close :: proc(w: ^Wav_Writer) -> bool {
	if w.file == nil {
		return false
	}
	header: [44]u8
	wav_header(header[:], w.frames, w.float)
	_, err := os.write_at(w.file, header[:], 0)
	os.close(w.file)
	w.file = nil
	return w.ok && err == nil
}

@(private = "file")
put32 :: proc(b: []u8, at: int, v: u32) {b[at], b[at + 1], b[at + 2], b[at + 3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)}

@(private = "file")
put16 :: proc(b: []u8, at: int, v: u16) {b[at], b[at + 1] = u8(v), u8(v >> 8)}

@(private = "file")
wav_header :: proc(h: []u8, frames: i64, float: bool) {
	bits := float ? 32 : 16
	data := u32(frames * i64(2 * bits / 8))
	copy(h[0:], "RIFF")
	put32(h, 4, 36 + data)
	copy(h[8:], "WAVEfmt ")
	put32(h, 16, 16)
	put16(h, 20, float ? 3 : 1)
	put16(h, 22, 2)
	put32(h, 24, RATE)
	put32(h, 28, u32(RATE * 2 * bits / 8))
	put16(h, 32, u16(2 * bits / 8))
	put16(h, 34, u16(bits))
	copy(h[36:], "data")
	put32(h, 40, data)
}

// The peak of a buffer pair, linear.
peak_from_samples :: proc(l, r: []f32) -> f32 {
	p: f32
	for v in l {
		p = max(p, abs(v))
	}
	for v in r {
		p = max(p, abs(v))
	}
	return p
}
