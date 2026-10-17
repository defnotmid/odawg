package odawg_device

import dsp "../dsp"
import base "../base"
import "core:math"
import "core:simd"

// The drum machines and the bass line: DrumMachine (the TR-808's and the
// TR-909's circuits) and AcidSynth (a TB-303). Streaming voices: all their
// memory is in the Voice_State, every stage runs sample by sample in order,
// so the samples never depend on how a note is split into calls.
//
// A DrumMachine pad is a row of MACHINE_TABLE: which circuit model makes its
// source (a rule of CIRCUIT_TABLE) and the circuit's constants. Every row then
// runs the same signal path the hardware shares:
//
//   source -> up to three parallel bands (a filter, a level, an envelope each)
//          -> + the source's direct part -> high-pass -> drive -> level
//
// The models:
//
//   - Membrane: the bridged-T resonators of the 808 (and the 909's VCO
//     tones): up to six decaying sines (or, by `shape`, triangle-ish tones),
//     their pitch starting `1 + sweep` times higher and falling back with
//     `sweep_time`, plus a short click pulse; their noise (snappy, the 909
//     kick's attack, a tom's skin) goes through the bands.
//   - Metal: the 808's six square oscillators (band-limited, free running,
//     so every hit starts at other phases), blended toward their pairwise
//     ring products by `ring` (the 909's sampled cymbals' denser metal),
//     plus noise, through the bands.
//   - Noise: white noise through the bands. The first band is retriggered
//     `bursts` times `spacing` apart (the clap's sawtooth bursts); the later
//     bands start with the last burst (its reverberant tail).
//
// A band's envelope ramps up over `attack` and falls with its `decay` time
// constant. The knobs: `.Decay` scales every time constant (not the sweep
// or the click), `.Tone` moves the bands' and the high-pass's cutoffs by up
// to an octave either way and scales the noise and the click (0.5: the
// row's), `.Tune` shifts the pitch (semitones), and a note's pitch, when it
// has one, tunes the pad's first tone to it (a note without a pad plays the
// `.None` row: the kick as a tuned 808 bass). Like the hardware, no two hits
// are quite alike: the seed drifts each hit's pitch, decays and level a
// little, the clap's burst spacing, and the metal's phases.

Machine :: enum u8 {
	R808,
	R909,
}

Circuit :: enum u8 {
	None,
	Membrane,
	Metal,
	Noise,
}

// One of a circuit's parallel paths: a filter (as svf_coefficients reads its
// q), its level, its envelope.
Band :: struct {
	type:   dsp.Filter_Type,
	hz, q:  f32,
	level:  f32,
	attack: f32, // seconds
	decay:  f32, // time constant, seconds (at `.Decay` 1)
}

Circuit_Row :: struct {
	circuit:    Circuit,
	level:      f32, // the output's gain at velocity 1
	hz:         [6]f32, // Membrane: its tones; Metal: its square oscillators
	mix:        [6]f32, // each one's level (Metal: 0 is 1)
	decay:      [6]f32, // Membrane: each tone's time constant (seconds)
	shape:      f32, // Membrane: 0 sine .. 1 triangle
	sweep:      f32, // Membrane: the pitch starts 1 + sweep times higher
	sweep_time: f32, // and falls back with this time constant
	click:      f32, // Membrane: a 1 ms pulse's level
	noise:      f32, // the noise's level into the bands
	ring:       f32, // Metal: 0 the squares' sum .. 1 their ring products
	bursts:     int, // Noise: how many times the first band retriggers (0: once)
	spacing:    f32, // seconds between bursts
	bands:      [3]Band, // level 0: unused
	highpass:   f32, // Hz (0: none)
	drive:      f32, // tanh saturation (0: clean)
}

// A source writes, from sample t0 of the note, the part that goes through the bands and the part that
// does not (the resonators), for the samples of one chunk.
Circuit_Proc :: #type proc(s: ^Drum_State, row: ^Circuit_Row, t0: i64, direct, source: []f32)

CIRCUIT_TABLE := [Circuit]Circuit_Proc {
	.None     = nil,
	.Membrane = source_membrane,
	.Metal    = source_metal,
	.Noise    = source_noise,
}

// ---- the circuits' constants ---------------------------------------------------------

@(private = "file")
BP :: dsp.Filter_Type.Bandpass
@(private = "file")
HP :: dsp.Filter_Type.Highpass
@(private = "file")
LP :: dsp.Filter_Type.Lowpass

// The 808's six metal oscillators (Hz).
@(private = "file")
METAL_808 :: [6]f32{205.3, 304.4, 369.6, 522.7, 540, 800}
// The 909's cymbals, modelled: the 808's set an octave and a bit up, ring
// modulated in pairs and laced with noise.
@(private = "file")
METAL_909 :: [6]f32{447, 657, 803, 1131, 1183, 1747}

