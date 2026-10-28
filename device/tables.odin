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
	Gain, // a level written in dB, kept linear (a node's gain_db)
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

// What shapes an effect (its stages, its program): read once, no lane moves
// it (a Choice, an Asset or a Table neither).
PARAM_FIXED :: Param_Set{.Filter_Rolloff, .Rolloff, .Program}

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
// A kind keeps its own state struct in it (#assert size_of(X) <= VOICE_STATE_SIZE).
VOICE_STATE_SIZE :: 32 * 1024 // the most a voice keeps: a program's state is checked against it (voice_too_big)

// Where a voice's bytes start, 16-aligned: as many as its slot holds
// (voice_bytes), only ever reached by pointer, so it has no size of its own
// for a copy or a zeroing to run past its slot with.
Voice_State :: struct #align (16) {}

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
Effect_Proc :: #type proc(state: []u8, p: ^Params, l, r: []f32, key_l, key_r: []f32, scratch: ^Fx_Scratch)
Effect_Latency_Proc :: #type proc(p: ^Params) -> int

// What an effect holds of what it heard, in seconds: how long its output
// rings on after its input stops (a reverb's tail: what a song's end waits
// for), and how long until its state no longer depends on older input (what
// an exact seek pre-rolls, and how long a node stays awake through silence
// before it may sleep and wake fresh). A filter or a reverb remembers as
// long as it rings; a compressor rings not at all, but its envelope
// remembers several of its releases.
Effect_Memory :: struct {
	ring:  f64,
	state: f64, // >= ring
}

// The kinds of memory an effect has, a rule each (MEMORY_RULES): every
// effect row names its own. The zero value, .Unset, is a row that doesn't:
// effect_memory refuses it, and so do the tests.
Memory_Rule :: enum u8 {
	Unset,
	Stateless, // each sample out from its sample in alone
	Filter, // SVFs at .Frequency and .Q, cascaded by .Rolloff
	Crossover, // EQ3's Butterworth stages, the slowest at .Low_Frequency
	Swept_Filter, // AutoFilter's SVFs, the slowest at .Base_Frequency
	Envelope, // a level follower over .Attack and .Release (Compressor, Limiter)
	Gate, // a 20 ms peak follower, then a gain over .Attack and .Release
	Oversampler, // Distortion's half-band filters
	Echo, // a delay line fed back into itself
	Chorus, // a swept delay line
	Reverb,
}

MEMORY_RULES := [Memory_Rule]proc(p: ^Params) -> Effect_Memory {
	.Unset        = nil,
	.Stateless    = proc(p: ^Params) -> Effect_Memory {return {}},
	.Filter       = memory_filter,
	.Crossover    = memory_crossover,
	.Swept_Filter = memory_swept_filter,
	.Envelope     = memory_envelope,
	.Gate         = memory_gate,
	.Oversampler  = memory_oversampler,
	.Echo         = memory_echo,
	.Chorus       = memory_chorus,
	.Reverb       = memory_reverb,
}

Param_Value :: struct {
	param: Param,
	value: f32,
}

// A device kind's row: what it reads and Tone's defaults; an effect's procs
// (the Voice, an instrument, plays a program of nodes: graph.odin's voice
// procs, its Program param naming the program; an effect Row plays one over
// its input: rows.odin).
Device_Row :: struct {
	name:        string,
	reads:       Param_Set,
	defaults:    []Param_Value, // Tone's; params read but not listed are 0
	effect:      Effect_Proc,
	state:       int, // an effect's state's bytes (its struct), before its rings
	rings:       proc(p: ^Params) -> int, // bytes of its delay rings after it (nil: none)
	clock:       bool, // its state starts with the song sample its next input is (a reset puts it at `at`)
	init:        proc(state: []u8), // what a reset sets past zero (nil: nothing)
	effect_latency: Effect_Latency_Proc, // nil: none
	memory:      Memory_Rule, // an effect's (MEMORY_RULES)
	program:     bool, // it plays a program of nodes (its .Program): its state and memory are its program's too
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
	// An effect row: a program of nodes over its input (rows.odin).
	Row,
}

@(private = "file")
FX :: Param_Set{.Wet}

