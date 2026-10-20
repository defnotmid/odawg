package odawg_device

import "core:math"

// The effects that follow a level: Compressor, Gate and the Limiter (also
// the master limiter). Each chunk runs in stages: the key's level, the gain
// the curve wants, its smoothing in time (carried across blocks), then the
// gain applied.

// The louder key channel's level in dB, per sample (stereo-linked).
@(private = "file")
fx_level_db :: proc(key_l, key_r: []f32, out: []f32) {
	for &v, i in out {
		k := max(abs(key_l[i]), abs(key_r[i]))
		v = k > 1e-10 ? f32(20 * math.log10(f64(k))) : -200
	}
}

// ---- Compressor --------------------------------------------------------------------

@(private)
Fx_Compressor :: struct {
	held, reduction: f64, // dB taken off, >= 0
}


// A soft-knee compressor after Giannoulis, Massberg and Reiss: the key's
// level (stereo-linked) through the static curve (.Threshold, .Ratio, .Knee
// in dB), and the gain reduction through their smooth decoupled peak
// detector (it rises at once and falls over .Release, then is smoothed
// over .Attack), so a steady tone is held at the curve's level rather than
// rippling between its peaks. Unlike Web Audio's DynamicsCompressorNode
// there is no automatic makeup gain.
effect_compressor :: proc(state: []u8, p: ^Params, l, r: []f32, key_l, key_r: []f32, scratch: ^Fx_Scratch) {
	fx_run(state, p, l, r, key_l, key_r, scratch, proc(state: []u8, p: ^Params, l, r, key_l, key_r: []f32, scratch: ^Fx_Scratch) {
		c := fx_header(state, Fx_Compressor)
		t := f64(p[.Threshold])
		ratio := max(f64(p[.Ratio]), 1)
		knee := max(f64(p[.Knee]), 0)
		work := scratch.a[:len(l)]

		fx_level_db(key_l, key_r, work)
		// The static curve: how many dB each sample wants taken off.
		for &v in work {
			x := f64(v)
			y := x
			over := x - t
			if 2 * over > knee {
				y = t + over / ratio
			} else if knee > 0 && 2 * over > -knee {
				d := over + knee / 2
				y = x + (1 / ratio - 1) * d * d / (2 * knee)
			}
			v = f32(x - y)
		}
		// The detector: hold with release, then smooth with attack.
		att := fx_time_coef(p[.Attack])
		rel := fx_time_coef(p[.Release])
		held, reduction := c.held, c.reduction
		for &v in work {
			want := f64(v)
			held = fx_flush(max(want, rel * held + (1 - rel) * want))
			reduction = fx_flush(att * reduction + (1 - att) * held)
			v = f32(math.pow(10, -reduction / 20))
		}
		c.held, c.reduction = held, reduction
		for g, i in work {
			l[i] *= g
			r[i] *= g
		}
	})
}

// ---- Gate --------------------------------------------------------------------------

@(private)
Fx_Gate :: struct {
	env:     f32,
	gain:    f64,
}


// A gate: a peak follower on the louder key channel (instant rise, 20 ms
// fall) opens it above .Threshold (dB); its gain opens over .Attack and
// closes over .Release.
effect_gate :: proc(state: []u8, p: ^Params, l, r: []f32, key_l, key_r: []f32, scratch: ^Fx_Scratch) {
	fx_run(state, p, l, r, key_l, key_r, scratch, proc(state: []u8, p: ^Params, l, r, key_l, key_r: []f32, scratch: ^Fx_Scratch) {
		g := fx_header(state, Fx_Gate)
		work := scratch.a[:len(l)]
		// The follower, then whether the gate wants to be open.
		fall := f32(fx_time_coef(0.02))
		open_level := f32(math.pow(10, f64(p[.Threshold]) / 20))
		env := g.env
		for &v, i in work {
			k := max(abs(key_l[i]), abs(key_r[i]))
			env = k > env ? k : env * fall
			env = env < 1e-30 ? 0 : env
			v = env > open_level ? 1 : 0
		}
		g.env = env
		// The gain moving toward it.
		att := fx_time_coef(p[.Attack])
		rel := fx_time_coef(p[.Release])
		gain := g.gain
		for &v in work {
			target := f64(v)
			coef := target > gain ? att : rel
			gain = fx_flush(target + coef * (gain - target))
			v = f32(gain)
		}
		g.gain = gain
		for v, i in work {
			l[i] *= v
			r[i] *= v
		}
	})
}

// ---- Limiter -----------------------------------------------------------------------

// The limiter's lookahead window, its inter-sample peak kernel (true
// peak's: Lanczos, a = 8, at the three phases between samples, as analyze
// reads it), and its latency: the window, plus the 8 samples a peak
// between two samples needs after it.
@(private = "file")
FX_LIMITER_WINDOW :: 240 // 5 ms
@(private = "file")
FX_TAPS :: 8
@(private = "file")
FX_LIMITER_LATENCY :: FX_LIMITER_WINDOW + FX_TAPS - 1
@(private = "file")
FX_LIMITER_RING :: 1024 // a chunk, the latency and the kernel's span
@(private = "file")
FX_LIMITER_MASK :: FX_LIMITER_RING - 1

