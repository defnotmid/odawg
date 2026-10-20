package odawg_device

import "core:math"

// The effects that remember: Reverb, FeedbackDelay, PingPongDelay, Chorus,
// and the tails they add after their input stops. Their delay lines are
// rings in the instance's state, indexed by the song sample.

// `ring` read `pos` (a song sample, fractional) with linear interpolation,
// as Web Audio's DelayNode reads.
@(private = "file")
fx_read_linear :: #force_inline proc "contextless" (ring: []f32, mask: i64, pos: f64) -> f64 {
	base := math.floor(pos)
	i := i64(base)
	a := f64(ring[i & mask])
	return a + (pos - base) * (f64(ring[(i + 1) & mask]) - a)
}

// `ring` read at `pos` with 4-point cubic (Hermite) interpolation.
@(private = "file")
fx_read_cubic :: #force_inline proc "contextless" (ring: []f32, mask: i64, pos: f64) -> f64 {
	base := math.floor(pos)
	i := i64(base)
	t := pos - base
	xm1, x0 := f64(ring[(i - 1) & mask]), f64(ring[i & mask])
	x1, x2 := f64(ring[(i + 1) & mask]), f64(ring[(i + 2) & mask])
	c1 := 0.5 * (x1 - xm1)
	c2 := xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
	c3 := 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
	return ((c3 * t + c2) * t + c1) * t + x0
}

// ---- Reverb --------------------------------------------------------------------------

// The reverb's eight feedback delay lines (samples at 48 kHz, 24 to 58 ms,
// coprime), its four input diffusers (Dattorro's lengths scaled to 48 kHz)
// and how much each diffuses.
@(private = "file")
FX_REVERB_LINES := [8]int{1153, 1327, 1559, 1801, 2039, 2251, 2503, 2797}
@(private = "file")
FX_REVERB_LINE_RING :: 4096
@(private = "file")
FX_REVERB_DIFFUSERS := [4]int{229, 173, 611, 447}
@(private = "file")
FX_REVERB_DIFFUSION := [4]f64{0.75, 0.75, 0.625, 0.625}
// The input's sign into each line (the outputs tap rows 1 and 2 of the
// Hadamard matrix: orthogonal, so left and right are decorrelated).
@(private = "file")
FX_REVERB_IN := [8]f64{1, -1, -1, 1, 1, 1, -1, -1}
// The high frequencies' RT60 as a fraction of .Decay (at Nyquist).
@(private = "file")
FX_REVERB_HF_RATIO :: 0.5
// The energy per second of an impulse response normalized as Web Audio's
// ConvolverNode does (RMS 10^(-58/20) * 44100 / 48000 per sample).
@(private = "file")
FX_REVERB_ENERGY :: 0.0642
// Each line's length wobbles by this many samples, slowly: its sine is
// exact every FX_REVERB_GRID samples of the song and linear between (a
// function of the song sample alone, so any block size gives the same
// samples).
@(private = "file")
FX_REVERB_MOD_DEPTH :: 3.0
@(private = "file")
FX_REVERB_GRID :: 256

#assert(FX_CHUNK + FX_REVERB_MOD_DEPTH + 2 < 1153) // a chunk reads its lines before writing them

@(private = "file")
Fx_Reverb :: struct {
	pos:          i64, // the song sample the next input is
	diffuser_pos: [4]int,
	z:            [8]f32, // the damping filters
	wobble_at:    i64, // the grid point `wobble` is for (-1: none yet)
	wobble:       [2][8]f32, // each line's wobble sine there and at the next grid point
	diffusers:    [4][1024]f32,
	lines:        [8][FX_REVERB_LINE_RING]f32,
	// then the pre-delay ring
}

// A line's wobble: its rate (Hz) and its sine at song sample `t`.
@(private = "file")
fx_wobble_rate :: proc "contextless" (i: int) -> f64 {return 0.13 + 0.071 * f64(i)}

