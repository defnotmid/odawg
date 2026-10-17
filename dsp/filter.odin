package odawg_dsp

import "core:math"

// Filters. A state-variable filter in its topology-preserving
// (zero-delay-feedback) form, after Andrew Simper's "Linear Trapezoidal SVF":
// its output is m0 x + m1 band + m2 low, which gives every Filter_Type,
// shelves and the peak included, from one structure that stays stable while
// the cutoff moves every sample. Tone's Filter chains one per 12 dB of
// rolloff. Also the one-pole low-pass synth.lua's voices use.

// The most SVFs a chain holds (rolloff -96).
MAX_STAGES :: 8

Svf :: struct {
	a1, a2, a3: f32,
	m0, m1, m2: f32,
}

// One SVF's memory (its two integrators).
Svf_State :: struct {
	ic1, ic2: f32,
}

// Coefficients as Web Audio's BiquadFilterNode reads its parameters (Tone's
// Filter is a chain of them): for the low-pass and high-pass `q` is the
// resonance in dB; for the band-pass, notch, all-pass and peak it is the
// usual Q; shelves ignore it (slope 1). `gain` is in dB. The band-pass peaks
// at 1, as Web Audio's.
svf_coefficients :: proc "contextless" (type: Filter_Type, hz, q, gain: f32) -> Svf {
	fc := clamp(f64(hz), 1, 0.49 * RATE)
	g := math.tan(math.PI * fc / RATE)
	A := math.pow(10, f64(gain) / 40)
	k, m0, m1, m2: f64
	switch type {
	case .Lowpass, .Highpass:
		k = 1 / math.pow(10, f64(q) / 20)
	case .Bandpass, .Notch, .Allpass, .Peaking:
		k = 1 / max(f64(q), 0.0001)
	case .Lowshelf, .Highshelf:
		k = math.SQRT_TWO
	}
	switch type {
	case .Lowpass:
		m0, m1, m2 = 0, 0, 1
	case .Highpass:
		m0, m1, m2 = 1, -k, -1
	case .Bandpass:
		m0, m1, m2 = 0, k, 0
	case .Notch:
		m0, m1, m2 = 1, -k, 0
	case .Allpass:
		m0, m1, m2 = 1, -2 * k, 0
	case .Peaking:
		k /= A
		m0, m1, m2 = 1, k * (A * A - 1), 0
	case .Lowshelf:
		g /= math.sqrt(A)
		m0, m1, m2 = 1, k * (A - 1), A * A - 1
	case .Highshelf:
		g *= math.sqrt(A)
		m0, m1, m2 = A * A, k * (1 - A) * A, 1 - A * A
	}
	a1 := 1 / (1 + g * (g + k))
	a2 := g * a1
	return {f32(a1), f32(a2), f32(g * a2), f32(m0), f32(m1), f32(m2)}
}

// Runs a slice through one SVF in place, at fixed coefficients.
svf_run :: proc "contextless" (c: Svf, s: ^Svf_State, x: []f32) {
	ic1, ic2 := s.ic1, s.ic2
	for i in 0 ..< len(x) {
		v0 := x[i]
		v3 := v0 - ic2
		v1 := c.a1 * ic1 + c.a2 * v3
		v2 := ic2 + c.a2 * ic1 + c.a3 * v3
		ic1 = 2 * v1 - ic1
		ic2 = 2 * v2 - ic2
		x[i] = c.m0 * v0 + c.m1 * v1 + c.m2 * v2
	}
	s.ic1, s.ic2 = ic1, ic2
}

// Runs a slice through one SVF in place, with each sample's own coefficients.
svf_run_swept :: proc "contextless" (c: []Svf, s: ^Svf_State, x: []f32) {
	ic1, ic2 := s.ic1, s.ic2
	for i in 0 ..< min(len(x), len(c)) {
		v0 := x[i]
		v3 := v0 - ic2
		v1 := c[i].a1 * ic1 + c[i].a2 * v3
		v2 := ic2 + c[i].a2 * ic1 + c[i].a3 * v3
		ic1 = 2 * v1 - ic1
		ic2 = 2 * v2 - ic2
		x[i] = c[i].m0 * v0 + c[i].m1 * v1 + c[i].m2 * v2
	}
	s.ic1, s.ic2 = ic1, ic2
}

// The number of 12 dB stages for Tone's rolloff (-12, -24, -48, -96).
rolloff_stages :: proc "contextless" (rolloff: f32) -> int {
	switch int(rolloff) {
	case -24:
		return 2
	case -48:
		return 4
	case -96:
		return 8
	}
	return 1
}

// Tone's Filter: `stages` SVFs at the same settings, for two channels.
Filter_Chain :: struct {
	type:    Filter_Type,
	q, gain: f32,
	stages:  int,
	state:   [2][MAX_STAGES]Svf_State,
}

filter_chain_init :: proc "contextless" (type: Filter_Type, q, rolloff, gain: f32) -> Filter_Chain {
	return {type = type, q = q, gain = gain, stages = rolloff_stages(rolloff)}
}

// Filters a slice of `channel` (0 or 1) in place at a fixed cutoff.
filter_chain_run :: proc "contextless" (f: ^Filter_Chain, hz: f32, x: []f32, channel := 0) {
	c := svf_coefficients(f.type, hz, f.q, f.gain)
	for s in 0 ..< f.stages {
		svf_run(c, &f.state[channel][s], x)
	}
}

// Filters a slice of `channel` in place with each sample's coefficients
// (from filter_chain_coefficients), shared by every stage.
filter_chain_run_swept :: proc "contextless" (f: ^Filter_Chain, c: []Svf, x: []f32, channel := 0) {
	for s in 0 ..< f.stages {
		svf_run_swept(c, &f.state[channel][s], x)
	}
}

// Coefficients for a cutoff that moves every sample (`hz`, one per sample).
filter_chain_coefficients :: proc "contextless" (f: ^Filter_Chain, hz: []f32, out: []Svf) {
	last: f32 = -1
	c: Svf
	for i in 0 ..< min(len(hz), len(out)) {
		if hz[i] != last {
			last = hz[i]
			c = svf_coefficients(f.type, last, f.q, f.gain)
		}
		out[i] = c
	}
}

// The one-pole low-pass coefficient for a cutoff (synth.lua's lp(hz)):
// y += k (x - y).
one_pole_k :: proc "contextless" (hz: f64) -> f64 {return 1 - math.exp(-math.TAU * hz / RATE)}

One_Pole :: struct {
	k, y: f32,
}

// Low-passes a slice in place.
one_pole_lowpass_run :: proc "contextless" (f: ^One_Pole, x: []f32) {
	y, k := f.y, f.k
	for i in 0 ..< len(x) {
		y += k * (x[i] - y)
		x[i] = y
	}
	f.y = y
}

// The responses a filter has.
Filter_Type :: enum u8 {
	Lowpass,
	Highpass,
	Bandpass,
	Lowshelf,
	Highshelf,
	Notch,
	Allpass,
	Peaking,
}
