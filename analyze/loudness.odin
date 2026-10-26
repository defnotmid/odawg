package odawg_analyze

import "core:math"
import "core:slice"

// Loudness and level measurements of a stereo buffer, as onimite's
// `audio analyze` (and fframes') reports them: ITU-R BS.1770-4 integrated
// loudness, EBU Tech 3342 loudness range, true peak and sample peak. Ported
// from onimite/audio_analysis.odin, so the two agree to the digit on the
// same samples; that code was checked against fframes and reference values.

// What `loudness_from_samples` reports.
Loudness :: struct {
	integrated:  f64, // LUFS (EBU R128 / ITU-R BS.1770-4, gated); -inf for silence
	range:       f64, // LRA in LU
	true_peak:   f64, // dBTP (4x oversampled)
	sample_peak: f64, // dBFS
	momentary:   []f32, // LUFS every 100 ms (400 ms windows)
	short_term:  []f32, // LUFS every 100 ms (3 s windows; the first 29 shorter)
}

loudness_destroy :: proc(l: ^Loudness, allocator := context.allocator) {
	delete(l.momentary, allocator)
	delete(l.short_term, allocator)
	l^ = {}
}

// Measures a stereo buffer at `rate`: the meter (meter.odin) fed the whole
// buffer at once. The K-weighted mean square is taken per 100 ms step (a
// trailing partial step is left out), and the blocks are built from the
// steps: 400 ms blocks every 100 ms for the integrated loudness and the
// momentary curve (its first value is the block ending at 0.4 s), 3 s
// blocks every 100 ms for the loudness range, which stays 0 until the
// buffer holds one full 3 s block. The curves are allocated with
// `allocator`; silence reads about -200 LUFS there, -inf as `integrated`.
loudness_from_samples :: proc(l, r: []f32, rate: int, allocator := context.allocator) -> (result: Loudness) {
	m: Meter
	meter_init(&m, rate)
	defer meter_destroy(&m)
	n := min(len(l), len(r))
	meter_push(&m, l[:n], r[:n])
	return loudness_from_meter(&m, allocator)
}

// What a meter has measured so far.
loudness_from_meter :: proc(m: ^Meter, allocator := context.allocator) -> (result: Loudness) {
	result.integrated = math.inf_f64(-1)
	result.true_peak = 20 * math.log10(max(f64(m.true_peak), 1e-9))
	result.sample_peak = 20 * math.log10(max(f64(m.sample_peak), 1e-9))
	energy := m.energy[:]
	steps := len(energy)
	if steps == 0 {
		result.momentary = make([]f32, 0, allocator)
		result.short_term = make([]f32, 0, allocator)
		return
	}
	// Integrated: 400 ms blocks every 100 ms, gated at -70 LUFS absolute and
	// 10 LU below the ungated mean.
	blocks := make([dynamic]Loudness_Block)
	defer delete(blocks)
	momentary := make([dynamic]f32, allocator)
	for s := 0; s + 4 <= steps; s += 1 {
		b := block_loudness(energy, s, 4)
		append(&blocks, b)
		append(&momentary, f32(b.lufs))
	}
	result.momentary = momentary[:]
	result.integrated = gated_loudness(blocks[:])
	short_term := make([]f32, steps, allocator)
	for s in 0 ..< steps {
		count := min(30, s + 1)
		short_term[s] = f32(block_loudness(energy, s + 1 - count, count).lufs)
	}
	result.short_term = short_term

	// Loudness range: 3 s blocks, -70 absolute and -20 relative gates,
	// P95 - P10.
	abs_gated := make([dynamic]f64)
	defer delete(abs_gated)
	sum: f64
	for s := 29; s < steps; s += 1 {
		b := block_loudness(energy, s - 29, 30)
		if b.lufs > -70 {
			append(&abs_gated, b.lufs)
			sum += b.ms
		}
	}
	if len(abs_gated) > 0 {
		rel := -0.691 + 10 * math.log10(sum / f64(len(abs_gated))) - 20
		kept := make([dynamic]f64)
		defer delete(kept)
		for v in abs_gated {
			if v > rel {
				append(&kept, v)
			}
		}
		if len(kept) > 1 {
			slice.sort(kept[:])
			result.range = percentile(kept[:], 0.95) - percentile(kept[:], 0.10)
		}
	}
	return
}

// The true peak of a stereo buffer in dBTP: the peak of the signal
// reconstructed at 4x the sample rate (windowed-sinc interpolation between
// samples). Silence reads -180.
true_peak_from_samples :: proc(l, r: []f32) -> f64 {
	n := min(len(l), len(r))
	peak := max(true_peak(l[:n]), true_peak(r[:n]))
	return 20 * math.log10(max(f64(peak), 1e-9))
}

