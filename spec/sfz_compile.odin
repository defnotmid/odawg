package odawg_spec

import "core:math"
import "core:strconv"
import "core:strings"
import base "../base"
import device "../device"

// An SFZ instrument as a layered program: every region a layer (its key,
// velocity, random, sequence, trigger and keyswitch conditions, its group
// and what cuts it) playing a program of its own over the registry's kinds:
// a Region node (its zone of the instrument's set) or a generator (an Osc,
// a Noise), its filters and EQ, its amp, filter and pitch envelopes, its
// LFOs, its velocity curve and crossfades, and an out with its level and
// pan. A CC is read at its value (the row's ccN, else set_ccN, else SFZ's
// default) wherever SFZ moves something by one or tests one, once, here: a
// region whose CC conditions fail isn't placed. An opcode odawg doesn't
// play is a finding, once a file, its count and first region given.

// A CC's value 0..1 through SFZ's built-in curves (curve_index 0: linear,
// 1: bipolar, 2: inverted, 3: inverted bipolar, 4: x^2, 5: sqrt, 6: inverted
// sqrt) or an instrument's own.
@(private = "file")
sfz_cc_curve :: proc(s: ^Sfz, index: int, x: f64) -> f64 {
	if c := sfz_curve(s, index); c != nil {
		t := clamp(x, 0, 1) * 127
		i := min(int(t), 126)
		return f64(c.points[i]) + f64(c.points[i + 1] - c.points[i]) * (t - f64(i))
	}
	switch index {
	case 1:
		return 2 * x - 1
	case 2:
		return 1 - x
	case 3:
		return 1 - 2 * x
	case 4:
		return x * x
	case 5:
		return math.sqrt(x)
	case 6:
		return math.sqrt(1 - x)
	}
	return x
}

// What compiling reads of a region: the instrument, its CC values, the
// opcodes it read (so the rest are findings).
@(private = "file")
Sfz_Compile :: struct {
	s:         ^Sfz,
	cc:        [128]f32,
	read:      map[string]bool, // opcode names (as the reference spells them) read
	overrides: map[string]f64, // opcodes the row sets for every region (the Sampler form's attack, release)
}

// `name`'s value in the region (its default when it gives none), plus what
// the CCs at their values add to it (name_onccN = amount: amount times the
// CC through name_curveccN's curve).
@(private = "file")
param :: proc(c: ^Sfz_Compile, region: int, name: string, fallback: f64) -> f64 {
	c.read[name] = true
	if v, given := c.overrides[name]; given {
		return v
	}
	v := sfz_number(c.s, region, name, fallback)
	row := sfz_name(name).row
	if row < 0 {
		return v
	}
	sp := c.s.regions[region].opcodes
	for op in c.s.opcodes[sp.first:base.span_end(sp)] {
		n := op.read
		if n.row != row || n.mod != .On || n.cc < 0 || n.cc >= 128 {
			continue
		}
		amount, _ := strconv.parse_f64(op.value)
		curve := 0
		if cv, found := sfz_value(c.s, region, strings.concatenate({name, "_curvecc", op.name[strings.last_index_any(op.name, "abcdefghijklmnopqrstuvwxyz") + 1:]}, context.temp_allocator)); found {
			curve, _ = strconv.parse_int(cv)
		}
		v += amount * sfz_cc_curve(c.s, curve, f64(c.cc[n.cc]) / 127)
	}
	return v
}

@(private = "file")
key_of :: proc(c: ^Sfz_Compile, region: int, name: string, fallback: int) -> int {
	c.read[name] = true
	v, found := sfz_value(c.s, region, name)
	return found ? sfz_key(c.s, v, fallback) : fallback
}

@(private = "file")
text_of :: proc(c: ^Sfz_Compile, region: int, name: string) -> (string, bool) {
	c.read[name] = true
	return sfz_value(c.s, region, name)
}

// Whether the region's CC conditions (loccN, hiccN) hold at the CCs' values.
@(private = "file")
cc_conditions :: proc(c: ^Sfz_Compile, region: int) -> bool {
	sp := c.s.regions[region].opcodes
	for op in c.s.opcodes[sp.first:base.span_end(sp)] {
		if !strings.has_prefix(op.name, "locc") && !strings.has_prefix(op.name, "hicc") {
			continue
		}
		c.read[op.name[:4] == "locc" ? "loccN" : "hiccN"] = true
		cc, ok := strconv.parse_int(op.name[4:])
		if !ok || cc < 0 || cc >= 128 {
			continue
		}
		bound, _ := strconv.parse_f64(op.value)
		v := f64(c.cc[cc])
		if (op.name[:4] == "locc" && v < bound) || (op.name[:4] == "hicc" && v > bound) {
			return false
		}
	}
	return true
}

