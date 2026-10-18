// device: the instruments and effects. Every instrument, preset and effect is a row of
// DEVICE_TABLE (its name, which params it reads, Tone's defaults, and its
// procs); every option any of them reads is a row of PARAM_TABLE (its `/`
// path in a spec, its unit, its choices). A device's values are a `Params`
// filled from its row; the procs read them by Param. Nothing here parses or
// knows songs: a reader fills Params from the tables, the engine calls the
// procs over buffers.
package odawg_device

import dsp "../dsp"
import base "../base"

RATE :: base.RATE

// ---- params ------------------------------------------------------------------------

Unit :: enum u8 {
	Number,
	Seconds, // a Tone length ("8n.") is turned into seconds at the reader's tempo
	Hz,
	Db,
	Cents,
	Choice, // one of the row's choices, stored as its index
	Asset, // a sample set by name ("vcsl/upright_piano"), stored as its index in the Bank
}

Param :: enum u8 {
	None,
	// Tone's OmniOscillator: "fatsawtooth" is the sawtooth with `count` copies
	// `spread` cents apart.
	Oscillator_Type,
	Oscillator_Count,
	Oscillator_Spread,
	Oscillator_Width,
	Envelope_Attack,
	Envelope_Decay,
	Envelope_Sustain,
	Envelope_Release,
	// An instrument's filter (MonoSynth) and AutoFilter's.
	Filter_Type,
	Filter_Frequency,
	Filter_Q,
	Filter_Rolloff,
	Filter_Gain,
	Filter_Envelope_Attack,
	Filter_Envelope_Decay,
	Filter_Envelope_Sustain,
	Filter_Envelope_Release,
	Filter_Envelope_Base_Frequency,
	Filter_Envelope_Octaves,
	Filter_Envelope_Exponent,
	// FMSynth's and AMSynth's modulator.
	Modulation_Type,
	Modulation_Envelope_Attack,
	Modulation_Envelope_Decay,
	Modulation_Envelope_Sustain,
	Modulation_Envelope_Release,
	Harmonicity,
	Modulation_Index,
	Pitch_Decay, // MembraneSynth
	Octaves, // MembraneSynth's sweep, MetalSynth's and AutoFilter's range
	Resonance, // MetalSynth's high-pass (Hz), PluckSynth's feedback (0..1)
	Attack_Noise,
	Dampening,
	Release, // PluckSynth, Limiter, Gate, Compressor
	Noise_Type,
	Portamento,
	// The presets' knobs (0: the preset's own value).
	Cutoff,
	Cutoff2,
	Decay, // a preset's decay rate (per second); Reverb's decay (seconds)
	Tone,
	Kit, // DrumKit
	Sample_Set, // Sampler: which set of the Bank it plays
	Machine, // DrumMachine: which machine's circuits
	Tune, // semitones
	Accent, // AcidSynth: how much an accented note (velocity > 0.8) opens and lifts
	// Player: a clip played as recorded.
	Offset, // seconds into the clip it starts from
	Fade_In,
	Fade_Out,
	Curve, // the fades' shape
	Mono, // 1: L and R folded to 0.707 (L + R)
	// Effects.
	Wet,
	Type, // Filter
	Frequency, // Filter's cutoff; Chorus's and AutoFilter's rate
	Q,
	Rolloff,
	Gain,
	Low,
	Mid,
	High,
	Low_Frequency,
	High_Frequency,
	Threshold,
	Ratio,
	Knee,
	Attack,
	Pre_Delay,
	Delay_Time,
	Feedback,
	Depth,
	Base_Frequency,
	Distortion,
	Bits,
	Width,
}

Params :: [Param]f32

Param_Set :: bit_set[Param;u128]

Param_Row :: struct {
	path:    string, // in a spec: nested tables, `/` here
	unit:    Unit,
	choices: []string,
}

WAVE_CHOICES := []string{"sine", "triangle", "sawtooth", "square", "pulse", "fatsine", "fattriangle", "fatsawtooth", "fatsquare"}
FILTER_CHOICES := []string{"lowpass", "highpass", "bandpass", "lowshelf", "highshelf", "notch", "allpass", "peaking"}
NOISE_CHOICES := []string{"white", "pink", "brown"}
KIT_CHOICES := []string{"synth", "808", "909"}
MACHINE_CHOICES := []string{"808", "909"}
CURVE_CHOICES := []string{"linear", "equal_power"}

