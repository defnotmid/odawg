package odawg_device

import "base:runtime"
import dsp "../dsp"
import base "../base"
import "core:math"

// The built-in node kinds, registered at init through register_node like
// any host's: oscillators, noise, a per-note random value, envelopes
// (Tone's ADSR, a one-pole decay with bursts, a ramp), an LFO, filters (the
// SVF chain, the 303's diode ladder), a drive, a slew, a map, a mix and a
// product, a comb (a delay line with feedback and damping inside: a plucked
// string, a body, a flanger), and the Sampler. Each kind's slots follow
// COMMON_FIELDS in its fields' order (a list last).

NODE_FILTER_CHOICES := []string{"lowpass", "highpass", "bandpass", "lowshelf", "highshelf", "notch", "allpass", "peaking", "diode", "onepole", "difference"}
PHASE_CHOICES := []string{"start", "random"}
PLAIN_WAVES := []string{"sine", "triangle", "sawtooth", "square", "pulse"}

// A comb's delay line (samples): its longest delay, and the lowest note a
// plucked string plays (about 12 Hz).
COMB_LINE :: 4096

// The kinds' ids (set at init).
NODE_OSC, NODE_NOISE, NODE_RANDOM, NODE_ENV, NODE_DECAY, NODE_RAMP, NODE_LFO: Node_Kind
NODE_FILTER, NODE_DRIVE, NODE_SLEW, NODE_MAP, NODE_CURVE, NODE_MIX, NODE_MUL, NODE_COMB, NODE_SAMPLER, NODE_REGION, NODE_SEGMENTS, NODE_CLIP: Node_Kind
NODE_LADDER, NODE_ONE_POLE, NODE_DIFFERENCE: Node_Kind

@(init, private = "file")
nodes_init :: proc "contextless" () {
	context = runtime.default_context()
	r := &NODES
	NODE_OSC = register_node(r, {
		name = "Osc", stereo = false, state = size_of(Osc_State), sides = osc_stereo, start = start_osc, process = process_osc,
		fields = {
			{name = "wave", unit = .Choice, choices = WAVE_CHOICES, default = f32(dsp.Wave.Sine)},
			{name = "count", unit = .Number, default = 3},
			{name = "spread", unit = .Cents, default = 20},
			{name = "width", unit = .Number, default = 0.5},
			{name = "ratio", unit = .Number, default = 1},
			{name = "tune", unit = .Number},
			{name = "frequency", unit = .Hz, per_sample = true},
			{name = "ring", unit = .Number},
			{name = "phase", unit = .Choice, choices = PHASE_CHOICES},
			{name = "hz", unit = .Hz, list = 6},
		},
	})
	NODE_NOISE = register_node(r, {name = "Noise", state = size_of(dsp.Noise), start = start_noise, process = process_noise, fields = {{name = "color", unit = .Choice, choices = NOISE_CHOICES}}})
	NODE_RANDOM = register_node(r, {name = "Random", steady = true, process = process_random})
	NODE_ENV = register_node(r, {
		name = "Env", unipolar = true, state = size_of(dsp.Adsr), start = start_env, process = process_env, tail = tail_env,
		fields = {
			{name = "attack", unit = .Seconds, default = 0.005},
			{name = "decay", unit = .Seconds, default = 0.1},
			{name = "sustain", unit = .Number, default = 1},
			{name = "release", unit = .Seconds, default = 0.1},
			{name = "attack_curve", unit = .Choice, choices = CURVE_NAMES},
			{name = "delay", unit = .Seconds},
			{name = "hold", unit = .Seconds},
			{name = "start", unit = .Number},
		},
	})
	NODE_DECAY = register_node(r, {
		name = "Decay", unipolar = true, state = size_of(Decay_State), start = start_decay, process = process_decay, tail = tail_decay,
		fields = {
			{name = "attack", unit = .Seconds},
			{name = "hold", unit = .Seconds},
			{name = "periods", unit = .Number},
			{name = "time", unit = .Seconds, default = 0.1},
			{name = "delay", unit = .Seconds},
			{name = "bursts", unit = .Number, default = 1},
			{name = "spacing", unit = .Seconds, default = 0.01},
			{name = "release", unit = .Seconds},
		},
	})
	NODE_RAMP = register_node(r, {
		name = "Ramp", unipolar = true, process = process_ramp,
		fields = {{name = "from", unit = .Number}, {name = "to", unit = .Number, default = 1}, {name = "time", unit = .Seconds}, {name = "curve", unit = .Number, default = 1}},
	})
	NODE_LFO = register_node(r, {
		name = "Lfo", state = size_of(dsp.Osc), start = start_lfo, process = process_lfo,
		fields = {
			{name = "wave", unit = .Choice, choices = PLAIN_WAVES},
			{name = "rate", unit = .Hz, default = 4, per_sample = true},
			{name = "delay", unit = .Seconds},
			{name = "fade", unit = .Seconds},
			{name = "phase", unit = .Number},
		},
	})
	NODE_FILTER = register_node(r, {
		name = "Filter", inputs = 1, state = size_of(Filter_State), start = start_filter, process = process_filter,
		fields = {
			{name = "type", unit = .Choice, choices = NODE_FILTER_CHOICES, shapes = true},
			{name = "frequency", unit = .Hz, default = 1000, per_sample = true},
			{name = "q", unit = .Number, default = 1, per_sample = true},
			{name = "rolloff", unit = .Number, default = -12},
			{name = "gain", unit = .Db},
		},
	})
	NODE_DRIVE = register_node(r, {name = "Drive", inputs = 1, stateless = true, process = process_drive, fields = {{name = "amount", unit = .Number, default = 1}}})
	NODE_SLEW = register_node(r, {
		name = "Slew", inputs = 1, keeps = true, state = size_of(Slew_State), process = process_slew, memory = memory_slew,
		fields = {{name = "rise", unit = .Seconds, default = 0.01}, {name = "fall", unit = .Seconds, default = 0.01}},
	})
	NODE_MAP = register_node(r, {
		name = "Map", inputs = 1, stateless = true, process = process_map,
		fields = {{name = "scale", unit = .Number, default = 1}, {name = "offset", unit = .Number}, {name = "min", unit = .Number, default = -1e30}, {name = "max", unit = .Number, default = 1e30}},
	})
	NODE_CURVE = register_node(r, {
		name = "Curve", inputs = 1, unipolar = true, stateless = true, process = process_curve,
		fields = {{name = "table", unit = .Table}},
	})
	NODE_MIX = register_node(r, {name = "Mix", inputs = -1, stateless = true, process = process_mix})
	NODE_MUL = register_node(r, {name = "Mul", inputs = -1, stateless = true, process = process_mul})
	NODE_COMB = register_node(r, {
		name = "Comb", inputs = 1, keeps = true, state = size_of(Comb_State), start = start_comb, process = process_comb, tail = tail_comb, memory = memory_comb,
		fields = {
			{name = "delay", unit = .Seconds, per_sample = true},
			{name = "feedback", unit = .Number, default = 0.7},
			{name = "damp", unit = .Hz},
			{name = "release", unit = .Seconds},
		},
	})
	NODE_SAMPLER = register_node(r, {
		name = "Sampler", stereo = true, state = size_of(Sampler_State), start = start_sampler, process = process_sampler, tail = tail_sampler_node,
		fields = {{name = "set", unit = .Asset, default = -1}, {name = "attack", unit = .Seconds}, {name = "release", unit = .Seconds, default = 0.1}},
	})
	NODE_SEGMENTS = register_node(r, {
		name = "Segments", unipolar = true, process = process_segments, tail = tail_segments,
		fields = {
			{name = "times", unit = .Number, list = SEGMENT_POINTS}, // seconds from the point before (the first: from the note's start)
			{name = "levels", unit = .Number, list = SEGMENT_POINTS},
			{name = "sustain", unit = .Number, default = -1}, // the point it holds at while the note is held (-1: none)
			{name = "points", unit = .Number},
		},
	})
	NODE_REGION = register_node(r, {
		name = "Region", stereo = true, state = size_of(Region_State), start = start_region, process = process_region, tail = tail_region,
		fields = {
			{name = "set", unit = .Asset, default = -1},
			{name = "zone", unit = .Number},
			{name = "keycenter", unit = .Number, default = 60},
			{name = "keytrack", unit = .Number, default = 100},
			{name = "tune", unit = .Cents},
			{name = "rate", unit = .Number, default = 1, per_sample = true},
			{name = "offset", unit = .Number},
			{name = "offset_random", unit = .Number},
			{name = "end", unit = .Number},
			{name = "loop_mode", unit = .Choice, choices = REGION_LOOP_MODES},
			{name = "loop_start", unit = .Number, default = -1},
			{name = "loop_end", unit = .Number},
			{name = "delay", unit = .Seconds},
			{name = "width", unit = .Number, default = 100},
		},
	})
	NODE_CLIP = register_node(r, {
		name = "Clip", stereo = true, jump = true, process = process_clip, tail = tail_clip,
		fields = {
			{name = "set", unit = .Asset, default = -1},
			{name = "offset", unit = .Seconds},
			{name = "fade_in", unit = .Seconds},
			{name = "fade_out", unit = .Seconds},
			{name = "curve", unit = .Choice, choices = CURVE_CHOICES},
			{name = "mono", unit = .Number},
			{name = "rate", unit = .Number, default = 1},
		},
	})
	NODE_LADDER = register_node(r, {
		name = "Ladder", inputs = 1, state = size_of(Ladder_State), start = start_ladder, process = process_ladder,
		fields = {{name = "frequency", unit = .Hz, default = 1000, per_sample = true}, {name = "q", unit = .Number, default = 1, per_sample = true}},
	})
	NODE_ONE_POLE = register_node(r, {
		name = "OnePole", inputs = 1, state = size_of(One_Pole_State), start = start_one_pole, process = process_one_pole,
		fields = {{name = "frequency", unit = .Hz, default = 1000, per_sample = true}},
	})
	NODE_DIFFERENCE = register_node(r, {name = "Difference", inputs = 1, state = size_of(Difference_State), start = start_difference, process = process_difference})
	// the Filter types that are kinds of their own
	append(&KINDS_BY_CHOICE, Kind_By_Choice{NODE_FILTER, FILTER_TYPE, DIODE, NODE_LADDER})
	append(&KINDS_BY_CHOICE, Kind_By_Choice{NODE_FILTER, FILTER_TYPE, ONE_POLE, NODE_ONE_POLE})
	append(&KINDS_BY_CHOICE, Kind_By_Choice{NODE_FILTER, FILTER_TYPE, DIFFERENCE, NODE_DIFFERENCE})
}

