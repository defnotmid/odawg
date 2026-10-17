package odawg_device

import dsp "../dsp"
import base "../base"
import "core:math"

// The presets: the voices of onimite's examples/common/synth.lua, ported
// note for note (the same math, constants, pans and lengths), a snare and a
// sub bass, and the DrumKit's pads. What differs from synth.lua:
//
//   - noise and random phases come from the note's seed, not math.random,
//     and glitch's grain pitches too (synth.lua hashed g + t0);
//   - synth.lua's `gain` is the note's velocity, its `dur` the note's
//     duration where it takes one, its `hz` or `note` the note's pitch;
//   - the sidechain (`duck`) is left out: the engine applies it per track;
//   - chord is two presets, `pad` and `stab`, each playing one note of it,
//     and tape_chord plays one note too (a chord is several notes);
//   - each voice streams: its loop's memories live in its state, and its
//     times come from the note's sample, so a note split into any calls
//     plays the same samples;
//   - the knobs cutoff, cutoff2, decay, tone and envelope/attack replace the
//     preset's constant when they are not 0.
//
// Pans follow onimite's audio_buffer: left 1 - pan, right 1 + pan.


// What a voice plays when the note gives no pitch (a drum pad), in MIDI;
// kinds not listed here choose their own.
DEFAULT_PITCH := #partial [Device_Kind]f32 {
	.Synth          = 60,
	.Mono_Synth     = 60,
	.FM_Synth       = 60,
	.AM_Synth       = 60,
	.Membrane_Synth = 36, // C2
	.Metal_Synth    = 55.35, // Tone's 200 Hz
	.Noise_Synth    = 60,
	.Pluck_Synth    = 60,
	.Drum_Kit       = 0,
	.Sampler        = 60,
	.Kick           = 0,
	.Snare          = 54.6, // 190 Hz
	.Clap           = 0,
	.Hat            = 0,
	.Open_Hat       = 0,
	.Crash          = 0,
	.Bass           = 36,
	.Sub_Bass       = 36,
	.Pad            = 60,
	.Stab           = 60,
	.Pluck          = 72,
	.Lead           = 72,
	.Bell           = 84,
	.Riser          = 0,
	.Whoosh         = 0,
	.Impact         = 0,
	.Tom            = 45, // 110 Hz
	.Thump          = 33,
	.Fall           = 57, // 220 Hz, falling to 14.7
	.Tape_Chord     = 60,
	.Tick           = 100.1, // 2600 Hz
	.Beep           = 81, // 880 Hz
	.Crackle        = 0,
	.Glitch         = 0,
	.Blip           = 88.02, // 1320 Hz
	.Done           = 88.02, // 1320 Hz, then a fifth up
	// Effects play no notes.
	.Filter          = 0,
	.EQ3             = 0,
	.Compressor      = 0,
	.Limiter         = 0,
	.Gate            = 0,
	.Reverb          = 0,
	.Feedback_Delay  = 0,
	.Ping_Pong_Delay = 0,
	.Chorus          = 0,
	.Distortion      = 0,
	.Bit_Crusher     = 0,
	.Stereo_Widener  = 0,
	.Auto_Filter     = 0,
}

@(private = "file")
SUB_BASS_RELEASE :: 0.08

@(private = "file")
DONE_GAP :: 0.12

@(private = "file")
TAU :: math.TAU

// A knob's value, or the preset's own when it is 0.
@(private = "file")
knob :: proc(p: ^Params, k: Param, own: f64) -> f64 {return p[k] != 0 ? f64(p[k]) : own}

// synth.lua's note(dur): the sample count.
@(private = "file")
samples :: proc(dur: f64) -> i64 {return max(0, i64(math.floor(dur * RATE)))}

@(private = "file")
midi :: proc(kind: Device_Kind, n: Note) -> f64 {return f64(n.pitch > 0 ? n.pitch : DEFAULT_PITCH[kind])}

@(private = "file")
pan_gains :: proc(pan: f64) -> (gl, gr: f64) {return 1 - pan, 1 + pan}

// A port's state: what synth.lua's loop keeps between samples (phases,
// filter memories, the noise generator), what it reads once (rates,
// cutoffs, the gain), and its length. One struct serves every port; each
// uses the fields its loop names.
@(private = "file")
Port_State :: struct {
	rng:                base.Rng,
	ph, ph2, ph3, y, y2: f64, // phases and filter memories
	prev, prev2:        f64, // high-pass memories
	f, f2:              f64, // phase increments or Hz
	k0, k1:             f64, // one-pole coefficients
	decay, attack:      f64,
	tone, lo, hi:       f64,
	gain:               f64,
	pan:                f64,
	count:              i64, // synth.lua's n: the samples it plays
	gate:               i64,
	band:               dsp.Svf,
	band_state:         dsp.Svf_State,
	grain:              f64, // glitch: a grain's length in samples
	grain_hz:           [8]f64,
}
#assert(size_of(Port_State) <= LAYER_STATE_SIZE)

// The port's state, started on the first call.
@(private = "file")
port :: proc(s: ^Voice_State, n: Note, seed: u64, at: i64) -> (st: ^Port_State, first: bool) {
	st = voice_state(s, Port_State)
	if at == 0 {
		st.rng = base.rng_init(seed)
		st.gain = f64(n.velocity)
	}
	return st, at == 0
}

// Samples this call plays of the port's count, and whether it sounds after.
@(private = "file")
port_span :: proc(st: ^Port_State, at: i64, l, r: []f32) -> (count: int, more: bool) {
	return voice_span(at, st.count, l, r), at + i64(min(len(l), len(r))) < st.count
}

// ---- synth.lua's voices ------------------------------------------------------------