// SFZ's fil_type as a Filter's type and rolloff.
@(private = "file")
filter_kind :: proc(t: string) -> (kind: string, rolloff: f32, ok: bool) {
	switch t {
	case "lpf_1p":
		return "onepole", -6, true
	case "hpf_1p":
		return "difference", -6, true
	case "lpf_2p", "":
		return "lowpass", -12, true
	case "lpf_4p":
		return "lowpass", -24, true
	case "lpf_6p":
		return "lowpass", -48, true
	case "hpf_2p":
		return "highpass", -12, true
	case "hpf_4p":
		return "highpass", -24, true
	case "hpf_6p":
		return "highpass", -48, true
	case "bpf_1p", "bpf_2p":
		return "bandpass", -12, true
	case "brf_1p", "brf_2p":
		return "notch", -12, true
	case "apf_1p":
		return "allpass", -12, true
	case "pkf_2p", "peq":
		return "peaking", -12, true
	case "lsh":
		return "lowshelf", -12, true
	case "hsh":
		return "highshelf", -12, true
	}
	return "lowpass", -12, false
}

// SFZ v2's lfoN_wave numbers as an Lfo's wave.
@(private = "file")
lfo_wave :: proc(n: int) -> string {
	switch n {
	case 0:
		return "triangle"
	case 2, 3, 4, 5:
		return "square"
	case 6, 7:
		return "sawtooth"
	}
	return "sine"
}

// The program an SFZ instrument plays: `set` its set of the bank (a zone a
// region with a sample, in order), `cc` the values its CCs sit at.
sfz_program_desc :: proc(s: ^Sfz, set: i32, cc: [128]f32, path: string, findings: ^base.Findings, overrides: map[string]f64 = nil) -> ^device.Program_Desc {
	c := Sfz_Compile{s = s, cc = cc, overrides = overrides}
	c.read = make(map[string]bool, context.temp_allocator)
	for k in ([]string{"sample", "region_label", "group_label", "master_label", "global_label", "sw_label", "key", "lokey", "hikey", "pitch_keycenter"}) {
		c.read[k] = true
	}
	desc := new(device.Program_Desc, context.temp_allocator)
	desc.path, desc.out = path, "out"
	layers := make([dynamic]device.Layer_Desc, context.temp_allocator)
	zone := 0
	sw_lo, sw_hi, sw_default := 255, -1, -1
	for r in 0 ..< len(s.regions) {
		sample, has_sample := text_of(&c, r, "sample")
		generator := has_sample && strings.has_prefix(sample, "*")
		this_zone := -1
		if has_sample && !generator {
			this_zone = zone
			zone += 1
		}
		// the instrument's keyswitch range
		if v, found := text_of(&c, r, "sw_lokey"); found {
			sw_lo = min(sw_lo, sfz_key(s, v, 0))
		}
		if v, found := text_of(&c, r, "sw_hikey"); found {
			sw_hi = max(sw_hi, sfz_key(s, v, 127))
		}
		if v, found := text_of(&c, r, "sw_default"); found {
			sw_default = sfz_key(s, v, -1)
		}
		if !has_sample || !cc_conditions(&c, r) {
			continue
		}
		// a bank program other than the first: not this instrument's
		if param(&c, r, "loprog", 0) > 0 {
			continue
		}
		_ = param(&c, r, "hiprog", 127)
		l := device.Layer_Desc{path = strings.concatenate({s.regions[r].file, ":", int_text(int(s.regions[r].line))})}
		row := &l.region
		lo, hi := key_of(&c, r, "lokey", 0), key_of(&c, r, "hikey", 127)
		if v, found := sfz_value(s, r, "key"); found {
			k := sfz_key(s, v, 60)
			lo, hi = k, k
		}
		row^ = {
			lo_key = u8(clamp(lo, 0, 127)), hi_key = u8(clamp(hi, 0, 127)),
			lo_vel = u8(clamp(param(&c, r, "lovel", 0), 0, 127)), hi_vel = u8(clamp(param(&c, r, "hivel", 127), 0, 127)),
			lo_rand = f32(param(&c, r, "lorand", 0)), hi_rand = f32(param(&c, r, "hirand", 1)),
			seq_length = u16(max(param(&c, r, "seq_length", 1), 1)), seq_position = u16(max(param(&c, r, "seq_position", 1), 1)),
			group = i32(param(&c, r, "group", 0)), off_by = i32(param(&c, r, "off_by", 0)),
			off_time = f32(param(&c, r, "off_time", 0.006)),
			polyphony = u16(max(param(&c, r, "polyphony", 0), 0)), note_polyphony = u16(max(param(&c, r, "note_polyphony", 0), 0)),
			rt_decay = f32(param(&c, r, "rt_decay", 0)),
		}
		if row.hi_rand >= 1 {
			row.hi_rand = 1.01 // its top includes 1
		}
		if t, found := text_of(&c, r, "trigger"); found {
			switch t {
			case "release", "release_key":
				row.trigger = .Release
			case "first":
				row.trigger = .First
			case "legato":
				row.trigger = .Legato
			}
		}
		if m, found := text_of(&c, r, "off_mode"); found {
			switch m {
			case "normal":
				row.off_mode = .Normal
			case "time":
				row.off_mode = .Time
			}
		}
		if v, found := text_of(&c, r, "sw_last"); found {
			k := u8(clamp(sfz_key(s, v, 0), 0, 127)) + 1
			row.sw_last_lo, row.sw_last_hi = k, k
		}
		if v, found := text_of(&c, r, "sw_lolast"); found {
			row.sw_last_lo = u8(clamp(sfz_key(s, v, 0), 0, 127)) + 1
			row.sw_last_hi = max(row.sw_last_hi, row.sw_last_lo)
		}
		if v, found := text_of(&c, r, "sw_hilast"); found {
			row.sw_last_hi = u8(clamp(sfz_key(s, v, 127), 0, 127)) + 1
		}
		l.program = sfz_region_desc(&c, r, set, this_zone, sample, row.trigger == .Release)
		append(&layers, l)
	}
	desc.layers = layers[:]
	if sw_hi >= 0 {
		desc.sw_lo, desc.sw_hi = u8(clamp(sw_lo, 0, 127)) + 1, u8(clamp(sw_hi, 0, 127)) + 1
	}
	if sw_default >= 0 {
		desc.sw_default = u8(clamp(sw_default, 0, 127)) + 1
	}
	// its CCs as knobs to read (set at compile: by the row, set_ccN, a label)
	controls := make([dynamic]device.Control_Desc, context.temp_allocator)
	for k in 0 ..< 128 {
		if k not_in s.cc_set && s.cc_labels[k] == "" && cc[k] == s.cc[k] {
			continue
		}
		append(&controls, device.Control_Desc{name = strings.concatenate({"cc", int_text(k)}, context.temp_allocator), value = cc[k], given = true, fixed = true, path = path})
		if s.cc_labels[k] != "" {
			append(&controls, device.Control_Desc{name = s.cc_labels[k], value = cc[k], given = true, fixed = true, path = path})
		}
	}
	desc.controls = controls[:]
	sfz_findings(&c, path, findings)
	return desc
}