CURVE_NAMES := []string{"linear", "exponential"}

// A per-node draw from the note's seed and the node's name (its identity in
// its instrument: the same however the song is cut, or nodes are added).
@(private = "file")
node_seed :: #force_inline proc "contextless" (c: ^Node_Call, lane: ^Lane, salt: u64 = 0) -> u64 {
	return base.hash_combine(base.hash_combine(lane.seed, u64(c.node.name)), salt)
}

// ---- Osc: Tone's OmniOscillator, or a bank of fixed frequencies --------------------

// Fields' slots.
@(private = "file")
OSC_WAVE :: 3
@(private = "file")
OSC_COUNT :: 4
@(private = "file")
OSC_SPREAD :: 5
@(private = "file")
OSC_WIDTH :: 6
@(private = "file")
OSC_RATIO :: 7
@(private = "file")
OSC_TUNE :: 8
@(private = "file")
OSC_FREQUENCY :: 9
@(private = "file")
OSC_RING :: 10
@(private = "file")
OSC_PHASE :: 11
@(private = "file")
OSC_HZ :: 12

@(private = "file")
Osc_State :: struct {
	osc:  dsp.Unison,
	bank: [6]dsp.Osc,
	used: int, // the bank's (0: the unison plays)
	mult: f64, // the note's Hz times ratio and tune (a fixed frequency: 0)
	hz:   f64, // a fixed frequency (0: the note's)
}

// A note starting: its unison or bank of oscillators, their phases (from the seed when random).
@(private = "file")
start_osc :: proc(c: ^Node_Call, lane: ^Lane) {
	v := node_values(c, lane)
	s := node_state(c, lane, Osc_State)
	random := v[OSC_PHASE] == 1
	count := int(v[OSC_COUNT])
	dsp.unison_init(&s.osc, dsp.Wave(u8(v[OSC_WAVE])), count >= 1 ? count : 3, v[OSC_SPREAD], v[OSC_WIDTH])
	s.used = 0
	wave, _ := dsp.wave_plain(dsp.Wave(u8(v[OSC_WAVE])))
	for k in 0 ..< 6 {
		if v[OSC_HZ + k] > 0 {
			s.used = k + 1
		}
		s.bank[k] = {wave = wave, width = v[OSC_WIDTH]}
	}
	for k in 0 ..< dsp.MAX_UNISON {
		if random {
			p := base.hash_unit(node_seed(c, lane, u64(k + 1)))
			if k < 6 {
				s.bank[k].phase = p
			}
			if k < s.osc.count {
				s.osc.oscs[k].phase = p
			}
		}
	}
	s.hz = f64(v[OSC_FREQUENCY]) // its base: what moves it moves it per sample
	s.mult = f64(node_value(c, lane, OSC_RATIO)) * math.pow(2, f64(node_value(c, lane, OSC_TUNE)) / 12)
}