// A sine with a fast pitch drop (178 Hz falling to 48) and an exponential
// decay, plus a click.
voice_kick :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count = samples(0.4)
	}
	count, more := port_span(st, at, l, r)
	w: [CHUNK]f32
	for off := 0; off < count; off += CHUNK {
		c := min(CHUNK, count - off)
		dsp.white_run(&st.rng, w[:c])
		for i in 0 ..< c {
			t := f64(at + i64(off + i)) / RATE
			st.ph += TAU * (48 + 130 * math.exp(-t * 30)) / RATE
			v := f32((math.sin(st.ph) * math.exp(-t * 7) + f64(w[i]) * math.exp(-t * 600) * 0.25) * st.gain)
			l[off + i] += v
			r[off + i] += v
		}
	}
	return more
}

// Three quick high-passed noise bursts and a tail, over a short tone body.
voice_clap :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count = samples(0.3)
	}
	count, more := port_span(st, at, l, r)
	gl, gr := pan_gains(-0.05)
	w: [CHUNK]f32
	for off := 0; off < count; off += CHUNK {
		c := min(CHUNK, count - off)
		dsp.white_run(&st.rng, w[:c])
		for i in 0 ..< c {
			t := f64(at + i64(off + i)) / RATE
			hp := f64(w[i]) - st.prev
			st.prev = f64(w[i])
			bursts := t < 0.033 ? math.exp(-math.mod(t, 0.011) * 300) : 0
			st.ph += TAU * 185 / RATE
			v := (hp * (bursts * 0.7 + math.exp(-t * 16) * 0.5) * 0.6 + math.sin(st.ph) * math.exp(-t * 30) * 0.5) * st.gain
			l[off + i] += f32(v * gl)
			r[off + i] += f32(v * gr)
		}
	}
	return more
}

// Twice high-passed noise decaying at `decay` per second, panned 0.12 right;
// crashes are long open hats. envelope/attack (0 in synth.lua) fades it in,
// for a shaker.
@(private = "file")
hat :: proc(st: ^Port_State, at: i64, l, r: []f32) -> bool {
	count, more := port_span(st, at, l, r)
	gl, gr := pan_gains(0.12)
	w: [CHUNK]f32
	for off := 0; off < count; off += CHUNK {
		c := min(CHUNK, count - off)
		dsp.white_run(&st.rng, w[:c])
		for i in 0 ..< c {
			t := f64(at + i64(off + i)) / RATE
			h1 := f64(w[i]) - st.prev
			h2 := h1 - st.prev2
			st.prev, st.prev2 = f64(w[i]), h1
			a := st.attack > 0 ? min(1, t / st.attack) : 1
			v := h2 * 0.25 * math.exp(-t * st.decay) * a * st.gain
			l[off + i] += f32(v * gl)
			r[off + i] += f32(v * gr)
		}
	}
	return more
}

// synth.lua's closed hat: hat(t, 0.045, 90, gain); a longer note holds it
// longer (synth.lua's `dur`), as far as its tail goes.
voice_hat :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count = min(samples(n.duration > 0 ? n.duration : 0.045), tail_samples(.Hat, p, n))
		st.decay, st.attack = knob(p, .Decay, 90), f64(p[.Envelope_Attack])
	}
	return hat(st, at, l, r)
}

voice_open_hat :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count = samples(0.22)
		st.decay, st.attack = knob(p, .Decay, 14), f64(p[.Envelope_Attack])
	}
	return hat(st, at, l, r)
}

voice_crash :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count = samples(1.6)
		st.decay, st.attack = knob(p, .Decay, 2.5), f64(p[.Envelope_Attack])
	}
	return hat(st, at, l, r)
}

// A saw (and a sine at its phase) through a one-pole low-pass at `cutoff`
// (420 Hz).
voice_bass :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count = samples(n.duration)
		st.f = base.midi_to_hz(midi(.Bass, n)) / RATE
		st.k1, st.attack = dsp.one_pole_k(knob(p, .Cutoff, 420)), f64(p[.Envelope_Attack])
	}
	count, more := port_span(st, at, l, r)
	for i in 0 ..< count {
		k := at + i64(i)
		t := f64(k) / RATE
		st.ph += st.f
		if st.ph >= 1 {
			st.ph -= 1
		}
		st.y += st.k1 * (2 * st.ph - 1 - st.y)
		env := min(1, st.attack > 0 ? t / st.attack : t * 400, f64(st.count - k - 1) / 480)
		v := f32((st.y + math.sin(TAU * st.ph) * 0.6) * env * st.gain)
		l[i] += v
		r[i] += v
	}
	return more
}

// One note of synth.lua's chord: a detuned saw pair, one side tuned up and
// the other down, low-passed, the cutoff moving from cutoff to cutoff2 over
// the note. Its phases start at random.
@(private = "file")
chord_start :: proc(st: ^Port_State, kind: Device_Kind, n: Note, cutoff, cutoff2, attack, decay: f64) {
	st.count = samples(n.duration)
	st.k0, st.k1 = dsp.one_pole_k(cutoff), dsp.one_pole_k(cutoff2)
	hz := base.midi_to_hz(midi(kind, n))
	st.f, st.f2 = hz * 1.006 / RATE, hz / 1.006 / RATE
	st.ph, st.ph2 = base.rng_unit(&st.rng), base.rng_unit(&st.rng)
	st.attack, st.decay = attack, decay
}

@(private = "file")
chord :: proc(st: ^Port_State, at: i64, l, r: []f32) -> bool {
	count, more := port_span(st, at, l, r)
	for i in 0 ..< count {
		k := at + i64(i)
		t := f64(k) / RATE
		kc := st.k0 + (st.k1 - st.k0) * f64(k) / f64(st.count)
		st.ph += st.f
		if st.ph >= 1 {
			st.ph -= 1
		}
		st.ph2 += st.f2
		if st.ph2 >= 1 {
			st.ph2 -= 1
		}
		st.y += kc * (2 * st.ph - 1 + st.ph2 - 0.5 - st.y)
		st.y2 += kc * (2 * st.ph2 - 1 + st.ph - 0.5 - st.y2)
		env := min(1, t / st.attack, f64(st.count - k - 1) / 2400) * math.exp(-t * st.decay) * st.gain
		l[i] += f32(st.y * env)
		r[i] += f32(st.y2 * env)
	}
	return more
}