// 808: a decaying sine at 52 Hz with a short blip down from twice that, a
// soft click through the tone low-pass, gently saturated.
@(private = "file")
KICK_808 :: Circuit_Row {
	circuit = .Membrane, level = 0.8, hz = {52, 0, 0, 0, 0, 0}, mix = {1, 0, 0, 0, 0, 0}, decay = {0.16, 0, 0, 0, 0, 0},
	sweep = 1.1, sweep_time = 0.0045, click = 0.22, drive = 1.2,
}
// The 808 as a bass: the kick, a longer boom and less blip.
@(private = "file")
BASS_808 :: Circuit_Row {
	circuit = .Membrane, level = 0.75, hz = {52, 0, 0, 0, 0, 0}, mix = {1, 0, 0, 0, 0, 0}, decay = {0.32, 0, 0, 0, 0, 0},
	sweep = 0.45, sweep_time = 0.008, click = 0.08, drive = 1.6,
}
@(private = "file")
SNARE_808 :: Circuit_Row {
	circuit = .Membrane, level = 0.55, hz = {180, 330, 0, 0, 0, 0}, mix = {0.62, 0.38, 0, 0, 0, 0}, decay = {0.032, 0.022, 0, 0, 0, 0},
	sweep = 0.12, sweep_time = 0.008, click = 0.1, noise = 0.55,
	bands = {{HP, 1900, -3, 1, 0.0005, 0.055}, {BP, 5200, 0.8, 0.35, 0.0005, 0.03}, {}}, drive = 1.1,
}
// Filtered noise in four sawtooth bursts about 10 ms apart, then the
// reverberant tail, both around 1 kHz.
@(private = "file")
CLAP_808 :: Circuit_Row {
	circuit = .Noise, level = 1.4, noise = 1, bursts = 4, spacing = 0.0105,
	bands = {{BP, 1000, 1.5, 1, 0.0004, 0.0032}, {BP, 1050, 1.2, 0.6, 0.0004, 0.075}, {}}, highpass = 350,
}
@(private = "file")
RIM_808 :: Circuit_Row {
	circuit = .Membrane, level = 0.42, hz = {455, 1667, 0, 0, 0, 0}, mix = {0.65, 0.5, 0, 0, 0, 0}, decay = {0.0075, 0.0045, 0, 0, 0, 0},
	shape = 0.3, click = 0.25, highpass = 280, drive = 2.5,
}
@(private = "file")
HAT_808 :: Circuit_Row {
	circuit = .Metal, level = 4.6, hz = METAL_808, bands = {{BP, 7100, 1.3, 1, 0, 0.013}, {HP, 9500, -3, 0.45, 0, 0.008}, {}}, highpass = 6000,
}
@(private = "file")
OPEN_HAT_808 :: Circuit_Row {
	circuit = .Metal, level = 3.3, hz = METAL_808, bands = {{BP, 7100, 1.3, 1, 0, 0.085}, {HP, 9500, -3, 0.4, 0, 0.05}, {}}, highpass = 6000,
}
// The cymbal: three bands with their own decays, the low one longest.
@(private = "file")
CYMBAL_808 :: Circuit_Row {
	circuit = .Metal, level = 2.0, hz = METAL_808,
	bands = {{BP, 3440, 1.3, 0.55, 0, 0.32}, {BP, 7100, 1.3, 0.8, 0, 0.17}, {HP, 9000, -3, 0.5, 0, 0.06}}, highpass = 2800,
}
// The 808 has no ride: its cymbal, narrower and higher.
@(private = "file")
RIDE_808 :: Circuit_Row {
	circuit = .Metal, level = 2.05, hz = METAL_808,
	bands = {{BP, 5200, 2.4, 0.7, 0, 0.28}, {BP, 8000, 1.5, 0.5, 0, 0.18}, {HP, 10000, -3, 0.3, 0, 0.05}}, highpass = 3800,
}
// Two squares at 540 and 800 Hz, band-passed, a sharp drop into a shorter
// ring.
@(private = "file")
COWBELL_808 :: Circuit_Row {
	circuit = .Metal, level = 0.4, hz = {540, 800, 0, 0, 0, 0}, mix = {1, 1, 0, 0, 0, 0},
	bands = {{BP, 1050, 0.9, 0.75, 0, 0.011}, {BP, 1050, 0.9, 0.3, 0, 0.085}, {BP, 2600, 1.5, 0.9, 0, 0.007}}, highpass = 280,
}
@(private = "file")
CLAVE_808 :: Circuit_Row {
	circuit = .Membrane, level = 0.39, hz = {2500, 0, 0, 0, 0, 0}, mix = {1, 0, 0, 0, 0, 0}, decay = {0.011, 0, 0, 0, 0, 0}, click = 0.05,
}
@(private = "file")
MARACAS_808 :: Circuit_Row {
	circuit = .Noise, level = 0.26, noise = 1, bands = {{HP, 5500, -3, 1, 0.0025, 0.017}, {}, {}}, highpass = 4000,
}
@(private = "file")
SHAKER :: Circuit_Row {
	circuit = .Noise, level = 0.43, noise = 1, bands = {{BP, 7000, 0.7, 1, 0.011, 0.028}, {}, {}}, highpass = 3000,
}

