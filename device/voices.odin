package odawg_device

import dsp "../dsp"
import base "../base"
import "core:math"

// Tone's instruments, each a Voice_Proc of DEVICE_TABLE. A voice streams:
// each call plays the note's next len(l) samples, adding into l and r, with
// everything that carries from sample to sample (phases, envelope stages,
// filter memories, the noise generator) in its state struct over the
// Voice_State bytes. The first call (at == 0) reads the params and seed into
// that state; later calls read only the state, so the samples are the same
// however the note is split into calls. Inside a call the work runs in
// chunks of CHUNK samples through whole-slice stages (the pitch per sample,
// the oscillator, the filter, the envelope), on the stack. The gate closes at
// sample round(n.duration * RATE), inside a call if it falls there (0: the
// release starts at once, as in Tone); velocity scales the level linearly. A
// voice returns false once the note's tail (note_tail) is over.
//
// Where odawg differs from Tone:
//
//   - a fat oscillator's copies are spread across the stereo field;
//   - portamento is read but not played (a note plays alone, with no
//     previous note to glide from);
//   - MetalSynth is scaled by METAL_GAIN (Tone's six summed squares peak
//     near 4.5);
//   - PluckSynth's dampening low-pass sits inside the Karplus-Strong loop
//     (as in Tone 13), so high partials die first; its delay line holds
//     PLUCK_LINE samples, so notes below about 13 Hz play at 13 Hz.

// What MetalSynth's sum is scaled by.
METAL_GAIN :: 0.2

// The samples a voice works on at a time, on the stack.
CHUNK :: 256

// The bytes a DrumKit gives each of a pad's layers (inside its own state):
// every kind a pad can play keeps its state within it.
LAYER_STATE_SIZE :: 4096

// PluckSynth's delay line, in samples.
PLUCK_LINE :: 3584

// MetalSynth's six inharmonic partials (Tone's ratios).
@(private = "file")
METAL_RATIOS := [6]f64{1.0, 1.483, 1.932, 2.546, 2.630, 3.897}

// ---- shared steps ------------------------------------------------------------------

// A kind's state struct over a voice's bytes.
voice_state :: #force_inline proc "contextless" (s: ^Voice_State, $T: typeid) -> ^T {
	return (^T)(&s.bytes[0])
}

// The sample the gate closes at.
gate_sample :: proc "contextless" (n: Note) -> i64 {return i64(math.round(max(n.duration, 0) * RATE))}

// The note's last sample (exclusive): its tail.
tail_samples :: proc(kind: Device_Kind, p: ^Params, n: Note) -> i64 {
	return i64(math.ceil(note_tail(kind, p, n) * RATE))
}

// How many of this call's samples the note still sounds for.
voice_span :: proc "contextless" (at, total: i64, l, r: []f32) -> int {
	return int(clamp(total - at, 0, i64(min(len(l), len(r)))))
}

// The note's pitch in Hz, or the kind's own when it has none.
note_hz :: proc(kind: Device_Kind, n: Note) -> f64 {
	return base.midi_to_hz(f64(n.pitch > 0 ? n.pitch : DEFAULT_PITCH[kind]))
}

// The oscillator params' Unison (a fat type with no count plays three).
@(private = "file")
oscillator_init :: proc(u: ^dsp.Unison, p: ^Params, wave: dsp.Wave, stereo_width: f32 = 0.5) {
	count := int(p[.Oscillator_Count])
	dsp.unison_init(u, wave, count >= 1 ? count : 3, p[.Oscillator_Spread], p[.Oscillator_Width], stereo_width)
}

@(private = "file")
amplitude_init :: proc(p: ^Params, exponential_attack := false) -> dsp.Adsr {
	return adsr_from_params(p, .Envelope_Attack, .Envelope_Decay, .Envelope_Sustain, .Envelope_Release, exponential_attack)
}

@(private = "file")
fill :: proc "contextless" (x: []f64, v: f64) {
	for i in 0 ..< len(x) {
		x[i] = v
	}
}