@(private = "file")
process_osc :: proc(c: ^Node_Call) {
	n := c.frames
	for &lane in c.lanes {
		v := node_values(c, &lane)
		s := node_state(c, &lane, Osc_State)
		l, r := node_out(c, &lane)
		hz, inc: [NODE_CHUNK]f64 = ---, ---
		tmp, moved: [NODE_CHUNK]f32 = ---, ---
		// what moves the frequency, as a ratio of its base (or, unmoved, the base)
		ratio :: proc(c: ^Node_Call, lane: ^Lane, hz: []f64, moved: []f32) {
			varies, v := node_curve(c, lane, OSC_FREQUENCY, 1, moved)
			for i in 0 ..< len(hz) {
				hz[i] = f64(varies ? moved[i] : v)
			}
		}
		if s.used > 0 {
			// a bank: each frequency moved as the field moves (a ratio)
			ratio(c, &lane, hz[:n], moved[:n])
			sum, ring: [NODE_CHUNK]f32
			prev: [NODE_CHUNK]f32
			ringing := v[OSC_RING]
			for k in 0 ..< s.used {
				f := f64(v[OSC_HZ + k]) / RATE
				for i in 0 ..< n {
					inc[i] = hz[i] * f
				}
				dsp.osc_run(&s.bank[k], inc[:n], tmp[:n])
				for i in 0 ..< n {
					sum[i] += tmp[i]
				}
				if k % 2 == 1 {
					for i in 0 ..< n {
						ring[i] += prev[i] * tmp[i]
					}
				}
				copy(prev[:n], tmp[:n])
			}
			norm := 1 / f32(s.used)
			for i in 0 ..< n {
				l[i] = (sum[i] * (1 - ringing) + 2 * ring[i] * ringing) * norm
			}
			continue
		}
		base_hz := s.hz > 0 ? s.hz : lane.hz * s.mult
		switch {
		case lane.glide != nil && s.hz == 0:
			ratio(c, &lane, hz[:n], moved[:n])
			for i in 0 ..< n {
				hz[i] *= lane.glide[i] * s.mult
			}
		case c.node.mod_slots & (u64(1) << OSC_FREQUENCY) == 0:
			for i in 0 ..< n {
				hz[i] = base_hz
			}
		case:
			varies, v := node_curve(c, &lane, OSC_FREQUENCY, f32(base_hz), moved[:n])
			for i in 0 ..< n {
				hz[i] = f64(varies ? moved[i] : v)
			}
		}
		dsp.unison_run(&s.osc, hz[:n], l, r, inc[:n], tmp[:n])
	}
}

// A fat oscillator's copies spread across the sides.
osc_stereo :: proc(values: ^[MAX_FIELDS]f32) -> bool {
	return int(values[OSC_WAVE]) >= int(dsp.Wave.Fat_Sine) && values[OSC_COUNT] != 1 && values[OSC_HZ] == 0
}

// ---- Noise and Random --------------------------------------------------------------

// A note starting: its generator seeded from the note.
@(private = "file")
start_noise :: proc(c: ^Node_Call, lane: ^Lane) {
	s := node_state(c, lane, dsp.Noise)
	s^ = dsp.noise_init(dsp.Noise_Type(u8(node_values(c, lane)[3])), node_seed(c, lane))
}

@(private = "file")
process_noise :: proc(c: ^Node_Call) {
	for &lane in c.lanes {
		s := node_state(c, &lane, dsp.Noise)
		l, _ := node_out(c, &lane)
		dsp.noise_run(s, l)
	}
}

// One value in -1..1 per note, from its seed.
@(private = "file")
process_random :: proc(c: ^Node_Call) {
	for &lane in c.lanes {
		x := f32(2 * base.hash_unit(node_seed(c, &lane, 0x52)) - 1)
		l, _ := node_out(c, &lane)
		for i in 0 ..< len(l) {
			l[i] = x
		}
	}
}

// ---- Env: Tone's envelope ----------------------------------------------------------

// A note starting: its envelope from its values.
@(private = "file")
start_env :: proc(c: ^Node_Call, lane: ^Lane) {
	s := node_state(c, lane, dsp.Adsr)
	s^ = {
		attack = max(node_value(c, lane, 3), 0), decay = max(node_value(c, lane, 4), 0),
		sustain = clamp(node_value(c, lane, 5), 0, 1), release = max(node_value(c, lane, 6), 0),
		exponential_attack = node_values(c, lane)[7] == 1,
		delay = max(node_value(c, lane, 8), 0), hold = max(node_value(c, lane, 9), 0), start = clamp(node_value(c, lane, 10), 0, 1),
	}
	dsp.adsr_init(s)
}

@(private = "file")
process_env :: proc(c: ^Node_Call) {
	for &lane in c.lanes {
		s := node_state(c, &lane, dsp.Adsr)
		l, _ := node_out(c, &lane)
		dsp.adsr_run(s, l, lane.release)
	}
}

@(private = "file")
tail_env :: proc(c: ^Node_Call, lane: ^Lane) -> f64 {
	return max(lane.note.duration, 0) + f64(max(node_value(c, lane, 6), 0))
}

// ---- Decay: a rise, a hold, an exponential fall; bursts; a release ----------------

@(private = "file")
DECAY_ATTACK :: 3
@(private = "file")
DECAY_HOLD :: 4
@(private = "file")
DECAY_PERIODS :: 5
@(private = "file")
DECAY_TIME :: 6
@(private = "file")
DECAY_DELAY :: 7
@(private = "file")
DECAY_BURSTS :: 8
@(private = "file")
DECAY_SPACING :: 9
@(private = "file")
DECAY_RELEASE :: 10

MAX_BURSTS :: 8

@(private = "file")
Decay_State :: struct {
	starts:  [MAX_BURSTS]i64, // samples from the note's start
	bursts:  int,
	attack:  f32, // samples
	hold:    f32,
	inv:     f32, // 1 / the fall's time constant in samples
	rinv:    f32, // 1 / the release's (0: none)
	next:    int, // the next burst
	from:    i64, // where the burst sounding started, from the note's start (-1: none yet)
	since:   i64, // samples since it started (its own count: a mono note sliding in carries it on)
}

@(private = "file")
decay_start :: proc(c: ^Node_Call, lane: ^Lane, s: ^Decay_State) {
	period := 1 / max(lane.hz, 1)
	s.attack = max(node_value(c, lane, DECAY_ATTACK), 0) * RATE
	s.hold = (max(node_value(c, lane, DECAY_HOLD), 0) + max(node_value(c, lane, DECAY_PERIODS), 0) * f32(period)) * RATE
	time := max(node_value(c, lane, DECAY_TIME), 1e-6)
	s.inv = 1 / (time * RATE)
	release := node_value(c, lane, DECAY_RELEASE)
	s.rinv = release > 0 ? 1 / (release * RATE) : 0
	s.bursts = clamp(int(node_value(c, lane, DECAY_BURSTS)), 1, MAX_BURSTS)
	at := f64(max(node_value(c, lane, DECAY_DELAY), 0))
	spacing := f64(max(node_value(c, lane, DECAY_SPACING), 0))
	for k in 0 ..< s.bursts {
		s.starts[k] = i64(math.round((at + f64(k) * spacing) * RATE))
	}
	s.next, s.from, s.since = 0, -1, 0
}

