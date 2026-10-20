// device: the instruments and effects. Every device is a row of DEVICE_TABLE
// (its name, which params it reads, Tone's defaults, and its procs); every
// option any of them reads is a row of PARAM_TABLE (its `/` path in a spec,
// its unit, its choices). A device's values are a `Params` filled from its
// row; the procs read them by Param. An instrument is a Voice playing a
// Program (graph.odin): a row of data over the primitives of NODE_TABLE.
// Nothing here parses or knows songs: a reader fills Params and Programs
// from the tables, the engine calls the procs over buffers.
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
	Table, // a table of CURVE_POINTS (a Curve's), stored as its index in Programs.tables
}

Param :: enum u8 {
	None,
	// AutoFilter's filter and range.
	Filter_Type,
	Filter_Q,
	Filter_Rolloff,
	Octaves,
	Release, // Limiter, Gate, Compressor
	Decay, // Reverb's (seconds)
	Program, // Voice: its program's index in Voice_Env.programs (set by the song, not a spec)
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
CURVE_CHOICES := []string{"linear", "equal_power"}

Curve :: dsp.Curve

PARAM_TABLE := [Param]Param_Row {
	.None                           = {"", .Number, nil},
	.Filter_Type                    = {"filter/type", .Choice, FILTER_CHOICES},
	.Filter_Q                       = {"filter/q", .Number, nil},
	.Filter_Rolloff                 = {"filter/rolloff", .Number, nil},
	.Octaves                        = {"octaves", .Number, nil},
	.Release                        = {"release", .Seconds, nil},
	.Decay                          = {"decay", .Number, nil},
	.Program                        = {"", .Number, nil},
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
	pad:      u32, // the pad it plays (name_id of its name; 0: none)
	accent:   f32, // 0..1
	kind:     Note_Kind,
	round:    u16, // earlier notes of its key on its track (a round robin's turn)
	keyswitch: u8, // 1 + the last keyswitch key before it (0: none)
	legato:   bool, // another note of its track is held when it starts
	level:    f32, // a gain on it (a release note's rt_decay; 0: 1)
}

// What a note is: played, or made at compose from another (an SFZ release
// trigger at a note's end, a key that switches articulation and doesn't
// sound).
Note_Kind :: enum u8 {
	Attack,
	Release,
	Keyswitch,
}

// General MIDI's drum names and keys: what a sample set's pad of one of
// these names answers when it gives no key (a sampled kit's zones, an SFZ
// keyed to General MIDI).
GM_PADS := [?]struct {
	name: string,
	key:  f32,
} {
	{"kick", 36}, {"rim", 37}, {"snare", 38}, {"clap", 39}, {"tom_low", 41}, {"hat", 42}, {"tom_mid", 45},
	{"open_hat", 46}, {"tom_high", 48}, {"crash", 49}, {"ride", 51}, {"tambourine", 54}, {"cowbell", 56},
	{"conga_high", 62}, {"conga_mid", 63}, {"conga_low", 64}, {"maracas", 70}, {"clave", 75}, {"shaker", 82},
}

gm_key :: proc(name: string) -> (f32, bool) {
	for g in GM_PADS {
		if g.name == name {
			return g.key, true
		}
	}
	return 0, false
}

// The fade a choked note takes: 5 ms.
CHOKE_SAMPLES :: RATE * 5 / 1000

// ---- devices -----------------------------------------------------------------------

// A playing note's state: a fixed slot (nothing is allocated while playing).
// A kind keeps its own state struct in it (#assert size_of(X) <= size_of(Voice_State)).
VOICE_STATE_SIZE :: 32 * 1024 // the most a voice keeps: a program's state is checked against it (voice_too_big)

Voice_State :: struct #align (16) {
	bytes: [VOICE_STATE_SIZE]u8,
}

// What a voice may read beyond its note: the sample bank, the song's
// instruments.
Voice_Env :: struct {
	bank:     ^Bank,
	programs: ^Programs,
}

// An effect instance's state is bytes the engine sizes once from the params
// (its delay lines) and keeps. Reset clears its history and puts what moves
// in time (an LFO, a reverb's drift) where it is at song sample `at`. The
// effect proc processes the next block in place, causally: a sample out
// depends only on samples in up to it and `latency` samples after (a
// lookahead), whatever the block size. Key: a sidechain detector input
// (nil: the signal).
Effect_Size_Proc :: #type proc(p: ^Params) -> int
Effect_Reset_Proc :: #type proc(state: []u8, p: ^Params, at: i64)
Effect_Proc :: #type proc(state: []u8, p: ^Params, l, r: []f32, key_l, key_r: []f32, scratch: ^Fx_Scratch)
Effect_Latency_Proc :: #type proc(p: ^Params) -> int
// Seconds of sound after the input stops (nil: none).
Effect_Tail_Proc :: #type proc(p: ^Params) -> f64

Param_Value :: struct {
	param: Param,
	value: f32,
}

// A device kind's row: what it reads and Tone's defaults; an effect's procs
// (the Voice, an instrument, plays a program of nodes: graph.odin's voice
// procs, its Program param naming the program).
Device_Row :: struct {
	name:        string,
	reads:       Param_Set,
	defaults:    []Param_Value, // Tone's; params read but not listed are 0
	effect:      Effect_Proc,
	effect_size: Effect_Size_Proc,
	effect_reset: Effect_Reset_Proc,
	effect_latency: Effect_Latency_Proc, // nil: none
	effect_tail: Effect_Tail_Proc,
}