// The chord as a pad: a 0.3 s attack, no decay, the cutoff opening from 600
// Hz to 2400 (four times cutoff when only cutoff is set).
voice_pad :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		c := knob(p, .Cutoff, 600)
		chord_start(st, .Pad, n, c, knob(p, .Cutoff2, 4 * c), knob(p, .Envelope_Attack, 0.3), knob(p, .Decay, 0))
	}
	return chord(st, at, l, r)
}

// The chord as a stab: a 3 ms attack, decaying at 7 per second, at 2600 Hz.
voice_stab :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		c := knob(p, .Cutoff, 2600)
		chord_start(st, .Stab, n, c, knob(p, .Cutoff2, c), knob(p, .Envelope_Attack, 0.003), knob(p, .Decay, 7))
	}
	return chord(st, at, l, r)
}

tail_chord :: proc(p: ^Params, n: Note) -> f64 {return n.duration}

// A low-passed square pluck for arps.
voice_pluck :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count = samples(0.18)
		st.f = base.midi_to_hz(midi(.Pluck, n)) / RATE
		st.decay, st.k1 = knob(p, .Decay, 16), dsp.one_pole_k(knob(p, .Cutoff, 2500))
	}
	count, more := port_span(st, at, l, r)
	for i in 0 ..< count {
		t := f64(at + i64(i)) / RATE
		st.ph += st.f
		if st.ph >= 1 {
			st.ph -= 1
		}
		st.y += st.k1 * ((st.ph < 0.5 ? 1 : -1) - st.y)
		v := f32(st.y * math.exp(-t * st.decay) * st.gain)
		l[i] += v
		r[i] += v
	}
	return more
}

// A hook voice: a detuned saw pair and a square an octave down, a little
// vibrato once the note settles.
voice_lead :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count = samples(n.duration)
		st.f = base.midi_to_hz(midi(.Lead, n))
		st.attack, st.k1 = f64(p[.Envelope_Attack]), dsp.one_pole_k(knob(p, .Cutoff, 3500))
		st.ph2 = base.rng_unit(&st.rng)
	}
	count, more := port_span(st, at, l, r)
	f := st.f
	for i in 0 ..< count {
		k := at + i64(i)
		t := f64(k) / RATE
		vib := 1 + 0.004 * math.sin(TAU * 5.5 * t) * min(1, t * 6)
		st.ph += f * 1.004 * vib / RATE
		if st.ph >= 1 {
			st.ph -= 1
		}
		st.ph2 += f / 1.004 * vib / RATE
		if st.ph2 >= 1 {
			st.ph2 -= 1
		}
		st.ph3 += f * 0.5 / RATE
		if st.ph3 >= 1 {
			st.ph3 -= 1
		}
		st.y += st.k1 * (2 * st.ph - 1 + 2 * st.ph2 - 1 + (st.ph3 < 0.5 ? 0.6 : -0.6) - st.y)
		env := min(1, st.attack > 0 ? t / st.attack : t * 200, f64(st.count - k - 1) / 400) * math.exp(-t * 1.2)
		v := f32(st.y * env * st.gain)
		l[i] += v
		r[i] += v
	}
	return more
}

// A struck bell: the note, a stretched partial and a high one that dies
// fast; `decay` 2.5 per second.
voice_bell :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.decay = knob(p, .Decay, 2.5)
		st.f = base.midi_to_hz(midi(.Bell, n))
		st.count = samples(min(4, 8 / st.decay))
	}
	count, more := port_span(st, at, l, r)
	f, decay := st.f, st.decay
	for i in 0 ..< count {
		t := f64(at + i64(i)) / RATE
		v := math.sin(TAU * f * t) + 0.35 * math.sin(TAU * f * 2.01 * t) * math.exp(-t * decay * 1.5) + 0.2 * math.sin(TAU * f * 3.5 * t) * math.exp(-t * decay * 3)
		v *= math.exp(-t * decay) * min(1, t * 500) * st.gain
		l[i] += f32(v)
		r[i] += f32(v)
	}
	return more
}

tail_bell :: proc(p: ^Params, n: Note) -> f64 {return min(4, 8 / knob(p, .Decay, 2.5))}

// Noise through a low-pass opening from cutoff (300 Hz) to cutoff2 (9300)
// and a rising sine at `tone`, swelling over the note.
@(private = "file")
riser :: proc(st: ^Port_State, p: ^Params, n: Note, at: i64, first: bool, tone: f64, l, r: []f32) -> bool {
	if first {
		st.count = samples(n.duration)
		st.lo, st.hi, st.tone = knob(p, .Cutoff, 300), knob(p, .Cutoff2, 9300), tone
	}
	count, more := port_span(st, at, l, r)
	w: [CHUNK]f32
	for off := 0; off < count; off += CHUNK {
		c := min(CHUNK, count - off)
		dsp.white_run(&st.rng, w[:c])
		for i in 0 ..< c {
			u := f64(at + i64(off + i)) / f64(st.count)
			st.y += dsp.one_pole_k(st.lo + (st.hi - st.lo) * u * u) * (f64(w[i]) - st.y)
			st.ph += TAU * (180 + 900 * u * u) / RATE
			v := f32((st.y * 0.8 + math.sin(st.ph) * st.tone) * u * u * st.gain)
			l[off + i] += v
			r[off + i] += v
		}
	}
	return more
}

voice_riser :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	return riser(st, p, n, at, first, knob(p, .Tone, 0.15), l, r)
}

// A riser with no tone.
voice_whoosh :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	return riser(st, p, n, at, first, f64(p[.Tone]), l, r)
}

// The big hit: a falling sub boom and a burst of dark noise (low-passed at
// `cutoff`, 900 Hz), saturated.
voice_impact :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count = samples(2.5)
		st.k1 = dsp.one_pole_k(knob(p, .Cutoff, 900))
	}
	count, more := port_span(st, at, l, r)
	w: [CHUNK]f32
	for off := 0; off < count; off += CHUNK {
		c := min(CHUNK, count - off)
		dsp.white_run(&st.rng, w[:c])
		for i in 0 ..< c {
			t := f64(at + i64(off + i)) / RATE
			st.ph += TAU * (30 + 70 * math.exp(-t * 6)) / RATE
			st.y += st.k1 * (f64(w[i]) - st.y)
			v := (math.sin(st.ph) * math.exp(-t * 1.6) + st.y * 1.5 * math.exp(-t * 4)) * st.gain
			v = v / (1 + abs(v)) * 1.6
			l[off + i] += f32(v)
			r[off + i] += f32(v)
		}
	}
	return more
}

