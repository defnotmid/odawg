package odawg_render

import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import wav "deps:odecs/audio/wav"
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
// lookahead, what it measured. Its rows are its own: the song's master
// copied when it starts (a command reaches it through engine_sync), or a
// target's (Mastering). An engine's master, and an export owner's.
Master_Run :: struct {
	songs:     bool, // its rows are the song's (else a target's)
	own_kinds: []device.Device_Kind,
	own:       []device.Params,
	own_gain:  f64,
	gain_to:   f64, // an edit's: the next block ramps there
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
		m.songs = true
		m.own_gain = s.master_gain_db
		m.own_kinds = make([]device.Device_Kind, s.master.count)
		m.own = make([]device.Params, s.master.count)
		for d, i in s.chain[s.master.first:base.span_end(s.master)] {
			m.own_kinds[i], m.own[i] = s.devices[d], s.params[d]
		}
	}
	m.gain_to = m.own_gain
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
	delete(m.own_kinds)
	delete(m.own)
	m^ = {}
}

@(private = "file")
master_run_rows :: proc(m: ^Master_Run) -> int {
	return len(m.own_kinds)
}

// Row i: its kind and its values now.
@(private = "file")
master_run_row :: proc(m: ^Master_Run, i: int) -> (device.Device_Kind, device.Params) {
	return m.own_kinds[i], m.own[i]
}

@(private = "file")
master_run_gain :: proc(m: ^Master_Run) -> f64 {
	return m.own_gain
}

// Whether it does anything to the mix.
master_run_active :: proc(m: ^Master_Run) -> bool {
	return master_run_rows(m) > 0 || master_run_gain(m) != 0 || m.gain_to != m.own_gain
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
	// an edit's gain: ramped to over this block
	to := f32(base.db_to_gain(m.gain_to))
	ramp := m.gain_to != m.own_gain
	m.own_gain = m.gain_to
	if ramp {
		for i in 0 ..< len(l) {
			x := g + (to - g) * f32(i + 1) / f32(len(l))
			l[i] *= x
			r[i] *= x
		}
	} else {
		for i in 0 ..< len(l) {
			l[i] *= g
			r[i] *= g
		}
	}
	peak: f32
	for i in 0 ..< len(l) {
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
// triangular noise, carried across pieces) or 32-bit float. The header is
// odecs's, written again with the frame count when the file closes.
Wav_Writer :: struct {
	file:   ^os.File,
	format: wav.Write_Format,
	frames: i64,
	rng:    base.Rng,
	ok:     bool,
}

wav_open :: proc(w: ^Wav_Writer, path: string, float := false) -> bool {
	f, err := os.create(path)
	if err != nil {
		return false
	}
	w^ = {file = f, format = float ? .F32 : .S16, rng = base.rng_init(0x6f646177), ok = true}
	header: [wav.HEADER_SIZE]u8
	w.ok = wav.header_into(header[:], 0, RATE, 2, w.format) == .None
	_, werr := os.write(f, header[:])
	w.ok &= werr == nil
	return w.ok
}

wav_push :: proc(w: ^Wav_Writer, l, r: []f32) {
	if !w.ok {
		return
	}
	n := min(len(l), len(r))
	bytes: []u8
	switch w.format {
	case .F32:
		out := make([]f32, 2 * n, context.temp_allocator)
		for i in 0 ..< n {
			out[2 * i], out[2 * i + 1] = l[i], r[i]
		}
		bytes = slice.to_bytes(out)
	case .S16:
		out := make([]i16, 2 * n, context.temp_allocator)
		for i in 0 ..< n {
			for v, c in ([2]f32{l[i], r[i]}) {
				dither := (base.rng_unit(&w.rng) - base.rng_unit(&w.rng)) / 32768
				out[2 * i + c] = i16(clamp(math.round((f64(v) + dither) * 32767), -32768, 32767))
			}
		}
		bytes = slice.to_bytes(out)
	}
	_, err := os.write(w.file, bytes)
	w.ok = err == nil
	w.frames += i64(n)
}

wav_close :: proc(w: ^Wav_Writer) -> bool {
	if w.file == nil {
		return false
	}
	header: [wav.HEADER_SIZE]u8
	sized := wav.header_into(header[:], int(w.frames), RATE, 2, w.format) == .None
	err: os.Error
	if sized {
		_, err = os.write_at(w.file, header[:], 0)
	}
	os.close(w.file)
	w.file = nil
	return w.ok && sized && err == nil
}

// The peak of a buffer pair, linear.
//
// Eight running maxima side by side, then the largest of them: one alone
// waits on itself every sample (a float max won't be reordered for it), 5x
// slower on a render's stems. A max is exact, so the peak is the same.
peak_from_samples :: proc(l, r: []f32) -> f32 #no_bounds_check {
	LANES :: 8
	p: [LANES]f32
	for x in ([2][]f32{l, r}) {
		i := 0
		for ; i + LANES <= len(x); i += LANES {
			for k in 0 ..< LANES {
				p[k] = max(p[k], abs(x[i + k]))
			}
		}
		for ; i < len(x); i += 1 {
			p[0] = max(p[0], abs(x[i]))
		}
	}
	peak: f32
	for v in p {
		peak = max(peak, v)
	}
	return peak
}
