package odawg_device

import dsp "../dsp"
import "core:math"
import "core:mem"

// Tone's effects as streams: the procs DEVICE_TABLE's effect rows name.
// An instance's state is bytes the engine allocates once from size_<kind>
// and clears with reset_<kind>; effect_<kind> processes the next block in
// place. Every effect is causal and its recursion runs per sample, so the
// output never depends on how the stream is cut into blocks (one call or
// blocks of one sample give the same bits); what moves in time (an LFO, a
// reverb's drift) is a function of the song sample, so a reset at sample K
// puts it where a stream from 0 has it. Each reads only its row's params.
// The filters, EQ, delays, chorus and reverb are linear (modulation runs on
// the clock, not the signal), so a part's send can go through its own copy
// of a return effect and the results be summed. Nothing is random.
//
// This file: what every effect shares (the state layout, the chunked run
// and the wet/dry mix, the state-variable filter) and the effects that
// only colour the sound: Filter, AutoFilter, EQ3, Distortion, BitCrusher,
// StereoWidener.

// ---- the state and the run every effect shares ----------------------------------------

// Blocks are processed in chunks of this many samples, each stage a loop
// over the chunk, with the scratch the stages need inside the state.
@(private)
FX_CHUNK :: 256

// Every effect's state struct starts with this.
@(private)
Fx_Scratch :: struct #align (16) {
	dry_l, dry_r: [FX_CHUNK]f32, // the input, or the dry signal delayed by the latency
	key_l, key_r: [FX_CHUNK]f32,
	a, b:         [FX_CHUNK]f32,
	d:            [FX_CHUNK]f64,
}

// An effect's processing of one chunk; key always present and as long.
@(private)
Fx_Body :: #type proc(state: []u8, p: ^Params, l, r, key_l, key_r: []f32)

// The state struct at the start of an instance's bytes.
@(private)
fx_header :: #force_inline proc(state: []u8, $T: typeid) -> ^T {
	assert(len(state) >= size_of(T), "an effect's state is smaller than its size proc said")
	return (^T)(raw_data(state))
}

// The smallest power of two holding `n`.
@(private)
fx_pow2 :: proc "contextless" (n: int) -> int {
	size := 1
	for size < n {
		size *= 2
	}
	return size
}

// The length of each of `arrays` f32 rings after the struct T: the largest
// power of two that fits the bytes the engine gave.
@(private)
fx_ring_len :: proc(state: []u8, $T: typeid, arrays: int) -> int {
	fits := (len(state) - size_of(T)) / (arrays * size_of(f32))
	size := 1
	for size * 2 <= fits {
		size *= 2
	}
	assert(fits >= 4, "an effect's rings are missing from its state")
	return size
}

// Ring `index` after the struct T.
@(private)
fx_ring :: proc(state: []u8, $T: typeid, ring_len, index: int) -> []f32 {
	return ([^]f32)(raw_data(state[size_of(T):]))[index * ring_len:][:ring_len]
}

// Clears an instance's bytes.
@(private)
fx_clear :: proc(state: []u8) {
	mem.zero_slice(state)
}

// Runs an effect's body over a block in chunks: both channels cut to one
// length, the key defaulted (nil: the signal; only key_l: both sides; past
// its end: silence), then each chunk mixed with the dry signal by .Wet
// with Tone's equal-power crossfade (dry cos, wet sin of wet * pi/2). A
// body with latency puts its delayed dry signal in the scratch's dry.
@(private)
fx_run :: proc(state: []u8, p: ^Params, left, right, key_l, key_r: []f32, body: Fx_Body) {
	s := fx_header(state, Fx_Scratch)
	n := min(len(left), len(right))
	wet := clamp(f64(p[.Wet]), 0, 1)
	dg := f32(math.cos(wet * math.PI / 2))
	wg := f32(math.sin(wet * math.PI / 2))
	for start := 0; start < n; start += FX_CHUNK {
		end := min(start + FX_CHUNK, n)
		l, r := left[start:end], right[start:end]
		m := end - start
		copy(s.dry_l[:m], l)
		copy(s.dry_r[:m], r)
		kl, kr := l, r
		if key_l != nil {
			kl = fx_key_chunk(key_l, start, end, s.key_l[:m])
			kr = key_r != nil ? fx_key_chunk(key_r, start, end, s.key_r[:m]) : kl
		}
		body(state, p, l, r, kl, kr)
		if wet < 1 {
			for &v, i in l {
				v = dg * s.dry_l[i] + wg * v
			}
			for &v, i in r {
				v = dg * s.dry_r[i] + wg * v
			}
		}
	}
}