@(private = "file")
int_text :: proc(n: int) -> string {
	buf: [24]u8
	return strings.clone(strconv.write_int(buf[:], i64(n), 10), context.temp_allocator)
}

// The program one region plays.
@(private = "file")
sfz_region_desc :: proc(c: ^Sfz_Compile, r: int, set: i32, zone: int, sample: string, release: bool) -> ^device.Program_Desc {
	s := c.s
	desc := new(device.Program_Desc, context.temp_allocator)
	desc.out = "out"
	nodes := make([dynamic]device.Node_Desc, context.temp_allocator)
	tables := make([dynamic]device.Table_Desc, context.temp_allocator)
	add :: proc(nodes: ^[dynamic]device.Node_Desc, name: string, kind: device.Node_Kind) -> ^device.Node_Desc {
		append(nodes, device.Node_Desc{name = name, kind = kind, values = device.node_defaults(kind)})
		return &nodes[len(nodes) - 1]
	}
	set_field :: proc(n: ^device.Node_Desc, name: string, v: f64) {
		if _, slot, ok := device.node_field_from_name(n.kind, name); ok {
			n.values[slot] = f32(v)
		}
	}
	mod :: proc(n: ^device.Node_Desc, field, source: string, kind: device.Mod_Kind, amount: f64) {
		_, slot, ok := device.node_field_from_name(n.kind, field)
		if !ok {
			return
		}
		mods := make([dynamic]device.Mod_Desc, context.temp_allocator)
		append(&mods, ..n.mods)
		append(&mods, device.Mod_Desc{slot = slot, source = source, kind = kind, amount = f32(amount), exponent = 1})
		n.mods = mods[:]
	}
	inputs :: proc(n: ^device.Node_Desc, names: ..string) {
		list := make([]string, len(names), context.temp_allocator)
		copy(list, names)
		n.inputs = list
	}
	// the key less a center (a keytrack's source)
	key_from :: proc(nodes: ^[dynamic]device.Node_Desc, center: f64) -> string {
		name := strings.concatenate({"key_", int_text(int(center))}, context.temp_allocator)
		for n in nodes {
			if n.name == name {
				return name
			}
		}
		m := add(nodes, name, device.NODE_MAP)
		set_field(m, "offset", -center)
		inputs(m, "key")
		return name
	}
	// ---- the source -----------------------------------------------------------------
	src: ^device.Node_Desc
	pitch_target := "rate"
	tune := param(c, r, "tune", 0) + 100 * param(c, r, "transpose", 0)
	if strings.has_prefix(sample, "*") {
		switch sample {
		case "*noise":
			src = add(&nodes, "src", device.NODE_NOISE)
		case "*silence":
			src = add(&nodes, "src", device.NODE_MAP) // nothing: a map of nothing
			inputs(src, "gate")
			set_field(src, "scale", 0)
		case:
			src = add(&nodes, "src", device.NODE_OSC)
			wave := "sine"
			switch sample {
			case "*saw":
				wave = "sawtooth"
			case "*square":
				wave = "square"
			case "*triangle", "*tri":
				wave = "triangle"
			}
			for w, i in device.WAVE_CHOICES {
				if w == wave {
					set_field(src, "wave", f64(i))
				}
			}
			set_field(src, "tune", tune / 100)
			pitch_target = "frequency"
		}
	} else {
		src = add(&nodes, "src", device.NODE_REGION)
		set_field(src, "set", f64(set))
		set_field(src, "zone", f64(zone))
		set_field(src, "keycenter", f64(key_of(c, r, "pitch_keycenter", sfz_value_key(s, r, 60))))
		set_field(src, "keytrack", param(c, r, "pitch_keytrack", 100))
		set_field(src, "tune", tune)
		set_field(src, "offset", param(c, r, "offset", 0))
		set_field(src, "offset_random", param(c, r, "offset_random", 0))
		set_field(src, "end", param(c, r, "end", 0))
		set_field(src, "delay", param(c, r, "delay", 0))
		set_field(src, "width", param(c, r, "width", 100))
		mode := device.Loop_Mode.Default
		m, has_mode := text_of(c, r, "loop_mode")
		if has_mode {
			mode, _ = device.loop_mode_from_name(m)
		}
		if !has_mode && release {
			mode = .One_Shot // a release region plays its sample out
		}
		set_field(src, "loop_mode", f64(mode))
		if v, found := text_of(c, r, "loop_start"); found {
			n, _ := strconv.parse_f64(v)
			set_field(src, "loop_start", n)
			if mode == .Default {
				set_field(src, "loop_mode", f64(device.Loop_Mode.Continuous))
			}
		}
		if v, found := text_of(c, r, "loop_end"); found {
			n, _ := strconv.parse_f64(v)
			set_field(src, "loop_end", n)
			if mode == .Default {
				set_field(src, "loop_mode", f64(device.Loop_Mode.Continuous))
			}
		}
		desc.one_shot = mode == .One_Shot
		if random := param(c, r, "delay_random", 0); random > 0 {
			rnd := add(&nodes, "delay_random", device.NODE_RANDOM)
			_ = rnd
			src = &nodes[0]
			mod(src, "delay", "delay_random", .Amount, random / 2)
			set_field(src, "delay", param(c, r, "delay", 0) + random / 2)
		}
	}
	src = &nodes[0]
	if v := param(c, r, "pitch_veltrack", 0); v != 0 && pitch_target == "rate" {
		mod(src, "tune", "velocity", .Amount, v)
	}
	if v := param(c, r, "pitch_random", 0); v != 0 {
		add(&nodes, "pitch_random", device.NODE_RANDOM)
		src = &nodes[0]
		mod(src, pitch_target == "rate" ? "tune" : "frequency", "pitch_random", pitch_target == "rate" ? .Amount : .Octaves, pitch_target == "rate" ? v : v / 1200)
	}
	last := "src"
	// ---- envelopes and LFOs ---------------------------------------------------------
	env :: proc(c: ^Sfz_Compile, r: int, nodes: ^[dynamic]device.Node_Desc, prefix, name: string, sustain_default: f64) -> ^device.Node_Desc {
		e := add(nodes, name, device.NODE_ENV)
		p :: proc(c: ^Sfz_Compile, r: int, prefix, field: string, fallback: f64) -> f64 {
			return param(c, r, strings.concatenate({prefix, "_", field}, context.temp_allocator), fallback)
		}
		set_field(e, "delay", p(c, r, prefix, "delay", 0))
		set_field(e, "start", p(c, r, prefix, "start", 0) / 100)
		set_field(e, "attack", p(c, r, prefix, "attack", 0))
		set_field(e, "hold", p(c, r, prefix, "hold", 0))
		set_field(e, "decay", p(c, r, prefix, "decay", 0))
		set_field(e, "sustain", p(c, r, prefix, "sustain", sustain_default) / 100)
		set_field(e, "release", max(p(c, r, prefix, "release", prefix == "ampeg" ? 0.001 : 0), 0))
		for f in ([]string{"delay", "attack", "hold", "decay", "release"}) {
			if v := p(c, r, prefix, strings.concatenate({"vel2", f}, context.temp_allocator), 0); v != 0 {
				mod(e, f, "velocity", .Amount, v)
			}
		}
		if v := p(c, r, prefix, "vel2sustain", 0); v != 0 {
			mod(e, "sustain", "velocity", .Amount, v / 100)
		}
		return e
	}
	lfo :: proc(c: ^Sfz_Compile, nodes: ^[dynamic]device.Node_Desc, r: int, name, freq, delay, fade: string) -> string {
		f := param(c, r, freq, 0)
		if f <= 0 {
			return ""
		}
		o := add(nodes, name, device.NODE_LFO)
		set_field(o, "rate", f)
		set_field(o, "delay", param(c, r, delay, 0))
		set_field(o, "fade", param(c, r, fade, 0))
		return name
	}
	// ---- the filters and EQ ---------------------------------------------------------
	for k in 0 ..< 2 {
		prefix := k == 0 ? "fil" : "fil2"
		cutoff_name := k == 0 ? "cutoff" : "cutoff2"
		type_name := k == 0 ? "fil_type" : "fil2_type"
		if _, has := sfz_value(s, r, cutoff_name); !has {
			c.read[cutoff_name] = true
			continue
		}
		t, _ := text_of(c, r, type_name)
		kind, rolloff, _ := filter_kind(t)
		name := k == 0 ? "fil" : "fil2"
		f := add(&nodes, name, device.NODE_FILTER)
		for x, i in device.node_row(device.NODE_FILTER).fields[0].choices {
			if x == kind {
				set_field(f, "type", f64(i))
			}
		}
		set_field(f, "rolloff", f64(rolloff))
		set_field(f, "frequency", max(param(c, r, cutoff_name, 20000), 1))
		res := param(c, r, k == 0 ? "resonance" : "resonance2", 0)
		set_field(f, "q", 0.7071 * base.db_to_gain(res))
		set_field(f, "gain", param(c, r, strings.concatenate({prefix, "_gain"}, context.temp_allocator), 0))
		inputs(f, last)
		last = name
		if v := param(c, r, strings.concatenate({prefix, "_veltrack"}, context.temp_allocator), 0); v != 0 {
			mod(f, "frequency", "velocity", .Octaves, v / 1200)
		}
		if v := param(c, r, strings.concatenate({prefix, "_keytrack"}, context.temp_allocator), 0); v != 0 {
			center := f64(key_of(c, r, strings.concatenate({prefix, "_keycenter"}, context.temp_allocator), 60))
			source := key_from(&nodes, center)
			mod(find(&nodes, name), "frequency", source, .Octaves, v / 1200)
		}
		if v := param(c, r, strings.concatenate({prefix, "_random"}, context.temp_allocator), 0); v != 0 {
			rn := strings.concatenate({name, "_random"}, context.temp_allocator)
			add(&nodes, rn, device.NODE_RANDOM)
			mod(find(&nodes, name), "frequency", rn, .Octaves, v / 2400)
		}
		if k == 0 {
			if depth := param(c, r, "fileg_depth", 0); depth != 0 {
				env(c, r, &nodes, "fileg", "fileg", 0)
				mod(find(&nodes, name), "frequency", "fileg", .Octaves, depth / 1200)
			}
			if lf := lfo(c, &nodes, r, "fillfo", "fillfo_freq", "fillfo_delay", "fillfo_fade"); lf != "" {
				mod(find(&nodes, name), "frequency", lf, .Octaves, param(c, r, "fillfo_depth", 0) / 1200)
			}
		}
	}
	EQ_FREQUENCIES := [3]f64{50, 500, 5000}
	for k in 1 ..= 3 {
		gain := param(c, r, strings.concatenate({"eq", int_text(k), "_gain"}, context.temp_allocator), 0)
		freq := param(c, r, strings.concatenate({"eq", int_text(k), "_freq"}, context.temp_allocator), EQ_FREQUENCIES[k - 1])
		bw := param(c, r, strings.concatenate({"eq", int_text(k), "_bw"}, context.temp_allocator), 1)
		if gain == 0 {
			continue
		}
		name := strings.concatenate({"eq", int_text(k)}, context.temp_allocator)
		f := add(&nodes, name, device.NODE_FILTER)
		for x, i in device.node_row(device.NODE_FILTER).fields[0].choices {
			if x == "peaking" {
				set_field(f, "type", f64(i))
			}
		}
		p2 := math.pow(2, max(bw, 0.01))
		set_field(f, "frequency", freq)
		set_field(f, "q", math.sqrt(p2) / (p2 - 1))
		set_field(f, "gain", gain)
		inputs(f, last)
		last = name
	}
	// ---- pitch --------------------------------------------------------------------
	if depth := param(c, r, "pitcheg_depth", 0); depth != 0 {
		env(c, r, &nodes, "pitcheg", "pitcheg", 0)
		mod(find(&nodes, "src"), pitch_target, "pitcheg", .Octaves, depth / 1200)
	}
	if lf := lfo(c, &nodes, r, "pitchlfo", "pitchlfo_freq", "pitchlfo_delay", "pitchlfo_fade"); lf != "" {
		mod(find(&nodes, "src"), pitch_target, lf, .Octaves, param(c, r, "pitchlfo_depth", 0) / 1200)
	}
	// ---- the amp ------------------------------------------------------------------
	env(c, r, &nodes, "ampeg", "ampeg", 100)
	out := add(&nodes, "out", device.NODE_MIX)
	inputs(out, last)
	volume := param(c, r, "volume", 0) + param(c, r, "group_volume", 0) + param(c, r, "master_volume", 0) + param(c, r, "global_volume", 0)
	amplitude := param(c, r, "amplitude", 100) / 100 * param(c, r, "global_amplitude", 100) / 100 * param(c, r, "master_amplitude", 100) / 100 * param(c, r, "group_amplitude", 100) / 100
	gain := base.db_to_gain(volume) * max(amplitude, 0)
	// crossfades over CCs, at their values
	gain *= cc_crossfade(c, r)
	set_field(out, "gain_db", gain) // linear in a desc
	set_field(out, "pan", clamp(param(c, r, "pan", 0) / 100, -1, 1))
	out = find(&nodes, "out")
	mod(out, "amp", "ampeg", .Depth, 1)
	// the velocity's level: its curve (amp_velcurve_N, else SFZ's square)
	// through amp_veltrack, and its crossfade
	if table, plain := velocity_table(c, r); !plain {
		v := add(&nodes, "vel", device.NODE_CURVE)
		inputs(v, "velocity")
		append(&tables, device.Table_Desc{"vel", table})
		mod(find(&nodes, "out"), "amp", "vel", .Depth, 1)
	}
	if table, plain := key_table(c, r); !plain {
		kn := add(&nodes, "key_unit", device.NODE_MAP)
		set_field(kn, "scale", 1.0 / 127)
		inputs(kn, "key")
		v := add(&nodes, "key_fade", device.NODE_CURVE)
		inputs(v, "key_unit")
		append(&tables, device.Table_Desc{"key_fade", table})
		mod(find(&nodes, "out"), "amp", "key_fade", .Depth, 1)
	}
	if v := param(c, r, "amp_keytrack", 0); v != 0 {
		source := key_from(&nodes, f64(key_of(c, r, "amp_keycenter", 60)))
		mod(find(&nodes, "out"), "amp", source, .Octaves, v / 6.0206)
	}
	if v := param(c, r, "amp_random", 0); v != 0 {
		add(&nodes, "amp_random", device.NODE_RANDOM)
		mod(find(&nodes, "out"), "amp", "amp_random", .Octaves, v / 12.041)
	}
	if lf := lfo(c, &nodes, r, "amplfo", "amplfo_freq", "amplfo_delay", "amplfo_fade"); lf != "" {
		mod(find(&nodes, "out"), "amp", lf, .Octaves, param(c, r, "amplfo_depth", 0) / 6.0206)
	}
	// SFZ v2's LFOs, each moving what its opcodes name
	for k in 1 ..= 8 {
		ks := int_text(k)
		pre := strings.concatenate({"lfo", ks, "_"}, context.temp_allocator)
		f := param(c, r, strings.concatenate({pre, "freq"}, context.temp_allocator), 0)
		if f <= 0 {
			continue
		}
		name := strings.concatenate({"lfo", ks}, context.temp_allocator)
		o := add(&nodes, name, device.NODE_LFO)
		set_field(o, "rate", f)
		set_field(o, "delay", param(c, r, strings.concatenate({pre, "delay"}, context.temp_allocator), 0))
		set_field(o, "fade", param(c, r, strings.concatenate({pre, "fade"}, context.temp_allocator), 0))
		set_field(o, "phase", param(c, r, strings.concatenate({pre, "phase"}, context.temp_allocator), 0))
		wave := lfo_wave(int(param(c, r, strings.concatenate({pre, "wave"}, context.temp_allocator), 1)))
		for w, i in device.node_row(device.NODE_LFO).fields[0].choices {
			if w == wave {
				set_field(o, "wave", f64(i))
			}
		}
		if v := param(c, r, strings.concatenate({pre, "pitch"}, context.temp_allocator), 0); v != 0 {
			mod(find(&nodes, "src"), pitch_target, name, .Octaves, v / 1200)
		}
		if v := param(c, r, strings.concatenate({pre, "volume"}, context.temp_allocator), 0); v != 0 {
			mod(find(&nodes, "out"), "amp", name, .Octaves, v / 6.0206)
		}
		if v := param(c, r, strings.concatenate({pre, "amplitude"}, context.temp_allocator), 0); v != 0 {
			mod(find(&nodes, "out"), "amp", name, .Amount, v / 100)
		}
		if v := param(c, r, strings.concatenate({pre, "pan"}, context.temp_allocator), 0); v != 0 {
			mod(find(&nodes, "out"), "pan", name, .Amount, v / 100)
		}
		if v := param(c, r, strings.concatenate({pre, "cutoff"}, context.temp_allocator), 0); v != 0 {
			if fil := find(&nodes, "fil"); fil != nil {
				mod(fil, "frequency", name, .Octaves, v / 1200)
			}
		}
	}
	// SFZ v2's flex envelopes: points, a sustain, and what each moves
	for k in 1 ..= 8 {
		pre := strings.concatenate({"eg", int_text(k), "_"}, context.temp_allocator)
		has := false
		for x in 0 ..< device.SEGMENT_POINTS {
			if _, found := sfz_value(s, r, strings.concatenate({pre, "time", int_text(x)}, context.temp_allocator)); found {
				has = true
			}
		}
		if !has {
			continue
		}
		name := strings.concatenate({"eg", int_text(k)}, context.temp_allocator)
		e := add(&nodes, name, device.NODE_SEGMENTS)
		points := 0
		for x in 0 ..< device.SEGMENT_POINTS {
			t_name := strings.concatenate({pre, "time", int_text(x)}, context.temp_allocator)
			l_name := strings.concatenate({pre, "level", int_text(x)}, context.temp_allocator)
			_, has_t := sfz_value(s, r, t_name)
			_, has_l := sfz_value(s, r, l_name)
			if has_t || has_l {
				points = x + 1
			}
			e.values[device.SEGMENTS_TIMES + x] = f32(param(c, r, t_name, 0))
			e.values[device.SEGMENTS_LEVELS + x] = f32(param(c, r, l_name, 0))
		}
		e.values[device.SEGMENTS_POINTS] = f32(max(points, 1))
		e.values[device.SEGMENTS_SUSTAIN] = f32(param(c, r, strings.concatenate({pre, "sustain"}, context.temp_allocator), -1))
		if v := param(c, r, strings.concatenate({pre, "amplitude"}, context.temp_allocator), 0); v != 0 {
			mod(find(&nodes, "out"), "amp", name, .Depth, v / 100)
		}
		if v := param(c, r, strings.concatenate({pre, "volume"}, context.temp_allocator), 0); v != 0 {
			mod(find(&nodes, "out"), "amp", name, .Octaves, v / 6.0206)
		}
		if v := param(c, r, strings.concatenate({pre, "pitch"}, context.temp_allocator), 0); v != 0 {
			mod(find(&nodes, "src"), pitch_target, name, .Octaves, v / 1200)
		}
		if v := param(c, r, strings.concatenate({pre, "cutoff"}, context.temp_allocator), 0); v != 0 {
			if fil := find(&nodes, "fil"); fil != nil {
				mod(fil, "frequency", name, .Octaves, v / 1200)
			}
		}
		if v := param(c, r, strings.concatenate({pre, "pan"}, context.temp_allocator), 0); v != 0 {
			mod(find(&nodes, "out"), "pan", name, .Amount, v / 100)
		}
	}
	desc.nodes = nodes[:]
	desc.tables = tables[:]
	desc.velocity = false // the velocity's level is the region's own curve
	return desc
}

