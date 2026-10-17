package odawg_analyze

import "core:math"
import "core:slice"

// Onsets: where sounds start in a stereo buffer (hits, notes, words), and
// the steady beat they imply, so a host that can't listen can place cues on
// the music. Spectral flux on log magnitudes (1024-sample frames every 256
// samples, about 5 ms at 48 kHz), adaptive-threshold peak picking, then
// each onset moved to the attack in the time domain (1 ms steps). The beat
// is the autocorrelation peak of the flux between 60 and 200 BPM (favouring
// 120), its phase the one the strongest onsets agree on. Ported from
// onimite's audio_onsets.odin.

Onset :: struct {
	time:     f32, // seconds from the buffer's start
	// 0..1: the rise in level at the attack (RMS over 20 ms after it minus
	// before it), relative to the largest rise.
	strength: f32,
}

Onsets :: struct {
	onsets: [dynamic]Onset,
	bpm:    f32, // 0: no steady beat
	offset: f32, // where the first beat falls (seconds, 0 <= offset < 60 / bpm)
}

onsets_destroy :: proc(o: ^Onsets) {
	delete(o.onsets)
	o^ = {}
}

ONSET_SIZE :: 1024
ONSET_HOP :: 256

// The onsets of a buffer at `rate`; the list in `allocator`.
onsets_from_samples :: proc(l, r: []f32, rate: int, allocator := context.allocator) -> (o: Onsets) {
	o.onsets = make([dynamic]Onset, allocator)
	n := min(len(l), len(r))
	if n < ONSET_SIZE {
		return
	}
	frames := (n - ONSET_SIZE) / ONSET_HOP + 1
	env := make([]f32, frames, context.temp_allocator)
	flux_from_samples(l, r, env)
	peak := slice.max(env)
	if peak <= 0 {
		return
	}
	// A peak: the largest within ±3 frames (16 ms), above the local mean
	// (±16 frames) by a margin, and not a ripple of a much louder one.
	WIDE :: 16
	sum: f32
	for i in 0 ..< min(WIDE, frames) {
		sum += env[i]
	}
	last := -100
	for i in 0 ..< frames {
		if i + WIDE < frames {sum += env[i + WIDE]}
		if i - WIDE - 1 >= 0 {sum -= env[i - WIDE - 1]}
		lo, hi := max(i - WIDE, 0), min(i + WIDE, frames - 1)
		mean := sum / f32(hi - lo + 1)
		v := env[i]
		if v < 0.06 * peak || v < mean * 1.4 + 0.02 * peak {
			continue
		}
		is_max := true
		for k in max(i - 3, 0) ..= min(i + 3, frames - 1) {
			if env[k] > v || (env[k] == v && k < i) {
				is_max = false
				break
			}
		}
		if !is_max || i - last < 6 { // 30 ms apart at least
			continue
		}
		last = i
		at := attack_from_samples(l, r, rate, i)
		append(&o.onsets, Onset{f32(at) / f32(rate), rise_from_samples(l, r, rate, at)})
	}
	strongest: f32
	for x in o.onsets {
		strongest = max(strongest, x.strength)
	}
	// Relative strengths; a rise under 2% of the largest is no onset (a
	// spectral change inside a held sound).
	kept := 0
	for x in o.onsets {
		v := x.strength / strongest if strongest > 0 else 0
		if v >= 0.02 {
			o.onsets[kept] = {x.time, v}
			kept += 1
		}
	}
	resize(&o.onsets, kept)
	o.bpm, o.offset = beat_from_flux(env, o.onsets[:], f32(rate) / ONSET_HOP)
	return
}

// Positive log-magnitude change per frame, summed over frequencies. Before
// the samples is silence: a sound from the first sample is an onset there.
@(private = "file")
flux_from_samples :: proc(l, r: []f32, env: []f32) {
	window: [ONSET_SIZE]f32
	for k in 0 ..< ONSET_SIZE {
		window[k] = WINDOW_TABLE[.Hann](k, ONSET_SIZE)
	}
	prev, cur: [ONSET_SIZE / 2]f32
	re, im: [ONSET_SIZE]f32
	for i in 0 ..< len(env) {
		at := i * ONSET_HOP
		for k in 0 ..< ONSET_SIZE {
			re[k] = (l[at + k] + r[at + k]) * 0.5 * window[k]
			im[k] = 0
		}
		fft(re[:], im[:])
		flux: f32
		for k in 1 ..< ONSET_SIZE / 2 {
			mag := math.sqrt(re[k] * re[k] + im[k] * im[k])
			cur[k] = math.ln(1 + 100 * mag)
			flux += max(cur[k] - prev[k], 0)
		}
		env[i] = flux
		prev = cur
	}
}