Device_Kind :: enum u8 {
	// An instrument: a program of nodes (graph.odin; a clip's too).
	Voice,
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
FX :: Param_Set{.Wet}

DEVICE_TABLE := [Device_Kind]Device_Row {
	.Voice = {name = ""},
	// effects: Tone's defaults
	.Filter = {name = "Filter", reads = FX + {.Type, .Frequency, .Q, .Rolloff, .Gain}, defaults = {{.Wet, 1}, {.Type, f32(dsp.Filter_Type.Lowpass)}, {.Frequency, 350}, {.Q, 1}, {.Rolloff, -12}}, effect = effect_filter, effect_size = size_filter, effect_reset = reset_filter},
	.EQ3 = {name = "EQ3", reads = FX + {.Low, .Mid, .High, .Low_Frequency, .High_Frequency}, defaults = {{.Wet, 1}, {.Low_Frequency, 400}, {.High_Frequency, 2500}}, effect = effect_eq3, effect_size = size_eq3, effect_reset = reset_eq3},
	.Compressor = {name = "Compressor", reads = FX + {.Threshold, .Ratio, .Knee, .Attack, .Release}, defaults = {{.Wet, 1}, {.Threshold, -24}, {.Ratio, 12}, {.Knee, 30}, {.Attack, 0.003}, {.Release, 0.25}}, effect = effect_compressor, effect_size = size_compressor, effect_reset = reset_compressor},
	.Limiter = {name = "Limiter", reads = FX + {.Threshold, .Release}, defaults = {{.Wet, 1}, {.Threshold, -12}, {.Release, 0.1}}, effect = effect_limiter, effect_size = size_limiter, effect_reset = reset_limiter, effect_latency = latency_limiter, effect_tail = tail_limiter},
	.Gate = {name = "Gate", reads = FX + {.Threshold, .Attack, .Release}, defaults = {{.Wet, 1}, {.Threshold, -40}, {.Attack, 0.001}, {.Release, 0.1}}, effect = effect_gate, effect_size = size_gate, effect_reset = reset_gate},
	.Reverb = {name = "Reverb", reads = FX + {.Decay, .Pre_Delay}, defaults = {{.Wet, 1}, {.Decay, 1.5}, {.Pre_Delay, 0.01}}, effect = effect_reverb, effect_size = size_reverb, effect_reset = reset_reverb, effect_tail = tail_reverb},
	.Feedback_Delay = {name = "FeedbackDelay", reads = FX + {.Delay_Time, .Feedback}, defaults = {{.Wet, 1}, {.Delay_Time, 0.25}, {.Feedback, 0.125}}, effect = effect_feedback_delay, effect_size = size_feedback_delay, effect_reset = reset_feedback_delay, effect_tail = tail_delay},
	.Ping_Pong_Delay = {name = "PingPongDelay", reads = FX + {.Delay_Time, .Feedback}, defaults = {{.Wet, 1}, {.Delay_Time, 0.25}, {.Feedback, 0.125}}, effect = effect_ping_pong_delay, effect_size = size_ping_pong_delay, effect_reset = reset_ping_pong_delay, effect_tail = tail_delay},
	.Chorus = {name = "Chorus", reads = FX + {.Frequency, .Delay_Time, .Depth}, defaults = {{.Wet, 0.5}, {.Frequency, 1.5}, {.Delay_Time, 0.0035}, {.Depth, 0.7}}, effect = effect_chorus, effect_size = size_chorus, effect_reset = reset_chorus, effect_tail = tail_chorus},
	.Distortion = {name = "Distortion", reads = FX + {.Distortion}, defaults = {{.Wet, 1}, {.Distortion, 0.4}}, effect = effect_distortion, effect_size = size_distortion, effect_reset = reset_distortion, effect_latency = latency_distortion},
	.Bit_Crusher = {name = "BitCrusher", reads = FX + {.Bits}, defaults = {{.Wet, 1}, {.Bits, 4}}, effect = effect_bit_crusher, effect_size = size_bit_crusher, effect_reset = reset_bit_crusher},
	.Stereo_Widener = {name = "StereoWidener", reads = FX + {.Width}, defaults = {{.Wet, 1}, {.Width, 0.5}}, effect = effect_stereo_widener, effect_size = size_stereo_widener, effect_reset = reset_stereo_widener},
	.Auto_Filter = {name = "AutoFilter", reads = FX + {.Frequency, .Depth, .Base_Frequency, .Octaves, .Filter_Type, .Filter_Q, .Filter_Rolloff}, defaults = {{.Wet, 1}, {.Frequency, 1}, {.Depth, 1}, {.Base_Frequency, 200}, {.Octaves, 2.6}, {.Filter_Type, f32(dsp.Filter_Type.Lowpass)}, {.Filter_Q, 1}, {.Filter_Rolloff, -12}}, effect = effect_auto_filter, effect_size = size_auto_filter, effect_reset = reset_auto_filter},
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

// Bytes a voice of an instrument (its Program) needs, a multiple of 16.
voice_bytes :: proc(p: ^Params, env: ^Voice_Env) -> int {
	n := voice_bytes_graph(p, env)
	return ((n > 0 ? n : VOICE_STATE_SIZE) + 15) &~ 15
}

// Seconds a note of an instrument sounds (at most 30 past what is held).
note_tail :: proc(p: ^Params, n: Note, env: ^Voice_Env = nil) -> f64 {
	return clamp(tail_graph(p, n, env), 0, max(30, n.duration))
}

effect_tail :: proc(kind: Device_Kind, p: ^Params) -> f64 {
	row := &DEVICE_TABLE[kind]
	return row.effect_tail != nil ? row.effect_tail(p) : 0
}