@(private = "file")
find :: proc(nodes: ^[dynamic]device.Node_Desc, name: string) -> ^device.Node_Desc {
	for &n in nodes {
		if n.name == name {
			return &n
		}
	}
	return nil
}

// A region's key center when it gives none: its key=, else 60.
@(private = "file")
sfz_value_key :: proc(s: ^Sfz, r: int, fallback: int) -> int {
	if v, found := sfz_value(s, r, "key"); found {
		return sfz_key(s, v, fallback)
	}
	return fallback
}

// The gain the region's CC crossfades give at the CCs' values.
@(private = "file")
cc_crossfade :: proc(c: ^Sfz_Compile, r: int) -> f64 {
	g := 1.0
	power := true
	if v, found := text_of(c, r, "xf_cccurve"); found {
		power = v != "gain"
	}
	sp := c.s.regions[r].opcodes
	for op in c.s.opcodes[sp.first:base.span_end(sp)] {
		for prefix in ([]string{"xfin_locc", "xfout_locc"}) {
			if !strings.has_prefix(op.name, prefix) {
				continue
			}
			cc, ok := strconv.parse_int(op.name[len(prefix):])
			if !ok || cc < 0 || cc >= 128 {
				continue
			}
			c.read[strings.concatenate({prefix, "N"}, context.temp_allocator)] = true
			hi_name := strings.concatenate({prefix[:len(prefix) - 4], "hicc", op.name[len(prefix):]}, context.temp_allocator)
			c.read[strings.concatenate({prefix[:len(prefix) - 4], "hiccN"}, context.temp_allocator)] = true
			lo, _ := strconv.parse_f64(op.value)
			hi := sfz_number(c.s, r, hi_name, lo)
			x := f64(c.cc[cc])
			t := hi > lo ? clamp((x - lo) / (hi - lo), 0, 1) : (x >= hi ? 1 : 0)
			if strings.has_prefix(prefix, "xfout") {
				t = 1 - t
			}
			g *= power ? math.sqrt(t) : t
		}
	}
	return g
}