// A key's samples start..end, silent past its end.
@(private = "file")
fx_key_chunk :: proc(key: []f32, start, end: int, out: []f32) -> []f32 {
	have := clamp(len(key) - start, 0, end - start)
	copy(out, key[start:][:have])
	for &v in out[have:] {
		v = 0
	}
	return out
}

// Values below ~1e-34 snap to zero, so decaying feedback never turns
// denormal (and slow).
@(private)
fx_flush :: #force_inline proc "contextless" (x: f64) -> f64 {return (x + 1e-18) - 1e-18}

// A one-pole smoothing coefficient for a time constant in seconds.
@(private)
fx_time_coef :: proc "contextless" (seconds: f32) -> f64 {
	return seconds > 0 ? math.exp(-1 / (f64(seconds) * RATE)) : 0
}

// A choice param's index as its enum.
@(private = "file")
fx_filter_type :: proc "contextless" (v: f32) -> dsp.Filter_Type {
	return dsp.Filter_Type(clamp(int(v), 0, len(dsp.Filter_Type) - 1))
}

// Sizes and resets for the effects whose state is only their struct.
@(private = "file")
fx_size_of :: proc($T: typeid) -> int {return size_of(T)}

// ---- the state-variable filter ---------------------------------------------------

// Simper's trapezoidal SVF. Its three outputs mixed by m0..m2 give exactly
// the responses of Web Audio's BiquadFilterNode (the RBJ cookbook, bilinear
// and prewarped at the cutoff), and it stays well behaved while its cutoff
// moves. A shape is a response before the cutoff is known: the cutoff's
// tan is scaled by g_scale, k damps.
@(private = "file")
Fx_Svf_Shape :: struct {
	g_scale, k, m0, m1, m2: f64,
}

@(private = "file")
Fx_Svf :: struct {
	a1, a2, a3, m0, m1, m2: f64,
}

// One filter stage's memory.
@(private = "file")
Fx_Svf_State :: struct {
	ic1, ic2: f64,
}

// Each filter type's shape from Tone's q and gain (dB), as Web Audio reads
// them: a lowpass or highpass Q is in dB, the others' as is; shelves have
// a slope of 1 and ignore q; gain is for shelves and peaking.
@(private = "file")
FX_SVF_RULES := [dsp.Filter_Type]proc "contextless" (q, gain_db: f64) -> Fx_Svf_Shape {
	.Lowpass = proc "contextless" (q, gain_db: f64) -> Fx_Svf_Shape {
		return {1, 1 / math.pow(10, q / 20), 0, 0, 1}
	},
	.Highpass = proc "contextless" (q, gain_db: f64) -> Fx_Svf_Shape {
		k := 1 / math.pow(10, q / 20)
		return {1, k, 1, -k, -1}
	},
	.Bandpass = proc "contextless" (q, gain_db: f64) -> Fx_Svf_Shape {
		k := 1 / max(q, 1e-4)
		return {1, k, 0, k, 0}
	},
	.Lowshelf = proc "contextless" (q, gain_db: f64) -> Fx_Svf_Shape {
		a := math.pow(10, gain_db / 40)
		return {1 / math.sqrt(a), math.SQRT_TWO, 1, math.SQRT_TWO * (a - 1), a * a - 1}
	},
	.Highshelf = proc "contextless" (q, gain_db: f64) -> Fx_Svf_Shape {
		a := math.pow(10, gain_db / 40)
		return {math.sqrt(a), math.SQRT_TWO, a * a, math.SQRT_TWO * (1 - a) * a, 1 - a * a}
	},
	.Notch = proc "contextless" (q, gain_db: f64) -> Fx_Svf_Shape {
		k := 1 / max(q, 1e-4)
		return {1, k, 1, -k, 0}
	},
	.Allpass = proc "contextless" (q, gain_db: f64) -> Fx_Svf_Shape {
		k := 1 / max(q, 1e-4)
		return {1, k, 1, -2 * k, 0}
	},
	.Peaking = proc "contextless" (q, gain_db: f64) -> Fx_Svf_Shape {
		a := math.pow(10, gain_db / 40)
		k := 1 / (max(q, 1e-4) * a)
		return {1, k, 1, k * (a * a - 1), 0}
	},
}