Curve :: enum u8 {
	Linear,
	Equal_Power,
}

// Indices into WAVE_CHOICES and FILTER_CHOICES, for the procs.



Kit :: enum u8 {
	Synth,
	R808,
	R909,
}

PARAM_TABLE := [Param]Param_Row {
	.None                           = {"", .Number, nil},
	.Oscillator_Type                = {"oscillator/type", .Choice, WAVE_CHOICES},
	.Oscillator_Count               = {"oscillator/count", .Number, nil},
	.Oscillator_Spread              = {"oscillator/spread", .Cents, nil},
	.Oscillator_Width               = {"oscillator/width", .Number, nil},
	.Envelope_Attack                = {"envelope/attack", .Seconds, nil},
	.Envelope_Decay                 = {"envelope/decay", .Seconds, nil},
	.Envelope_Sustain               = {"envelope/sustain", .Number, nil},
	.Envelope_Release               = {"envelope/release", .Seconds, nil},
	.Filter_Type                    = {"filter/type", .Choice, FILTER_CHOICES},
	.Filter_Frequency               = {"filter/frequency", .Hz, nil},
	.Filter_Q                       = {"filter/q", .Number, nil},
	.Filter_Rolloff                 = {"filter/rolloff", .Number, nil},
	.Filter_Gain                    = {"filter/gain", .Db, nil},
	.Filter_Envelope_Attack         = {"filter_envelope/attack", .Seconds, nil},
	.Filter_Envelope_Decay          = {"filter_envelope/decay", .Seconds, nil},
	.Filter_Envelope_Sustain        = {"filter_envelope/sustain", .Number, nil},
	.Filter_Envelope_Release        = {"filter_envelope/release", .Seconds, nil},
	.Filter_Envelope_Base_Frequency = {"filter_envelope/base_frequency", .Hz, nil},
	.Filter_Envelope_Octaves        = {"filter_envelope/octaves", .Number, nil},
	.Filter_Envelope_Exponent       = {"filter_envelope/exponent", .Number, nil},
	.Modulation_Type                = {"modulation/type", .Choice, WAVE_CHOICES},
	.Modulation_Envelope_Attack     = {"modulation_envelope/attack", .Seconds, nil},
	.Modulation_Envelope_Decay      = {"modulation_envelope/decay", .Seconds, nil},
	.Modulation_Envelope_Sustain    = {"modulation_envelope/sustain", .Number, nil},
	.Modulation_Envelope_Release    = {"modulation_envelope/release", .Seconds, nil},
	.Harmonicity                    = {"harmonicity", .Number, nil},
	.Modulation_Index               = {"modulation_index", .Number, nil},
	.Pitch_Decay                    = {"pitch_decay", .Seconds, nil},
	.Octaves                        = {"octaves", .Number, nil},
	.Resonance                      = {"resonance", .Number, nil},
	.Attack_Noise                   = {"attack_noise", .Number, nil},
	.Dampening                      = {"dampening", .Hz, nil},
	.Release                        = {"release", .Seconds, nil},
	.Noise_Type                     = {"noise/type", .Choice, NOISE_CHOICES},
	.Portamento                     = {"portamento", .Seconds, nil},
	.Cutoff                         = {"cutoff", .Hz, nil},
	.Cutoff2                        = {"cutoff2", .Hz, nil},
	.Decay                          = {"decay", .Number, nil},
	.Tone                           = {"tone", .Number, nil},
	.Kit                            = {"kit", .Choice, KIT_CHOICES},
	.Sample_Set                     = {"set", .Asset, nil},
	.Machine                        = {"machine", .Choice, MACHINE_CHOICES},
	.Tune                           = {"tune", .Number, nil},
	.Accent                         = {"accent", .Number, nil},
	.Offset                         = {"offset", .Seconds, nil},
	.Fade_In                        = {"fade_in", .Seconds, nil},
	.Fade_Out                       = {"fade_out", .Seconds, nil},
	.Curve                          = {"curve", .Choice, CURVE_CHOICES},
	.Mono                           = {"mono", .Number, nil},
	.Wet                            = {"wet", .Number, nil},
	.Type                           = {"type", .Choice, FILTER_CHOICES},
	.Frequency                      = {"frequency", .Hz, nil},
	.Q                              = {"q", .Number, nil},
	.Rolloff                        = {"rolloff", .Number, nil},
	.Gain                           = {"gain", .Db, nil},
	.Low                            = {"low", .Db, nil},
	.Mid                            = {"mid", .Db, nil},
	.High                           = {"high", .Db, nil},
	.Low_Frequency                  = {"low_frequency", .Hz, nil},
	.High_Frequency                 = {"high_frequency", .Hz, nil},
	.Threshold                      = {"threshold", .Db, nil},
	.Ratio                          = {"ratio", .Number, nil},
	.Knee                           = {"knee", .Db, nil},
	.Attack                         = {"attack", .Seconds, nil},
	.Pre_Delay                      = {"pre_delay", .Seconds, nil},
	.Delay_Time                     = {"delay_time", .Seconds, nil},
	.Feedback                       = {"feedback", .Number, nil},
	.Depth                          = {"depth", .Number, nil},
	.Base_Frequency                 = {"base_frequency", .Hz, nil},
	.Distortion                     = {"distortion", .Number, nil},
	.Bits                           = {"bits", .Number, nil},
	.Width                          = {"width", .Number, nil},
}