@(private = "file")
fx_wobble_at :: proc "contextless" (i: int, t: i64) -> f32 {
	return f32(math.sin(f64(i) * 2.1 + math.TAU * fx_wobble_rate(i) * f64(t) / RATE))
}

size_reverb :: proc(p: ^Params) -> int {
	pre := int(math.round(f64(clamp(p[.Pre_Delay], 0, 1)) * RATE))
	return size_of(Fx_Reverb) + fx_pow2(pre + 1) * size_of(f32)
}

reset_reverb :: proc(state: []u8, p: ^Params, at: i64) {
	fx_clear(state)
	v := fx_header(state, Fx_Reverb)
	v.pos = at
	v.wobble_at = -1
}

// The reverb's decay (to -60 dB) after its pre-delay.
tail_reverb :: proc(p: ^Params) -> f64 {
	return f64(max(p[.Pre_Delay], 0)) + f64(max(p[.Decay], 0.01))
}

@(private = "file")
fx_flush32 :: #force_inline proc "contextless" (x: f32) -> f32 {return (x + 1e-18) - 1e-18}

// An algorithmic reverb. Stages per chunk: the input summed to mono and
// delayed by .Pre_Delay; four diffusing allpasses; an eight-line feedback
// delay network mixed by a Hadamard matrix. Each line's gain gives an RT60
// of .Decay at low frequencies, its one-pole damping a shorter one up
// high; its length wobbles a few samples (cubic interpolation) so the tail
// doesn't ring metallic. The two outputs tap the lines with orthogonal
// rows of the matrix. The level follows Tone's convolution reverb, whose
// impulse response Web Audio normalizes to a fixed power per sample: an
// impulse comes out with FX_REVERB_ENERGY per second of decay and
// pre-delay in each channel (the input gain divides by the loop's energy
// gain, which the damping lowers). Unlike Tone's, whose noise falls 60 dB
// sooner than its `decay`, .Decay here is the RT60.
//
// The network runs a stage at a time over the chunk, each line an array:
// every line's shortest delay is longer than a chunk, so all its reads come
// before any of its writes; only the damping is a recurrence.
effect_reverb :: proc(state: []u8, p: ^Params, l, r: []f32, key_l, key_r: []f32, scratch: ^Fx_Scratch) {
	fx_run(state, p, l, r, key_l, key_r, scratch, proc(state: []u8, p: ^Params, l, r, _, _: []f32, scratch: ^Fx_Scratch) {
		LINE :: FX_REVERB_LINE_RING - 1
		v := fx_header(state, Fx_Reverb)
		n := len(l)
		decay := max(f64(p[.Decay]), 0.01)
		pre_delay := max(f64(p[.Pre_Delay]), 0)
		ring_len := fx_ring_len(state, Fx_Reverb, 1)
		ring := fx_ring(state, Fx_Reverb, ring_len, 0)
		ring_mask := i64(ring_len - 1)
		pre := i64(min(int(math.round(pre_delay * RATE)), ring_len - 1))
		x := scratch.a[:n]

		// Mono, after the pre-delay.
		for &s, i in x {
			t := v.pos + i64(i)
			ring[t & ring_mask] = 0.5 * (l[i] + r[i])
			s = ring[(t - pre) & ring_mask]
		}
		// The diffusers, in stretches up to each one's end: a stretch reads
		// each slot once before writing it and none twice (the delay is longer
		// than any stretch), so its samples don't depend on each other.
		for length, d in FX_REVERB_DIFFUSERS {
			buf := v.diffusers[d][:length]
			g := f32(FX_REVERB_DIFFUSION[d])
			at := v.diffuser_pos[d]
			for i := 0; i < n; {
				m := min(n - i, length - at)
				slots, xs := buf[at:][:m], x[i:][:m]
				#no_bounds_check for j in 0 ..< m {
					delayed := slots[j]
					w := xs[j] + g * delayed
					xs[j] = delayed - g * w
					slots[j] = fx_flush32(w)
				}
				i += m
				at = at + m == length ? 0 : at + m
			}
			v.diffuser_pos[d] = at
		}
		// The coefficients, once a chunk.
		damp_a, damp_b: [8]f32
		loop_energy: f64 // a pass's energy gain through the damping, white input
		for d, k in FX_REVERB_LINES {
			g_dc := math.pow(10, -3 * f64(d) / (decay * RATE))
			g_ny := math.pow(10, -3 * f64(d) / (decay * FX_REVERB_HF_RATIO * RATE))
			a := (g_dc - g_ny) / (g_dc + g_ny)
			b := g_dc * (1 - a)
			damp_a[k], damp_b[k] = f32(a), f32(b)
			loop_energy += b * b / (1 - a * a) / 8
		}
		in_gain := f32(math.sqrt(FX_REVERB_ENERGY * (decay + pre_delay) * (1 - loop_energy) / loop_energy))
		norm := f32(1 / math.sqrt(f64(8)))
		// Each line's read offset (its wobble), by grid cell.
		offset: [8][FX_CHUNK]f32 = ---
		for i := 0; i < n; {
			t := v.pos + i64(i)
			g := t - (((t % FX_REVERB_GRID) + FX_REVERB_GRID) % FX_REVERB_GRID)
			if g != v.wobble_at {
				for k in 0 ..< 8 {
					v.wobble[0][k], v.wobble[1][k] = fx_wobble_at(k, g), fx_wobble_at(k, g + FX_REVERB_GRID)
				}
				v.wobble_at = g
			}
			m := min(n - i, int(g + FX_REVERB_GRID - t))
			f := f32(t - g)
			for k in 0 ..< 8 {
				s0 := v.wobble[0][k]
				ds := (v.wobble[1][k] - s0) / FX_REVERB_GRID
				for j in 0 ..< m {
					offset[k][i + j] = -FX_REVERB_MOD_DEPTH * (s0 + ds * (f + f32(j)))
				}
			}
			i += m
		}
		// Every line read (4-point cubic at its wobbling length). The offset is
		// within ±3: shifted positive, truncation floors it. Its whole part
		// changes seldom (the wobble is a few samples over seconds), so the
		// reads go in stretches of one whole offset whose taps stay inside the
		// ring: from one slice, in a loop that vectorizes.
		z: [8][FX_CHUNK]f32 = ---
		cubic :: #force_inline proc "contextless" (xm1, x0, x1, x2, t: f32) -> f32 {
			c1 := 0.5 * (x1 - xm1)
			c2 := xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
			c3 := 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
			return ((c3 * t + c2) * t + c1) * t + x0
		}
		for d, k in FX_REVERB_LINES {
			line := v.lines[k][:]
			first := v.pos - i64(d)
			out, off := z[k][:n], offset[k][:n]
			for i := 0; i < n; {
				o := off[i] + 8
				whole := i32(o)
				at := first + i64(i) + i64(whole) - 8
				lo := int((at - 1) & LINE) // sample i's first tap
				if lo + 3 > LINE {
					// its taps wrap around the ring
					out[i] = cubic(line[(at - 1) & LINE], line[at & LINE], line[(at + 1) & LINE], line[(at + 2) & LINE], o - f32(whole))
					i += 1
					continue
				}
				m := 1
				for i + m < n && lo + m + 3 <= LINE && i32(off[i + m] + 8) == whole {
					m += 1
				}
				taps, outs, offs := line[lo:][:m + 3], out[i:][:m], off[i:][:m]
				#no_bounds_check for j in 0 ..< m {
					outs[j] = cubic(taps[j], taps[j + 1], taps[j + 2], taps[j + 3], (offs[j] + 8) - f32(whole))
				}
				i += m
			}
		}
		// Then damped: the eight one-poles side by side, their recurrences
		// independent.
		zs := v.z
		for i in 0 ..< n {
			for k in 0 ..< 8 {
				zs[k] = fx_flush32(damp_b[k] * z[k][i] + damp_a[k] * zs[k])
				z[k][i] = zs[k]
			}
		}
		v.z = zs
		// The Hadamard matrix over the chunk, sample-parallel: rows 1 and 2
		// are the output taps, every row a line's feedback.
		for h := 1; h < 8; h *= 2 {
			for a := 0; a < 8; a += 2 * h {
				for k in a ..< a + h {
					p0, p1 := z[k][:n], z[k + h][:n]
					for i in 0 ..< n {
						m0, m1 := p0[i], p1[i]
						p0[i], p1[i] = m0 + m1, m0 - m1
					}
				}
			}
		}
		for i in 0 ..< n {
			l[i] = z[1][i] * norm
			r[i] = z[2][i] * norm
		}
		for k in 0 ..< 8 {
			line := v.lines[k][:]
			sign := f32(FX_REVERB_IN[k]) * in_gain
			for i in 0 ..< n {
				line[(v.pos + i64(i)) & LINE] = z[k][i] * norm + sign * x[i]
			}
		}
		v.pos += i64(n)
	})
}