// The velocity's level over 128 points: amp_velcurve_N's points (straight
// between them), else SFZ's square, through amp_veltrack; times the
// velocity crossfades. Plain: 1 everywhere (no node needed).
@(private = "file")
velocity_table :: proc(c: ^Sfz_Compile, r: int) -> (table: []f32, plain: bool) {
	table = make([]f32, device.CURVE_POINTS, context.temp_allocator)
	points: [128]f32
	given: [128]bool
	any_given := false
	sp := c.s.regions[r].opcodes
	for op in c.s.opcodes[sp.first:base.span_end(sp)] {
		if strings.has_prefix(op.name, "amp_velcurve_") {
			c.read["amp_velcurve_N"] = true
			if k, ok := strconv.parse_int(op.name[len("amp_velcurve_"):]); ok && k >= 0 && k < 128 {
				v, _ := strconv.parse_f64(op.value)
				points[k], given[k], any_given = f32(v), true, true
			}
		}
	}
	if any_given {
		if !given[0] {
			points[0], given[0] = 0, true
		}
		if !given[127] {
			points[127], given[127] = 1, true
		}
		last := 0
		for k in 1 ..< 128 {
			if !given[k] {
				continue
			}
			for j in last + 1 ..< k {
				points[j] = points[last] + (points[k] - points[last]) * f32(j - last) / f32(k - last)
			}
			last = k
		}
	} else {
		for k in 0 ..< 128 {
			x := f32(k) / 127
			points[k] = x * x
		}
	}
	track := f32(param(c, r, "amp_veltrack", 100) / 100)
	xf_lo_in, xf_hi_in := param(c, r, "xfin_lovel", 0), param(c, r, "xfin_hivel", 0)
	xf_lo_out, xf_hi_out := param(c, r, "xfout_lovel", 127), param(c, r, "xfout_hivel", 127)
	power := true
	if v, found := text_of(c, r, "xf_velcurve"); found {
		power = v != "gain"
	}
	plain = true
	for k in 0 ..< 128 {
		curve := points[k]
		g := track >= 0 ? 1 - track + track * curve : 1 + track * curve
		x := f64(k)
		fade := 1.0
		if xf_hi_in > xf_lo_in {
			fade *= clamp((x - xf_lo_in) / (xf_hi_in - xf_lo_in), 0, 1)
		}
		if xf_hi_out > xf_lo_out {
			fade *= 1 - clamp((x - xf_lo_out) / (xf_hi_out - xf_lo_out), 0, 1)
		}
		if power {
			fade = math.sqrt(fade)
		}
		table[k] = g * f32(fade)
		plain &&= abs(table[k] - 1) < 1e-6
	}
	return
}