// ---- notes -------------------------------------------------------------------------

// A note as a voice plays it: times in seconds.
Note :: struct {
	time:     f64, // its start (the voice renders from its own sample 0)
	duration: f64, // how long the gate is held; the release follows
	pitch:    f32, // MIDI, 60 = C4; drums: 0 means the pad's own tuning
	velocity: f32, // 0..1
	pad:      Pad,
}

// A DrumKit's pads.
Pad :: enum u8 {
	None,
	Kick,
	Snare,
	Clap,
	Rim,
	Hat,
	Open_Hat,
	Crash,
	Ride,
	Tom_Low,
	Tom_Mid,
	Tom_High,
	Shaker,
	Cowbell,
	Conga_Low,
	Conga_Mid,
	Conga_High,
	Clave,
	Maracas,
	Tambourine,
}

PAD_NAMES := [Pad]string {
	.None     = "",
	.Kick     = "kick",
	.Snare    = "snare",
	.Clap     = "clap",
	.Rim      = "rim",
	.Hat      = "hat",
	.Open_Hat = "open_hat",
	.Crash    = "crash",
	.Ride     = "ride",
	.Tom_Low  = "tom_low",
	.Tom_Mid  = "tom_mid",
	.Tom_High = "tom_high",
	.Shaker   = "shaker",
	.Cowbell  = "cowbell",
	.Conga_Low = "conga_low",
	.Conga_Mid = "conga_mid",
	.Conga_High = "conga_high",
	.Clave    = "clave",
	.Maracas  = "maracas",
	.Tambourine = "tambourine",
}

// A pad that cuts others on its track when it starts (a closed hat chokes
// a ringing open one), as rows.
PAD_CHOKES := #partial [Pad]bit_set[Pad] {
	.Hat = {.Open_Hat},
}

// The fade a choked note takes: 5 ms.
CHOKE_SAMPLES :: RATE * 5 / 1000

pad_from_name :: proc(name: string) -> (Pad, bool) {
	for n, p in PAD_NAMES {
		if p != .None && n == name {
			return p, true
		}
	}
	return .None, false
}

// ---- devices -----------------------------------------------------------------------

Device_Category :: enum u8 {
	Instrument, // a Tone class
	Preset, // one of onimite's synth.lua voices
	Effect,
}

// A playing note's state: a fixed slot (nothing is allocated while playing).
// A kind keeps its own state struct in it (#assert size_of(X) <= size_of(Voice_State)).
VOICE_STATE_SIZE :: 16 * 1024

Voice_State :: struct #align (16) {
	bytes: [VOICE_STATE_SIZE]u8,
}

// What a voice may read beyond its note: the sample bank.
Voice_Env :: struct {
	bank: ^Bank,
}