// Adds sl, sr times a gain curve times `velocity` into l and r.
@(private = "file")
mix :: proc "contextless" (l, r, sl, sr, gain: []f32, velocity: f32) {
	for i in 0 ..< len(gain) {
		g := gain[i] * velocity
		l[i] += sl[i] * g
		r[i] += sr[i] * g
	}
}

// The release sample inside a chunk starting at note sample `from`.
@(private = "file")
release_in :: #force_inline proc "contextless" (gate, from: i64) -> int {
	d := gate - from
	return d >= 0 && d < CHUNK ? int(d) : -1
}

// ---- Synth -------------------------------------------------------------------------

@(private = "file")
Synth_State :: struct {
	osc:         dsp.Unison,
	env:         dsp.Adsr,
	hz:          f64,
	velocity:    f32,
	gate, total: i64,
}
#assert(size_of(Synth_State) <= LAYER_STATE_SIZE)

// Synth: the oscillator through the amplitude envelope.
voice_synth :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st := voice_state(s, Synth_State)
	if at == 0 {
		oscillator_init(&st.osc, p, dsp.Wave(u8(p[.Oscillator_Type])))
		st.env = amplitude_init(p)
		st.hz, st.velocity = note_hz(.Synth, n), n.velocity
		st.gate, st.total = gate_sample(n), tail_samples(.Synth, p, n)
	}
	count := voice_span(at, st.total, l, r)
	hz, inc: [CHUNK]f64
	sl, sr, tmp, g: [CHUNK]f32
	for off := 0; off < count; off += CHUNK {
		c := min(CHUNK, count - off)
		fill(hz[:c], st.hz)
		dsp.unison_run(&st.osc, hz[:c], sl[:c], sr[:c], inc[:c], tmp[:c])
		dsp.adsr_run(&st.env, g[:c], release_in(st.gate, at + i64(off)))
		mix(l[off:], r[off:], sl[:c], sr[:c], g[:c], st.velocity)
	}
	return at + i64(len(l)) < st.total
}

// ---- MonoSynth ---------------------------------------------------------------------

@(private = "file")
Mono_State :: struct {
	osc:           dsp.Unison,
	env, fenv:     dsp.Adsr,
	filter:        dsp.Filter_Chain,
	hz:            f64,
	lo, hi, shape: f32, // the cutoff's range and exponent
	velocity:      f32,
	gate, total:   i64,
}
#assert(size_of(Mono_State) <= LAYER_STATE_SIZE)

// MonoSynth: the oscillator through Tone's Filter, whose cutoff the filter
// envelope moves from base_frequency up `octaves` octaves (the envelope
// raised to `exponent`, scaled linearly between them as Tone's
// FrequencyEnvelope does), then the amplitude envelope.
voice_mono_synth :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st := voice_state(s, Mono_State)
	if at == 0 {
		oscillator_init(&st.osc, p, dsp.Wave(u8(p[.Oscillator_Type])))
		st.env = amplitude_init(p)
		st.fenv = adsr_from_params(p, .Filter_Envelope_Attack, .Filter_Envelope_Decay, .Filter_Envelope_Sustain, .Filter_Envelope_Release)
		st.filter = dsp.filter_chain_init(dsp.Filter_Type(u8(p[.Filter_Type])), p[.Filter_Q], p[.Filter_Rolloff], p[.Filter_Gain])
		st.lo = p[.Filter_Envelope_Base_Frequency]
		st.hi = st.lo * math.pow(2, p[.Filter_Envelope_Octaves])
		st.shape = p[.Filter_Envelope_Exponent]
		st.hz, st.velocity = note_hz(.Mono_Synth, n), n.velocity
		st.gate, st.total = gate_sample(n), tail_samples(.Mono_Synth, p, n)
	}
	count := voice_span(at, st.total, l, r)
	hz, inc: [CHUNK]f64
	sl, sr, tmp, g, cutoff: [CHUNK]f32
	coefficients: [CHUNK]dsp.Svf
	for off := 0; off < count; off += CHUNK {
		c := min(CHUNK, count - off)
		release := release_in(st.gate, at + i64(off))
		fill(hz[:c], st.hz)
		dsp.unison_run(&st.osc, hz[:c], sl[:c], sr[:c], inc[:c], tmp[:c])
		dsp.adsr_run(&st.fenv, cutoff[:c], release)
		for i in 0 ..< c {
			cutoff[i] = st.lo + (st.hi - st.lo) * math.pow(cutoff[i], st.shape)
		}
		dsp.filter_chain_coefficients(&st.filter, cutoff[:c], coefficients[:c])
		dsp.filter_chain_run_swept(&st.filter, coefficients[:c], sl[:c], 0)
		if st.osc.count > 1 {
			dsp.filter_chain_run_swept(&st.filter, coefficients[:c], sr[:c], 1)
		} else {
			copy(sr[:c], sl[:c])
		}
		dsp.adsr_run(&st.env, g[:c], release)
		mix(l[off:], r[off:], sl[:c], sr[:c], g[:c], st.velocity)
	}
	return at + i64(len(l)) < st.total
}