// ---- delays --------------------------------------------------------------------------

@(private = "file")
Fx_Delay :: struct {
	pos:     i64, // the song sample the next input is
	// then two rings: left and right (FeedbackDelay), the two sends (PingPongDelay)
}

@(private = "file")
fx_delay_samples :: proc(p: ^Params) -> f64 {
	return clamp(f64(p[.Delay_Time]), 0, 10) * RATE
}

size_feedback_delay :: proc(p: ^Params) -> int {
	return size_of(Fx_Delay) + 2 * fx_pow2(int(fx_delay_samples(p)) + 3) * size_of(f32)
}

reset_feedback_delay :: proc(state: []u8, p: ^Params, at: i64) {
	fx_clear(state)
	fx_header(state, Fx_Delay).pos = at
}

// Tone's FeedbackDelay, per channel: the wet signal is the delay line's
// output (.Delay_Time), fed back into its input by .Feedback.
effect_feedback_delay :: proc(state: []u8, p: ^Params, l, r: []f32, key_l, key_r: []f32, scratch: ^Fx_Scratch) {
	fx_run(state, p, l, r, key_l, key_r, scratch, proc(state: []u8, p: ^Params, l, r, _, _: []f32, scratch: ^Fx_Scratch) {
		f := fx_header(state, Fx_Delay)
		ring_len := fx_ring_len(state, Fx_Delay, 2)
		mask := i64(ring_len - 1)
		d := clamp(fx_delay_samples(p), 1, f64(ring_len - 2))
		fb := f64(p[.Feedback])
		for x, c in ([2][]f32{l, r}) {
			ring := fx_ring(state, Fx_Delay, ring_len, c)
			for &s, i in x {
				t := f.pos + i64(i)
				w := fx_read_linear(ring, mask, f64(t) - d)
				ring[t & mask] = f32(f64(s) + fb * w)
				s = f32(w)
			}
		}
		f.pos += i64(len(l))
	})
}