// Plays a note's next len(l) samples, adding into l and r. `at` is how many
// of the note's samples earlier calls played; at == 0 starts it (s is
// zeroed: read the params and the seed into it). The gate closes at sample
// round(n.duration * RATE). Returns false once the note is silent for good.
// The samples never depend on how the note is split into calls.
Voice_Proc :: #type proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool
// Seconds the note sounds, when the row's rule (`length`, or the gate plus
// `release`) is not enough.
Tail_Proc :: #type proc(p: ^Params, n: Note, env: ^Voice_Env) -> f64
// An effect instance's state is bytes the engine sizes once from the params
// (its delay lines) and keeps. Reset clears its history and puts what moves
// in time (an LFO, a reverb's drift) where it is at song sample `at`. The
// effect proc processes the next block in place, causally: a sample out
// depends only on samples in up to it and `latency` samples after (a
// lookahead), whatever the block size. Key: a sidechain detector input
// (nil: the signal).
Effect_Size_Proc :: #type proc(p: ^Params) -> int
Effect_Reset_Proc :: #type proc(state: []u8, p: ^Params, at: i64)
Effect_Proc :: #type proc(state: []u8, p: ^Params, l, r: []f32, key_l, key_r: []f32)
Effect_Latency_Proc :: #type proc(p: ^Params) -> int
// Seconds of sound after the input stops (nil: none).
Effect_Tail_Proc :: #type proc(p: ^Params) -> f64

Param_Value :: struct {
	param: Param,
	value: f32,
}

Device_Row :: struct {
	name:        string,
	category:    Device_Category,
	reads:       Param_Set,
	defaults:    []Param_Value, // Tone's; params read but not listed are 0
	voice:       Voice_Proc,
	tail:        Tail_Proc,
	length:      f32, // a fixed length (seconds) for one-shots
	release:     Param, // the gate plus this param's seconds (None: the gate)
	// Bytes a voice's state takes (0: VOICE_STATE_SIZE): a track's slots are
	// this big, so hundreds of one-note clip tracks stay small.
	state:       int,
	// One voice for the whole track: a new note goes to the playing voice
	// (its state kept, `at` 0 again), which reads from its state whether the
	// last gate was still open (a slide, legato) or not (a new attack).
	mono:        bool,
	// Its output is a function of the note's sample index alone (a sample
	// read at a position): a seek starts it where it is, nothing rendered.
	jump:        bool,
	effect:      Effect_Proc,
	effect_size: Effect_Size_Proc,
	effect_reset: Effect_Reset_Proc,
	effect_latency: Effect_Latency_Proc, // nil: none
	effect_tail: Effect_Tail_Proc,
}

Device_Kind :: enum u8 {
	// Tone's instruments.
	Synth,
	Mono_Synth,
	FM_Synth,
	AM_Synth,
	Membrane_Synth,
	Metal_Synth,
	Noise_Synth,
	Pluck_Synth,
	Drum_Kit,
	Sampler,
	Drum_Machine,
	Acid_Synth,
	Player,
	// onimite's synth.lua voices, and a snare and a sub.
	Kick,
	Snare,
	Clap,
	Hat,
	Open_Hat,
	Crash,
	Bass,
	Sub_Bass,
	Pad,
	Stab,
	Pluck,
	Lead,
	Bell,
	Riser,
	Whoosh,
	Impact,
	Tom,
	Thump,
	Fall,
	Tape_Chord,
	Tick,
	Beep,
	Crackle,
	Glitch,
	Blip,
	Done,
	// Tone's effects.
	Filter,
	EQ3,
	Compressor,
	Limiter,
	Gate,
	Reverb,
	Feedback_Delay,
	Ping_Pong_Delay,
	Chorus,
	Distortion,
	Bit_Crusher,
	Stereo_Widener,
	Auto_Filter,
}

@(private = "file")
OSC :: Param_Set{.Oscillator_Type, .Oscillator_Count, .Oscillator_Spread, .Oscillator_Width}
@(private = "file")
ENV :: Param_Set{.Envelope_Attack, .Envelope_Decay, .Envelope_Sustain, .Envelope_Release}
@(private = "file")
FILTER :: Param_Set{.Filter_Type, .Filter_Frequency, .Filter_Q, .Filter_Rolloff, .Filter_Gain}
@(private = "file")
FILTER_ENV :: Param_Set {
	.Filter_Envelope_Attack,
	.Filter_Envelope_Decay,
	.Filter_Envelope_Sustain,
	.Filter_Envelope_Release,
	.Filter_Envelope_Base_Frequency,
	.Filter_Envelope_Octaves,
	.Filter_Envelope_Exponent,
}
@(private = "file")
MOD :: Param_Set {
	.Modulation_Type,
	.Modulation_Envelope_Attack,
	.Modulation_Envelope_Decay,
	.Modulation_Envelope_Sustain,
	.Modulation_Envelope_Release,
	.Harmonicity,
}
@(private = "file")
KNOBS :: Param_Set{.Cutoff, .Cutoff2, .Decay, .Tone, .Envelope_Attack}
@(private = "file")
FX :: Param_Set{.Wet}