// Linkwitz-Riley's halves: Butterworth lowpass and highpass, and the
// allpass their fourth-order pair sums to.
@(private = "file")
FX_BUTTERWORTH_LOW :: Fx_Svf_Shape{1, math.SQRT_TWO, 0, 0, 1}
@(private = "file")
FX_BUTTERWORTH_HIGH :: Fx_Svf_Shape{1, math.SQRT_TWO, 1, -math.SQRT_TWO, -1}
@(private = "file")
FX_BUTTERWORTH_ALL :: Fx_Svf_Shape{1, math.SQRT_TWO, 1, -2 * math.SQRT_TWO, 0}

// The tan of a cutoff, kept below Nyquist.
@(private = "file")
fx_warp :: proc "contextless" (hz: f64) -> f64 {
	return math.tan(math.PI * clamp(hz, 1, 0.49 * RATE) / RATE)
}

@(private = "file")
fx_svf :: proc "contextless" (s: Fx_Svf_Shape, hz: f64) -> Fx_Svf {
	g := fx_warp(hz) * s.g_scale
	a1 := 1 / (1 + g * (g + s.k))
	return {a1, g * a1, g * g * a1, s.m0, s.m1, s.m2}
}

// One filter stage over a slice, in place, carrying its memory.
@(private = "file")
fx_svf_pass :: proc(c: Fx_Svf, st: ^Fx_Svf_State, x: []f32) {
	ic1, ic2 := st.ic1, st.ic2
	for &s in x {
		v0 := f64(s)
		v3 := v0 - ic2
		v1 := c.a1 * ic1 + c.a2 * v3
		v2 := ic2 + c.a2 * ic1 + c.a3 * v3
		ic1 = fx_flush(2 * v1 - ic1)
		ic2 = fx_flush(2 * v2 - ic2)
		s = f32(c.m0 * v0 + c.m1 * v1 + c.m2 * v2)
	}
	st.ic1, st.ic2 = ic1, ic2
}

// One filter stage whose cutoff moves: `g` holds each sample's warped
// cutoff (already scaled by the shape's g_scale).
@(private = "file")
fx_svf_pass_moving :: proc(s: Fx_Svf_Shape, g: []f64, st: ^Fx_Svf_State, x: []f32) {
	ic1, ic2 := st.ic1, st.ic2
	for &v, i in x {
		a1 := 1 / (1 + g[i] * (g[i] + s.k))
		a2 := g[i] * a1
		a3 := g[i] * a2
		v0 := f64(v)
		v3 := v0 - ic2
		v1 := a1 * ic1 + a2 * v3
		v2 := ic2 + a2 * ic1 + a3 * v3
		ic1 = fx_flush(2 * v1 - ic1)
		ic2 = fx_flush(2 * v2 - ic2)
		v = f32(s.m0 * v0 + s.m1 * v1 + s.m2 * v2)
	}
	st.ic1, st.ic2 = ic1, ic2
}

// ---- Filter, AutoFilter, EQ3 -------------------------------------------------------