size_ping_pong_delay :: proc(p: ^Params) -> int {
	return size_of(Fx_Delay) + 2 * fx_pow2(int(2 * fx_delay_samples(p)) + 3) * size_of(f32)
}

reset_ping_pong_delay :: proc(state: []u8, p: ^Params, at: i64) {
	fx_clear(state)
	fx_header(state, Fx_Delay).pos = at
}

// Tone's PingPongDelay: the left input delayed once by .Delay_Time, the
// right twice (Tone's pre-delay), and each side's echo fed into the other
// side's input by .Feedback. A centred sound echoes left, right, then both.
effect_ping_pong_delay :: proc(state: []u8, p: ^Params, l, r: []f32, key_l, key_r: []f32, scratch: ^Fx_Scratch) {
	fx_run(state, p, l, r, key_l, key_r, scratch, proc(state: []u8, p: ^Params, l, r, _, _: []f32, scratch: ^Fx_Scratch) {
		f := fx_header(state, Fx_Delay)
		ring_len := fx_ring_len(state, Fx_Delay, 2)
		mask := i64(ring_len - 1)
		d := clamp(fx_delay_samples(p), 1, f64(ring_len - 2) / 2)
		fb := f64(p[.Feedback])
		send_l := fx_ring(state, Fx_Delay, ring_len, 0)
		send_r := fx_ring(state, Fx_Delay, ring_len, 1)
		for i in 0 ..< len(l) {
			t := f.pos + i64(i)
			wl := fx_read_linear(send_l, mask, f64(t) - d)
			wr := fx_read_linear(send_r, mask, f64(t) - 2 * d)
			send_l[t & mask] = f32(f64(l[i]) + fb * wr)
			send_r[t & mask] = f32(f64(r[i]) + fb * wl)
			l[i], r[i] = f32(wl), f32(wr)
		}
		f.pos += i64(len(l))
	})
}