// A note starting: its bursts placed.
@(private = "file")
start_decay :: proc(c: ^Node_Call, lane: ^Lane) {
	s := node_state(c, lane, Decay_State)
	decay_start(c, lane, s)
}

@(private = "file")
process_decay :: proc(c: ^Node_Call) {
	for &lane in c.lanes {
		s := node_state(c, &lane, Decay_State)
		l, _ := node_out(c, &lane)
		// the chunk in stretches between bursts' starts, each a function of
		// the samples since its burst alone (no sample-to-sample carry: it
		// vectorizes)
		n := len(l)
		for i := 0; i < n; {
			t := lane.at + i64(i)
			if s.next < s.bursts && t >= s.starts[s.next] {
				s.from, s.since = s.starts[s.next], t - s.starts[s.next]
				s.next += 1
				continue
			}
			end := n
			if s.next < s.bursts {
				end = int(clamp(s.starts[s.next] - lane.at, i64(i), i64(n)))
			}
			if s.from < 0 {
				for j in i ..< end {
					l[j] = 0
				}
				i = end
				continue
			}
			hold, attack, inv, rinv := s.hold, s.attack, s.inv, s.rinv
			since, gate, at := s.since - i64(i), lane.gate, lane.at
			// times since the burst and the gate as whole samples: the same
			// however the note is cut into calls (the plain fall alone, the
			// common case, in a loop of its own)
			if attack == 0 && hold == 0 && (rinv == 0 || at + i64(end) <= gate) {
				for j in i ..< end {
					l[j] = dsp.exp_decay(-f32(since + i64(j)) * inv)
				}
			} else {
				for j in i ..< end {
					x := f32(since + i64(j))
					fall := dsp.exp_decay(-max(x - hold, 0) * inv)
					rise := attack > 0 ? min(1, x / attack) : 1
					rel := dsp.exp_decay(-f32(max(at + i64(j) - gate, 0)) * rinv)
					l[j] = rise * fall * rel
				}
			}
			s.since += i64(end - i)
			i = end
		}
	}
}

@(private = "file")
tail_decay :: proc(c: ^Node_Call, lane: ^Lane) -> f64 {
	period := 1 / max(lane.hz, 1)
	bursts := clamp(f64(node_value(c, lane, DECAY_BURSTS)), 1, MAX_BURSTS)
	last := f64(node_value(c, lane, DECAY_DELAY)) + (bursts - 1) * f64(node_value(c, lane, DECAY_SPACING))
	// 8 time constants: -70 dB
	ring := last + f64(node_value(c, lane, DECAY_ATTACK)) + f64(node_value(c, lane, DECAY_HOLD)) + f64(node_value(c, lane, DECAY_PERIODS)) * period + 8 * f64(node_value(c, lane, DECAY_TIME))
	// a release to -104 dB: a mono voice still sounding hands what it holds
	// to the next note (the 303's VCA, as its circuit does under 1e-5)
	if release := f64(node_value(c, lane, DECAY_RELEASE)); release > 0 {
		ring = min(ring, max(lane.note.duration, 0) + 12 * release)
	}
	return ring
}

// ---- Ramp: from `from` to `to` over `time` (the gate when 0), as t^curve ----------

@(private = "file")
process_ramp :: proc(c: ^Node_Call) {
	for &lane in c.lanes {
		from, to := node_value(c, &lane, 3), node_value(c, &lane, 4)
		span := f64(node_value(c, &lane, 5)) * RATE
		curve := f64(node_value(c, &lane, 6))
		if span <= 0 {
			span = f64(lane.gate)
		}
		l, _ := node_out(c, &lane)
		for i in 0 ..< len(l) {
			t := span > 0 ? clamp(f64(lane.at + i64(i)) / span, 0, 1) : 1
			if curve != 1 {
				t = math.pow(t, curve)
			}
			l[i] = from + (to - from) * f32(t)
		}
	}
}

// ---- Lfo ---------------------------------------------------------------------------

// A note starting: its oscillator at its phase.
@(private = "file")
start_lfo :: proc(c: ^Node_Call, lane: ^Lane) {
	s := node_state(c, lane, dsp.Osc)
	vals := node_values(c, lane)
	s^ = {wave = dsp.Wave(u8(vals[3])), width = 0.5, phase = f64(vals[7]) - math.floor(f64(vals[7]))}
}

@(private = "file")
process_lfo :: proc(c: ^Node_Call) {
	n := c.frames
	for &lane in c.lanes {
		s := node_state(c, &lane, dsp.Osc)
		vals := node_values(c, &lane)
		rate: [NODE_CHUNK]f32 = ---
		inc: [NODE_CHUNK]f64 = ---
		varies, v := node_curve(c, &lane, 4, vals[4], rate[:n])
		// it starts after its delay and grows to its depth over its fade
		delay := i64(f64(vals[5]) * RATE)
		fade := f64(vals[6]) * RATE
		for i in 0 ..< n {
			inc[i] = lane.at + i64(i) < delay ? 0 : f64(varies ? rate[i] : v) / RATE
		}
		l, _ := node_out(c, &lane)
		dsp.osc_run(s, inc[:n], l)
		if delay > 0 || fade > 0 {
			for i in 0 ..< n {
				k := lane.at + i64(i) - delay
				g: f32 = k < 0 ? 0 : (fade > 0 && f64(k) < fade ? f32(f64(k) / fade) : 1)
				l[i] *= g
			}
		}
	}
}

// ---- Filters: Tone's (SVF stages by rolloff), the 303's ladder, a one-pole, a difference ----

// A Filter written with one of these types is that kind of its own
// (compile_program; its values and modulators moved by their fields' names).
@(private = "file")
DIODE :: 8
@(private = "file")
ONE_POLE :: 9 // a one-pole low-pass: y += k (x - y), k from the cutoff
@(private = "file")
DIFFERENCE :: 10 // x - its last: a gentle high-pass (6 dB an octave, no cutoff)

// Tone's Filter: Filter_Type's SVF, cascaded by rolloff.
@(private = "file")
FILTER_TYPE :: 3
@(private = "file")
FILTER_FREQUENCY :: 4
@(private = "file")
FILTER_Q :: 5
@(private = "file")
FILTER_ROLLOFF :: 6
@(private = "file")
FILTER_GAIN :: 7

@(private = "file")
Filter_State :: struct {
	chain: dsp.Filter_Chain,
	fixed: dsp.Svf, // a cutoff and q nothing moves: their coefficients, once a note
}

@(private = "file")
start_filter :: proc(c: ^Node_Call, lane: ^Lane) {
	v := node_values(c, lane)
	s := node_state(c, lane, Filter_State)
	s.chain = dsp.filter_chain_init(dsp.Filter_Type(u8(v[FILTER_TYPE])), v[FILTER_Q], v[FILTER_ROLLOFF], v[FILTER_GAIN])
	s.fixed = dsp.svf_coefficients(s.chain.type, v[FILTER_FREQUENCY], v[FILTER_Q], v[FILTER_GAIN])
}