// A sine whose pitch falls from (1 + drop) times `f` with exp(-rate t),
// decaying with exp(-decay t), over a click of noise at `click` decaying with
// exp(-click_rate t): synth.lua's tom and thump.
@(private = "file")
drum :: proc(st: ^Port_State, at: i64, drop, rate, decay, click, click_rate: f64, l, r: []f32) -> bool {
	count, more := port_span(st, at, l, r)
	w: [CHUNK]f32
	for off := 0; off < count; off += CHUNK {
		c := min(CHUNK, count - off)
		dsp.white_run(&st.rng, w[:c])
		for i in 0 ..< c {
			t := f64(at + i64(off + i)) / RATE
			st.ph += TAU * st.f * (1 + drop * math.exp(-t * rate)) / RATE
			v := f32((math.sin(st.ph) * math.exp(-t * decay) + f64(w[i]) * math.exp(-t * click_rate) * click) * st.gain)
			l[off + i] += v
			r[off + i] += v
		}
	}
	return more
}

// A tuned drum: a sine falling from 1.6x its pitch.
voice_tom :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count, st.f = samples(0.5), base.midi_to_hz(midi(.Tom, n))
	}
	return drum(st, at, 0.6, 25, 9, 0.2, 400, l, r)
}

// A heavy landing: a low sine dropping a little, a click on top.
voice_thump :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count, st.f = samples(0.7), base.midi_to_hz(midi(.Thump, n))
	}
	return drum(st, at, 0.8, 40, 6, 0.3, 500, l, r)
}

// A sine gliding from the note's pitch to cutoff2 Hz (a fifteenth of it)
// and fading: tape slowing, a boot.
voice_fall :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count = samples(n.duration)
		st.f = base.midi_to_hz(midi(.Fall, n))
		st.f2 = knob(p, .Cutoff2, st.f / 15)
	}
	count, more := port_span(st, at, l, r)
	for i in 0 ..< count {
		k := at + i64(i)
		u := f64(k) / f64(st.count)
		st.ph += TAU * st.f * math.pow(st.f2 / st.f, u) / RATE
		v := f32((math.sin(st.ph) + 0.4 * math.sin(2 * st.ph)) * math.pow(1 - u, 1.5) * min(1, f64(k) / 200) * st.gain)
		l[i] += v
		r[i] += v
	}
	return more
}

// One note of a chord on a stopping tape: its pitch falls to nothing.
voice_tape_chord :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count = samples(n.duration)
		st.k1 = dsp.one_pole_k(knob(p, .Cutoff, 2500))
		st.f = base.midi_to_hz(midi(.Tape_Chord, n)) / RATE
		st.ph = base.rng_unit(&st.rng)
	}
	count, more := port_span(st, at, l, r)
	for i in 0 ..< count {
		k := at + i64(i)
		u := f64(k) / f64(st.count)
		st.ph += st.f * (1 - u) * (1 - u)
		if st.ph >= 1 {
			st.ph -= 1
		}
		st.y += st.k1 * (2 * st.ph - 1 - st.y)
		v := f32(st.y * (1 - u) * min(1, f64(k) / 100) * st.gain)
		l[i] += v
		r[i] += v
	}
	return more
}

// A key: a high-passed click over a short tap at the note's pitch.
voice_tick :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count, st.f = samples(0.025), base.midi_to_hz(midi(.Tick, n))
	}
	count, more := port_span(st, at, l, r)
	w: [CHUNK]f32
	for off := 0; off < count; off += CHUNK {
		c := min(CHUNK, count - off)
		dsp.white_run(&st.rng, w[:c])
		for i in 0 ..< c {
			t := f64(at + i64(off + i)) / RATE
			h := f64(w[i]) - st.prev
			st.prev = f64(w[i])
			v := f32((h * math.exp(-t * 500) * 0.5 + math.sin(TAU * st.f * t) * math.exp(-t * 300) * 0.5) * st.gain)
			l[off + i] += v
			r[off + i] += v
		}
	}
	return more
}

// A terminal's beep: a short square.
voice_beep :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count, st.f = samples(0.03), base.midi_to_hz(midi(.Beep, n)) / RATE
	}
	count, more := port_span(st, at, l, r)
	for i in 0 ..< count {
		t := f64(at + i64(i)) / RATE
		st.ph += st.f
		if st.ph >= 1 {
			st.ph -= 1
		}
		square: f64 = st.ph < 0.5 ? 1 : -1
		v := f32(square * math.exp(-t * 90) * min(1, t * 800) * st.gain)
		l[i] += v
		r[i] += v
	}
	return more
}

// A tiny ember popping.
voice_crackle :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count = samples(0.012)
	}
	count, more := port_span(st, at, l, r)
	w: [CHUNK]f32
	for off := 0; off < count; off += CHUNK {
		c := min(CHUNK, count - off)
		dsp.white_run(&st.rng, w[:c])
		for i in 0 ..< c {
			t := f64(at + i64(off + i)) / RATE
			h := f64(w[i]) - st.prev
			st.prev = f64(w[i])
			v := f32(h * math.exp(-t * 900) * st.gain)
			l[off + i] += v
			r[off + i] += v
		}
	}
	return more
}