// 909: a sine swept down from four times its pitch, a noise click, the drive
// that squares its top.
@(private = "file")
KICK_909 :: Circuit_Row {
	circuit = .Membrane, level = 0.86, hz = {50, 0, 0, 0, 0, 0}, mix = {1, 0, 0, 0, 0, 0}, decay = {0.1, 0, 0, 0, 0, 0},
	shape = 0.15, sweep = 3, sweep_time = 0.0085, click = 0.3, noise = 0.4, bands = {{LP, 5000, -3, 1, 0, 0.0035}, {}, {}}, drive = 2.2,
}
@(private = "file")
BASS_909 :: Circuit_Row {
	circuit = .Membrane, level = 0.8, hz = {50, 0, 0, 0, 0, 0}, mix = {1, 0, 0, 0, 0, 0}, decay = {0.22, 0, 0, 0, 0, 0},
	shape = 0.15, sweep = 1.5, sweep_time = 0.008, click = 0.15, drive = 2.2,
}
// Two detuned triangle-ish tones with a small pitch drop, a noisy body
// (low-passed) and the snappy (high-passed), driven.
@(private = "file")
SNARE_909 :: Circuit_Row {
	circuit = .Membrane, level = 0.62, hz = {182, 334, 0, 0, 0, 0}, mix = {0.55, 0.35, 0, 0, 0, 0}, decay = {0.042, 0.028, 0, 0, 0, 0},
	shape = 0.7, sweep = 0.25, sweep_time = 0.012, click = 0.12, noise = 0.75,
	bands = {{LP, 7000, -3, 0.45, 0.0003, 0.06}, {HP, 2600, -3, 0.75, 0.0003, 0.11}, {}}, drive = 1.6,
}
@(private = "file")
CLAP_909 :: Circuit_Row {
	circuit = .Noise, level = 1.3, noise = 1, bursts = 4, spacing = 0.009,
	bands = {{BP, 1200, 1.1, 1, 0.0003, 0.0028}, {BP, 1300, 0.9, 0.55, 0.0003, 0.055}, {}}, highpass = 500,
}
@(private = "file")
RIM_909 :: Circuit_Row {
	circuit = .Membrane, level = 0.4, hz = {500, 1700, 0, 0, 0, 0}, mix = {0.6, 0.55, 0, 0, 0, 0}, decay = {0.006, 0.0042, 0, 0, 0, 0},
	shape = 0.5, click = 0.3, highpass = 400, drive = 3,
}
@(private = "file")
HAT_909 :: Circuit_Row {
	circuit = .Metal, level = 1.0, hz = METAL_909, ring = 0.8, noise = 0.45,
	bands = {{BP, 9000, 0.9, 1, 0, 0.011}, {HP, 12000, -3, 0.5, 0, 0.006}, {}}, highpass = 7200,
}
@(private = "file")
OPEN_HAT_909 :: Circuit_Row {
	circuit = .Metal, level = 0.79, hz = METAL_909, ring = 0.8, noise = 0.45,
	bands = {{BP, 9000, 0.9, 1, 0, 0.07}, {HP, 12000, -3, 0.5, 0, 0.04}, {}}, highpass = 7200,
}
@(private = "file")
CRASH_909 :: Circuit_Row {
	circuit = .Metal, level = 0.63, hz = METAL_909, ring = 0.7, noise = 0.6,
	bands = {{BP, 5000, 0.8, 0.6, 0, 0.42}, {HP, 8000, -3, 0.7, 0, 0.24}, {BP, 3000, 1, 0.3, 0, 0.09}}, highpass = 2500,
}
// A bell ping in the mids over the wash.
@(private = "file")
RIDE_909 :: Circuit_Row {
	circuit = .Metal, level = 1.14, hz = METAL_909, ring = 0.5, noise = 0.25,
	bands = {{BP, 4200, 3, 0.8, 0, 0.38}, {BP, 6800, 2, 0.5, 0, 0.28}, {HP, 9000, -3, 0.4, 0, 0.11}}, highpass = 3000,
}