// The attack (a sample) of the onset flux frame `i` found: in 1 ms blocks
// around the frame, the block after which the energy rises the most.
@(private = "file")
attack_from_samples :: proc(l, r: []f32, rate, i: int) -> int {
	block := max(rate / 1000, 1)
	n := min(len(l), len(r))
	from := max(i * ONSET_HOP, 0)
	to := min(i * ONSET_HOP + ONSET_SIZE, n)
	blocks := (to - from) / block
	if blocks < 3 {
		return from + ONSET_SIZE / 2
	}
	energy :: proc(l, r: []f32, a, b: int) -> f32 {
		e: f32
		for s in a ..< b {
			e += l[s] * l[s] + r[s] * r[s]
		}
		return e
	}
	best, best_rise := from + ONSET_SIZE / 2, f32(0)
	prev := energy(l, r, max(from - 4 * block, 0), from) / 4 // 4 ms before
	for b in 0 ..< blocks {
		a := from + b * block
		e := energy(l, r, a, a + block)
		rise := math.ln((e + 1e-9) / (prev + 1e-9))
		if rise > best_rise {
			best, best_rise = a, rise
		}
		prev = prev * 0.5 + e * 0.5
	}
	return best
}

// RMS over the 20 ms after sample `at` minus over the 20 ms before (0 for
// a fall).
@(private = "file")
rise_from_samples :: proc(l, r: []f32, rate, at: int) -> f32 {
	w := max(rate / 50, 1)
	n := min(len(l), len(r))
	rms :: proc(l, r: []f32, a, b: int) -> f32 {
		if b <= a {
			return 0
		}
		e: f32
		for k in a ..< b {
			e += l[k] * l[k] + r[k] * r[k]
		}
		return math.sqrt(e / f32(2 * (b - a)))
	}
	return max(rms(l, r, at, min(at + w, n)) - rms(l, r, max(at - w, 0), at), 0)
}

// The steady beat of the flux envelope (`env_rate` frames a second): bpm
// (0 for none) and the phase of the first beat, snapped to the strongest
// onset near the grid.
@(private = "file")
beat_from_flux :: proc(env: []f32, onsets: []Onset, env_rate: f32) -> (bpm, offset: f32) {
	n := len(env)
	lo := int(math.round(60 * env_rate / 200)) // 200 BPM, in envelope frames
	hi := int(math.round(60 * env_rate / 60)) // 60 BPM
	if n < hi * 4 || len(onsets) < 8 {
		return 0, 0
	}
	mean: f32
	for v in env {
		mean += v
	}
	mean /= f32(n)
	e := make([]f32, n, context.temp_allocator)
	for v, i in env {
		e[i] = max(v - mean, 0)
	}
	ac := make([]f32, hi + 2, context.temp_allocator)
	for lag in 0 ..< len(ac) {
		s: f32
		for i in 0 ..< n - lag {
			s += e[i] * e[i + lag]
		}
		ac[lag] = s
	}
	if ac[0] <= 0 {
		return 0, 0
	}
	best, best_score := 0, f32(0)
	for lag in lo ..= hi {
		if ac[lag] < ac[lag - 1] || ac[lag] < ac[lag + 1] {
			continue
		}
		b := 60 * env_rate / f32(lag)
		octaves := math.log2(b / 120)
		score := ac[lag] * math.exp(-0.5 * octaves * octaves)
		if score > best_score {
			best, best_score = lag, score
		}
	}
	if best == 0 || ac[best] < 0.1 * ac[0] {
		return 0, 0
	}
	// Parabolic peak for a fractional lag.
	y0, y1, y2 := ac[best - 1], ac[best], ac[best + 1]
	shift: f32
	if d := y0 - 2 * y1 + y2; d != 0 {
		shift = clamp(0.5 * (y0 - y2) / d, -0.5, 0.5)
	}
	lag := f32(best) + shift
	bpm = 60 * env_rate / lag
	period := lag / env_rate

	// The phase whose grid collects the most onset strength (10 ms steps),
	// then the strongest onset within 30 ms of it.
	PHASES :: 100
	best_phase, best_sum := f32(0), f32(-1)
	for p in 0 ..< PHASES {
		phase := period * f32(p) / PHASES
		s: f32
		for o in onsets {
			d := math.mod(o.time - phase + period * 1000, period)
			d = min(d, period - d)
			if d < 0.02 {
				s += o.strength
			}
		}
		if s > best_sum {
			best_phase, best_sum = phase, s
		}
	}
	offset = best_phase
	strongest := f32(0)
	for o in onsets {
		d := math.mod(o.time - best_phase + period * 1000, period)
		if (d < 0.03 || period - d < 0.03) && o.strength > strongest {
			strongest = o.strength
			offset = math.mod(o.time, period)
		}
	}
	return
}
