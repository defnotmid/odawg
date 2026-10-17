package odawg_render

import "core:math"
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
// The song's master is left as the target sets it.
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
	s.master_gain_db, s.master = 0, {}
	before := measure(s, o, {})
	if math.is_inf(before.integrated) || before.integrated < -150 {
		return measure(s, opts, sink)
	}
	// the limiter at the ceiling, on the master
	p := device.params_from_kind(.Limiter)
	p[.Threshold] = f32(row.ceiling)
	append(&s.devices, device.Device_Kind.Limiter)
	append(&s.params, p)
	s.master = {i32(len(s.chain)), 1}
	append(&s.chain, i32(len(s.devices) - 1))
	gain := row.lufs - before.integrated
	for pass in 0 ..< 3 {
		s.master_gain_db = gain
		got := measure(s, o, {})
		miss := row.lufs - got.integrated
		if math.abs(miss) < 0.3 || pass == 2 {
			break
		}
		gain += miss
	}
	return measure(s, opts, sink)
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