// ---- FMSynth and AMSynth -----------------------------------------------------------

@(private = "file")
Modulated_State :: struct {
	osc, mod:      dsp.Unison,
	env, mod_env:  dsp.Adsr,
	hz, depth, h:  f64,
	velocity:      f32,
	gate, total:   i64,
}
#assert(size_of(Modulated_State) <= LAYER_STATE_SIZE)

// The carrier and the modulator: Modulation_Type at harmonicity times the
// pitch, shaped by the modulation envelope (a fat type plays three copies 20
// cents apart, Tone's FatOscillator defaults).
@(private = "file")
modulated_init :: proc(st: ^Modulated_State, kind: Device_Kind, p: ^Params, n: Note) {
	oscillator_init(&st.osc, p, dsp.Wave(u8(p[.Oscillator_Type])))
	dsp.unison_init(&st.mod, dsp.Wave(u8(p[.Modulation_Type])), 3, 20, 0.5, 0)
	st.env = amplitude_init(p)
	st.mod_env = adsr_from_params(p, .Modulation_Envelope_Attack, .Modulation_Envelope_Decay, .Modulation_Envelope_Sustain, .Modulation_Envelope_Release)
	st.hz, st.h, st.velocity = note_hz(kind, n), f64(p[.Harmonicity]), n.velocity
	st.gate, st.total = gate_sample(n), tail_samples(kind, p, n)
}

// The modulator's next c samples, enveloped, into `mod`.
@(private = "file")
modulator_run :: proc(st: ^Modulated_State, release: int, mod, shape, scratch_r, tmp: []f32, hz, inc: []f64) {
	fill(hz, st.hz * st.h)
	dsp.unison_run(&st.mod, hz, mod, scratch_r, inc, tmp)
	dsp.adsr_run(&st.mod_env, shape, release)
	for i in 0 ..< len(mod) {
		mod[i] *= shape[i]
	}
}

// FMSynth: the modulator moves the carrier's frequency by modulation_index
// times the pitch (Tone wires modulationIndex x frequency into the
// modulation gain).
voice_fm_synth :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st := voice_state(s, Modulated_State)
	if at == 0 {
		modulated_init(st, .FM_Synth, p, n)
		st.depth = st.hz * f64(p[.Modulation_Index])
	}
	count := voice_span(at, st.total, l, r)
	hz, inc: [CHUNK]f64
	sl, sr, tmp, g, mod: [CHUNK]f32
	for off := 0; off < count; off += CHUNK {
		c := min(CHUNK, count - off)
		release := release_in(st.gate, at + i64(off))
		modulator_run(st, release, mod[:c], g[:c], sr[:c], tmp[:c], hz[:c], inc[:c])
		for i in 0 ..< c {
			hz[i] = st.hz + st.depth * f64(mod[i])
		}
		dsp.unison_run(&st.osc, hz[:c], sl[:c], sr[:c], inc[:c], tmp[:c])
		dsp.adsr_run(&st.env, g[:c], release)
		mix(l[off:], r[off:], sl[:c], sr[:c], g[:c], st.velocity)
	}
	return at + i64(len(l)) < st.total
}