DEVICE_TABLE := [Device_Kind]Device_Row {
	.Synth = {
		name = "Synth", category = .Instrument, reads = OSC + ENV + {.Portamento},
		defaults = {{.Oscillator_Type, f32(dsp.Wave.Triangle)}, {.Oscillator_Count, 3}, {.Oscillator_Spread, 20}, {.Oscillator_Width, 0.5}, {.Envelope_Attack, 0.005}, {.Envelope_Decay, 0.1}, {.Envelope_Sustain, 0.3}, {.Envelope_Release, 1}},
		voice = voice_synth, release = .Envelope_Release,
	},
	.Mono_Synth = {
		name = "MonoSynth", category = .Instrument, reads = OSC + ENV + FILTER + FILTER_ENV + {.Portamento},
		defaults = {{.Oscillator_Type, f32(dsp.Wave.Square)}, {.Oscillator_Count, 3}, {.Oscillator_Spread, 20}, {.Oscillator_Width, 0.5}, {.Envelope_Attack, 0.005}, {.Envelope_Decay, 0.1}, {.Envelope_Sustain, 0.9}, {.Envelope_Release, 1}, {.Filter_Type, f32(dsp.Filter_Type.Lowpass)}, {.Filter_Q, 1}, {.Filter_Rolloff, -12}, {.Filter_Envelope_Attack, 0.6}, {.Filter_Envelope_Decay, 0.2}, {.Filter_Envelope_Sustain, 0.5}, {.Filter_Envelope_Release, 2}, {.Filter_Envelope_Base_Frequency, 200}, {.Filter_Envelope_Octaves, 3}, {.Filter_Envelope_Exponent, 2}},
		voice = voice_mono_synth, release = .Envelope_Release,
	},
	.FM_Synth = {
		name = "FMSynth", category = .Instrument, reads = OSC + ENV + MOD + {.Modulation_Index, .Portamento},
		defaults = {{.Oscillator_Type, f32(dsp.Wave.Sine)}, {.Oscillator_Count, 3}, {.Oscillator_Spread, 20}, {.Envelope_Attack, 0.01}, {.Envelope_Decay, 0.01}, {.Envelope_Sustain, 1}, {.Envelope_Release, 0.5}, {.Modulation_Type, f32(dsp.Wave.Square)}, {.Modulation_Envelope_Attack, 0.5}, {.Modulation_Envelope_Sustain, 1}, {.Modulation_Envelope_Release, 0.5}, {.Harmonicity, 3}, {.Modulation_Index, 10}},
		voice = voice_fm_synth, release = .Envelope_Release,
	},
	.AM_Synth = {
		name = "AMSynth", category = .Instrument, reads = OSC + ENV + MOD + {.Portamento},
		defaults = {{.Oscillator_Type, f32(dsp.Wave.Sine)}, {.Oscillator_Count, 3}, {.Oscillator_Spread, 20}, {.Envelope_Attack, 0.01}, {.Envelope_Decay, 0.01}, {.Envelope_Sustain, 1}, {.Envelope_Release, 0.5}, {.Modulation_Type, f32(dsp.Wave.Square)}, {.Modulation_Envelope_Attack, 0.5}, {.Modulation_Envelope_Sustain, 1}, {.Modulation_Envelope_Release, 0.5}, {.Harmonicity, 3}},
		voice = voice_am_synth, release = .Envelope_Release,
	},
	.Membrane_Synth = {
		name = "MembraneSynth", category = .Instrument, reads = OSC + ENV + {.Pitch_Decay, .Octaves},
		defaults = {{.Oscillator_Type, f32(dsp.Wave.Sine)}, {.Oscillator_Count, 3}, {.Oscillator_Spread, 20}, {.Envelope_Attack, 0.001}, {.Envelope_Decay, 0.4}, {.Envelope_Sustain, 0.01}, {.Envelope_Release, 1.4}, {.Pitch_Decay, 0.05}, {.Octaves, 10}},
		voice = voice_membrane_synth, release = .Envelope_Release,
	},
	.Metal_Synth = {
		name = "MetalSynth", category = .Instrument, reads = ENV + {.Harmonicity, .Modulation_Index, .Resonance, .Octaves},
		defaults = {{.Envelope_Attack, 0.001}, {.Envelope_Decay, 1.4}, {.Envelope_Sustain, 0}, {.Envelope_Release, 0.2}, {.Harmonicity, 5.1}, {.Modulation_Index, 32}, {.Resonance, 4000}, {.Octaves, 1.5}},
		voice = voice_metal_synth, release = .Envelope_Release,
	},
	.Noise_Synth = {
		name = "NoiseSynth", category = .Instrument, reads = ENV + {.Noise_Type},
		defaults = {{.Envelope_Attack, 0.005}, {.Envelope_Decay, 0.1}, {.Envelope_Sustain, 0}, {.Envelope_Release, 1}, {.Noise_Type, f32(dsp.Noise_Type.White)}},
		voice = voice_noise_synth, release = .Envelope_Release,
	},
	.Pluck_Synth = {
		name = "PluckSynth", category = .Instrument, reads = {.Attack_Noise, .Dampening, .Resonance, .Release},
		defaults = {{.Attack_Noise, 1}, {.Dampening, 4000}, {.Resonance, 0.7}, {.Release, 1}},
		voice = voice_pluck_synth, tail = tail_pluck_synth,
	},
	.Drum_Kit = {name = "DrumKit", category = .Instrument, reads = {.Kit}, voice = voice_drum_kit, tail = tail_drum_kit},
	.Drum_Machine = {name = "DrumMachine", category = .Instrument, reads = {.Machine, .Decay, .Tone, .Tune}, defaults = {{.Decay, 1}, {.Tone, 0.5}}, voice = voice_drum_machine, tail = tail_drum_machine},
	.Acid_Synth = {
		name = "AcidSynth", category = .Instrument, mono = true,
		reads = {.Oscillator_Type, .Filter_Frequency, .Filter_Q, .Filter_Envelope_Octaves, .Envelope_Decay, .Accent, .Portamento, .Tune},
		defaults = {{.Oscillator_Type, f32(dsp.Wave.Sawtooth)}, {.Filter_Frequency, 400}, {.Filter_Q, 8}, {.Filter_Envelope_Octaves, 3}, {.Envelope_Decay, 0.3}, {.Accent, 0.5}, {.Portamento, 0.06}},
		voice = voice_acid_synth, tail = tail_acid_synth,
	},
	.Player = {name = "Player", category = .Instrument, reads = {.Sample_Set, .Offset, .Fade_In, .Fade_Out, .Curve, .Mono}, voice = voice_player, tail = tail_player, state = PLAYER_STATE_BYTES, jump = true},
	.Sampler = {name = "Sampler", category = .Instrument, reads = {.Sample_Set, .Attack, .Release}, defaults = {{.Release, 0.1}}, voice = voice_sampler, tail = tail_sampler, release = .Release, jump = true},
	// synth.lua's lengths: a fixed one for one-shots, the note's for the rest
	.Kick = {name = "kick", category = .Preset, reads = KNOBS, voice = voice_kick, length = 0.4},
	.Snare = {name = "snare", category = .Preset, reads = KNOBS, voice = voice_snare, length = 0.35},
	.Clap = {name = "clap", category = .Preset, reads = KNOBS, voice = voice_clap, length = 0.3},
	.Hat = {name = "hat", category = .Preset, reads = KNOBS, voice = voice_hat, tail = tail_hat},
	.Open_Hat = {name = "open_hat", category = .Preset, reads = KNOBS, voice = voice_open_hat, length = 0.22},
	.Crash = {name = "crash", category = .Preset, reads = KNOBS, voice = voice_crash, length = 1.6},
	.Bass = {name = "bass", category = .Preset, reads = KNOBS, voice = voice_bass},
	.Sub_Bass = {name = "sub_bass", category = .Preset, reads = KNOBS, voice = voice_sub_bass, tail = tail_sub_bass},
	.Pad = {name = "pad", category = .Preset, reads = KNOBS, voice = voice_pad, tail = tail_chord},
	.Stab = {name = "stab", category = .Preset, reads = KNOBS, voice = voice_stab, tail = tail_chord},
	.Pluck = {name = "pluck", category = .Preset, reads = KNOBS, voice = voice_pluck, length = 0.18},
	.Lead = {name = "lead", category = .Preset, reads = KNOBS, voice = voice_lead},
	.Bell = {name = "bell", category = .Preset, reads = KNOBS, voice = voice_bell, tail = tail_bell},
	.Riser = {name = "riser", category = .Preset, reads = KNOBS, voice = voice_riser},
	.Whoosh = {name = "whoosh", category = .Preset, reads = KNOBS, voice = voice_whoosh},
	.Impact = {name = "impact", category = .Preset, reads = KNOBS, voice = voice_impact, length = 2.5},
	.Tom = {name = "tom", category = .Preset, reads = KNOBS, voice = voice_tom, length = 0.5},
	.Thump = {name = "thump", category = .Preset, reads = KNOBS, voice = voice_thump, length = 0.7},
	.Fall = {name = "fall", category = .Preset, reads = KNOBS, voice = voice_fall},
	.Tape_Chord = {name = "tape_chord", category = .Preset, reads = KNOBS, voice = voice_tape_chord},
	.Tick = {name = "tick", category = .Preset, reads = KNOBS, voice = voice_tick, length = 0.025},
	.Beep = {name = "beep", category = .Preset, reads = KNOBS, voice = voice_beep, length = 0.03},
	.Crackle = {name = "crackle", category = .Preset, reads = KNOBS, voice = voice_crackle, length = 0.012},
	.Glitch = {name = "glitch", category = .Preset, reads = KNOBS, voice = voice_glitch},
	.Blip = {name = "blip", category = .Preset, reads = KNOBS, voice = voice_blip, length = 0.09},
	.Done = {name = "done", category = .Preset, reads = KNOBS, voice = voice_done, length = 0.21},
	// effects: Tone's defaults
	.Filter = {name = "Filter", category = .Effect, reads = FX + {.Type, .Frequency, .Q, .Rolloff, .Gain}, defaults = {{.Wet, 1}, {.Type, f32(dsp.Filter_Type.Lowpass)}, {.Frequency, 350}, {.Q, 1}, {.Rolloff, -12}}, effect = effect_filter, effect_size = size_filter, effect_reset = reset_filter},
	.EQ3 = {name = "EQ3", category = .Effect, reads = FX + {.Low, .Mid, .High, .Low_Frequency, .High_Frequency}, defaults = {{.Wet, 1}, {.Low_Frequency, 400}, {.High_Frequency, 2500}}, effect = effect_eq3, effect_size = size_eq3, effect_reset = reset_eq3},
	.Compressor = {name = "Compressor", category = .Effect, reads = FX + {.Threshold, .Ratio, .Knee, .Attack, .Release}, defaults = {{.Wet, 1}, {.Threshold, -24}, {.Ratio, 12}, {.Knee, 30}, {.Attack, 0.003}, {.Release, 0.25}}, effect = effect_compressor, effect_size = size_compressor, effect_reset = reset_compressor},
	.Limiter = {name = "Limiter", category = .Effect, reads = FX + {.Threshold, .Release}, defaults = {{.Wet, 1}, {.Threshold, -12}, {.Release, 0.1}}, effect = effect_limiter, effect_size = size_limiter, effect_reset = reset_limiter, effect_latency = latency_limiter, effect_tail = tail_limiter},
	.Gate = {name = "Gate", category = .Effect, reads = FX + {.Threshold, .Attack, .Release}, defaults = {{.Wet, 1}, {.Threshold, -40}, {.Attack, 0.001}, {.Release, 0.1}}, effect = effect_gate, effect_size = size_gate, effect_reset = reset_gate},
	.Reverb = {name = "Reverb", category = .Effect, reads = FX + {.Decay, .Pre_Delay}, defaults = {{.Wet, 1}, {.Decay, 1.5}, {.Pre_Delay, 0.01}}, effect = effect_reverb, effect_size = size_reverb, effect_reset = reset_reverb, effect_tail = tail_reverb},
	.Feedback_Delay = {name = "FeedbackDelay", category = .Effect, reads = FX + {.Delay_Time, .Feedback}, defaults = {{.Wet, 1}, {.Delay_Time, 0.25}, {.Feedback, 0.125}}, effect = effect_feedback_delay, effect_size = size_feedback_delay, effect_reset = reset_feedback_delay, effect_tail = tail_delay},
	.Ping_Pong_Delay = {name = "PingPongDelay", category = .Effect, reads = FX + {.Delay_Time, .Feedback}, defaults = {{.Wet, 1}, {.Delay_Time, 0.25}, {.Feedback, 0.125}}, effect = effect_ping_pong_delay, effect_size = size_ping_pong_delay, effect_reset = reset_ping_pong_delay, effect_tail = tail_delay},
	.Chorus = {name = "Chorus", category = .Effect, reads = FX + {.Frequency, .Delay_Time, .Depth}, defaults = {{.Wet, 0.5}, {.Frequency, 1.5}, {.Delay_Time, 0.0035}, {.Depth, 0.7}}, effect = effect_chorus, effect_size = size_chorus, effect_reset = reset_chorus, effect_tail = tail_chorus},
	.Distortion = {name = "Distortion", category = .Effect, reads = FX + {.Distortion}, defaults = {{.Wet, 1}, {.Distortion, 0.4}}, effect = effect_distortion, effect_size = size_distortion, effect_reset = reset_distortion, effect_latency = latency_distortion},
	.Bit_Crusher = {name = "BitCrusher", category = .Effect, reads = FX + {.Bits}, defaults = {{.Wet, 1}, {.Bits, 4}}, effect = effect_bit_crusher, effect_size = size_bit_crusher, effect_reset = reset_bit_crusher},
	.Stereo_Widener = {name = "StereoWidener", category = .Effect, reads = FX + {.Width}, defaults = {{.Wet, 1}, {.Width, 0.5}}, effect = effect_stereo_widener, effect_size = size_stereo_widener, effect_reset = reset_stereo_widener},
	.Auto_Filter = {name = "AutoFilter", category = .Effect, reads = FX + {.Frequency, .Depth, .Base_Frequency, .Octaves, .Filter_Type, .Filter_Q, .Filter_Rolloff}, defaults = {{.Wet, 1}, {.Frequency, 1}, {.Depth, 1}, {.Base_Frequency, 200}, {.Octaves, 2.6}, {.Filter_Type, f32(dsp.Filter_Type.Lowpass)}, {.Filter_Q, 1}, {.Filter_Rolloff, -12}}, effect = effect_auto_filter, effect_size = size_auto_filter, effect_reset = reset_auto_filter},
}

