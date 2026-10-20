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
	// set as the stage starts (its row's enter): the count it ends on (its
	// last sample's level is its row's finish; max(int): never), and an
	// approach's: where its curve becomes a line (90% of its time), 1 / its
	// time constant (samples), its level there, its length (samples)
	end, bend:                       int,
	inv_tc:                          f32,
	v90:                             f32,
	length:                          f64,
}

// A stage as rows: what starting it sets (its end, an approach's curve),
// its levels before its end (each from its count alone: a loop with no
// branch), and its last sample's level, starting what follows.
Adsr_Row :: struct {
	enter:  proc "contextless" (e: ^Adsr),
	fill:   proc "contextless" (e: ^Adsr, out: []f32),
	finish: proc "contextless" (e: ^Adsr) -> f32,
}

ADSR_STAGES := [Adsr_Stage]Adsr_Row {
	.Idle = {
		enter = proc "contextless" (e: ^Adsr) {e.end = max(int)},
		fill = proc "contextless" (e: ^Adsr, out: []f32) {fill(out, 0)},
	},
	.Delay = {
		enter = proc "contextless" (e: ^Adsr) {e.end = first_reaching(f64(e.delay) * RATE)},
		fill = proc "contextless" (e: ^Adsr, out: []f32) {fill(out, 0)},
		finish = proc "contextless" (e: ^Adsr) -> f32 {
			e.from = e.start
			stage_enter(e, .Attack)
			return e.start
		},
	},
	.Attack = {
		enter = proc "contextless" (e: ^Adsr) {
			if e.exponential_attack {
				approach_enter(e, e.attack, 1)
				return
			}
			// linear: done where f64(k) / RATE reaches it, which rises with k
			// (its estimate is within a count of that)
			a := f64(e.attack)
			e.end = first_reaching(a * RATE)
			if e.end > 0 && f64(e.end - 1) / RATE >= a {
				e.end -= 1
			} else if f64(e.end) / RATE < a {
				e.end += 1
			}
		},
		fill = proc "contextless" (e: ^Adsr, out: []f32) {
			if e.exponential_attack {
				approach_fill(e, 1, out)
				return
			}
			k0, from, a := e.samples, e.from, f64(e.attack)
			for i in 0 ..< len(out) {
				out[i] = from + (1 - from) * f32(f64(k0 + i) / RATE / a)
			}
		},
		finish = proc "contextless" (e: ^Adsr) -> f32 {
			e.from = 1
			stage_enter(e, e.hold > 0 ? .Hold : .Decay)
			return 1
		},
	},
	.Hold = {
		enter = proc "contextless" (e: ^Adsr) {e.end = first_reaching(f64(e.hold) * RATE)},
		fill = proc "contextless" (e: ^Adsr, out: []f32) {fill(out, 1)},
		finish = proc "contextless" (e: ^Adsr) -> f32 {
			e.from = 1
			stage_enter(e, .Decay)
			return 1
		},
	},
	.Decay = {
		enter = proc "contextless" (e: ^Adsr) {approach_enter(e, e.decay, e.sustain)},
		fill = proc "contextless" (e: ^Adsr, out: []f32) {approach_fill(e, e.sustain, out)},
		finish = proc "contextless" (e: ^Adsr) -> f32 {
			e.stage, e.end = .Sustain, max(int) // its count runs on
			return e.sustain
		},
	},
	.Sustain = {
		enter = proc "contextless" (e: ^Adsr) {e.end = max(int)},
		fill = proc "contextless" (e: ^Adsr, out: []f32) {fill(out, e.sustain)},
	},
	.Release = {
		enter = proc "contextless" (e: ^Adsr) {approach_enter(e, e.release, 0)},
		fill = proc "contextless" (e: ^Adsr, out: []f32) {approach_fill(e, 0, out)},
		finish = proc "contextless" (e: ^Adsr) -> f32 {
			e.stage, e.end = .Idle, max(int)
			return 0
		},
	},
}

// Starts the envelope its fields describe: its delay, or its attack from
// `start`.
adsr_init :: proc "contextless" (e: ^Adsr) {
	e.from = e.start
	stage_enter(e, e.delay > 0 ? .Delay : .Attack)
}

// The gate closing: the release from wherever the level is.
adsr_release :: proc "contextless" (e: ^Adsr) {
	if e.stage != .Idle {
		e.from = e.value
		stage_enter(e, .Release)
	}
}

// Fills `out` with the envelope's levels; the gate closes (the release
// starts) at sample `release_at` of this slice (negative or past the end: not
// in it). Each stage fills to its end in one loop, its last sample finishes
// it.
adsr_run :: proc "contextless" (e: ^Adsr, out: []f32, release_at: int) {
	n := len(out)
	for i := 0; i < n; {
		if i == release_at {
			adsr_release(e)
		}
		limit := release_at > i && release_at < n ? release_at : n
		row := ADSR_STAGES[e.stage]
		if m := clamp(e.end - e.samples, 0, limit - i); m > 0 {
			row.fill(e, out[i:][:m])
			e.value = out[i + m - 1]
			e.samples += m
			i += m
			continue
		}
		e.value = row.finish(e)
		e.samples += 1
		out[i] = e.value
		i += 1
	}
}

@(private = "file")
stage_enter :: proc "contextless" (e: ^Adsr, stage: Adsr_Stage) {
	e.stage, e.samples = stage, 0
	ADSR_STAGES[stage].enter(e)
}

// The first count k (samples into a stage) with f64(k) >= x: k against a
// fixed f64 compares as against its ceiling.
@(private = "file")
first_reaching :: #force_inline proc "contextless" (x: f64) -> int {
	return int(math.ceil(clamp(x, 0, 1e15)))
}

@(private = "file")
fill :: #force_inline proc "contextless" (out: []f32, v: f32) {
	for i in 0 ..< len(out) {
		out[i] = v
	}
}

// Tone's exponentialApproachValueAtTime from e.from to `target` over `ramp`
// seconds: a time constant of ln(ramp + 1) / ln(200) to 90% of its time, then
// a line onto the target; done at its time.
@(private = "file")
approach_enter :: proc "contextless" (e: ^Adsr, ramp: f32, target: f32) {
	r := f64(ramp)
	e.length = r * RATE
	e.end, e.bend = first_reaching(e.length), first_reaching(0.9 * e.length)
	if r <= 0 {
		return
	}
	tc := math.ln(r + 1) / math.ln(f64(200))
	e.inv_tc = f32(1 / (tc * RATE))
	e.v90 = f32(f64(target) + f64(e.from - target) * math.exp(-0.9 * r / tc))
}

@(private = "file")
approach_fill :: #force_inline proc "contextless" (e: ^Adsr, target: f32, out: []f32) #no_bounds_check {
	k0 := e.samples
	curve := clamp(e.bend - k0, 0, len(out))
	from, inv_tc := e.from, e.inv_tc
	for i in 0 ..< curve {
		out[i] = target + (from - target) * exp_decay(-f32(k0 + i) * inv_tc)
	}
	v90, length := f64(e.v90), e.length
	for i in curve ..< len(out) {
		out[i] = f32(v90 + (f64(target) - v90) * (f64(k0 + i) - 0.9 * length) / (0.1 * length))
	}
}