// The integrated loudness (BS.1770's gates) of steps [first, last) of a
// stream's K-weighted energy (100 ms each, a Steps' or a Meter's): its
// 400 ms blocks every 100 ms inside the span. -inf where no block of it is
// above -70 LUFS (silence, or a span under 400 ms).
loudness_of_span :: proc(energy: []f64, first, last: int) -> f64 {
	first, last := max(first, 0), min(last, len(energy))
	blocks := make([]Loudness_Block, max(last - first - 3, 0), context.temp_allocator)
	for &b, k in blocks {
		b = block_loudness(energy, first + k, 4)
	}
	return gated_loudness(blocks)
}

// The integrated loudness of several spans of steps taken as one (each
// [first, last)): their blocks gated together, as loudness_of_span gates
// one span's.
loudness_of_spans :: proc(energy: []f64, spans: [][2]int) -> f64 {
	count := 0
	for sp in spans {
		count += max(min(sp[1], len(energy)) - max(sp[0], 0) - 3, 0)
	}
	blocks := make([]Loudness_Block, count, context.temp_allocator)
	at := 0
	for sp in spans {
		first, last := max(sp[0], 0), min(sp[1], len(energy))
		for s := first; s + 4 <= last; s += 1 {
			blocks[at] = block_loudness(energy, s, 4)
			at += 1
		}
	}
	return gated_loudness(blocks)
}

// A block's mean square and its loudness.
@(private = "file")
Loudness_Block :: struct {
	ms, lufs: f64,
}

@(private = "file")
block_loudness :: proc(energy: []f64, first, count: int) -> Loudness_Block {
	sum: f64
	for e in energy[first:][:count] {
		sum += e
	}
	ms := sum / f64(count)
	return {ms, -0.691 + 10 * math.log10(max(ms, 1e-20))}
}

@(private = "file")
percentile :: proc(v: []f64, q: f64) -> f64 {
	return v[clamp(int(math.round(q * f64(len(v) - 1))), 0, len(v) - 1)]
}

// Two gates: blocks under -70 LUFS are left out, then those more than 10 LU
// below the mean of the rest.
@(private = "file")
gated_loudness :: proc(blocks: []Loudness_Block) -> f64 {
	sum: f64
	count := 0
	for b in blocks {
		if b.lufs > -70 {
			sum += b.ms
			count += 1
		}
	}
	if count == 0 {
		return math.inf_f64(-1)
	}
	rel := -0.691 + 10 * math.log10(sum / f64(count)) - 10
	sum, count = 0, 0
	for b in blocks {
		if b.lufs > -70 && b.lufs > rel {
			sum += b.ms
			count += 1
		}
	}
	if count == 0 {
		return math.inf_f64(-1)
	}
	return -0.691 + 10 * math.log10(sum / f64(count))
}

K_Biquad :: struct {
	b0, b1, b2, a1, a2: f64,
}

// BS.1770's K-weighting filters at `rate`: the published 48 kHz
// coefficients (onimite's), or at other rates the same analog prototypes
// through the bilinear transform (libebur128's derivation).
k_coefficients :: proc(rate: int) -> (shelf, hp: K_Biquad) {
	if rate == 48000 {
		return {1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585},
			{1, -2, 1, -1.99004745483398, 0.99007225036621}
	}
	fs := f64(rate)
	{
		f0 := 1681.974450955533
		g := 3.999843853973347
		q := 0.7071752369554196
		k := math.tan(math.PI * f0 / fs)
		vh := math.pow(10, g / 20)
		vb := math.pow(vh, 0.4996667741545416)
		a0 := 1 + k / q + k * k
		shelf = {(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0}
	}
	{
		f0 := 38.13547087602444
		q := 0.5003270373238773
		k := math.tan(math.PI * f0 / fs)
		a0 := 1 + k / q + k * k
		hp = {1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0}
	}
	return
}


// Peak of one channel reconstructed at 4x the sample rate: Lanczos (a = 8)
// interpolation at the three phases between samples, skipped within 8
// samples of the ends.
@(private = "file")
true_peak :: proc(x: []f32) -> f32 {
	TAPS :: TRUE_PEAK_TAPS
	n := len(x)
	peak: f32
	for i in 0 ..< n {
		peak = max(peak, abs(x[i]))
		if i + TAPS >= n || i < TAPS - 1 {
			continue
		}
		win := x[i - TAPS + 1:][:2 * TAPS]
		for ph in 0 ..< 3 {
			sum: f32
			for k in 0 ..< 2 * TAPS {
				sum += win[k] * TRUE_PEAK_KERNEL[ph][k]
			}
			peak = max(peak, abs(sum))
		}
	}
	return peak
}

lanczos :: proc "contextless" (x: f64, a: f64) -> f64 {
	if x == 0 {
		return 1
	}
	if abs(x) >= a {
		return 0
	}
	px := math.PI * x
	return a * math.sin(px) * math.sin(px / a) / (px * px)
}