// AMSynth: the modulator, mapped from -1..1 to 0..1 (Tone's AudioToGain),
// scales the carrier's level.
voice_am_synth :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st := voice_state(s, Modulated_State)
	if at == 0 {
		modulated_init(st, .AM_Synth, p, n)
	}
	count := voice_span(at, st.total, l, r)
	hz, inc: [CHUNK]f64
	sl, sr, tmp, g, mod: [CHUNK]f32
	for off := 0; off < count; off += CHUNK {
		c := min(CHUNK, count - off)
		release := release_in(st.gate, at + i64(off))
		modulator_run(st, release, mod[:c], g[:c], sr[:c], tmp[:c], hz[:c], inc[:c])
		fill(hz[:c], st.hz)
		dsp.unison_run(&st.osc, hz[:c], sl[:c], sr[:c], inc[:c], tmp[:c])
		dsp.adsr_run(&st.env, g[:c], release)
		for i in 0 ..< c {
			g[i] *= (mod[i] + 1) / 2
		}
		mix(l[off:], r[off:], sl[:c], sr[:c], g[:c], st.velocity)
	}
	return at + i64(len(l)) < st.total
}

// ---- MembraneSynth -----------------------------------------------------------------

@(private = "file")
Membrane_State :: struct {
	osc:              dsp.Unison,
	env:              dsp.Adsr,
	hz, start, sweep: f64,
	velocity:         f32,
	gate, total:      i64,
}
#assert(size_of(Membrane_State) <= LAYER_STATE_SIZE)

// MembraneSynth: the pitch starts `octaves` times higher (Tone multiplies
// the frequency by it) and falls exponentially to the note over
// pitch_decay; the attack is exponential.
voice_membrane_synth :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st := voice_state(s, Membrane_State)
	if at == 0 {
		oscillator_init(&st.osc, p, dsp.Wave(u8(p[.Oscillator_Type])))
		st.env = amplitude_init(p, exponential_attack = true)
		st.hz, st.velocity = note_hz(.Membrane_Synth, n), n.velocity
		st.start = st.hz * f64(max(p[.Octaves], 0.01))
		st.sweep = f64(p[.Pitch_Decay]) * RATE
		st.gate, st.total = gate_sample(n), tail_samples(.Membrane_Synth, p, n)
	}
	count := voice_span(at, st.total, l, r)
	hz, inc: [CHUNK]f64
	sl, sr, tmp, g: [CHUNK]f32
	for off := 0; off < count; off += CHUNK {
		c := min(CHUNK, count - off)
		for i in 0 ..< c {
			k := f64(at + i64(off + i))
			hz[i] = k < st.sweep ? st.start * math.pow(st.hz / st.start, k / st.sweep) : st.hz
		}
		dsp.unison_run(&st.osc, hz[:c], sl[:c], sr[:c], inc[:c], tmp[:c])
		dsp.adsr_run(&st.env, g[:c], release_in(st.gate, at + i64(off)))
		mix(l[off:], r[off:], sl[:c], sr[:c], g[:c], st.velocity)
	}
	return at + i64(len(l)) < st.total
}

// ---- MetalSynth --------------------------------------------------------------------

@(private = "file")
Metal_State :: struct {
	carriers, modulators: [len(METAL_RATIOS)]dsp.Osc,
	env:                  dsp.Adsr,
	filter:               dsp.Filter_Chain,
	hz, h, index:         f64,
	res, top, gain:       f32,
	gate, total:          i64,
}
#assert(size_of(Metal_State) <= LAYER_STATE_SIZE)