@(private = "file")
process_filter :: proc(c: ^Node_Call) {
	n := c.frames
	for &lane in c.lanes {
		v := node_values(c, &lane)
		s := node_state(c, &lane, Filter_State)
		il, ir := node_input(c, &lane, 0)
		l, r := node_out(c, &lane)
		copy(l, il)
		if c.node.stereo {
			copy(r, ir)
		}
		sides := c.node.stereo ? 2 : 1
		hz, q: [NODE_CHUNK]f32 = ---, ---
		swept, cutoff := node_curve(c, &lane, FILTER_FREQUENCY, v[FILTER_FREQUENCY], hz[:n])
		resonant, res := node_curve(c, &lane, FILTER_Q, v[FILTER_Q], q[:n])
		if !swept && !resonant {
			// one setting for the chunk: the note's (computed at its start), or
			// another a steady modulator gives
			coefficient := s.fixed
			if cutoff != v[FILTER_FREQUENCY] || res != v[FILTER_Q] {
				coefficient = dsp.svf_coefficients(s.chain.type, cutoff, res, s.chain.gain)
			}
			for side in 0 ..< sides {
				x := side == 0 ? l : r
				for k in 0 ..< s.chain.stages {
					dsp.svf_run(coefficient, &s.chain.state[side][k], x)
				}
			}
			continue
		}
		if !swept {
			for i in 0 ..< n {
				hz[i] = cutoff
			}
		}
		if !resonant {
			for i in 0 ..< n {
				q[i] = res
			}
		}
		coefficients: [NODE_CHUNK]dsp.Svf = ---
		if resonant || res != s.chain.q {
			for i in 0 ..< n {
				coefficients[i] = dsp.svf_coefficients(s.chain.type, hz[i], q[i], s.chain.gain)
			}
		} else {
			dsp.filter_chain_coefficients(&s.chain, hz[:n], coefficients[:n])
		}
		for side in 0 ..< sides {
			dsp.filter_chain_run_swept(&s.chain, coefficients[:n], side == 0 ? l : r, side)
		}
	}
}

// The 303's diode ladder (its stages carry across a mono program's slide).
@(private = "file")
LADDER_FREQUENCY :: 3
@(private = "file")
LADDER_Q :: 4

@(private = "file")
Ladder_State :: struct {
	y:      [2][4]f32, // its stages, per side
	x_last: [2]f32,
}

// The ladder's level in and its saturation out.
LADDER_DRIVE :: 0.4

@(private = "file")
start_ladder :: proc(c: ^Node_Call, lane: ^Lane) {
	if lane.fresh {
		node_state(c, lane, Ladder_State)^ = {}
	}
}

@(private = "file")
process_ladder :: proc(c: ^Node_Call) {
	n := c.frames
	for &lane in c.lanes {
		v := node_values(c, &lane)
		s := node_state(c, &lane, Ladder_State)
		il, ir := node_input(c, &lane, 0)
		l, r := node_out(c, &lane)
		copy(l, il)
		if c.node.stereo {
			copy(r, ir)
		}
		hz, q: [NODE_CHUNK]f32 = ---, ---
		swept, cutoff := node_curve(c, &lane, LADDER_FREQUENCY, v[LADDER_FREQUENCY], hz[:n])
		resonant, res := node_curve(c, &lane, LADDER_Q, v[LADDER_Q], q[:n])
		if !swept {
			for i in 0 ..< n {
				hz[i] = cutoff
			}
		}
		if !resonant {
			for i in 0 ..< n {
				q[i] = res
			}
		}
		for side in 0 ..< (c.node.stereo ? 2 : 1) {
			ladder(&s.y[side], &s.x_last[side], side == 0 ? l : r, hz[:n], q[:n])
		}
	}
}

// A one-pole low-pass, per side: its cutoff moved per sample, or its
// coefficient once a note.
@(private = "file")
ONE_POLE_FREQUENCY :: 3

@(private = "file")
One_Pole_State :: struct {
	y: [2]f32,
	k: f32, // its coefficient at a fixed cutoff
}

@(private = "file")
start_one_pole :: proc(c: ^Node_Call, lane: ^Lane) {
	s := node_state(c, lane, One_Pole_State)
	s.y = {}
	s.k = f32(dsp.one_pole_k(f64(node_values(c, lane)[ONE_POLE_FREQUENCY])))
}

@(private = "file")
process_one_pole :: proc(c: ^Node_Call) {
	n := c.frames
	for &lane in c.lanes {
		s := node_state(c, &lane, One_Pole_State)
		il, ir := node_input(c, &lane, 0)
		l, r := node_out(c, &lane)
		hz: [NODE_CHUNK]f32 = ---
		base_hz := node_values(c, &lane)[ONE_POLE_FREQUENCY]
		swept, cutoff := node_curve(c, &lane, ONE_POLE_FREQUENCY, base_hz, hz[:n])
		ks: [NODE_CHUNK]f32 = ---
		if swept {
			for i in 0 ..< n {
				ks[i] = 1 - dsp.exp_decay(-math.TAU * min(hz[i], 0.49 * RATE) / RATE)
			}
		} else if cutoff != base_hz {
			s.k = 1 - dsp.exp_decay(-math.TAU * min(cutoff, 0.49 * RATE) / RATE) // a steady modulator's
		}
		for side in 0 ..< (c.node.stereo ? 2 : 1) {
			x, out := side == 0 ? il : ir, side == 0 ? l : r
			y := s.y[side]
			if swept {
				for i in 0 ..< n {
					y += ks[i] * (x[i] - y)
					out[i] = y
				}
			} else {
				k := s.k
				for i in 0 ..< n {
					y += k * (x[i] - y)
					out[i] = y
				}
			}
			s.y[side] = y
		}
	}
}

// x - its last, per side (its last carries across a mono program's slide).
@(private = "file")
Difference_State :: struct {
	x_last: [2]f32,
}

@(private = "file")
start_difference :: proc(c: ^Node_Call, lane: ^Lane) {
	if lane.fresh {
		node_state(c, lane, Difference_State)^ = {}
	}
}

@(private = "file")
process_difference :: proc(c: ^Node_Call) {
	n := c.frames
	for &lane in c.lanes {
		s := node_state(c, &lane, Difference_State)
		il, ir := node_input(c, &lane, 0)
		l, r := node_out(c, &lane)
		for side in 0 ..< (c.node.stereo ? 2 : 1) {
			x, out := side == 0 ? il : ir, side == 0 ? l : r
			last := s.x_last[side]
			for i in 0 ..< n {
				out[i] = x[i] - last
				last = x[i]
			}
			s.x_last[side] = last
		}
	}
}

@(private = "file")
tanh_ladder :: #force_inline proc "contextless" (x: f32) -> f32 {
	c := clamp(x, -3, 3)
	return c * (27 + c * c) / (27 + 9 * c * c)
}