device_from_name :: proc(name: string) -> (Device_Kind, bool) {
	for row, k in DEVICE_TABLE {
		if row.name == name {
			return k, true
		}
	}
	return {}, false
}

// A kind's values with nothing set: its row's defaults.
params_from_kind :: proc(kind: Device_Kind) -> (p: Params) {
	for d in DEVICE_TABLE[kind].defaults {
		p[d.param] = d.value
	}
	return
}

// Seconds a note sounds: the row's proc, else its fixed length, else the
// gate plus its release (at most 30).
// Bytes a voice of `kind` needs, a multiple of 16.
voice_state_bytes :: proc(kind: Device_Kind) -> int {
	n := DEVICE_TABLE[kind].state
	return ((n > 0 ? n : VOICE_STATE_SIZE) + 15) &~ 15
}

note_tail :: proc(kind: Device_Kind, p: ^Params, n: Note, env: ^Voice_Env = nil) -> f64 {
	row := &DEVICE_TABLE[kind]
	t: f64
	switch {
	case row.tail != nil:
		t = row.tail(p, n, env)
	case row.length > 0:
		t = f64(row.length)
	case:
		t = n.duration + (row.release != .None ? f64(p[row.release]) : 0)
	}
	return clamp(t, 0, 30)
}

effect_tail :: proc(kind: Device_Kind, p: ^Params) -> f64 {
	row := &DEVICE_TABLE[kind]
	return row.effect_tail != nil ? row.effect_tail(p) : 0
}

// synth.lua's hat lasts its `dur` (the note's), 45 ms when none is given.
tail_hat :: proc(p: ^Params, n: Note, env: ^Voice_Env) -> f64 {return n.duration > 0 ? n.duration : 0.045}