// The note's length of stutter: eight grains of square tone and noise at
// pitches drawn from the seed, bouncing left and right. A grain starts at
// floor(g * length / 8) and lasts 0.7 of an eighth; its phase starts at 0.
voice_glitch :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count = samples(n.duration)
		st.grain = n.duration / 8
		for g in 0 ..< 8 {
			st.grain_hz[g] = base.midi_to_hz(72 + math.floor(base.rng_unit(&st.rng) * 24)) / RATE
		}
	}
	count, more := port_span(st, at, l, r)
	length := samples(st.grain * 0.7)
	w: [CHUNK]f32
	for off := 0; off < count; off += CHUNK {
		c := min(CHUNK, count - off)
		dsp.white_run(&st.rng, w[:c])
		for i in 0 ..< c {
			k := at + i64(off + i)
			g := clamp(i64(f64(k) / (st.grain * RATE)), 0, 7)
			for g < 7 && k >= samples(f64(g + 1) * st.grain) {
				g += 1
			}
			for g > 0 && k < samples(f64(g) * st.grain) {
				g -= 1
			}
			into := k - samples(f64(g) * st.grain)
			if into >= length {
				continue
			}
			if into == 0 {
				st.ph = 0
			}
			st.ph += st.grain_hz[g]
			if st.ph >= 1 {
				st.ph -= 1
			}
			gl, gr := pan_gains(g % 2 == 0 ? -0.6 : 0.6)
			v := ((st.ph < 0.5 ? 0.5 : -0.5) + f64(w[i]) * 0.3) * st.gain
			l[off + i] += f32(v * gl)
			r[off + i] += f32(v * gr)
		}
	}
	return more
}

// A short sine blip with an octave on top, at note sample k (0.09 s long).
@(private = "file")
blip :: #force_inline proc(hz, gain: f64, k: i64) -> f64 {
	if k < 0 || k >= samples(0.09) {
		return 0
	}
	t := f64(k) / RATE
	return (math.sin(TAU * hz * t) + 0.3 * math.sin(TAU * 2 * hz * t)) * math.exp(-t * 45) * gain
}

voice_blip :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count, st.f = samples(0.09), base.midi_to_hz(midi(.Blip, n))
	}
	count, more := port_span(st, at, l, r)
	for i in 0 ..< count {
		v := f32(blip(st.f, st.gain, at + i64(i)))
		l[i] += v
		r[i] += v
	}
	return more
}

// Two rising blips 0.12 s apart: 1320 Hz, then a fifth up (1980).
voice_done :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count, st.f = samples(DONE_GAP + 0.09), base.midi_to_hz(midi(.Done, n))
	}
	count, more := port_span(st, at, l, r)
	gap := samples(DONE_GAP)
	for i in 0 ..< count {
		k := at + i64(i)
		v := f32(blip(st.f, st.gain, k) + blip(st.f * 1.5, st.gain, k - gap))
		l[i] += v
		r[i] += v
	}
	return more
}

// ---- added in odawg ----------------------------------------------------------------

// A snare: a tuned body (190 Hz) dropping from 1.45x its pitch, noise
// band-passed around `cutoff` (3200 Hz) decaying at `decay` (13) per second,
// and a click.
voice_snare :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.count = samples(0.35)
		st.band = dsp.svf_coefficients(.Bandpass, f32(knob(p, .Cutoff, 3200)), 0.7, 0)
		st.f, st.decay = base.midi_to_hz(midi(.Snare, n)), knob(p, .Decay, 13)
	}
	count, more := port_span(st, at, l, r)
	w, snap: [CHUNK]f32
	for off := 0; off < count; off += CHUNK {
		c := min(CHUNK, count - off)
		dsp.white_run(&st.rng, w[:c])
		copy(snap[:c], w[:c])
		dsp.svf_run(st.band, &st.band_state, snap[:c])
		for i in 0 ..< c {
			t := f64(at + i64(off + i)) / RATE
			st.ph += TAU * st.f * (1 + 0.45 * math.exp(-t * 35)) / RATE
			body := math.sin(st.ph) * math.exp(-t * 18) * 0.45
			v := f32((body + f64(snap[i]) * math.exp(-t * st.decay) * 0.8 + f64(w[i]) * math.exp(-t * 700) * 0.12) * st.gain)
			l[off + i] += v
			r[off + i] += v
		}
	}
	return more
}

// A sub bass: a sine with a little second harmonic, a soft attack
// (envelope/attack, 10 ms) and an 80 ms release after the gate, gently
// saturated.
voice_sub_bass :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st, first := port(s, n, seed, at)
	if first {
		st.gate = samples(n.duration)
		st.count = samples(n.duration + SUB_BASS_RELEASE)
		st.f = base.midi_to_hz(midi(.Sub_Bass, n))
		st.attack = knob(p, .Envelope_Attack, 0.01)
	}
	count, more := port_span(st, at, l, r)
	DRIVE :: 1.6
	norm := 1 / math.tanh(f64(DRIVE))
	gain := st.gain * 0.9
	for i in 0 ..< count {
		k := at + i64(i)
		t := f64(k) / RATE
		st.ph += TAU * st.f / RATE
		env := min(1, t / st.attack)
		if k >= st.gate {
			fade := max(0, 1 - f64(k - st.gate) / (SUB_BASS_RELEASE * RATE))
			env *= fade * fade
		}
		v := f32(math.tanh((math.sin(st.ph) + 0.12 * math.sin(2 * st.ph)) / 1.12 * DRIVE) * norm * env * gain)
		l[i] += v
		r[i] += v
	}
	return more
}

tail_sub_bass :: proc(p: ^Params, n: Note) -> f64 {return n.duration + SUB_BASS_RELEASE}

// ---- the drum kit ------------------------------------------------------------------

// One sound of a pad: a device kind with param overrides, its pitch (MIDI; 0
// = the kind's own), its gate (0 = the note's) and its level. A pad sounds
// up to three; a layer with no gain is empty.
Kit_Layer :: struct {
	kind:  Device_Kind,
	gain:  f32,
	pitch: f32,
	gate:  f32,
	set:   [6]Param_Value,
}

@(private = "file")
W_TRIANGLE :: f32(dsp.Wave.Triangle)
@(private = "file")
W_SINE :: f32(dsp.Wave.Sine)
@(private = "file")
W_SQUARE :: f32(dsp.Wave.Square)