@(private = "file")
TOM_LOW_808 :: Circuit_Row {
	circuit = .Membrane, level = 0.52, hz = {90, 0, 0, 0, 0, 0}, mix = {1, 0, 0, 0, 0, 0}, decay = {0.085, 0, 0, 0, 0, 0},
	sweep = 0.22, sweep_time = 0.035, click = 0.08, noise = 0.12, bands = {{LP, 2600, -3, 1, 0.0005, 0.04}, {}, {}},
}
@(private = "file")
TOM_MID_808 :: Circuit_Row {
	circuit = .Membrane, level = 0.52, hz = {130, 0, 0, 0, 0, 0}, mix = {1, 0, 0, 0, 0, 0}, decay = {0.085, 0, 0, 0, 0, 0},
	sweep = 0.22, sweep_time = 0.035, click = 0.08, noise = 0.12, bands = {{LP, 2600, -3, 1, 0.0005, 0.04}, {}, {}},
}
@(private = "file")
TOM_HIGH_808 :: Circuit_Row {
	circuit = .Membrane, level = 0.52, hz = {180, 0, 0, 0, 0, 0}, mix = {1, 0, 0, 0, 0, 0}, decay = {0.085, 0, 0, 0, 0, 0},
	sweep = 0.22, sweep_time = 0.035, click = 0.08, noise = 0.12, bands = {{LP, 2600, -3, 1, 0.0005, 0.04}, {}, {}},
}
@(private = "file")
CONGA_LOW_808 :: Circuit_Row {
	circuit = .Membrane, level = 0.52, hz = {185, 0, 0, 0, 0, 0}, mix = {1, 0, 0, 0, 0, 0}, decay = {0.05, 0, 0, 0, 0, 0},
	sweep = 0.1, sweep_time = 0.012, click = 0.12,
}
@(private = "file")
CONGA_MID_808 :: Circuit_Row {
	circuit = .Membrane, level = 0.52, hz = {275, 0, 0, 0, 0, 0}, mix = {1, 0, 0, 0, 0, 0}, decay = {0.05, 0, 0, 0, 0, 0},
	sweep = 0.1, sweep_time = 0.012, click = 0.12,
}
@(private = "file")
CONGA_HIGH_808 :: Circuit_Row {
	circuit = .Membrane, level = 0.52, hz = {370, 0, 0, 0, 0, 0}, mix = {1, 0, 0, 0, 0, 0}, decay = {0.05, 0, 0, 0, 0, 0},
	sweep = 0.1, sweep_time = 0.012, click = 0.12,
}
@(private = "file")
TOM_LOW_909 :: Circuit_Row {
	circuit = .Membrane, level = 0.52, hz = {95, 0, 0, 0, 0, 0}, mix = {1, 0, 0, 0, 0, 0}, decay = {0.1, 0, 0, 0, 0, 0},
	shape = 0.3, sweep = 0.6, sweep_time = 0.03, click = 0.15, noise = 0.18, bands = {{LP, 4000, -3, 1, 0, 0.02}, {}, {}}, drive = 1.3,
}
@(private = "file")
TOM_MID_909 :: Circuit_Row {
	circuit = .Membrane, level = 0.52, hz = {140, 0, 0, 0, 0, 0}, mix = {1, 0, 0, 0, 0, 0}, decay = {0.1, 0, 0, 0, 0, 0},
	shape = 0.3, sweep = 0.6, sweep_time = 0.03, click = 0.15, noise = 0.18, bands = {{LP, 4000, -3, 1, 0, 0.02}, {}, {}}, drive = 1.3,
}
@(private = "file")
TOM_HIGH_909 :: Circuit_Row {
	circuit = .Membrane, level = 0.52, hz = {190, 0, 0, 0, 0, 0}, mix = {1, 0, 0, 0, 0, 0}, decay = {0.1, 0, 0, 0, 0, 0},
	shape = 0.3, sweep = 0.6, sweep_time = 0.03, click = 0.15, noise = 0.18, bands = {{LP, 4000, -3, 1, 0, 0.02}, {}, {}}, drive = 1.3,
}

// The pads of each machine. The 909 had no cowbell, congas, clave or
// maracas: it plays the 808's, as a 909 with an 808 beside it would.
MACHINE_TABLE := [Machine][Pad]Circuit_Row {
	.R808 = {
		.None       = BASS_808,
		.Kick       = KICK_808,
		.Snare      = SNARE_808,
		.Clap       = CLAP_808,
		.Rim        = RIM_808,
		.Hat        = HAT_808,
		.Open_Hat   = OPEN_HAT_808,
		.Crash      = CYMBAL_808,
		.Ride       = RIDE_808,
		.Tom_Low    = TOM_LOW_808,
		.Tom_Mid    = TOM_MID_808,
		.Tom_High   = TOM_HIGH_808,
		.Shaker     = SHAKER,
		.Cowbell    = COWBELL_808,
		.Conga_Low  = CONGA_LOW_808,
		.Conga_Mid  = CONGA_MID_808,
		.Conga_High = CONGA_HIGH_808,
		.Clave      = CLAVE_808,
		.Maracas    = MARACAS_808,
	},
	.R909 = {
		.None       = BASS_909,
		.Kick       = KICK_909,
		.Snare      = SNARE_909,
		.Clap       = CLAP_909,
		.Rim        = RIM_909,
		.Hat        = HAT_909,
		.Open_Hat   = OPEN_HAT_909,
		.Crash      = CRASH_909,
		.Ride       = RIDE_909,
		.Tom_Low    = TOM_LOW_909,
		.Tom_Mid    = TOM_MID_909,
		.Tom_High   = TOM_HIGH_909,
		.Shaker     = SHAKER,
		.Cowbell    = COWBELL_808,
		.Conga_Low  = CONGA_LOW_808,
		.Conga_Mid  = CONGA_MID_808,
		.Conga_High = CONGA_HIGH_808,
		.Clave      = CLAVE_808,
		.Maracas    = MARACAS_808,
	},
}

// How much hits differ (the hardware's drift): pitch, decays, level, the
// clap's burst spacing; each a fraction either way.
DRIFT_PITCH :: 0.004
DRIFT_DECAY :: 0.04
DRIFT_LEVEL :: 0.03
DRIFT_SPACING :: 0.12

