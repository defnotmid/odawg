package odawg_dsp

import "core:math"

// Tone's envelope. The attack ramps linearly to 1 (or, `exponential_attack`,
// approaches it as MembraneSynth's does); the decay and the release approach
// their targets as Tone's exponentialApproachValueAtTime does: a time
// constant of ln(time + 1) / ln(200) for the first 90% of the time, then a
// straight line onto the target, so each stage ends exactly at its time. A
// release starts from wherever the level is (mid-attack too).

Adsr_Stage :: enum u8 {
	Idle,
	Delay, // silent until it starts (SFZ's delay)
	Attack,
	Hold, // at the top (SFZ's hold)
	Decay,
	Sustain,
	Release,
}

Adsr :: struct {
	attack, decay, sustain, release: f32,
	delay, hold:                     f32, // seconds (0: none: Tone's ADSR)
	start:                           f32, // the level the attack rises from
	exponential_attack:              bool,
	stage:                           Adsr_Stage,
	samples:                         int, // into the stage
	from:                            f32, // the level the stage started at
	value:                           f32,
	// the stage's approach, set as it starts (stage_set): 1 / its time
	// constant (samples), its level at 90% of its time, its length (samples)
	inv_tc:                          f32,
	v90:                             f32,
	length:                          f64,
}

// Starts an approach from e.from to `target` over `ramp` seconds: its time
// constant and its 90% point once, not per sample.
@(private = "file")
stage_set :: proc "contextless" (e: ^Adsr, ramp: f32, target: f32) {
	r := f64(ramp)
	e.length = r * RATE
	if r <= 0 {
		return
	}
	tc := math.ln(r + 1) / math.ln(f64(200))
	e.inv_tc = f32(1 / (tc * RATE))
	e.v90 = f32(f64(target) + f64(e.from - target) * math.exp(-0.9 * r / tc))
}

// The stage's approach to `target` at its sample k: as approach, from what
// stage_set kept.
@(private = "file")
stage_value :: #force_inline proc "contextless" (e: ^Adsr, target: f32, k: int) -> (v: f32, done: bool) {
	x := f64(k)
	if x >= e.length {
		return target, true
	}
	if x < 0.9 * e.length {
		return target + (e.from - target) * exp_decay(-f32(k) * e.inv_tc), false
	}
	return f32(f64(e.v90) + (f64(target) - f64(e.v90)) * (x - 0.9 * e.length) / (0.1 * e.length)), false
}


// Tone's exponentialApproachValueAtTime: `t` seconds into a `ramp` from
// `from` to `target`; done when the ramp is over.
approach :: #force_inline proc "contextless" (from, target: f32, ramp, t: f64) -> (v: f32, done: bool) {
	if t >= ramp {
		return target, true
	}
	tc := math.ln(ramp + 1) / math.ln(f64(200))
	if t < 0.9 * ramp {
		return target + (from - target) * f32(math.exp(-t / tc)), false
	}
	v90 := f64(target) + f64(from - target) * math.exp(-0.9 * ramp / tc)
	return f32(v90 + (f64(target) - v90) * (t - 0.9 * ramp) / (0.1 * ramp)), false
}

// Fills `out` with the envelope's levels; the gate closes (the release
// starts) at sample `release_at` of this slice (negative or past the end: not
// in it). Each stage runs as a span up to the sample it changes on (its
// samples a function of their count alone: adsr_span), that sample as
// adsr_step: the same samples as stepping every one.
adsr_run :: proc "contextless" (e: ^Adsr, out: []f32, release_at: int) {
	adsr_begin(e)
	n := len(out)
	for i := 0; i < n; {
		if i == release_at {
			adsr_release(e)
		}
		end := release_at > i && release_at < n ? release_at : n
		m := adsr_span(e, out[i:end])
		i += m
		if m == 0 {
			out[i] = adsr_step(e)
			i += 1
		}
	}
}

// What adsr_run does before its first sample, and as the gate closes.
adsr_begin :: proc "contextless" (e: ^Adsr) {
	if e.samples == 0 && e.stage == .Attack && e.exponential_attack && e.length == 0 {
		stage_set(e, e.attack, 1)
	}
}

adsr_release :: proc "contextless" (e: ^Adsr) {
	if e.stage != .Idle {
		e.stage, e.samples, e.from = .Release, 0, e.value
		stage_set(e, e.release, 0)
	}
}

// The first count k (samples into a stage) with f64(k) >= x: k against a
// fixed f64 compares as against its ceiling.
@(private = "file")
first_reaching :: #force_inline proc "contextless" (x: f64) -> int {
	return int(math.ceil(clamp(x, 0, 1e15)))
}