// What each pad of each kit plays. "synth" is synth.lua's sounds; "808" a
// long boomy MembraneSynth kick, MembraneSynth toms and MetalSynth hats and
// cymbals; "909" a punchier kick with a click, a brighter snare and hats.
// Pitches in MIDI: 31 = 49 Hz, 40/45/50 = 82/110/147 Hz, 92.4 = 1700 Hz.
KIT_TABLE := [Kit][Pad][3]Kit_Layer {
	.Synth = {
		.None = {},
		.Kick = {{kind = .Kick, gain = 1}, {}, {}},
		.Snare = {{kind = .Snare, gain = 1}, {}, {}},
		.Clap = {{kind = .Clap, gain = 0.6}, {}, {}},
		.Rim = {{kind = .Tick, gain = 0.7, pitch = 92.4}, {kind = .Beep, gain = 0.2, pitch = 71.9}, {}},
		.Hat = {{kind = .Hat, gain = 0.35}, {}, {}},
		.Open_Hat = {{kind = .Open_Hat, gain = 0.33}, {}, {}},
		.Crash = {{kind = .Crash, gain = 0.45}, {}, {}},
		.Ride = {{kind = .Crash, gain = 0.18, set = {0 = {.Decay, 4.5}}}, {kind = .Metal_Synth, gain = 0.3, pitch = 64.0, gate = 1.2, set = {{.Envelope_Decay, 1.2}, {.Envelope_Release, 0.3}, {.Resonance, 3500}, {.Octaves, 1}, {}, {}}}, {}},
		.Tom_Low = {{kind = .Tom, gain = 0.75, pitch = 40}, {}, {}},
		.Tom_Mid = {{kind = .Tom, gain = 0.75, pitch = 45}, {}, {}},
		.Tom_High = {{kind = .Tom, gain = 0.75, pitch = 50}, {}, {}},
		.Shaker = {{kind = .Open_Hat, gain = 0.3, set = {{.Decay, 35}, {.Envelope_Attack, 0.012}, {}, {}, {}, {}}}, {}, {}},
		.Cowbell = {{kind = .Synth, gain = 0.22, pitch = 72.6, gate = 0.3, set = {{.Oscillator_Type, W_SQUARE}, {.Envelope_Attack, 0.0005}, {.Envelope_Decay, 0.3}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.05}, {}}}, {kind = .Synth, gain = 0.22, pitch = 79.4, gate = 0.3, set = {{.Oscillator_Type, W_SQUARE}, {.Envelope_Attack, 0.0005}, {.Envelope_Decay, 0.3}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.05}, {}}}, {}},
		.Conga_Low = {{kind = .Tom, gain = 0.6, pitch = 55}, {}, {}},
		.Conga_Mid = {{kind = .Tom, gain = 0.6, pitch = 60}, {}, {}},
		.Conga_High = {{kind = .Tom, gain = 0.6, pitch = 64}, {}, {}},
		.Clave = {{kind = .Tick, gain = 0.8, pitch = 99.1}, {}, {}},
		.Maracas = {{kind = .Open_Hat, gain = 0.3, set = {{.Decay, 60}, {.Envelope_Attack, 0.004}, {}, {}, {}, {}}}, {}, {}},
	},
	.R808 = {
		.None = {},
		.Kick = {{kind = .Membrane_Synth, gain = 1, pitch = 31, gate = 1.2, set = {{.Pitch_Decay, 0.07}, {.Octaves, 3}, {.Envelope_Decay, 1.3}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.4}, {}}}, {}, {}},
		.Snare = {
			{kind = .Membrane_Synth, gain = 0.4, pitch = 54, gate = 0.2, set = {{.Pitch_Decay, 0.02}, {.Octaves, 1.6}, {.Envelope_Decay, 0.15}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.1}, {}}},
			{kind = .Membrane_Synth, gain = 0.2, pitch = 64, gate = 0.15, set = {{.Pitch_Decay, 0.02}, {.Octaves, 1.4}, {.Envelope_Decay, 0.1}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.08}, {}}},
			{kind = .Open_Hat, gain = 0.5, set = {{.Decay, 16}, {}, {}, {}, {}, {}}},
		},
		.Clap = {{kind = .Clap, gain = 0.6}, {}, {}},
		.Rim = {
			{kind = .Synth, gain = 0.45, pitch = 92.4, gate = 0.03, set = {{.Oscillator_Type, W_TRIANGLE}, {.Envelope_Attack, 0.0005}, {.Envelope_Decay, 0.025}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.02}, {}}},
			{kind = .Synth, gain = 0.35, pitch = 70.1, gate = 0.04, set = {{.Oscillator_Type, W_SINE}, {.Envelope_Attack, 0.0005}, {.Envelope_Decay, 0.04}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.02}, {}}},
			{},
		},
		.Hat = {{kind = .Metal_Synth, gain = 0.4, gate = 0.08, set = {{.Envelope_Decay, 0.08}, {.Envelope_Release, 0.01}, {}, {}, {}, {}}}, {}, {}},
		.Open_Hat = {{kind = .Metal_Synth, gain = 0.4, gate = 0.5, set = {{.Envelope_Decay, 0.5}, {.Envelope_Release, 0.1}, {}, {}, {}, {}}}, {}, {}},
		.Crash = {{kind = .Metal_Synth, gain = 0.4, pitch = 62.4, gate = 2, set = {{.Envelope_Decay, 2}, {.Envelope_Release, 0.5}, {.Resonance, 3000}, {}, {}, {}}}, {kind = .Crash, gain = 0.15}, {}},
		.Ride = {{kind = .Metal_Synth, gain = 0.5, pitch = 66.5, gate = 1.6, set = {{.Envelope_Decay, 1.6}, {.Envelope_Release, 0.3}, {.Resonance, 5000}, {.Octaves, 1}, {}, {}}}, {}, {}},
		.Tom_Low = {{kind = .Membrane_Synth, gain = 0.8, pitch = 43, gate = 0.5, set = {{.Pitch_Decay, 0.05}, {.Octaves, 1.5}, {.Envelope_Decay, 0.6}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.3}, {}}}, {}, {}},
		.Tom_Mid = {{kind = .Membrane_Synth, gain = 0.8, pitch = 48, gate = 0.5, set = {{.Pitch_Decay, 0.05}, {.Octaves, 1.5}, {.Envelope_Decay, 0.6}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.3}, {}}}, {}, {}},
		.Tom_High = {{kind = .Membrane_Synth, gain = 0.8, pitch = 53, gate = 0.5, set = {{.Pitch_Decay, 0.05}, {.Octaves, 1.5}, {.Envelope_Decay, 0.6}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.3}, {}}}, {}, {}},
		.Shaker = {{kind = .Open_Hat, gain = 0.4, set = {{.Decay, 45}, {.Envelope_Attack, 0.015}, {}, {}, {}, {}}}, {}, {}},
		.Cowbell = {{kind = .Synth, gain = 0.22, pitch = 72.6, gate = 0.3, set = {{.Oscillator_Type, W_SQUARE}, {.Envelope_Attack, 0.0005}, {.Envelope_Decay, 0.3}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.05}, {}}}, {kind = .Synth, gain = 0.22, pitch = 79.4, gate = 0.3, set = {{.Oscillator_Type, W_SQUARE}, {.Envelope_Attack, 0.0005}, {.Envelope_Decay, 0.3}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.05}, {}}}, {}},
		.Conga_Low = {{kind = .Membrane_Synth, gain = 0.7, pitch = 55, gate = 0.3, set = {{.Pitch_Decay, 0.02}, {.Octaves, 1.3}, {.Envelope_Decay, 0.3}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.1}, {}}}, {}, {}},
		.Conga_Mid = {{kind = .Membrane_Synth, gain = 0.7, pitch = 60, gate = 0.3, set = {{.Pitch_Decay, 0.02}, {.Octaves, 1.3}, {.Envelope_Decay, 0.3}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.1}, {}}}, {}, {}},
		.Conga_High = {{kind = .Membrane_Synth, gain = 0.7, pitch = 64, gate = 0.3, set = {{.Pitch_Decay, 0.02}, {.Octaves, 1.3}, {.Envelope_Decay, 0.3}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.1}, {}}}, {}, {}},
		.Clave = {{kind = .Synth, gain = 0.6, pitch = 99.1, gate = 0.05, set = {{.Oscillator_Type, W_TRIANGLE}, {.Envelope_Attack, 0.0005}, {.Envelope_Decay, 0.04}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.02}, {}}}, {}, {}},
		.Maracas = {{kind = .Open_Hat, gain = 0.35, set = {{.Decay, 70}, {.Envelope_Attack, 0.003}, {}, {}, {}, {}}}, {}, {}},
	},
	.R909 = {
		.None = {},
		.Kick = {{kind = .Membrane_Synth, gain = 0.85, pitch = 33, gate = 0.4, set = {{.Pitch_Decay, 0.035}, {.Octaves, 5}, {.Envelope_Decay, 0.45}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.15}, {}}}, {kind = .Crackle, gain = 0.3}, {}},
		.Snare = {
			{kind = .Membrane_Synth, gain = 0.4, pitch = 55.5, gate = 0.15, set = {{.Pitch_Decay, 0.015}, {.Octaves, 1.5}, {.Envelope_Decay, 0.12}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.08}, {}}},
			{kind = .Open_Hat, gain = 0.6, set = {{.Decay, 11}, {}, {}, {}, {}, {}}},
			{},
		},
		.Clap = {{kind = .Clap, gain = 0.6}, {}, {}},
		.Rim = {{kind = .Tick, gain = 0.6, pitch = 96.9}, {kind = .Synth, gain = 0.25, pitch = 84.9, gate = 0.02, set = {{.Oscillator_Type, W_SQUARE}, {.Envelope_Attack, 0.0005}, {.Envelope_Decay, 0.015}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.01}, {}}}, {}},
		.Hat = {{kind = .Hat, gain = 0.35, set = {{.Decay, 70}, {}, {}, {}, {}, {}}}, {kind = .Metal_Synth, gain = 0.5, pitch = 67.35, gate = 0.05, set = {{.Envelope_Decay, 0.05}, {.Envelope_Release, 0.01}, {.Resonance, 7000}, {.Octaves, 1}, {}, {}}}, {}},
		.Open_Hat = {{kind = .Open_Hat, gain = 0.3, set = {{.Decay, 10}, {}, {}, {}, {}, {}}}, {kind = .Metal_Synth, gain = 0.5, pitch = 67.35, gate = 0.35, set = {{.Envelope_Decay, 0.35}, {.Envelope_Release, 0.1}, {.Resonance, 7000}, {.Octaves, 1}, {}, {}}}, {}},
		.Crash = {{kind = .Crash, gain = 0.4}, {kind = .Metal_Synth, gain = 0.3, pitch = 63.5, gate = 1.8, set = {{.Envelope_Decay, 1.8}, {.Envelope_Release, 0.4}, {.Resonance, 5000}, {.Octaves, 1.2}, {}, {}}}, {}},
		.Ride = {{kind = .Metal_Synth, gain = 0.5, pitch = 68.2, gate = 1.8, set = {{.Envelope_Decay, 1.8}, {.Envelope_Release, 0.3}, {.Resonance, 6000}, {.Octaves, 1}, {}, {}}}, {kind = .Crash, gain = 0.1, set = {{.Decay, 3.5}, {}, {}, {}, {}, {}}}, {}},
		.Tom_Low = {{kind = .Tom, gain = 0.75, pitch = 41}, {}, {}},
		.Tom_Mid = {{kind = .Tom, gain = 0.75, pitch = 46}, {}, {}},
		.Tom_High = {{kind = .Tom, gain = 0.75, pitch = 51}, {}, {}},
		.Shaker = {{kind = .Open_Hat, gain = 0.35, set = {{.Decay, 40}, {.Envelope_Attack, 0.008}, {}, {}, {}, {}}}, {}, {}},
		.Cowbell = {{kind = .Synth, gain = 0.22, pitch = 74.6, gate = 0.3, set = {{.Oscillator_Type, W_SQUARE}, {.Envelope_Attack, 0.0005}, {.Envelope_Decay, 0.3}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.05}, {}}}, {kind = .Synth, gain = 0.22, pitch = 81.4, gate = 0.3, set = {{.Oscillator_Type, W_SQUARE}, {.Envelope_Attack, 0.0005}, {.Envelope_Decay, 0.3}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.05}, {}}}, {}},
		.Conga_Low = {{kind = .Tom, gain = 0.6, pitch = 56}, {}, {}},
		.Conga_Mid = {{kind = .Tom, gain = 0.6, pitch = 61}, {}, {}},
		.Conga_High = {{kind = .Tom, gain = 0.6, pitch = 65}, {}, {}},
		.Clave = {{kind = .Synth, gain = 0.6, pitch = 99.1, gate = 0.05, set = {{.Oscillator_Type, W_TRIANGLE}, {.Envelope_Attack, 0.0005}, {.Envelope_Decay, 0.04}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.02}, {}}}, {}, {}},
		.Maracas = {{kind = .Open_Hat, gain = 0.35, set = {{.Decay, 60}, {.Envelope_Attack, 0.004}, {}, {}, {}, {}}}, {}, {}},
	},
}