// The click pulse's length (seconds).
@(private = "file")
CLICK_TIME :: 0.001

// Samples a chunk of a voice runs in (stack scratch).
@(private = "file")
CHUNK :: 256

// ---- the drum voice ------------------------------------------------------------------

Drum_State :: struct {
	machine:    Machine,
	pad:        Pad,
	length:     i64, // samples it sounds
	gain:       f32, // level x velocity x drift
	ratio:      f64, // the tuning (the note, `.Tune`, drift)
	dscale:     f32, // `.Decay` x drift
	tone:       f32, // `.Tone` - 0.5
	// Membrane
	phase:      [6]f64,
	amp:        [6]f32,
	amp_k:      [6]f32,
	sweep:      f32,
	sweep_k:    f32,
	// Metal
	oscs:       [6]dsp.Osc,
	// the bands, their envelopes, the high-pass
	band:       [3]dsp.Svf,
	band_state: [3]dsp.Svf_State,
	inv_decay:  [3]f32, // 1 / (time constant in samples)
	burst_at:   [4]i64, // where the first band retriggers (samples)
	hp:         dsp.Svf,
	hp_state:   [2]dsp.Svf_State,
	drive_norm: f32,
	rng:        base.Rng,
}

#assert(size_of(Drum_State) <= VOICE_STATE_SIZE)

@(private = "file")
machine_of :: proc "contextless" (p: ^Params) -> Machine {return Machine(min(u8(max(p[.Machine], 0)), u8(max(Machine))))}

@(private = "file")
drum_row :: proc(p: ^Params, n: Note) -> ^Circuit_Row {return &MACHINE_TABLE[machine_of(p)][n.pad]}

@(private = "file")
knob_or :: proc "contextless" (v, own: f32) -> f32 {return v > 0 ? v : own}

// The longest time constant a row's envelopes have, the tones' and the bands'.
@(private = "file")
row_longest :: proc "contextless" (row: ^Circuit_Row) -> (longest: f32, last_start: f32) {
	for d in row.decay {
		longest = max(longest, d)
	}
	for b in row.bands {
		if b.level != 0 {
			longest = max(longest, b.decay + b.attack)
		}
	}
	return longest, f32(max(row.bursts - 1, 0)) * row.spacing * (1 + DRIFT_SPACING)
}

tail_drum_machine :: proc(p: ^Params, n: Note) -> f64 {
	row := drum_row(p, n)
	longest, start := row_longest(row)
	// 8 time constants: -70 dB
	return f64(start + 8 * longest * knob_or(p[.Decay], 1) * (1 + DRIFT_DECAY) + CLICK_TIME) + 0.002
}

@(private = "file")
drum_start :: proc(s: ^Drum_State, p: ^Params, n: Note, seed: u64) {
	row := drum_row(p, n)
	s.machine = machine_of(p)
	s.pad = n.pad
	s.rng = base.rng_init(seed)
	drift :: proc(r: ^base.Rng, amount: f64) -> f64 {return 1 + amount * (2 * base.rng_unit(r) - 1)}
	pitch_drift := drift(&s.rng, DRIFT_PITCH)
	decay_drift := drift(&s.rng, DRIFT_DECAY)
	level_drift := drift(&s.rng, DRIFT_LEVEL)

	s.ratio = math.pow(2, f64(p[.Tune]) / 12) * pitch_drift
	if n.pitch > 0 && row.hz[0] > 0 {
		s.ratio *= base.midi_to_hz(f64(n.pitch)) / f64(row.hz[0])
	}
	s.dscale = knob_or(p[.Decay], 1) * f32(decay_drift)
	s.tone = clamp(p[.Tone], 0, 1) - 0.5
	s.gain = row.level * n.velocity * f32(level_drift)
	s.length = i64(math.ceil(tail_drum_machine(p, n) * RATE))

	for i in 0 ..< 6 {
		s.amp[i] = 1
		s.amp_k[i] = row.decay[i] > 0 ? f32(math.exp(-1 / (f64(row.decay[i] * s.dscale) * RATE))) : 0
		// free-running metal: every hit catches the oscillators elsewhere
		s.oscs[i] = {wave = .Square, phase = base.rng_unit(&s.rng)}
	}
	s.sweep = row.sweep
	s.sweep_k = row.sweep_time > 0 ? f32(math.exp(-1 / (f64(row.sweep_time) * RATE))) : 0
	shift := math.pow(2, 2 * s.tone) // Tone: an octave either way
	for b, i in row.bands {
		s.band[i] = dsp.svf_coefficients(b.type, b.hz * shift, b.q, 0)
		s.inv_decay[i] = b.decay > 0 ? 1 / (b.decay * s.dscale * RATE) : 0
	}
	if row.highpass > 0 {
		s.hp = dsp.svf_coefficients(.Highpass, row.highpass * shift, -3, 0)
	}
	t: f64
	for k in 0 ..< len(s.burst_at) {
		s.burst_at[k] = i64(t * RATE)
		t += f64(row.spacing) * drift(&s.rng, DRIFT_SPACING)
	}
	s.drive_norm = row.drive > 0 ? 1 / f32(math.tanh(f64(row.drive))) : 1
}