@(private = "file")
Fx_Filter :: struct {
	scratch: Fx_Scratch,
	svf:     [2][4]Fx_Svf_State,
}

size_filter :: proc(p: ^Params) -> int {return fx_size_of(Fx_Filter)}
reset_filter :: proc(state: []u8, p: ^Params, at: i64) {fx_clear(state)}

// Tone's Filter: .Type at .Frequency with .Q, .Gain for shelves and peaks,
// cascaded by .Rolloff.
effect_filter :: proc(state: []u8, p: ^Params, l, r: []f32, key_l, key_r: []f32) {
	fx_run(state, p, l, r, key_l, key_r, proc(state: []u8, p: ^Params, l, r, _, _: []f32) {
		f := fx_header(state, Fx_Filter)
		c := fx_svf(FX_SVF_RULES[fx_filter_type(p[.Type])](f64(p[.Q]), f64(p[.Gain])), f64(p[.Frequency]))
		for k in 0 ..< dsp.rolloff_stages(p[.Rolloff]) {
			fx_svf_pass(c, &f.svf[0][k], l)
			fx_svf_pass(c, &f.svf[1][k], r)
		}
	})
}

@(private = "file")
Fx_Auto_Filter :: struct {
	scratch: Fx_Scratch,
	pos:     i64, // the song sample the next input is
	svf:     [2][4]Fx_Svf_State,
}

size_auto_filter :: proc(p: ^Params) -> int {return fx_size_of(Fx_Auto_Filter)}

reset_auto_filter :: proc(state: []u8, p: ^Params, at: i64) {
	fx_clear(state)
	fx_header(state, Fx_Auto_Filter).pos = at
}

// Tone's AutoFilter: a sine LFO at .Frequency (phase 0 at song sample 0)
// sweeps the filter's cutoff linearly between .Base_Frequency and
// .Base_Frequency * 2^.Octaves, around their midpoint by .Depth. The filter
// is .Filter_Type with .Filter_Q, cascaded by .Filter_Rolloff.
effect_auto_filter :: proc(state: []u8, p: ^Params, l, r: []f32, key_l, key_r: []f32) {
	fx_run(state, p, l, r, key_l, key_r, proc(state: []u8, p: ^Params, l, r, _, _: []f32) {
		f := fx_header(state, Fx_Auto_Filter)
		shape := FX_SVF_RULES[fx_filter_type(p[.Filter_Type])](f64(p[.Filter_Q]), 0)
		lo := f64(p[.Base_Frequency])
		hi := lo * math.pow(2, f64(p[.Octaves]))
		w := math.TAU * f64(p[.Frequency]) / RATE
		depth := f64(p[.Depth])
		g := f.scratch.d[:len(l)]
		for &v, i in g {
			v = fx_warp(lo + (hi - lo) * (0.5 + 0.5 * depth * math.sin(w * f64(f.pos + i64(i))))) * shape.g_scale
		}
		for k in 0 ..< dsp.rolloff_stages(p[.Filter_Rolloff]) {
			fx_svf_pass_moving(shape, g, &f.svf[0][k], l)
			fx_svf_pass_moving(shape, g, &f.svf[1][k], r)
		}
		f.pos += i64(len(l))
	})
}

@(private = "file")
Fx_EQ3 :: struct {
	scratch: Fx_Scratch,
	svf:     [2][9]Fx_Svf_State,
}

size_eq3 :: proc(p: ^Params) -> int {return fx_size_of(Fx_EQ3)}
reset_eq3 :: proc(state: []u8, p: ^Params, at: i64) {fx_clear(state)}