// The key crossfades' level over 128 keys. Plain: none.
@(private = "file")
key_table :: proc(c: ^Sfz_Compile, r: int) -> (table: []f32, plain: bool) {
	table = make([]f32, device.CURVE_POINTS, context.temp_allocator)
	lo_in, hi_in := param(c, r, "xfin_lokey", 0), param(c, r, "xfin_hikey", 0)
	lo_out, hi_out := param(c, r, "xfout_lokey", 127), param(c, r, "xfout_hikey", 127)
	power := true
	if v, found := text_of(c, r, "xf_keycurve"); found {
		power = v != "gain"
	}
	plain = true
	for k in 0 ..< 128 {
		x := f64(k)
		fade := 1.0
		if hi_in > lo_in {
			fade *= clamp((x - lo_in) / (hi_in - lo_in), 0, 1)
		}
		if hi_out > lo_out {
			fade *= 1 - clamp((x - lo_out) / (hi_out - lo_out), 0, 1)
		}
		table[k] = f32(power ? math.sqrt(fade) : fade)
		plain &&= abs(table[k] - 1) < 1e-6
	}
	return
}

// The opcodes the instrument uses that odawg doesn't read: a finding each
// (once, its count and first region): a Warning where the sound differs
// from SFZ's, Info where it doesn't (a label, metadata).
@(private = "file")
sfz_findings :: proc(c: ^Sfz_Compile, path: string, findings: ^base.Findings) {
	Unread :: struct {
		count: int,
		file:  string,
		line:  i32,
	}
	unread := make(map[string]Unread, context.temp_allocator)
	order := make([dynamic]string, context.temp_allocator)
	for region, ri in c.s.regions {
		for op in c.s.opcodes[region.opcodes.first:base.span_end(region.opcodes)] {
			n := op.read
			if n.row < 0 {
				continue // not in the reference: the reader's finding
			}
			row := SFZ_OPCODES[n.row]
			if c.read[row.name] || c.read[op.name] || row.status == .Info || n.mod == .Smooth || n.mod == .Step {
				continue
			}
			if n.mod == .Curve {
				continue // a curve read with the modulation it shapes
			}
			key := n.mod == .On ? strings.concatenate({row.name, " (by a CC)"}, context.temp_allocator) : row.name
			if n.mod == .On && c.read[row.name] {
				continue
			}
			u, seen := unread[key]
			if !seen {
				append(&order, key)
				u.file, u.line = c.s.regions[ri].file, c.s.regions[ri].line
			}
			u.count += 1
			unread[key] = u
		}
	}
	for key in order {
		u := unread[key]
		base.report(findings, "unsupported_opcode", .Warning, path, "%s: %s isn't played (%d use%s, first at %s:%d); the sound differs from SFZ's there", path, key, u.count, u.count == 1 ? "" : "s", u.file, u.line)
	}
	for u in c.s.unknown {
		base.report(findings, "unknown_opcode", .Warning, path, "%s: %s is not an SFZ opcode (%d use%s, first at %s:%d)", path, u.name, u.count, u.count == 1 ? "" : "s", u.file, u.line)
	}
	if c.s.effects > 0 {
		base.report(findings, "unsupported_opcode", .Warning, path, "%s: its <effect> headers aren't played (%d)", path, c.s.effects)
	}
}
