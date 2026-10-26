package odawg_dsp

import "core:math"

// Band-limited oscillators. An oscillator is a plain state struct (its wave
// and phase); `osc_run` fills a whole slice in one loop from a slice of
// phase increments (Hz / RATE per sample), so a sweep, a vibrato or FM is
// just a different increment slice. Waveforms start where Web Audio's do: at
// zero, rising (the square and pulse start high). Saw, square and pulse are
// polyBLEP-corrected and the triangle polyBLAMP-corrected, which removes
// most of the aliasing a naive waveform makes.

// The most copies a fat oscillator plays.
MAX_UNISON :: 16

Osc :: struct {
	wave:  Wave, // a fat wave plays as its plain one here; Unison makes it fat
	width: f32, // the pulse's duty cycle, 0..1
	phase: f64, // 0..1
}

// The 2-point polyBLEP residual for a step of height 2 at phase 0 (`t` the
// phase, `dt` the phase advance per sample).
poly_blep :: #force_inline proc "contextless" (t, dt: f64) -> f64 {
	if t < dt {
		x := t / dt
		return x + x - x * x - 1
	}
	if t > 1 - dt {
		x := (t - 1) / dt
		return x * x + x + x + 1
	}
	return 0
}

// The 2-point polyBLAMP residual (the polyBLEP's integral, in samples) for a
// unit change of slope per sample at phase 0: it rounds off a corner.
poly_blamp :: #force_inline proc "contextless" (t, dt: f64) -> f64 {
	if t < dt {
		x := 1 - t / dt
		return x * x * x / 6
	}
	if t > 1 - dt {
		x := 1 + (t - 1) / dt
		return x * x * x / 6
	}
	return 0
}

@(private = "file")
frac :: #force_inline proc "contextless" (x: f64) -> f64 {return x - math.floor(x)}

// Whether a wave is one of Tone's "fat" ones, and its plain shape.
wave_plain :: proc "contextless" (w: Wave) -> (plain: Wave, fat: bool) {
	#partial switch w {
	case .Fat_Sine:
		return .Sine, true
	case .Fat_Triangle:
		return .Triangle, true
	case .Fat_Sawtooth:
		return .Sawtooth, true
	case .Fat_Square:
		return .Square, true
	}
	return w, false
}

// Fills `out` with the oscillator at the increments `inc` (cycles per
// sample; they may be negative, as in deep FM, the phase wrapping either
// way). The pulse has its DC offset removed (and may take a per-sample duty
// cycle `widths`).
osc_run :: proc "contextless" (o: ^Osc, inc: []f64, out: []f32, widths: []f32 = nil) #no_bounds_check {
	plain, _ := wave_plain(o.wave)
	t := o.phase
	n := min(len(inc), len(out))
	switch plain {
	case .Sine, .Fat_Sine:
		for i in 0 ..< n {
			out[i] = sin_turns(t)
			t = wrap(t + inc[i])
		}
	case .Triangle, .Fat_Triangle:
		for i in 0 ..< n {
			dt := min(abs(inc[i]), 0.5)
			v := t < 0.25 ? 4 * t : (t < 0.75 ? 2 - 4 * t : 4 * t - 4)
			if dt > 0 {
				v += 8 * dt * (poly_blamp(wrap(t - 0.75), dt) - poly_blamp(wrap(t - 0.25), dt))
			}
			out[i] = f32(v)
			t = wrap(t + inc[i])
		}
	case .Sawtooth, .Fat_Sawtooth:
		for i in 0 ..< n {
			dt := min(abs(inc[i]), 0.5)
			s := wrap(t + 0.5)
			v := 2 * s - 1
			if dt > 0 {
				v -= poly_blep(s, dt)
			}
			out[i] = f32(v)
			t = wrap(t + inc[i])
		}
	case .Square, .Fat_Square, .Pulse:
		if plain == .Pulse && len(widths) >= n {
			for i in 0 ..< n {
				w := clamp(f64(widths[i]), 0.01, 0.99)
				dt := min(abs(inc[i]), 0.5)
				v: f64 = t < w ? 1 : -1
				if dt > 0 {
					v += poly_blep(t, dt) - poly_blep(wrap(t - w), dt)
				}
				out[i] = f32(v - (2 * w - 1))
				t = wrap(t + inc[i])
			}
		} else {
			w := plain == .Pulse ? clamp(f64(o.width), 0.01, 0.99) : 0.5
			dc := 2 * w - 1
			for i in 0 ..< n {
				dt := min(abs(inc[i]), 0.5)
				v: f64 = t < w ? 1 : -1
				if dt > 0 {
					v += poly_blep(t, dt) - poly_blep(wrap(t - w), dt)
				}
				out[i] = f32(v - dc)
				t = wrap(t + inc[i])
			}
		}
	}
	o.phase = t
}