voice_drum_machine :: proc(vs: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	s := (^Drum_State)(vs)
	if at == 0 {
		drum_start(s, p, n, seed)
	}
	row := &MACHINE_TABLE[s.machine][s.pad]
	source_proc := CIRCUIT_TABLE[row.circuit]
	if source_proc == nil {
		return false
	}
	total := int(clamp(s.length - at, 0, i64(min(len(l), len(r)))))
	direct, source, sum: [CHUNK]f32
	// the bands side by side, a lane each (the fourth idle): their filters'
	// coefficients and memories as structures of arrays, and per sample each
	// band's level times its envelope
	F4 :: #simd[4]f32
	a1, a2, a3, m0, m1, m2, ic1, ic2: [4]f32
	for &b, bi in row.bands {
		if b.level == 0 {
			continue
		}
		c := s.band[bi]
		a1[bi], a2[bi], a3[bi], m0[bi], m1[bi], m2[bi] = c.a1, c.a2, c.a3, c.m0, c.m1, c.m2
		ic1[bi], ic2[bi] = s.band_state[bi].ic1, s.band_state[bi].ic2
	}
	va1, va2, va3 := transmute(F4)a1, transmute(F4)a2, transmute(F4)a3
	vm0, vm1, vm2 := transmute(F4)m0, transmute(F4)m1, transmute(F4)m2
	vic1, vic2 := transmute(F4)ic1, transmute(F4)ic2
	weight: [CHUNK][4]f32
	for done := 0; done < total; {
		m := min(CHUNK, total - done)
		t0 := at + i64(done)
		source_proc(s, row, t0, direct[:m], source[:m])
		copy(sum[:m], direct[:m])
		for &b, bi in row.bands {
			for i in 0 ..< m {
				weight[i][bi] = b.level == 0 ? 0 : b.level * band_envelope(s, row, bi, t0 + i64(i))
			}
		}
		for i in 0 ..< m {
			v0 := F4(source[i])
			v3 := v0 - vic2
			v1 := va1 * vic1 + va2 * v3
			v2 := vic2 + va2 * vic1 + va3 * v3
			vic1 = 2 * v1 - vic1
			vic2 = 2 * v2 - vic2
			sum[i] += simd.reduce_add_ordered((vm0 * v0 + vm1 * v1 + vm2 * v2) * transmute(F4)weight[i])
		}
		if row.highpass > 0 {
			dsp.svf_run(s.hp, &s.hp_state[0], sum[:m])
			dsp.svf_run(s.hp, &s.hp_state[1], sum[:m])
		}
		if row.drive > 0 {
			for i in 0 ..< m {
				sum[i] = dsp.tanh_fast(row.drive * sum[i]) * s.drive_norm
			}
		}
		for i in 0 ..< m {
			v := sum[i] * s.gain
			l[done + i] += v
			r[done + i] += v
		}
		done += m
	}
	ic1, ic2 = transmute([4]f32)vic1, transmute([4]f32)vic2
	for bi in 0 ..< len(row.bands) {
		s.band_state[bi] = {ic1[bi], ic2[bi]}
	}
	return at + i64(min(len(l), len(r))) < s.length
}

// A band's envelope at sample t: the first band from its latest burst, the
// others from the last burst; a linear rise over `attack`, then the decay.
@(private = "file")
band_envelope :: proc(s: ^Drum_State, row: ^Circuit_Row, band: int, t: i64) -> f32 {
	bursts := clamp(row.bursts, 1, len(s.burst_at))
	start := s.burst_at[bursts - 1]
	if band == 0 {
		for k := bursts - 1; k >= 0; k -= 1 {
			if t >= s.burst_at[k] {
				start = s.burst_at[k]
				break
			}
		}
	}
	if t < start {
		return 0
	}
	x := f32(t - start)
	b := &row.bands[band]
	rise := b.attack > 0 ? min(1, x / (b.attack * RATE)) : 1
	return rise * dsp.exp_decay(-x * s.inv_decay[band])
}

// The noise's level: the row's, by `.Tone` (0.5x .. 1.5x).
@(private = "file")
noise_into :: proc(s: ^Drum_State, level: f32, out: []f32) {
	dsp.white_run(&s.rng, out)
	g := level * (1 + s.tone)
	for i in 0 ..< len(out) {
		out[i] *= g
	}
}

