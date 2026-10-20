package odawg_dsp

import "core:math"

// Filters. A state-variable filter in its topology-preserving
// (zero-delay-feedback) form, after Andrew Simper's "Linear Trapezoidal SVF":
// its output is m0 x + m1 band + m2 low, which gives every Filter_Type,
// shelves and the peak included, from one structure that stays stable while
// the cutoff moves every sample (its shapes one table, SVF_SHAPES, for the
// Filter node and the effects). Tone's Filter chains one per 12 dB of
// rolloff. Also the one-pole coefficient synth.lua's voices use.

// The most SVFs a chain holds (rolloff -96).
MAX_STAGES :: 4

Svf :: struct {
	a1, a2, a3: f32,
	m0, m1, m2: f32,
}

// One SVF's memory (its two integrators).
Svf_State :: struct {
	ic1, ic2: f32,
}

// Simper's trapezoidal SVF. Its three outputs mixed by m0..m2 give exactly
// the responses of Web Audio's BiquadFilterNode (the RBJ cookbook, bilinear
// and prewarped at the cutoff), and it stays well behaved while its cutoff
// moves. A shape is a response before the cutoff is known: the cutoff's tan
// is scaled by g_scale (a shelf's gain moves it), k damps, m0..m2 mix.
Svf_Shape :: struct {
	g_scale, k, m0, m1, m2: f64,
}

// Each Filter_Type's shape from Tone's q and gain (dB), as Web Audio reads
// them: a lowpass or highpass Q is the resonance in dB, the others' as is;
// shelves have a slope of 1 and ignore q; gain is for shelves and peaking.
// The band-pass peaks at 1, as Web Audio's. The Filter node and the effects
// both.
SVF_SHAPES := [Filter_Type]proc "contextless" (q, gain_db: f64) -> Svf_Shape {
	.Lowpass = proc "contextless" (q, gain_db: f64) -> Svf_Shape {
		return {1, 1 / math.pow(10, q / 20), 0, 0, 1}
	},
	.Highpass = proc "contextless" (q, gain_db: f64) -> Svf_Shape {
		k := 1 / math.pow(10, q / 20)
		return {1, k, 1, -k, -1}
	},
	.Bandpass = proc "contextless" (q, gain_db: f64) -> Svf_Shape {
		k := 1 / max(q, 1e-4)
		return {1, k, 0, k, 0}
	},
	.Lowshelf = proc "contextless" (q, gain_db: f64) -> Svf_Shape {
		a := math.pow(10, gain_db / 40)
		return {1 / math.sqrt(a), math.SQRT_TWO, 1, math.SQRT_TWO * (a - 1), a * a - 1}
	},
	.Highshelf = proc "contextless" (q, gain_db: f64) -> Svf_Shape {
		a := math.pow(10, gain_db / 40)
		return {math.sqrt(a), math.SQRT_TWO, a * a, math.SQRT_TWO * (1 - a) * a, 1 - a * a}
	},
	.Notch = proc "contextless" (q, gain_db: f64) -> Svf_Shape {
		k := 1 / max(q, 1e-4)
		return {1, k, 1, -k, 0}
	},
	.Allpass = proc "contextless" (q, gain_db: f64) -> Svf_Shape {
		k := 1 / max(q, 1e-4)
		return {1, k, 1, -2 * k, 0}
	},
	.Peaking = proc "contextless" (q, gain_db: f64) -> Svf_Shape {
		a := math.pow(10, gain_db / 40)
		k := 1 / (max(q, 1e-4) * a)
		return {1, k, 1, k * (a * a - 1), 0}
	},
}

// A shape at a cutoff: its coefficients (in f64; an effect runs them so,
// a node's voices in f32: svf_coefficients).
Svf64 :: struct {
	a1, a2, a3, m0, m1, m2: f64,
}

// The tan of a cutoff, kept below Nyquist.
svf_warp :: proc "contextless" (hz: f64) -> f64 {
	return math.tan(math.PI * clamp(hz, 1, 0.49 * RATE) / RATE)
}

svf64 :: proc "contextless" (s: Svf_Shape, hz: f64) -> Svf64 {
	g := svf_warp(hz) * s.g_scale
	a1 := 1 / (1 + g * (g + s.k))
	return {a1, g * a1, g * g * a1, s.m0, s.m1, s.m2}
}

// A Filter_Type's coefficients at `hz` with `q` and `gain` (dB), for f32.
svf_coefficients :: proc "contextless" (type: Filter_Type, hz, q, gain: f32) -> Svf {
	c := svf64(SVF_SHAPES[type](f64(q), f64(gain)), f64(hz))
	return {f32(c.a1), f32(c.a2), f32(c.a3), f32(c.m0), f32(c.m1), f32(c.m2)}
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

// Tone's rolloffs and how many 12 dB stages it cascades for each (its own
// mapping: -48 is three, -96 four); anything else reads as the nearest. The
// Filter node and the Filter effect both.
ROLLOFFS := [?]struct {
	rolloff: f32,
	stages:  int,
}{{-12, 1}, {-24, 2}, {-48, 3}, {-96, 4}}

rolloff_stages :: proc "contextless" (rolloff: f32) -> int {
	best := ROLLOFFS[0]
	for row in ROLLOFFS {
		if abs(row.rolloff - rolloff) < abs(best.rolloff - rolloff) {
			best = row
		}
	}
	return best.stages
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
