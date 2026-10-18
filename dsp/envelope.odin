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
	Attack,
	Decay,
	Sustain,
	Release,
}

Adsr :: struct {
	attack, decay, sustain, release: f32,
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
// in it).
adsr_run :: proc "contextless" (e: ^Adsr, out: []f32, release_at: int) {
	if e.samples == 0 && e.stage == .Attack && e.exponential_attack && e.length == 0 {
		stage_set(e, e.attack, 1)
	}
	for i in 0 ..< len(out) {
		if i == release_at && e.stage != .Idle {
			e.stage, e.samples, e.from = .Release, 0, e.value
			stage_set(e, e.release, 0)
		}
		done: bool
		switch e.stage {
		case .Idle:
			e.value = 0
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
		out[i] = e.value
	}
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