// General MIDI drum notes and their pads, for a DrumKit note with a pitch
// and no pad.
GM_DRUMS := [?]struct {
	note: u8,
	pad:  Pad,
} {
	{35, .Kick}, {36, .Kick}, {37, .Rim}, {38, .Snare}, {39, .Clap}, {40, .Snare},
	{41, .Tom_Low}, {42, .Hat}, {43, .Tom_Low}, {44, .Hat}, {45, .Tom_Mid}, {46, .Open_Hat},
	{47, .Tom_Mid}, {48, .Tom_High}, {49, .Crash}, {50, .Tom_High}, {51, .Ride}, {52, .Crash},
	{53, .Ride}, {55, .Crash}, {56, .Cowbell}, {57, .Crash}, {59, .Ride}, {60, .Conga_High}, {61, .Conga_Mid},
	{62, .Conga_High}, {63, .Conga_Mid}, {64, .Conga_Low}, {69, .Shaker}, {70, .Maracas}, {75, .Clave},
	{76, .Clave}, {82, .Shaker},
}

// The pad a DrumKit note plays: its own, or the General MIDI drum its pitch
// names.
note_pad :: proc(n: Note) -> Pad {
	if n.pad != .None {
		return n.pad
	}
	for d in GM_DRUMS {
		if f32(d.note) == math.round(n.pitch) {
			return d.pad
		}
	}
	return .None
}