// Bridged-T resonators: decaying tones whose pitch blips down, and the
// trigger's click (a raised-cosine pulse).
source_membrane :: proc(s: ^Drum_State, row: ^Circuit_Row, t0: i64, direct, source: []f32) {
	click_len := f64(CLICK_TIME * RATE)
	click := row.click * (1 + s.tone)
	for i in 0 ..< len(direct) {
		bend := 1 + f64(s.sweep)
		v: f32
		for k in 0 ..< 6 {
			if row.mix[k] == 0 {
				continue
			}
			ph := s.phase[k]
			sine := dsp.sin_turns(ph)
			tri := f32(ph < 0.25 ? 4 * ph : (ph < 0.75 ? 2 - 4 * ph : 4 * ph - 4))
			v += (sine + row.shape * (tri - sine)) * s.amp[k] * row.mix[k]
			s.phase[k] = dsp.wrap(s.phase[k] + f64(row.hz[k]) * s.ratio * bend / RATE)
			s.amp[k] *= s.amp_k[k]
		}
		s.sweep *= s.sweep_k
		if t := f64(t0) + f64(i); t < click_len {
			v += click * f32(0.5 - 0.5 * math.cos(math.TAU * t / click_len))
		}
		direct[i] = v
	}
	noise_into(s, row.noise, source)
}

// The square oscillators, summed or ring modulated in pairs, with noise.
source_metal :: proc(s: ^Drum_State, row: ^Circuit_Row, t0: i64, direct, source: []f32) {
	m := len(direct)
	inc: [CHUNK]f64
	sq: [6][CHUNK]f32
	used := 0
	for k in 0 ..< 6 {
		if row.hz[k] == 0 {
			continue
		}
		for i in 0 ..< m {
			inc[i] = f64(row.hz[k]) * s.ratio / RATE
		}
		dsp.osc_run(&s.oscs[k], inc[:m], sq[k][:m])
		used = k + 1
	}
	noise_into(s, row.noise, source)
	for i in 0 ..< m {
		sum, ring: f32
		for k in 0 ..< used {
			sum += sq[k][i] * (row.mix[k] != 0 ? row.mix[k] : 1)
		}
		for k := 0; k + 1 < used; k += 2 {
			ring += sq[k][i] * sq[k + 1][i]
		}
		direct[i] = 0
		source[i] += (sum * (1 - row.ring) + 2 * ring * row.ring) / f32(max(used, 1))
	}
}

source_noise :: proc(s: ^Drum_State, row: ^Circuit_Row, t0: i64, direct, source: []f32) {
	for i in 0 ..< len(direct) {
		direct[i] = 0
	}
	noise_into(s, row.noise, source)
}

// ---- the acid synth ------------------------------------------------------------------

// AcidSynth: a TB-303. One voice plays the whole track (its row is `mono`):
// a new note arrives with `at` 0 and the state kept, and the voice reads
// from it whether the last note's gate was still open when this one began.
// Open: a slide (the pitch glides there over `.Portamento`, nothing
// retriggers); closed: a new attack.
//
//   - the oscillator: a band-limited saw or square (`.Oscillator_Type`),
//     its pitch the note's plus `.Tune` semitones;
//   - the filter: a 4-pole ladder, 2x oversampled, a tanh in every stage
//     and in the feedback, so it saturates and squelches as the 303's diode
//     ladder does; `.Filter_Q` 0..10 is the resonance, 10 the edge of
//     self-oscillation (it goes a little past);
//   - the filter envelope (MEG): restarted by each attack, it opens the
//     cutoff from `.Filter_Frequency` by `.Filter_Envelope_Octaves` and falls
//     over `.Envelope_Decay`;
//   - accent (velocity over 0.8, by `.Accent`): louder, the MEG at its
//     shortest, and the accent sweep: a capacitor charged by the MEG that
//     lifts the cutoff and drains slower than it fills, so accents close
//     together build on each other;
//   - the VCA: a fast attack, a slow fall while the gate is open, a short
//     release after it.

// Time constants (seconds) of the circuit.
ACID_ATTACK :: 0.0015
ACID_HOLD :: 1.6 // the VCA's fall with the gate open
ACID_RELEASE :: 0.004
ACID_ACCENT_DECAY :: 0.2 // the MEG's decay on an accent (at most)
ACID_CHARGE :: 0.012 // the accent capacitor filling
ACID_DRAIN :: 0.3 // and draining
// Octaves the full accent charge lifts the cutoff by (at `.Accent` 1).
ACID_ACCENT_OCTAVES :: 2.5
// How much louder a full accent is (at `.Accent` 1).
ACID_ACCENT_GAIN :: 1.0
// Samples a slide's gate must still have to run when the next note starts.
ACID_GATE_SLACK :: 24
ACID_LEVEL :: 0.42
// The level into the ladder: lower, cleaner and more resonant; higher, more
// saturated.
ACID_DRIVE :: 0.4
// The pitch a note without one plays (C2).
ACID_PITCH :: 36

Acid_State :: struct {
	started:  bool,
	osc:      dsp.Osc,
	pitch:    f64, // log2 Hz, gliding
	target:   f64,
	glide_k:  f64,
	gate:     i64, // this note's gate, in samples from its start
	pos:      i64, // samples of this note played
	amp:      f32, // the VCA's attack/release
	hold:     f32, // its slow fall with the gate open
	meg:      f32,
	meg_k:    f32,
	accent:   f32, // this note's accent, 0..1 times `.Accent`
	charge:   f32,
	gain:     f32,
	y:        [4]f32, // the ladder's stages
	x_last:   f32, // the input one sample ago (the oversampling's midpoint)
	legato:   bool, // whether this note slid in
}

#assert(size_of(Acid_State) <= VOICE_STATE_SIZE)