// The 303's diode ladder, as a 4-pole ladder: 2x oversampled, a tanh in
// every stage and in the feedback, so it saturates and squelches; q 0..10
// is the resonance (10 the edge of self-oscillation; it goes a little
// past), the cutoff at most 18 kHz.
@(private = "file")
ladder :: proc(y: ^[4]f32, x_last: ^f32, x: []f32, hz: []f32, q: []f32) {
	for i in 0 ..< len(x) {
		res := clamp(q[i], 0, 11) / 10
		g := 1 - dsp.exp_decay(-math.TAU * min(hz[i], 18000) / (2 * RATE))
		xi := x[i]
		out: f32
		for step in 0 ..< 2 {
			xin := step == 0 ? 0.5 * (x_last^ + xi) : xi
			t0 := tanh_ladder(LADDER_DRIVE * xin - 4 * res * y[3])
			t1, t2, t3 := tanh_ladder(y[0]), tanh_ladder(y[1]), tanh_ladder(y[2])
			y[0] += g * (t0 - t1)
			y[1] += g * (t1 - t2)
			y[2] += g * (t2 - t3)
			y[3] += g * (t3 - tanh_ladder(y[3]))
			out += 0.5 * y[3]
		}
		x_last^ = xi
		x[i] = tanh_ladder(out / LADDER_DRIVE * (1 + 0.6 * res))
	}
}

// ---- Drive, Slew, Map, Mix, Mul ----------------------------------------------------

@(private = "file")
process_drive :: proc(c: ^Node_Call) {
	for &lane in c.lanes {
		a := max(node_value(c, &lane, 3), 1e-3)
		norm := 1 / f32(math.tanh(f64(a)))
		il, ir := node_input(c, &lane, 0)
		l, r := node_out(c, &lane)
		for i in 0 ..< len(l) {
			l[i] = dsp.tanh_fast(a * il[i]) * norm
		}
		if c.node.stereo {
			for i in 0 ..< len(r) {
				r[i] = dsp.tanh_fast(a * ir[i]) * norm
			}
		}
	}
}

@(private = "file")
Slew_State :: struct {
	y: f32,
}

// A one-pole lag: toward its input with the `rise` time constant going up,
// `fall` going down. Its charge carries across a mono program's notes.
@(private = "file")
process_slew :: proc(c: ^Node_Call) {
	for &lane in c.lanes {
		s := node_state(c, &lane, Slew_State)
		rise := 1 - f32(math.exp(-1 / (f64(max(node_value(c, &lane, 3), 1e-6)) * RATE)))
		fall := 1 - f32(math.exp(-1 / (f64(max(node_value(c, &lane, 4), 1e-6)) * RATE)))
		il, _ := node_input(c, &lane, 0)
		l, _ := node_out(c, &lane)
		y := s.y
		for i in 0 ..< len(l) {
			x := il[i]
			y += (x - y) * (x > y ? rise : fall)
			l[i] = y
		}
		s.y = y
	}
}

@(private = "file")
memory_slew :: proc(values: ^[MAX_FIELDS]f32, slots: []int) -> f64 {
	return 12 * f64(max(values[3], values[4]))
}

@(private = "file")
process_map :: proc(c: ^Node_Call) {
	for &lane in c.lanes {
		scale, offset := node_value(c, &lane, 3), node_value(c, &lane, 4)
		lo, hi := node_value(c, &lane, 5), node_value(c, &lane, 6)
		il, ir := node_input(c, &lane, 0)
		l, r := node_out(c, &lane)
		for i in 0 ..< len(l) {
			l[i] = clamp(offset + scale * il[i], lo, hi)
		}
		if c.node.stereo {
			for i in 0 ..< len(r) {
				r[i] = clamp(offset + scale * ir[i], lo, hi)
			}
		}
	}
}

// The points a Curve's table has: its input 0..1 read at 127 steps (an
// SFZ curve's: a velocity's level, a crossfade).
CURVE_POINTS :: 128

// Its input (0..1) through a table of CURVE_POINTS, straight between its
// points (Programs.tables, at the `table` field's index).
@(private = "file")
process_curve :: proc(c: ^Node_Call) {
	read :: #force_inline proc "contextless" (table: []f32, x: f32) -> f32 {
		t := clamp(x, 0, 1) * (CURVE_POINTS - 1)
		i := min(int(t), CURVE_POINTS - 2)
		return table[i] + (table[i + 1] - table[i]) * (t - f32(i))
	}
	for &lane in c.lanes {
		il, ir := node_input(c, &lane, 0)
		l, r := node_out(c, &lane)
		// its table: its layer's (a region's own velocity curve)
		at := int(node_values(c, &lane)[3]) * CURVE_POINTS
		if at < 0 || at + CURVE_POINTS > len(c.progs.tables) {
			slice_zero(l)
			slice_zero(r)
			continue
		}
		table := c.progs.tables[at:][:CURVE_POINTS]
		for i in 0 ..< len(l) {
			l[i] = read(table, il[i])
		}
		if c.node.stereo {
			for i in 0 ..< len(r) {
				r[i] = read(table, ir[i])
			}
		}
	}
}

@(private = "file")
process_mix :: proc(c: ^Node_Call) {
	for &lane in c.lanes {
		l, r := node_out(c, &lane)
		il, ir := node_input(c, &lane, 0)
		copy(l, il)
		if c.node.stereo {
			copy(r, ir)
		}
		for k in 1 ..< int(c.node.inputs.count) {
			il, ir = node_input(c, &lane, k)
			for i in 0 ..< len(l) {
				l[i] += il[i]
			}
			if c.node.stereo {
				for i in 0 ..< len(r) {
					r[i] += ir[i]
				}
			}
		}
	}
}

@(private = "file")
process_mul :: proc(c: ^Node_Call) {
	for &lane in c.lanes {
		l, r := node_out(c, &lane)
		il, ir := node_input(c, &lane, 0)
		copy(l, il)
		if c.node.stereo {
			copy(r, ir)
		}
		for k in 1 ..< int(c.node.inputs.count) {
			il, ir = node_input(c, &lane, k)
			for i in 0 ..< len(l) {
				l[i] *= il[i]
			}
			if c.node.stereo {
				for i in 0 ..< len(r) {
					r[i] *= ir[i]
				}
			}
		}
	}
}

// ---- Comb: a delay line with feedback through a one-pole low-pass ----------------

@(private = "file")
COMB_DELAY :: 3
@(private = "file")
COMB_FEEDBACK :: 4
@(private = "file")
COMB_DAMP :: 5
@(private = "file")
COMB_RELEASE :: 6

@(private = "file")
Comb_State :: struct {
	line:  [COMB_LINE]f32,
	write: int,
	lp:    f32,
	k:     f32, // the low-pass's (1: none)
	delay: f64, // samples (a note's period: shortened by the low-pass's own delay there, so it is in tune)
}