// A layer's params (its kind's defaults and its overrides) and note: its own
// pitch, moved by as much as the note's pitch is from the pad's first layer
// when the note gives a pad and a pitch; its own gate; the note's velocity
// times its gain; no pad.
@(private = "file")
layer_setup :: proc(layers: ^[3]Kit_Layer, i: int, n: Note) -> (p: Params, ln: Note) {
	layer := &layers[i]
	p = params_from_kind(layer.kind)
	for s in layer.set {
		if s.param != .None {
			p[s.param] = s.value
		}
	}
	own := layer.pitch > 0 ? layer.pitch : DEFAULT_PITCH[layer.kind]
	first := layers[0].pitch > 0 ? layers[0].pitch : DEFAULT_PITCH[layers[0].kind]
	ln = n
	ln.pad = .None
	ln.pitch = own
	if n.pad != .None && n.pitch > 0 && own > 0 {
		ln.pitch += n.pitch - first
	}
	if layer.gate > 0 {
		ln.duration = f64(layer.gate)
	}
	ln.velocity = n.velocity * layer.gain
	return
}

// The GM key that names a pad (kick 36, snare 38, ...): what a sampled kit's
// zones answer for it.
PAD_GM_NOTE := [Pad]f32 {
	.None     = 0,
	.Kick     = 36,
	.Snare    = 38,
	.Clap     = 39,
	.Rim      = 37,
	.Hat      = 42,
	.Open_Hat = 46,
	.Crash    = 49,
	.Ride     = 51,
	.Tom_Low  = 41,
	.Tom_Mid  = 45,
	.Tom_High = 48,
	.Shaker     = 82,
	.Cowbell    = 56,
	.Conga_Low  = 64,
	.Conga_Mid  = 63,
	.Conga_High = 62,
	.Clave      = 75,
	.Maracas    = 70,
}

note_from_pad :: proc(pad: Pad) -> f32 {return PAD_GM_NOTE[pad]}

// A DrumKit note's state: each layer's own, in a slot of its own.
@(private = "file")
Layer_Slot :: struct #align (16) {
	bytes: [LAYER_STATE_SIZE]u8,
}

@(private = "file")
Kit_State :: struct {
	done:  [3]bool,
	slots: [3]Layer_Slot,
}
#assert(size_of(Kit_State) <= VOICE_STATE_SIZE)

// A DrumKit plays its pad's layers side by side, each from its own slot; it
// sounds while any of them does.
voice_drum_kit :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st := voice_state(s, Kit_State)
	layers := &KIT_TABLE[Kit(u8(p[.Kit]))][note_pad(n)]
	alive := false
	for i in 0 ..< len(layers) {
		if layers[i].gain == 0 || st.done[i] {
			continue
		}
		lp, ln := layer_setup(layers, i, n)
		slot := (^Voice_State)(&st.slots[i])
		if DEVICE_TABLE[layers[i].kind].voice(slot, &lp, ln, base.hash_combine(seed, u64(i + 1)), at, env, l, r) {
			alive = true
		} else {
			st.done[i] = true
		}
	}
	return alive
}

tail_drum_kit :: proc(p: ^Params, n: Note) -> f64 {
	layers := &KIT_TABLE[Kit(u8(p[.Kit]))][note_pad(n)]
	tail: f64
	for i in 0 ..< len(layers) {
		if layers[i].gain != 0 {
			lp, ln := layer_setup(layers, i, n)
			tail = max(tail, note_tail(layers[i].kind, &lp, ln))
		}
	}
	return tail
}