// The leading samples of `out` before the stage changes, each from its
// count alone as adsr_step gives it (a loop with no branch); how many.
@(private = "file")
adsr_span :: proc "contextless" (e: ^Adsr, out: []f32) -> int #no_bounds_check {
	k0, n := e.samples, len(out)
	span :: #force_inline proc "contextless" (k0, n, end: int) -> int {return clamp(end - k0, 0, n)}
	fill :: #force_inline proc "contextless" (out: []f32, v: f32) {
		for i in 0 ..< len(out) {
			out[i] = v
		}
	}
	m: int
	switch e.stage {
	case .Idle:
		m = n
		fill(out, 0)
	case .Sustain:
		m = n
		fill(out, e.sustain)
	case .Delay:
		m = span(k0, n, first_reaching(f64(e.delay) * RATE))
		fill(out[:m], 0)
	case .Hold:
		m = span(k0, n, first_reaching(f64(e.hold) * RATE))
		fill(out[:m], 1)
	case .Attack:
		if e.exponential_attack {
			m = approach_span(e, 1, out)
			break
		}
		// f64(k) / RATE rises with k: the first k it reaches the attack at,
		// from its estimate
		a := f64(e.attack)
		end := first_reaching(a * RATE)
		for guard := 0; guard < 4 && end > 0 && f64(end - 1) / RATE >= a; guard += 1 {
			end -= 1
		}
		for guard := 0; guard < 4 && f64(end) / RATE < a; guard += 1 {
			end += 1
		}
		if f64(end) / RATE < a {
			break // a whole span can't be told: step it
		}
		m = span(k0, n, end)
		from := e.from
		for i in 0 ..< m {
			out[i] = from + (1 - from) * f32(f64(k0 + i) / RATE / a)
		}
	case .Decay:
		m = approach_span(e, e.sustain, out)
	case .Release:
		m = approach_span(e, 0, out)
	}
	if m > 0 {
		e.value = out[m - 1]
		e.samples += m
	}
	return m
}

// stage_value's samples up to its end: the approach to 90% of its time,
// then the line.
@(private = "file")
approach_span :: #force_inline proc "contextless" (e: ^Adsr, target: f32, out: []f32) -> int #no_bounds_check {
	k0 := e.samples
	m := clamp(first_reaching(e.length) - k0, 0, len(out))
	curve := clamp(first_reaching(0.9 * e.length) - k0, 0, m)
	from, inv_tc := e.from, e.inv_tc
	for i in 0 ..< curve {
		out[i] = target + (from - target) * exp_decay(-f32(k0 + i) * inv_tc)
	}
	v90, length := f64(e.v90), e.length
	for i in curve ..< m {
		out[i] = f32(v90 + (f64(target) - v90) * (f64(k0 + i) - 0.9 * length) / (0.1 * length))
	}
	return m
}

// One sample of the envelope (the gate aside): its stage's level at its
// count, the next stage where it ends there.
adsr_step :: proc "contextless" (e: ^Adsr) -> f32 {
	done: bool
	switch e.stage {
	case .Idle:
		e.value = 0
	case .Delay:
		e.value = 0
		if f64(e.samples) >= f64(e.delay) * RATE {
			e.stage, e.samples, e.from, e.length = .Attack, 0, e.start, 0
			if e.exponential_attack {
				stage_set(e, e.attack, 1)
			}
			e.value = e.start
		}
	case .Attack:
		a := f64(e.attack)
		t := f64(e.samples) / RATE
		if e.exponential_attack {
			e.value, done = stage_value(e, 1, e.samples)
		} else if t >= a {
			e.value, done = 1, true
		} else {
			e.value = e.from + (1 - e.from) * f32(t / a)
		}
		if done {
			if e.hold > 0 {
				e.stage, e.samples = .Hold, 0
			} else {
				e.stage, e.samples, e.from = .Decay, 0, 1
				stage_set(e, e.decay, e.sustain)
			}
		}
	case .Hold:
		e.value = 1
		if f64(e.samples) >= f64(e.hold) * RATE {
			e.stage, e.samples, e.from = .Decay, 0, 1
			stage_set(e, e.decay, e.sustain)
		}
	case .Decay:
		e.value, done = stage_value(e, e.sustain, e.samples)
		if done {
			e.stage = .Sustain
		}
	case .Sustain:
		e.value = e.sustain
	case .Release:
		e.value, done = stage_value(e, 0, e.samples)
		if done {
			e.stage, e.value = .Idle, 0
		}
	}
	e.samples += 1
	return e.value
}

// A value gliding to its target with a one-pole lag (`time` the time
// constant), so a value set once per block or event doesn't click.
Smoother :: struct {
	value, target, k: f32,
}

smoother_init :: proc "contextless" (value: f32, time: f32) -> Smoother {
	return {value, value, time > 0 ? f32(1 - math.exp(-1 / (f64(time) * RATE))) : 1}
}

// Fills `out` with the glide toward the current target.
smoother_run :: proc "contextless" (s: ^Smoother, out: []f32) {
	v, target, k := s.value, s.target, s.k
	for i in 0 ..< len(out) {
		v += k * (target - v)
		out[i] = v
	}
	s.value = v
}