@(private = "file")
comb_start :: proc(c: ^Node_Call, lane: ^Lane, s: ^Comb_State) {
	damp := f64(node_value(c, lane, COMB_DAMP))
	k := damp > 0 ? dsp.one_pole_k(damp) : 1
	s.k = f32(k)
	d := f64(node_values(c, lane)[COMB_DELAY]) * RATE // its base: what moves it moves it per sample
	if d <= 0 {
		f := max(lane.hz, RATE / f64(COMB_LINE - 2))
		w := math.TAU * f / RATE
		lp_delay := k < 1 ? math.atan2((1 - k) * math.sin(w), 1 - (1 - k) * math.cos(w)) / w : 0
		d = RATE / f - lp_delay
	}
	s.delay = clamp(d, 1, COMB_LINE - 2)
}

// Its input plus `feedback` times the line `delay` ago, low-passed at
// `damp`; after the gate the feedback ramps to nothing over `release` (0:
// it holds). A delay of 0 is the note's period: a plucked string.
// A note starting: its delay set (its line emptied on a fresh voice; a slide keeps it ringing).
@(private = "file")
start_comb :: proc(c: ^Node_Call, lane: ^Lane) {
	s := node_state(c, lane, Comb_State)
	if lane.fresh {
		s.line, s.write, s.lp = {}, 0, 0
	}
	comb_start(c, lane, s)
}

@(private = "file")
process_comb :: proc(c: ^Node_Call) {
	n := c.frames
	for &lane in c.lanes {
		s := node_state(c, &lane, Comb_State)
		fb := node_value(c, &lane, COMB_FEEDBACK)
		release := f64(node_value(c, &lane, COMB_RELEASE)) * RATE
		delays: [NODE_CHUNK]f32 = ---
		moved, d := node_curve(c, &lane, COMB_DELAY, f32(s.delay / RATE), delays[:n])
		if !moved {
			for i in 0 ..< n {
				delays[i] = d
			}
			moved = d != f32(s.delay / RATE)
		}
		il, _ := node_input(c, &lane, 0)
		l, _ := node_out(c, &lane)
		for i in 0 ..< n {
			t := lane.at + i64(i)
			fade := f32(1)
			if release > 0 && t >= lane.gate {
				fade = f32(max(0, 1 - f64(t - lane.gate) / release))
			}
			d := moved ? clamp(f64(delays[i]) * RATE, 1, COMB_LINE - 2) : s.delay
			pos := f64(s.write) - d
			if pos < 0 {
				pos += COMB_LINE
			}
			i0 := int(pos)
			fr := f32(pos - f64(i0))
			delayed := s.line[i0 & (COMB_LINE - 1)] * (1 - fr) + s.line[(i0 + 1) & (COMB_LINE - 1)] * fr
			s.lp += s.k * (delayed - s.lp)
			y := il[i] + fb * fade * s.lp
			s.line[s.write] = y
			s.write = (s.write + 1) & (COMB_LINE - 1)
			l[i] = y
		}
	}
}

// Its ring: until the release has taken its feedback away, or it has
// fallen 80 dB.
@(private = "file")
tail_comb :: proc(c: ^Node_Call, lane: ^Lane) -> f64 {
	fb := f64(abs(node_value(c, lane, COMB_FEEDBACK)))
	d := f64(node_value(c, lane, COMB_DELAY))
	period := d > 0 ? d : 1 / max(lane.hz, 1)
	ring := 30.0
	if fb <= 0 {
		ring = 0
	} else if fb < 1 {
		ring = math.ln(f64(1e-4)) / math.ln(fb) * period
	}
	if release := f64(node_value(c, lane, COMB_RELEASE)); release > 0 {
		ring = min(ring, max(lane.note.duration, 0) + release)
	}
	return ring + period
}

@(private = "file")
memory_comb :: proc(values: ^[MAX_FIELDS]f32, slots: []int) -> f64 {
	fb := f64(abs(values[COMB_FEEDBACK]))
	d := max(f64(values[COMB_DELAY]), 0.02)
	return fb > 0 && fb < 1 ? min(math.ln(f64(1e-4)) / math.ln(fb) * d, 30) : 0
}

// ---- Sampler: a set's zones ---------------------------------------------------------

// A note starting: its zone and read head.
@(private = "file")
start_sampler :: proc(c: ^Node_Call, lane: ^Lane) {
	s := node_state(c, lane, Sampler_State)
	sampler_start(s, i32(node_values(c, lane)[3]), node_value(c, lane, 4), node_value(c, lane, 5), lane.key, lane.note, lane.seed, c.env)
}

@(private = "file")
process_sampler :: proc(c: ^Node_Call) {
	for &lane in c.lanes {
		s := node_state(c, &lane, Sampler_State)
		l, r := node_out(c, &lane)
		sampler_play(s, lane.at, c.env, l, r)
	}
}

@(private = "file")
tail_sampler_node :: proc(c: ^Node_Call, lane: ^Lane) -> f64 {
	return tail_sampler(i32(node_values(c, lane)[3]), node_value(c, lane, 5), lane.key, lane.note, c.env)
}

// ---- Clip: a recording as it was made ----------------------------------------------

// A clip played as recorded (Tone's Player; onimite's track, sample for
// sample: its envelope is onimite's track_envelope): the first sample of
// bank set `set`, from `offset` seconds in, for the note's gate, with fades
// in and out of `curve`'s shape (dsp.edge_fade: at least a declick where it
// cuts into its file),
// `mono` folding the sides together, at `rate` (a tape's: 2 plays twice as
// fast an octave up, -1 backwards from `offset`; beyond the recording's
// ends, silence) through the Sampler's kernel. Its output is a function of
// where the note is (a seek jumps there): sample k of the note reads frame
// offset + k * rate, never a sum of steps. The fades are the note's.

CLIP_SET :: 3
CLIP_OFFSET :: 4
CLIP_FADE_IN :: 5
CLIP_FADE_OUT :: 6
CLIP_CURVE :: 7
CLIP_MONO :: 8
CLIP_RATE :: 9

@(private = "file")
process_clip :: proc(c: ^Node_Call) {
	bank := c.env != nil ? c.env.bank : nil
	for &lane in c.lanes {
		v := node_values(c, &lane)
		set := int(v[CLIP_SET])
		l, r := node_out(c, &lane)
		for i in 0 ..< len(l) {
			l[i], r[i] = 0, 0
		}
		if bank == nil || set < 0 || set >= len(bank.sets) || bank.sets[set].zones.count == 0 {
			continue
		}
		sm := bank.samples[bank.zones[bank.sets[set].zones.first].sample]
		switch sm.format {
		case .F32:
			clip_run(v, &lane, sample_f32(bank, sm), int(sm.channels), 1, l, r)
		case .I16:
			clip_run(v, &lane, sample_i16(bank, sm), int(sm.channels), 1.0 / 32768, l, r)
		}
	}
}