// Three bands, .Low, .Mid and .High (dB), split at .Low_Frequency and
// .High_Frequency by Linkwitz-Riley crossovers (two Butterworth stages),
// the low band through the high crossover's allpass so the bands sum flat:
// at 0 dB the EQ only shifts phase. (Tone splits with 12 dB filters whose
// sum notches at each crossover; this keeps its bands and gains.)
effect_eq3 :: proc(state: []u8, p: ^Params, l, r: []f32, key_l, key_r: []f32) {
	fx_run(state, p, l, r, key_l, key_r, proc(state: []u8, p: ^Params, l, r, _, _: []f32) {
		e := fx_header(state, Fx_EQ3)
		f1 := f64(p[.Low_Frequency])
		f2 := max(f64(p[.High_Frequency]), f1)
		lp1, hp1 := fx_svf(FX_BUTTERWORTH_LOW, f1), fx_svf(FX_BUTTERWORTH_HIGH, f1)
		lp2, hp2 := fx_svf(FX_BUTTERWORTH_LOW, f2), fx_svf(FX_BUTTERWORTH_HIGH, f2)
		ap2 := fx_svf(FX_BUTTERWORTH_ALL, f2)
		gl := f32(math.pow(10, f64(p[.Low]) / 20))
		gm := f32(math.pow(10, f64(p[.Mid]) / 20))
		gh := f32(math.pow(10, f64(p[.High]) / 20))
		low := e.scratch.a[:len(l)]
		mid := e.scratch.b[:len(l)]
		for x, c in ([2][]f32{l, r}) {
			s := &e.svf[c]
			copy(low, x)
			fx_svf_pass(lp1, &s[0], low)
			fx_svf_pass(lp1, &s[1], low)
			fx_svf_pass(ap2, &s[2], low)
			fx_svf_pass(hp1, &s[3], x)
			fx_svf_pass(hp1, &s[4], x)
			copy(mid, x)
			fx_svf_pass(lp2, &s[5], mid)
			fx_svf_pass(lp2, &s[6], mid)
			fx_svf_pass(hp2, &s[7], x)
			fx_svf_pass(hp2, &s[8], x)
			for &v, i in x {
				v = gl * low[i] + gm * mid[i] + gh * v
			}
		}
	})
}

// ---- Distortion --------------------------------------------------------------------

// The 2x oversampler: a linear-phase half-band FIR (a Blackman-windowed
// sinc at the half-sample offsets 0.5, 1.5, ..., summing to 1 over both
// sides) up, and the same filter down. Its two passes delay the output by
// FX_DISTORTION_LATENCY samples.
@(private = "file")
FX_HALFBAND_TAPS :: 16
@(private = "file")
FX_DISTORTION_LATENCY :: 2 * FX_HALFBAND_TAPS - 1
@(private = "file")
FX_DISTORTION_RING :: 512 // a chunk and both filters' spans
@(private = "file")
FX_DISTORTION_MASK :: FX_DISTORTION_RING - 1

@(private = "file")
fx_halfband :: proc() -> (h: [FX_HALFBAND_TAPS]f64) {
	sum: f64
	span := f64(FX_HALFBAND_TAPS) + 0.5
	for &v, k in h {
		x := f64(k) + 0.5
		win := 0.42 + 0.5 * math.cos(math.PI * x / span) + 0.08 * math.cos(2 * math.PI * x / span)
		v = math.sin(math.PI * x) / (math.PI * x) * win
		sum += 2 * v
	}
	for &v in h {
		v /= sum
	}
	return
}

// Tone's Distortion curve (its WaveShaper clamps the input to -1..1 first).
@(private = "file")
fx_curve :: #force_inline proc "contextless" (x, k: f64) -> f64 {
	DEG :: math.PI / 180
	v := clamp(x, -1, 1)
	return (3 + k) * v * 20 * DEG / (math.PI + k * abs(v))
}

@(private = "file")
Fx_Distortion :: struct {
	scratch: Fx_Scratch,
	count:   i64, // samples in since the reset
	input:   [2][FX_DISTORTION_RING]f32,
	half:    [2][FX_DISTORTION_RING]f32, // the shaped values at t + 0.5
}

size_distortion :: proc(p: ^Params) -> int {return fx_size_of(Fx_Distortion)}
reset_distortion :: proc(state: []u8, p: ^Params, at: i64) {fx_clear(state)}