// MetalSynth: six FM pairs of squares at inharmonic ratios of the pitch
// (harmonicity and modulation_index as in FMSynth), summed through a
// high-pass whose cutoff the envelope sweeps from `resonance` up `octaves`
// octaves (scaled linearly), and the same envelope on the level.
voice_metal_synth :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st := voice_state(s, Metal_State)
	if at == 0 {
		for i in 0 ..< len(METAL_RATIOS) {
			st.carriers[i].wave, st.modulators[i].wave = .Square, .Square
		}
		st.env = amplitude_init(p)
		st.filter = dsp.filter_chain_init(.Highpass, 0, -12, 0)
		st.hz, st.h, st.index = note_hz(.Metal_Synth, n), f64(p[.Harmonicity]), f64(p[.Modulation_Index])
		st.res = p[.Resonance]
		st.top = st.res * math.pow(2, p[.Octaves])
		st.gain = n.velocity * METAL_GAIN
		st.gate, st.total = gate_sample(n), tail_samples(.Metal_Synth, p, n)
	}
	count := voice_span(at, st.total, l, r)
	inc: [CHUNK]f64
	sum, mod, car, shape, cutoff: [CHUNK]f32
	coefficients: [CHUNK]dsp.Svf
	for off := 0; off < count; off += CHUNK {
		c := min(CHUNK, count - off)
		for i in 0 ..< c {
			sum[i] = 0
		}
		for ratio, j in METAL_RATIOS {
			f := st.hz * ratio
			fill(inc[:c], f * st.h / RATE)
			dsp.osc_run(&st.modulators[j], inc[:c], mod[:c])
			for i in 0 ..< c {
				inc[i] = (f + f * st.index * f64(mod[i])) / RATE
			}
			dsp.osc_run(&st.carriers[j], inc[:c], car[:c])
			for i in 0 ..< c {
				sum[i] += car[i]
			}
		}
		dsp.adsr_run(&st.env, shape[:c], release_in(st.gate, at + i64(off)))
		for i in 0 ..< c {
			cutoff[i] = st.res + (st.top - st.res) * shape[i]
		}
		dsp.filter_chain_coefficients(&st.filter, cutoff[:c], coefficients[:c])
		dsp.filter_chain_run_swept(&st.filter, coefficients[:c], sum[:c])
		for i in 0 ..< c {
			v := sum[i] * shape[i] * st.gain
			l[off + i] += v
			r[off + i] += v
		}
	}
	return at + i64(len(l)) < st.total
}

// ---- NoiseSynth --------------------------------------------------------------------

@(private = "file")
Noise_State :: struct {
	noise:       dsp.Noise,
	env:         dsp.Adsr,
	velocity:    f32,
	gate, total: i64,
}
#assert(size_of(Noise_State) <= LAYER_STATE_SIZE)

// NoiseSynth: white, pink or brown noise through the amplitude envelope.
voice_noise_synth :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st := voice_state(s, Noise_State)
	if at == 0 {
		st.noise = dsp.noise_init(dsp.Noise_Type(u8(p[.Noise_Type])), seed)
		st.env = amplitude_init(p)
		st.velocity = n.velocity
		st.gate, st.total = gate_sample(n), tail_samples(.Noise_Synth, p, n)
	}
	count := voice_span(at, st.total, l, r)
	x, g: [CHUNK]f32
	for off := 0; off < count; off += CHUNK {
		c := min(CHUNK, count - off)
		dsp.noise_run(&st.noise, x[:c])
		dsp.adsr_run(&st.env, g[:c], release_in(st.gate, at + i64(off)))
		mix(l[off:], r[off:], x[:c], x[:c], g[:c], st.velocity)
	}
	return at + i64(len(l)) < st.total
}

// ---- PluckSynth --------------------------------------------------------------------

@(private = "file")
Pluck_State :: struct {
	line:            [PLUCK_LINE]f32,
	noise:           dsp.Noise,
	delay:           f64,
	mean:            f32, // the burst's, taken out of it
	k, y, resonance: f32,
	velocity:        f32,
	release:         f64, // samples
	size, write:     int,
	burst:           i64,
	gate, total:     i64,
}
#assert(size_of(Pluck_State) <= VOICE_STATE_SIZE)