// The clip's frames into l and r: one typed loop per sample format.
@(private = "file")
clip_run :: proc(v: ^[MAX_FIELDS]f32, lane: ^Lane, data: []$T, channels: int, scale: f32, l, r: []f32) {
	frames := i64(len(data) / channels)
	first := i64(math.round(f64(v[CLIP_OFFSET]) * RATE))
	length := lane.gate
	rate := f64(v[CLIP_RATE])
	// its edges cut into the file unless it starts at the file's first frame
	// and ends at its last or past it
	last := f64(first) + f64(length) * rate
	fade_in := dsp.edge_fade(i64(math.round(f64(v[CLIP_FADE_IN]) * RATE)), first > 0)
	fade_out := dsp.edge_fade(i64(math.round(f64(v[CLIP_FADE_OUT]) * RATE)), last > 0 && last < f64(frames))
	curve := Curve(clamp(int(v[CLIP_CURVE]), 0, len(Curve) - 1))
	mono := v[CLIP_MONO] > 0.5
	right := channels > 1 ? 1 : 0
	if rate != 1 {
		clip_run_rate(data, channels, scale, frames, first, rate, length, fade_in, fade_out, curve, mono, lane.at, l, r)
		return
	}
	for i in 0 ..< i64(len(l)) {
		k := lane.at + i
		src := first + k
		if k >= length || src < 0 || src >= frames {
			continue
		}
		g := dsp.fade_gain(k, fade_in, curve) * dsp.fade_gain(length - 1 - k, fade_out, curve)
		a := f32(data[src * i64(channels)]) * scale
		b := f32(data[src * i64(channels) + i64(right)]) * scale
		if mono {
			a = a * 0.70710678 + b * 0.70710678
			b = a
		}
		l[i] = a * g
		r[i] = b * g
	}
}

// The clip away from rate 1: sample k reads frame first + k * rate through
// the kernel, widened (and lowered) when it plays faster so nothing aliases.
@(private = "file")
clip_run_rate :: proc(data: []$T, channels: int, scale: f32, frames, first: i64, rate: f64, length, fade_in, fade_out: i64, curve: Curve, mono: bool, at: i64, l, r: []f32) {
	cutoff := clamp(1 / abs(rate), 1.0 / SINC_MAX_STRETCH, 1)
	taps := i64(math.ceil(SINC_HALF / cutoff))
	right := i64(channels > 1 ? 1 : 0)
	for i in 0 ..< i64(len(l)) {
		k := at + i
		pos := f64(first) + f64(k) * rate
		if k >= length || pos < 0 || pos >= f64(frames) {
			continue
		}
		a, b := read_frame(data, i64(channels), right, frames, 0, 0, pos, f32(cutoff), taps, f32(cutoff) * scale, cutoff == 1)
		g := dsp.fade_gain(k, fade_in, curve) * dsp.fade_gain(length - 1 - k, fade_out, curve)
		if mono {
			a = a * 0.70710678 + b * 0.70710678
			b = a
		}
		l[i] = a * g
		r[i] = b * g
	}
}

@(private = "file")
tail_clip :: proc(c: ^Node_Call, lane: ^Lane) -> f64 {
	return f64(lane.gate) / RATE
}

// ---- Segments: an envelope of points ------------------------------------------------

// Up to SEGMENT_POINTS points, each a level reached `times` seconds after
// the one before (straight between them), from the first's level at the
// note's start; held at the `sustain` point while the note is held, and on
// from there when it ends (SFZ v2's egN). Its value is a function of where
// the note is.

SEGMENT_POINTS :: 8
SEGMENTS_TIMES :: 3
SEGMENTS_LEVELS :: SEGMENTS_TIMES + SEGMENT_POINTS
SEGMENTS_SUSTAIN :: SEGMENTS_LEVELS + SEGMENT_POINTS
SEGMENTS_POINTS :: SEGMENTS_SUSTAIN + 1

// Its level `t` seconds after its start, held at `sustain` until `gate`.
@(private = "file")
segments_at :: proc(v: ^[MAX_FIELDS]f32, t, gate: f64) -> f32 {
	points := clamp(int(v[SEGMENTS_POINTS]), 1, SEGMENT_POINTS)
	sustain := int(v[SEGMENTS_SUSTAIN])
	// the time each point is reached
	at: [SEGMENT_POINTS]f64
	for k in 1 ..< points {
		at[k] = at[k - 1] + max(f64(v[SEGMENTS_TIMES + k]), 0)
	}
	level :: proc(v: ^[MAX_FIELDS]f32, at: [SEGMENT_POINTS]f64, points: int, t: f64) -> f32 {
		if t <= 0 {
			return v[SEGMENTS_LEVELS]
		}
		for k in 1 ..< points {
			if t < at[k] {
				span := at[k] - at[k - 1]
				x := span > 0 ? f32((t - at[k - 1]) / span) : 1
				return v[SEGMENTS_LEVELS + k - 1] + (v[SEGMENTS_LEVELS + k] - v[SEGMENTS_LEVELS + k - 1]) * x
			}
		}
		return v[SEGMENTS_LEVELS + points - 1]
	}
	if sustain < 0 || sustain >= points {
		return level(v, at, points, t)
	}
	if t < gate {
		return level(v, at, points, min(t, at[sustain]))
	}
	// released: from where it was at the gate, on through the points after the sustain
	from := level(v, at, points, min(gate, at[sustain]))
	r := t - gate
	if sustain + 1 >= points {
		return from
	}
	first := max(f64(v[SEGMENTS_TIMES + sustain + 1]), 0)
	if r < first {
		x := first > 0 ? f32(r / first) : 1
		return from + (v[SEGMENTS_LEVELS + sustain + 1] - from) * x
	}
	return level(v, at, points, at[sustain + 1] + (r - first))
}

@(private = "file")
process_segments :: proc(c: ^Node_Call) {
	for &lane in c.lanes {
		v := node_values(c, &lane)
		l, _ := node_out(c, &lane)
		gate := f64(lane.gate) / RATE
		for i in 0 ..< len(l) {
			l[i] = segments_at(v, f64(lane.at + i64(i)) / RATE, gate)
		}
	}
}

@(private = "file")
tail_segments :: proc(c: ^Node_Call, lane: ^Lane) -> f64 {
	v := node_values(c, lane)
	points := clamp(int(v[SEGMENTS_POINTS]), 1, SEGMENT_POINTS)
	sustain := int(v[SEGMENTS_SUSTAIN])
	total: f64
	for k in 1 ..< points {
		total += max(f64(v[SEGMENTS_TIMES + k]), 0)
	}
	if v[SEGMENTS_LEVELS + points - 1] != 0 {
		return math.INF_F64 // it ends somewhere other than silence: what it moves decides
	}
	if sustain >= 0 && sustain < points {
		after: f64
		for k in sustain + 1 ..< points {
			after += max(f64(v[SEGMENTS_TIMES + k]), 0)
		}
		return max(lane.note.duration, total - after) + after
	}
	return total
}