tail_acid_synth :: proc(p: ^Params, n: Note) -> f64 {
	// the gate, the release to -100 dB, the ladder's ring
	return max(n.duration, 0) + 12 * ACID_RELEASE + 0.02
}

@(private = "file")
tanh_fast :: #force_inline proc "contextless" (x: f32) -> f32 {
	c := clamp(x, -3, 3)
	return c * (27 + c * c) / (27 + 9 * c * c)
}

@(private = "file")
coef :: proc "contextless" (seconds: f64) -> f64 {
	return seconds > 0 ? 1 - math.exp(-1 / (seconds * RATE)) : 1
}

@(private = "file")
acid_note :: proc(s: ^Acid_State, p: ^Params, n: Note) {
	// the last note's gate still open: a slide
	slide := s.started && s.gate - s.pos > ACID_GATE_SLACK
	wave, _ := dsp.wave_plain(dsp.Wave(u8(p[.Oscillator_Type])))
	if wave != .Square && wave != .Pulse {
		wave = .Sawtooth
	}
	s.osc.wave, s.osc.width = wave, 0.5
	pitch := f64(n.pitch > 0 ? n.pitch : ACID_PITCH) + f64(p[.Tune])
	s.target = math.log2(base.midi_to_hz(pitch))
	s.glide_k = coef(f64(max(p[.Portamento], 0)) / 3)
	s.accent = clamp((n.velocity - 0.8) / 0.2, 0, 1) * clamp(p[.Accent], 0, 1)
	level := min(n.velocity, 0.8) / 0.8
	s.gain = ACID_LEVEL * level * (1 + ACID_ACCENT_GAIN * s.accent)
	s.gate = i64(math.round(max(n.duration, 0) * RATE))
	s.pos = 0
	s.legato = slide
	if slide {
		return
	}
	s.pitch = s.target
	s.started = true
	s.hold = 1
	s.meg = 1
	decay := f64(max(p[.Envelope_Decay], 0.01))
	if s.accent > 0 {
		decay = min(decay, ACID_ACCENT_DECAY)
	}
	// most of the way down in `decay`
	s.meg_k = f32(math.exp(-2.3 / (decay * RATE)))
}

voice_acid_synth :: proc(vs: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	s := (^Acid_State)(vs)
	if at == 0 {
		acid_note(s, p, n)
	}
	total := min(len(l), len(r))
	attack_k, release_k := f32(coef(ACID_ATTACK)), f32(math.exp(-1 / (ACID_RELEASE * RATE)))
	hold_k := f32(math.exp(-1 / (ACID_HOLD * RATE)))
	fill_k, drain_k := f32(coef(ACID_CHARGE)), f32(coef(ACID_DRAIN))
	base_oct := math.log2(f64(max(p[.Filter_Frequency], 20)))
	env_oct := f64(p[.Filter_Envelope_Octaves])
	res := clamp(p[.Filter_Q], 0, 11) / 10
	inc: [CHUNK]f64
	wave: [CHUNK]f32
	for done := 0; done < total; {
		m := min(CHUNK, total - done)
		for i in 0 ..< m {
			s.pitch += (s.target - s.pitch) * s.glide_k
			inc[i] = math.pow(2, s.pitch) / RATE
		}
		dsp.osc_run(&s.osc, inc[:m], wave[:m])
		for i in 0 ..< m {
			open := s.pos < s.gate
			if open {
				s.amp += (1 - s.amp) * attack_k
				s.hold *= hold_k
			} else {
				s.amp *= release_k
			}
			// the accent sweep: charged by the MEG on an accent, slower to drain
			want := s.accent * s.meg
			s.charge += (want - s.charge) * (want > s.charge ? fill_k : drain_k)
			oct := base_oct + env_oct * f64(s.meg) * (1 - 0.5 * f64(s.accent)) + ACID_ACCENT_OCTAVES * f64(s.charge)
			hz := min(math.pow(2, oct), 18000)
			g := f32(1 - math.exp(-math.TAU * hz / (2 * RATE)))
			x := wave[i]
			// two steps at twice the rate: the midpoint, then the sample
			out: f32
			for step in 0 ..< 2 {
				xin := step == 0 ? 0.5 * (s.x_last + x) : x
				t0 := tanh_fast(ACID_DRIVE * xin - 4 * res * s.y[3])
				t1, t2, t3 := tanh_fast(s.y[0]), tanh_fast(s.y[1]), tanh_fast(s.y[2])
				s.y[0] += g * (t0 - t1)
				s.y[1] += g * (t1 - t2)
				s.y[2] += g * (t2 - t3)
				s.y[3] += g * (t3 - tanh_fast(s.y[3]))
				out += 0.5 * s.y[3]
			}
			s.x_last = x
			s.meg *= s.meg_k
			v := tanh_fast(out / ACID_DRIVE * (1 + 0.6 * res)) * s.amp * s.hold * s.gain
			l[done + i] += v
			r[done + i] += v
			s.pos += 1
		}
		done += m
	}
	return s.pos < s.gate || s.amp > 1e-5
}
