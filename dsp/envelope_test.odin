package odawg_dsp

import "core:math"
import "core:testing"

// Tone's envelope: a linear attack, a decay approaching the sustain (not
// linearly, and there exactly at its time), held, then a release from there
// to nothing by its time; the same samples however the run is cut.
@(test)
test_envelope_curves :: proc(t: ^testing.T) {
	envelope :: proc() -> Adsr {
		e := Adsr{attack = 0.01, decay = 0.2, sustain = 0.5, release = 0.3}
		adsr_init(&e)
		return e
	}
	whole := make([]f32, int(0.8 * RATE), context.temp_allocator)
	e := envelope()
	adsr_run(&e, whole, int(0.4 * RATE))
	testing.expect(t, abs(whole[int(0.005 * RATE)] - 0.5) < 0.01) // halfway up the attack
	testing.expect(t, whole[int(0.05 * RATE)] < 0.75 && whole[int(0.05 * RATE)] > 0.5) // decaying, not linearly
	testing.expect(t, abs(whole[int(0.21 * RATE) + 1] - 0.5) < 1e-4)
	testing.expect(t, abs(whole[int(0.39 * RATE)] - 0.5) < 1e-6)
	testing.expect(t, whole[int(0.45 * RATE)] < 0.5 && whole[int(0.45 * RATE)] > 0.05)
	testing.expect(t, whole[int(0.69 * RATE)] > 0)
	testing.expect_value(t, whole[int(0.7 * RATE) + 1], 0)
	testing.expect(t, e.stage == .Idle)
	// cut into runs of 1, 7 and 300 samples
	for step in ([]int{1, 7, 300}) {
		cut := make([]f32, len(whole), context.temp_allocator)
		x := envelope()
		for at := 0; at < len(cut); at += step {
			end := min(at + step, len(cut))
			rel := int(0.4 * RATE) - at
			adsr_run(&x, cut[at:end], rel >= 0 && rel < end - at ? rel : -1)
		}
		same := true
		for v, i in whole {
			same &&= v == cut[i]
		}
		testing.expectf(t, same, "cut into runs of %d it differs", step)
	}
}

// The stage table gives the samples of Tone's envelope stepped a sample at a
// time (the state machine below, the envelope as it was first written), bit
// for bit: every stage, each kind of attack, the gate closing in each stage,
// however the run is cut.
@(test)
test_envelope_stages :: proc(t: ^testing.T) {
	shapes := []Adsr {
		{attack = 0.01, decay = 0.2, sustain = 0.5, release = 0.3},
		{attack = 0.3, decay = 0, sustain = 1, release = 0.05},
		{attack = 1.8, decay = 1, sustain = 0.8, release = 3.5},
		{attack = 0.02, decay = 0.1, sustain = 0.3, release = 0.2, exponential_attack = true},
		{attack = 0.01, decay = 0.05, sustain = 0.2, release = 0.1, delay = 0.03, hold = 0.02, start = 0.25},
		{attack = 0, decay = 0, sustain = 0.7, release = 0},
		{attack = 1 / f32(RATE), decay = 3 / f32(RATE), sustain = 0.4, release = 2 / f32(RATE), hold = 1 / f32(RATE)},
	}
	length := int(1.2 * RATE)
	for shape, k in shapes {
		for gate in ([]int{0, 100, 500, int(0.02 * RATE), int(0.15 * RATE), int(0.6 * RATE), length + 10}) {
			want := make([]f32, length, context.temp_allocator)
			x := Stepped{adsr = shape}
			for i in 0 ..< length {
				want[i] = stepped_sample(&x, i == gate)
			}
			for step in ([]int{1, 7, 256, 300, length}) {
				got := make([]f32, length, context.temp_allocator)
				e := shape
				adsr_init(&e)
				for at := 0; at < length; at += step {
					end := min(at + step, length)
					rel := gate - at
					adsr_run(&e, got[at:end], rel >= 0 && rel < end - at ? rel : -1)
				}
				first := -1
				for v, i in want {
					if transmute(u32)v != transmute(u32)got[i] {
						first = i
						break
					}
				}
				testing.expectf(t, first < 0, "shape %d, gate at %d, runs of %d: differs from sample %d", k, gate, step, first)
			}
		}
	}
}