// The oversampler's two half-band filters: 31 samples (0.65 ms).
latency_distortion :: proc(p: ^Params) -> int {return FX_DISTORTION_LATENCY}

// Tone's Distortion (.Distortion 0..1), 2x oversampled and causal: each
// half-sample point is interpolated once the 16 samples after it are in,
// the samples and the half points are shaped, and the result is low-passed
// back onto the samples, FX_DISTORTION_LATENCY samples late (the dry
// signal is delayed to match).
effect_distortion :: proc(state: []u8, p: ^Params, l, r: []f32, key_l, key_r: []f32) {
	fx_run(state, p, l, r, key_l, key_r, proc(state: []u8, p: ^Params, l, r, _, _: []f32) {
		D :: FX_DISTORTION_MASK
		d := fx_header(state, Fx_Distortion)
		k := f64(p[.Distortion]) * 100
		h := fx_halfband()
		dry := [2][]f32{d.scratch.dry_l[:len(l)], d.scratch.dry_r[:len(l)]}
		for x, c in ([2][]f32{l, r}) {
			input := &d.input[c]
			half := &d.half[c]
			// In, and the half point 16 samples back.
			for v, i in x {
				m := d.count + i64(i)
				input[m & D] = v
				t := m - FX_HALFBAND_TAPS
				sum: f64
				for tap, j in h {
					sum += tap * (f64(input[(t - i64(j)) & D]) + f64(input[(t + 1 + i64(j)) & D]))
				}
				half[t & D] = f32(fx_curve(sum, k))
			}
			// Out, FX_DISTORTION_LATENCY back.
			for &v, i in x {
				t := d.count + i64(i) - FX_DISTORTION_LATENCY
				sum := 0.5 * fx_curve(f64(input[t & D]), k)
				for tap, j in h {
					sum += 0.5 * tap * (f64(half[(t - 1 - i64(j)) & D]) + f64(half[(t + i64(j)) & D]))
				}
				dry[c][i] = input[t & D]
				v = f32(sum)
			}
		}
		d.count += i64(len(l))
	})
}

// ---- BitCrusher, StereoWidener -----------------------------------------------------

@(private = "file")
Fx_Stateless :: struct {
	scratch: Fx_Scratch,
}

size_bit_crusher :: proc(p: ^Params) -> int {return fx_size_of(Fx_Stateless)}
reset_bit_crusher :: proc(state: []u8, p: ^Params, at: i64) {fx_clear(state)}

// Tone's BitCrusher: each sample rounded to a step of 2^(1 - .Bits).
effect_bit_crusher :: proc(state: []u8, p: ^Params, l, r: []f32, key_l, key_r: []f32) {
	fx_run(state, p, l, r, key_l, key_r, proc(state: []u8, p: ^Params, l, r, _, _: []f32) {
		step := math.pow(0.5, f64(clamp(p[.Bits], 1, 16)) - 1)
		for x in ([2][]f32{l, r}) {
			for &s in x {
				s = f32(step * math.floor(f64(s) / step + 0.5))
			}
		}
	})
}

size_stereo_widener :: proc(p: ^Params) -> int {return fx_size_of(Fx_Stateless)}
reset_stereo_widener :: proc(state: []u8, p: ^Params, at: i64) {fx_clear(state)}

// Tone's StereoWidener: mid scaled by 2 (1 - .Width), side by 2 .Width, so
// 0.5 leaves the signal as it is, 0 is mono and 1 only the sides.
effect_stereo_widener :: proc(state: []u8, p: ^Params, l, r: []f32, key_l, key_r: []f32) {
	fx_run(state, p, l, r, key_l, key_r, proc(state: []u8, p: ^Params, l, r, _, _: []f32) {
		gm := 2 * (1 - p[.Width])
		gs := 2 * p[.Width]
		for i in 0 ..< len(l) {
			m := 0.5 * (l[i] + r[i]) * gm
			s := 0.5 * (l[i] - r[i]) * gs
			l[i], r[i] = m + s, m - s
		}
	})
}