// The naive (aliasing) waveform at a phase: the reference the tests hold the
// band-limited ones against.
naive_wave :: proc "contextless" (w: Wave, t: f64, width: f32 = 0.5) -> f32 {
	plain, _ := wave_plain(w)
	#partial switch plain {
	case .Sine:
		return f32(math.sin(math.TAU * t))
	case .Triangle:
		return f32(t < 0.25 ? 4 * t : (t < 0.75 ? 2 - 4 * t : 4 * t - 4))
	case .Sawtooth:
		return f32(2 * frac(t + 0.5) - 1)
	case .Square:
		return t < 0.5 ? 1 : -1
	case .Pulse:
		return t < f64(width) ? 1 : -1
	}
	return 0
}

// Tone's OmniOscillator: a plain wave is one copy at full level; a fat one
// is `count` copies detuned evenly over `spread` cents, their phases spread
// over the cycle, each at -6 - 1.1 count dB (FatOscillator's level). odawg
// also pans the copies from -stereo_width to +stereo_width (Tone's are
// mono), which leaves the mono sum unchanged.
Unison :: struct {
	oscs:   [MAX_UNISON]Osc,
	ratios: [MAX_UNISON]f64,
	left:   [MAX_UNISON]f32,
	right:  [MAX_UNISON]f32,
	count:  int,
}

unison_init :: proc(u: ^Unison, wave: Wave, count: int, spread, width: f32, stereo_width: f32 = 0.5) {
	u^ = {}
	_, fat := wave_plain(wave)
	u.count = fat ? clamp(count, 1, MAX_UNISON) : 1
	gain := fat ? f32(math.pow(10, (-6 - 1.1 * f64(u.count)) / 20)) : 1
	for i in 0 ..< u.count {
		u.oscs[i] = {wave = wave, width = width, phase = f64(i) / f64(u.count)}
		cents, pan: f32
		if u.count > 1 {
			x := f32(i) / f32(u.count - 1)
			cents = -spread / 2 + spread * x
			pan = stereo_width * (2 * x - 1)
		}
		u.ratios[i] = math.pow(2, f64(cents) / 1200)
		u.left[i], u.right[i] = (1 - pan) * gain, (1 + pan) * gain
	}
}

// Writes the copies' sum at `hz` (per sample) into l and r. `inc` and `tmp`
// are scratch as long as l; `widths` is an optional per-sample pulse duty
// cycle.
unison_run :: proc(u: ^Unison, hz: []f64, l, r: []f32, inc: []f64, tmp: []f32, widths: []f32 = nil) #no_bounds_check {
	n := min(len(l), len(r), len(hz), len(inc), len(tmp))
	for i in 0 ..< n {
		l[i], r[i] = 0, 0
	}
	for v in 0 ..< u.count {
		ratio := u.ratios[v] / RATE
		for i in 0 ..< n {
			inc[i] = hz[i] * ratio
		}
		osc_run(&u.oscs[v], inc[:n], tmp[:n], widths)
		gl, gr := u.left[v], u.right[v]
		for i in 0 ..< n {
			l[i] += tmp[i] * gl
			r[i] += tmp[i] * gr
		}
	}
}

// The waveforms the oscillators draw (fat ones are Unison's).
Wave :: enum u8 {
	Sine,
	Triangle,
	Sawtooth,
	Square,
	Pulse,
	Fat_Sine,
	Fat_Triangle,
	Fat_Sawtooth,
	Fat_Square,
}