DEVICE_TABLE := [Device_Kind]Device_Row {
	.Voice = {name = "", program = true},
	// effects: Tone's defaults
	.Filter = {name = "Filter", reads = FX + {.Type, .Frequency, .Q, .Rolloff, .Gain}, defaults = {{.Wet, 1}, {.Type, f32(dsp.Filter_Type.Lowpass)}, {.Frequency, 350}, {.Q, 1}, {.Rolloff, -12}}, effect = effect_filter, state = size_of(Fx_Filter), memory = .Filter},
	.EQ3 = {name = "EQ3", reads = FX + {.Low, .Mid, .High, .Low_Frequency, .High_Frequency}, defaults = {{.Wet, 1}, {.Low_Frequency, 400}, {.High_Frequency, 2500}}, effect = effect_eq3, state = size_of(Fx_EQ3), memory = .Crossover},
	.Compressor = {name = "Compressor", reads = FX + {.Threshold, .Ratio, .Knee, .Attack, .Release}, defaults = {{.Wet, 1}, {.Threshold, -24}, {.Ratio, 12}, {.Knee, 30}, {.Attack, 0.003}, {.Release, 0.25}}, effect = effect_compressor, state = size_of(Fx_Compressor), memory = .Envelope},
	.Limiter = {name = "Limiter", reads = FX + {.Threshold, .Release}, defaults = {{.Wet, 1}, {.Threshold, -12}, {.Release, 0.1}}, effect = effect_limiter, state = size_of(Fx_Limiter), clock = true, init = init_limiter, effect_latency = latency_limiter, memory = .Envelope},
	.Gate = {name = "Gate", reads = FX + {.Threshold, .Attack, .Release}, defaults = {{.Wet, 1}, {.Threshold, -40}, {.Attack, 0.001}, {.Release, 0.1}}, effect = effect_gate, state = size_of(Fx_Gate), memory = .Gate},
	.Reverb = {name = "Reverb", reads = FX + {.Decay, .Pre_Delay}, defaults = {{.Wet, 1}, {.Decay, 1.5}, {.Pre_Delay, 0.01}}, effect = effect_reverb, state = size_of(Fx_Reverb), rings = rings_reverb, clock = true, init = init_reverb, memory = .Reverb},
	.Feedback_Delay = {name = "FeedbackDelay", reads = FX + {.Delay_Time, .Feedback}, defaults = {{.Wet, 1}, {.Delay_Time, 0.25}, {.Feedback, 0.125}}, effect = effect_feedback_delay, state = size_of(Fx_Delay), rings = rings_feedback_delay, clock = true, memory = .Echo},
	.Ping_Pong_Delay = {name = "PingPongDelay", reads = FX + {.Delay_Time, .Feedback}, defaults = {{.Wet, 1}, {.Delay_Time, 0.25}, {.Feedback, 0.125}}, effect = effect_ping_pong_delay, state = size_of(Fx_Delay), rings = rings_ping_pong_delay, clock = true, memory = .Echo},
	.Chorus = {name = "Chorus", reads = FX + {.Frequency, .Delay_Time, .Depth}, defaults = {{.Wet, 0.5}, {.Frequency, 1.5}, {.Delay_Time, 0.0035}, {.Depth, 0.7}}, effect = effect_chorus, state = size_of(Fx_Delay), rings = rings_chorus, clock = true, memory = .Chorus},
	.Distortion = {name = "Distortion", reads = FX + {.Distortion}, defaults = {{.Wet, 1}, {.Distortion, 0.4}}, effect = effect_distortion, state = size_of(Fx_Distortion), effect_latency = latency_distortion, memory = .Oversampler},
	.Bit_Crusher = {name = "BitCrusher", reads = FX + {.Bits}, defaults = {{.Wet, 1}, {.Bits, 4}}, effect = effect_bit_crusher, state = 0, memory = .Stateless},
	.Stereo_Widener = {name = "StereoWidener", reads = FX + {.Width}, defaults = {{.Wet, 1}, {.Width, 0.5}}, effect = effect_stereo_widener, state = 0, memory = .Stateless},
	.Auto_Filter = {name = "AutoFilter", reads = FX + {.Frequency, .Depth, .Base_Frequency, .Octaves, .Filter_Type, .Filter_Q, .Filter_Rolloff}, defaults = {{.Wet, 1}, {.Frequency, 1}, {.Depth, 1}, {.Base_Frequency, 200}, {.Octaves, 2.6}, {.Filter_Type, f32(dsp.Filter_Type.Lowpass)}, {.Filter_Q, 1}, {.Filter_Rolloff, -12}}, effect = effect_auto_filter, state = size_of(Fx_Auto_Filter), clock = true, memory = .Swept_Filter},
	// a row: named by its own name (a spec's `effects`), its clock and then its program's voice
	.Row = {name = "", reads = {.Program}, effect = effect_row, state = size_of(Fx_Row), clock = true, memory = .Stateless, program = true},
}

// A built-in by its name (an instrument row's or an effect row's own name
// is no kind's).
device_from_name :: proc(name: string) -> (Device_Kind, bool) {
	for row, k in DEVICE_TABLE {
		if row.name != "" && row.name == name {
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

// An effect's memory by its row's rule (an effect without one is a bug in
// its row: the tests name it), and its program's (a Row's: progs holds it).
effect_memory :: proc(kind: Device_Kind, p: ^Params, progs: ^Programs = nil) -> Effect_Memory {
	row := &DEVICE_TABLE[kind]
	assert(row.memory != .Unset, "an effect row without a memory rule")
	m := MEMORY_RULES[row.memory](p)
	if row.program && progs != nil {
		if program := i32(p[.Program]); program >= 0 && int(program) < len(progs.programs) {
			x := program_memory(progs, program)
			m.ring += x
			m.state += x
		}
	}
	m.state = max(m.state, m.ring)
	return m
}