@(private = "file")
fx_peak_kernel :: proc() -> (kernel: [3][2 * FX_TAPS]f32) {
	for ph in 0 ..< 3 {
		frac := f64(ph + 1) / 4
		for &v, k in kernel[ph] {
			x := f64(k - FX_TAPS + 1) - frac
			v = 1
			if x != 0 {
				px := math.PI * x
				v = f32(FX_TAPS * math.sin(px) * math.sin(px / FX_TAPS) / (px * px))
			}
		}
	}
	return
}

@(private)
Fx_Limiter :: struct {
	pos:        i64, // the song sample the next input is
	released:   f64,
	sum:        f64, // of `hold`
	prev_inter: f32,
	head, size: int, // the window minimum's deque
	input:      [2][FX_LIMITER_RING]f32,
	dq_pos:     [FX_LIMITER_WINDOW + 1]i64,
	dq_gain:    [FX_LIMITER_WINDOW + 1]f64,
	hold:       [FX_LIMITER_WINDOW]f64, // the last window minima, for the average
}



// What a reset sets past zero: nothing released, the window's minima at 1.
@(private)
init_limiter :: proc(state: []u8) {
	f := fx_header(state, Fx_Limiter)
	f.released = 1
	f.sum = FX_LIMITER_WINDOW
	for &h in f.hold {
		h = 1
	}
}

// The lookahead: 247 samples (5.1 ms) at 48 kHz.
latency_limiter :: proc(p: ^Params) -> int {return FX_LIMITER_LATENCY}

// The limiter adds nothing after its input beyond its latency.
tail_limiter :: proc(p: ^Params) -> f64 {return 0}

// A lookahead brickwall limiter whose output's true peak stays at
// .Threshold (dB), FX_LIMITER_LATENCY samples late (the dry signal is
// delayed to match). Stages per chunk: the input into the ring; each
// sample's peak (its own level or the interpolated peak on either side of
// it, whichever is larger) and the gain it needs; that gain recovering
// toward 1 over .Release, its minimum over the 5 ms window and that
// minimum averaged over the window again, a ramp that reaches every peak's
// gain before the peak; the delayed input times the ramp.
effect_limiter :: proc(state: []u8, p: ^Params, l, r: []f32, key_l, key_r: []f32, scratch: ^Fx_Scratch) {
	fx_run(state, p, l, r, key_l, key_r, scratch, proc(state: []u8, p: ^Params, l, r, _, _: []f32, scratch: ^Fx_Scratch) {
		W :: FX_LIMITER_WINDOW
		M :: FX_LIMITER_MASK
		CAP :: W + 1
		f := fx_header(state, Fx_Limiter)
		n := len(l)
		ceiling := f32(math.pow(10, f64(p[.Threshold]) / 20))
		kernel := fx_peak_kernel()
		gain := scratch.d[:n]

		for i in 0 ..< n {
			f.input[0][(f.pos + i64(i)) & M] = l[i]
			f.input[1][(f.pos + i64(i)) & M] = r[i]
		}
		// The peak around sample j = pos - FX_TAPS, once the samples after it are in.
		for &g, i in gain {
			j := f.pos + i64(i) - FX_TAPS
			inter: f32
			for c in 0 ..< 2 {
				x := &f.input[c]
				for ph in 0 ..< 3 {
					sum: f32
					for tap, k in kernel[ph] {
						sum += x[(j - FX_TAPS + 1 + i64(k)) & M] * tap
					}
					inter = max(inter, abs(sum))
				}
			}
			peak := max(abs(f.input[0][j & M]), abs(f.input[1][j & M]), inter, f.prev_inter)
			f.prev_inter = inter
			g = peak > ceiling ? f64(ceiling) / f64(peak) : 1
		}
		// Release, the window minimum, its average.
		rel := fx_time_coef(p[.Release])
		for &g, i in gain {
			j := f.pos + i64(i) - FX_TAPS
			f.released = min(g, 1 - (1 - f.released) * rel)
			for f.size > 0 && f.dq_gain[(f.head + f.size - 1) % CAP] >= f.released {
				f.size -= 1
			}
			f.dq_pos[(f.head + f.size) % CAP] = j
			f.dq_gain[(f.head + f.size) % CAP] = f.released
			f.size += 1
			for f.dq_pos[f.head] <= j - W {
				f.head = (f.head + 1) % CAP
				f.size -= 1
			}
			minimum := f.dq_gain[f.head]
			slot := int(((j % W) + W) % W)
			f.sum += minimum - f.hold[slot]
			f.hold[slot] = minimum
			if slot == W - 1 {
				f.sum = 0 // recomputed now and then so rounding doesn't drift
				for h in f.hold {
					f.sum += h
				}
			}
			g = min(f.sum / W, 1)
		}
		// Out: the input FX_LIMITER_LATENCY back, times the ramp.
		for i in 0 ..< n {
			k := (f.pos + i64(i) - FX_LIMITER_LATENCY) & M
			scratch.dry_l[i] = f.input[0][k]
			scratch.dry_r[i] = f.input[1][k]
			l[i] = f.input[0][k] * f32(gain[i])
			r[i] = f.input[1][k] * f32(gain[i])
		}
		f.pos += i64(n)
	})
}
