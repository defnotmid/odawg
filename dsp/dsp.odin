// dsp: signal primitives over slices: band-limited oscillators and unison,
// filters, envelopes, noise. Plain state structs and procs that run a whole
// slice in one typed loop; nothing here knows devices, songs or params.
package odawg_dsp

import base "../base"

RATE :: base.RATE

// ---- per-sample math ---------------------------------------------------------------------

// What the hot loops call per sample instead of libm: each a pure function
// of its argument (so a sample never depends on where a block began),
// polynomial, and well inside 16-bit output's precision.

// A phase in [0, 1) after adding at most one cycle (deep FM may add more:
// the slow path).
wrap :: #force_inline proc "contextless" (t: f64) -> f64 {
	switch {
	case t >= 1:
		if t < 2 {
			return t - 1
		}
	case t < 0:
		if t >= -1 {
			return t + 1
		}
	case:
		return t
	}
	return t - f64(i64(t)) + (t < 0 ? 1 : 0)
}

// sin(2π t) for a phase in [0, 1): folded to a quarter cycle, odd
// polynomial to x^11 (error under 1e-7).
sin_turns :: #force_inline proc "contextless" (t: f64) -> f32 {
	u := f32(t) - 0.5 // sin(2π t) = -sin(2π u)
	if u > 0.25 {
		u = 0.5 - u
	} else if u < -0.25 {
		u = -0.5 - u
	}
	x := u * 6.283185307
	x2 := x * x
	p := f32(-2.5052108e-8)
	p = p * x2 + 2.7557319e-6
	p = p * x2 - 1.9841270e-4
	p = p * x2 + 8.3333333e-3
	p = p * x2 - 1.6666667e-1
	return -(x + x * x2 * p)
}

// e^x for x <= 0 (decays): 2^(x log2 e) as an exponent and a polynomial
// for the fraction (relative error under 2e-7); 0 below -87.
exp_decay :: #force_inline proc "contextless" (x: f32) -> f32 {
	if x < -87 {
		return 0
	}
	y := x * 1.442695041
	k := i32(y)
	if f32(k) > y {
		k -= 1
	}
	f := y - f32(k) // [0, 1)
	p := f32(1.8775767e-3)
	p = p * f + 8.9893397e-3
	p = p * f + 5.5826318e-2
	p = p * f + 2.4015361e-1
	p = p * f + 6.9315308e-1
	p = p * f + 1
	return p * transmute(f32)(u32(k + 127) << 23)
}

// 2^y for any y (clamped to f32's exponents): its whole part as the
// exponent, the same polynomial for the fraction (relative error under
// 2e-7): a pitch or a cutoff moved in octaves, per sample.
exp2_fast :: #force_inline proc "contextless" (y: f32) -> f32 {
	y := clamp(y, -126, 127)
	k := i32(y)
	if f32(k) > y {
		k -= 1
	}
	f := y - f32(k) // [0, 1)
	p := f32(1.8775767e-3)
	p = p * f + 8.9893397e-3
	p = p * f + 5.5826318e-2
	p = p * f + 2.4015361e-1
	p = p * f + 6.9315308e-1
	p = p * f + 1
	return p * transmute(f32)(u32(k + 127) << 23)
}

// tanh(x) as (1 - e) / (1 + e) with e = e^(-2|x|) from exp_decay (error
// under 1e-6), its sign restored.
tanh_fast :: #force_inline proc "contextless" (x: f32) -> f32 {
	e := exp_decay(-2 * abs(x))
	y := (1 - e) / (1 + e)
	return x < 0 ? -y : y
}