// PluckSynth: Karplus-Strong. A burst of pink noise `attack_noise` periods
// long excites a delay line one period long whose output feeds back through
// a one-pole low-pass at `dampening` Hz, `resonance` times per pass; when
// the gate closes the feedback ramps to nothing over `release`. The delay is
// shortened by the low-pass's own delay at the pitch, so the note is in tune,
// and the burst has its mean taken out (the loop would hold a DC offset
// longer than the tone).
voice_pluck_synth :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st := voice_state(s, Pluck_State)
	if at == 0 {
		f := max(note_hz(.Pluck_Synth, n), RATE / f64(PLUCK_LINE - 2))
		period := RATE / f
		k := dsp.one_pole_k(f64(p[.Dampening]))
		w := math.TAU * f / RATE
		lp_delay := math.atan2((1 - k) * math.sin(w), 1 - (1 - k) * math.cos(w)) / w
		st.delay = max(period - lp_delay, 1)
		st.size = int(math.ceil(st.delay)) + 2
		st.k, st.resonance, st.velocity = f32(k), p[.Resonance], n.velocity
		st.release = max(f64(p[.Release]) * RATE, 1)
		st.burst = i64(f64(p[.Attack_Noise]) * period)
		st.gate, st.total = gate_sample(n), tail_samples(.Pluck_Synth, p, n)
		st.noise = dsp.noise_init(.Pink, seed)
		// The burst's mean, from a copy of the generator that plays it.
		probe := st.noise
		chunk: [CHUNK]f32
		sum: f64
		for done: i64 = 0; done < st.burst; done += CHUNK {
			c := int(min(CHUNK, st.burst - done))
			dsp.noise_run(&probe, chunk[:c])
			for v in chunk[:c] {
				sum += f64(v)
			}
		}
		st.mean = f32(sum / f64(max(st.burst, 1)))
	}
	count := voice_span(at, st.total, l, r)
	excite: [CHUNK]f32
	for off := 0; off < count; off += CHUNK {
		c := min(CHUNK, count - off)
		from := at + i64(off)
		burst := int(clamp(st.burst - from, 0, i64(c)))
		dsp.noise_run(&st.noise, excite[:burst])
		for i in 0 ..< burst {
			excite[i] -= st.mean
		}
		for i in burst ..< c {
			excite[i] = 0
		}
		for i in 0 ..< c {
			k := from + i64(i)
			fade := k < st.gate ? 1 : max(0, 1 - f64(k - st.gate) / st.release)
			pos := f64(st.write) - st.delay
			if pos < 0 {
				pos += f64(st.size)
			}
			i0 := int(pos)
			fr := f32(pos - f64(i0))
			delayed := st.line[i0 % st.size] * (1 - fr) + st.line[(i0 + 1) % st.size] * fr
			st.y += st.k * (delayed - st.y)
			v := excite[i] + st.resonance * f32(fade) * st.y
			st.line[st.write] = v
			st.write = st.write + 1 == st.size ? 0 : st.write + 1
			l[off + i] += v * st.velocity
			r[off + i] += v * st.velocity
		}
	}
	return at + i64(len(l)) < st.total
}

// PluckSynth's tail: the burst, then the string ringing until the release
// has taken its feedback away or it has fallen 80 dB.
tail_pluck_synth :: proc(p: ^Params, n: Note) -> f64 {
	period := 1 / note_hz(.Pluck_Synth, n)
	res := f64(p[.Resonance])
	ring := 30.0
	if res <= 0 {
		ring = 0
	} else if res < 1 {
		ring = math.ln(f64(1e-4)) / math.ln(res) * period
	}
	return f64(p[.Attack_Noise]) * period + min(max(n.duration, 0) + f64(p[.Release]), ring) + period
}

// An envelope from four params (attack, decay, sustain, release), triggered.
adsr_from_params :: proc(p: ^Params, attack, decay, sustain, release: Param, exponential_attack := false) -> dsp.Adsr {
	return {
		attack = max(p[attack], 0),
		decay = max(p[decay], 0),
		sustain = clamp(p[sustain], 0, 1),
		release = max(p[release], 0),
		exponential_attack = exponential_attack,
		stage = .Attack,
	}
}