// The envelope stepped a sample at a time, every stage a branch: the
// reference the stage table is held to.
@(private = "file")
Stepped :: struct {
	adsr:    Adsr,
	started: bool,
	length:  f64,
	inv_tc:  f32,
	v90:     f32,
}

@(private = "file")
stepped_sample :: proc(x: ^Stepped, gate_closes: bool) -> f32 {
	e := &x.adsr
	set :: proc(x: ^Stepped, ramp, target: f32) {
		r := f64(ramp)
		x.length = r * RATE
		if r <= 0 {
			return
		}
		tc := math.ln(r + 1) / math.ln(f64(200))
		x.inv_tc = f32(1 / (tc * RATE))
		x.v90 = f32(f64(target) + f64(x.adsr.from - target) * math.exp(-0.9 * r / tc))
	}
	value :: proc(x: ^Stepped, target: f32) -> (f32, bool) {
		k := x.adsr.samples
		v := f64(k)
		if v >= x.length {
			return target, true
		}
		if v < 0.9 * x.length {
			return target + (x.adsr.from - target) * exp_decay(-f32(k) * x.inv_tc), false
		}
		return f32(f64(x.v90) + (f64(target) - f64(x.v90)) * (v - 0.9 * x.length) / (0.1 * x.length)), false
	}
	if !x.started {
		x.started = true
		e.stage, e.from = e.delay > 0 ? .Delay : .Attack, e.start
		if e.stage == .Attack && e.exponential_attack {
			set(x, e.attack, 1)
		}
	}
	if gate_closes && e.stage != .Idle {
		e.stage, e.samples, e.from = .Release, 0, e.value
		set(x, e.release, 0)
	}
	done: bool
	switch e.stage {
	case .Idle:
		e.value = 0
	case .Delay:
		e.value = 0
		if f64(e.samples) >= f64(e.delay) * RATE {
			e.stage, e.samples, e.from = .Attack, 0, e.start
			x.length = 0
			if e.exponential_attack {
				set(x, e.attack, 1)
			}
			e.value = e.start
		}
	case .Attack:
		a := f64(e.attack)
		tt := f64(e.samples) / RATE
		if e.exponential_attack {
			e.value, done = value(x, 1)
		} else if tt >= a {
			e.value, done = 1, true
		} else {
			e.value = e.from + (1 - e.from) * f32(tt / a)
		}
		if done {
			if e.hold > 0 {
				e.stage, e.samples = .Hold, 0
			} else {
				e.stage, e.samples, e.from = .Decay, 0, 1
				set(x, e.decay, e.sustain)
			}
		}
	case .Hold:
		e.value = 1
		if f64(e.samples) >= f64(e.hold) * RATE {
			e.stage, e.samples, e.from = .Decay, 0, 1
			set(x, e.decay, e.sustain)
		}
	case .Decay:
		e.value, done = value(x, e.sustain)
		if done {
			e.stage = .Sustain
		}
	case .Sustain:
		e.value = e.sustain
	case .Release:
		e.value, done = value(x, 0)
		if done {
			e.stage, e.value = .Idle, 0
		}
	}
	e.samples += 1
	return e.value
}

// An envelope never started (all zero) plays silence, released or not: a
// node run over a voice whose start was missed is silent, never a crash.
@(test)
test_adsr_unstarted :: proc(t: ^testing.T) {
	e: Adsr
	out: [300]f32
	for &v in out {
		v = 1
	}
	adsr_run(&e, out[:], 100)
	for v in out {
		testing.expect_value(t, v, 0)
	}
	testing.expect(t, e.stage == .Idle)
}