// A delay's echoes until they are 60 dB down (at most a minute). Counted
// at two delay times an echo, which a ping-pong needs; a FeedbackDelay is
// padded more than it sounds.
tail_delay :: proc(p: ^Params) -> f64 {
	d := f64(max(p[.Delay_Time], 0))
	fb := clamp(f64(p[.Feedback]), 0, 0.99)
	echoes := fb > 0.001 ? math.ceil(math.ln(f64(1e-3)) / math.ln(fb)) : 0
	return min(d + 2 * d * (echoes + 1), 60)
}

// ---- Chorus ------------------------------------------------------------------------

size_chorus :: proc(p: ^Params) -> int {
	longest := clamp(f64(p[.Delay_Time]), 0, 0.1) * RATE * (1 + f64(clamp(p[.Depth], 0, 1)))
	return size_of(Fx_Delay) + 2 * fx_pow2(int(longest) + 6) * size_of(f32)
}

reset_chorus :: proc(state: []u8, p: ^Params, at: i64) {
	fx_clear(state)
	fx_header(state, Fx_Delay).pos = at
}

// Tone's Chorus: each channel through its own delay, swept by a sine LFO at
// .Frequency (phase 0 at song sample 0) between .Delay_Time * (1 - .Depth)
// and .Delay_Time * (1 + .Depth), the right LFO half a cycle behind the
// left (Tone's spread of 180). Read with cubic interpolation.
effect_chorus :: proc(state: []u8, p: ^Params, l, r: []f32, key_l, key_r: []f32, scratch: ^Fx_Scratch) {
	fx_run(state, p, l, r, key_l, key_r, scratch, proc(state: []u8, p: ^Params, l, r, _, _: []f32, scratch: ^Fx_Scratch) {
		f := fx_header(state, Fx_Delay)
		ring_len := fx_ring_len(state, Fx_Delay, 2)
		mask := i64(ring_len - 1)
		base := f64(p[.Delay_Time]) * RATE
		dev := base * f64(p[.Depth])
		w := math.TAU * f64(p[.Frequency]) / RATE
		delay := scratch.d[:len(l)]
		for x, c in ([2][]f32{l, r}) {
			ring := fx_ring(state, Fx_Delay, ring_len, c)
			phase := c == 0 ? 0.0 : math.PI
			for &d, i in delay {
				d = clamp(base + dev * math.sin(w * f64(f.pos + i64(i)) + phase), 2, f64(ring_len - 4))
			}
			for &s, i in x {
				t := f.pos + i64(i)
				ring[t & mask] = s
				s = f32(fx_read_cubic(ring, mask, f64(t) - delay[i]))
			}
		}
		f.pos += i64(len(l))
	})
}

// The chorus's longest delay.
tail_chorus :: proc(p: ^Params) -> f64 {
	return f64(max(p[.Delay_Time], 0)) * (1 + f64(clamp(p[.Depth], 0, 1)))
}
