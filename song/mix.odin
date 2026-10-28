package odawg_song

import "core:encoding/json"
import "core:slice"
import "core:strings"
import base "../base"
import device "../device"
import spec "../spec"

// A mix: songs and clips on one timeline (onimite's video), as one Song the
// engine streams. A song is appended by copying its tables with every index
// moved past what is there and every time moved to where it starts, and a
// placement row saying where it plays and how (core.odin); a clip is a track
// of its own playing one note on a program of one Clip node. The form,
// chords and markers stay with the songs (questions go to them); the mix is
// what plays.

mix_init :: proc(m: ^Song) {
	m^ = {master_gain = 1}
	m.findings = make(base.Findings)
}

// Appends a composed song starting at `at` seconds on the mix's clock, its
// parts named `prefix/part` ("score/drums"): its rows copied with every
// index moved past what is there and every time to where it starts, and its
// placement, where the rest of its playing is said once: `gain` on its
// level, `window` (on the mix's clock) letting it through with fades as a
// placed clip is, `duck` (a spans sidechain) dipping all it plays under the
// voice. Returns its placement (a host's room spans for it name it).
append_song :: proc(m: ^Song, s: ^Song, at: base.Seconds, prefix: string, gain: base.Gain = 1, window: Window = {}, duck: Sidechain = {}) -> i32 {
	if m.bank == nil {
		m.bank = s.bank
	}
	part0, dev0, chain0 := i32(len(m.parts)), i32(len(m.devices)), i32(len(m.chain))
	send0, ret0, track0, note0 := i32(len(m.sends)), i32(len(m.returns)), i32(len(m.tracks)), i32(len(m.notes))
	bus0, place0 := i32(len(m.buses)), i32(len(m.placements))
	shift :: proc(sp: Span, by: i32) -> Span {return {sp.first + by, sp.count}}
	for p in s.parts {
		append(&m.parts, strings.concatenate({prefix, "/", p}))
	}
	ctl0 := i32(len(m.programs.controls))
	prog0 := programs_append(&m.programs, &s.programs)
	for n in s.pad_names {
		pad_intern(m, n)
	}
	append(&m.devices, ..s.devices[:])
	append(&m.labels, ..s.labels[:])
	for p, i in s.params {
		x := p
		if device.DEVICE_TABLE[s.devices[i]].program {
			x[.Program] += f32(prog0)
		}
		append(&m.params, x)
	}
	for d in s.chain {
		append(&m.chain, d + dev0)
	}
	for snd in s.sends {
		append(&m.sends, Send{snd.ret + ret0, snd.gain})
	}
	for r in s.returns {
		append(&m.returns, Return{strings.concatenate({prefix, "/", r.name}), shift(r.chain, chain0)})
	}
	for t in s.tracks {
		x := t
		x.style = style_intern(m, style_name(s, t.style))
		x.part += part0
		x.instrument += dev0
		x.chain = shift(t.chain, chain0)
		x.sends = shift(t.sends, send0)
		x.notes = shift(t.notes, note0)
		x.sidechains = {i32(len(m.sidechains)), 0}
		for sc in s.sidechains[t.sidechains.first:base.span_end(t.sidechains)] {
			y := sc
			if y.mode == .Hits {
				y.part += part0
			}
			append(&m.sidechains, y)
			x.sidechains.count += 1
		}
		append(&m.tracks, x)
	}
	for g in s.pad_gains {
		append(&m.pad_gains, Pad_Gain{g.track + track0, g.pad, g.gain})
	}
	for i in 0 ..< len(s.notes) {
		n := s.notes[i]
		n.time += at
		n.track += u16(track0)
		append_soa(&m.notes, n)
	}
	for r in s.regions {
		append(&m.regions, Region{r.part + part0, r.start + at, r.stop + at, r.source})
	}
	// its buses, named under the prefix ("score/glue"), and its routes moved
	// past what is there; what went to its master goes to its placement's
	// node (graph_build)
	for b in s.buses {
		append(&m.buses, Bus{strings.concatenate({prefix, "/", b.name}), shift(b.chain, chain0)})
	}
	moved :: proc(n: Node, part0, ret0, bus0: i32) -> Node {
		#partial switch n.kind {
		case .Part:
			return {n.kind, n.ref + part0}
		case .Return:
			return {n.kind, n.ref + ret0}
		case .Bus:
			return {n.kind, n.ref + bus0}
		}
		return n
	}
	for rt in s.routes {
		x := rt
		x.from, x.to = moved(rt.from, part0, ret0, bus0), moved(rt.to, part0, ret0, bus0)
		append(&m.routes, x)
	}
	// its placements (a composed song's one) moved here; this placing's
	// level adds to theirs, its window and duck are theirs
	for pl, i in s.placements {
		// its tempo map kept (a copy: the song may go), its beats its own
		if i < len(s.placement_tempo) {
			append(&m.placement_tempo, Tempo_Map{slice.clone_to_dynamic(s.placement_tempo[i].segments[:])})
		} else {
			append(&m.placement_tempo, Tempo_Map{})
		}
		x := pl
		x.name = prefix
		x.at += at
		x.gain *= gain
		if window.stop > window.start {
			x.window = window
		}
		if duck.mode != .None {
			x.duck = duck
		}
		x.tracks, x.parts = shift(pl.tracks, track0), shift(pl.parts, part0)
		x.returns, x.buses = shift(pl.returns, ret0), shift(pl.buses, bus0)
		append(&m.placements, x)
	}
	for r in s.room {
		append(&m.room, Room_Span{r.placement + place0, r.start + at, r.stop + at})
	}
	// its lanes, on what moved here and from where it starts; paths under
	// the prefix as its parts are
	at_sample := i64(at * base.RATE + 0.5)
	point0 := i32(len(m.automation_points))
	for pt in s.automation_points {
		x := pt
		x.at += at_sample
		append(&m.automation_points, x)
	}
	for a in s.automation {
		x := a
		x.path = strings.concatenate({prefix, "/", a.path})
		x.points = shift(a.points, point0)
		switch a.kind {
		case .Track_Gain, .Track_Pan:
			x.ref += track0
		case .Control:
			x.ref += ctl0
			x.track += track0
		case .Effect_Control:
			x.ref += ctl0
		case .Param:
			x.ref += dev0
		case .Placement_Gain:
			x.ref += place0
		case .Send:
			x.from, x.to = moved(a.from, part0, ret0, bus0), moved(a.to, part0, ret0, bus0)
			if a.from.kind == .Track {
				x.from.ref += track0
			}
		}
		append(&m.automation, x)
	}
	m.duration = max(m.duration, at + s.duration)
	return place0
}

// A clip on the mix: a bank set played from `offset` seconds in, from
// `start` to `stop` seconds on the mix, with onimite's track options. At
// `rate`, mix time t plays the set at offset + (t - start) * rate.
Clip :: struct {
	name:     string, // its part ("music.mp3", "intro")
	set:      i32, // into bank.sets
	start:    base.Seconds,
	stop:     base.Seconds,
	offset:   base.Seconds,
	gain:     Maybe(base.Gain), // nil: 1
	pan:      f64,
	fade_in:  base.Seconds,
	fade_out: base.Seconds,
	curve:    device.Curve,
	mono:     bool,
	rate:     f64, // playback rate, a tape's (pitch moves with it; -1: backwards from offset); 0 reads as 1
	voice:    bool, // speech: ducks the ducked
	ducked:   bool,
	duck:     struct {
		floor:                         Maybe(base.Gain), // nil: duck_under_voice's
		attack, hold, release, merge: base.Seconds,
	},
	// its effects, as a part's `effects` is written ({ { "Reverb", wet =
	// 0.2 }, "tremolo", ... }: a built-in, or a row the mix's host_rows
	// names; nil: none). A clip has no tempo: a Tone length in them reads at
	// 120 bpm.
	effects:  json.Value,
}

CLIP_BEAT_SECONDS :: 0.5

append_clip :: proc(m: ^Song, c: Clip) -> i32 {
	part := i32(len(m.parts))
	append(&m.parts, strings.clone(c.name))
	// a program of one node: the Clip, playing the set from its offset
	node := device.Node_Desc{name = "clip", kind = device.NODE_CLIP, values = device.node_defaults(device.NODE_CLIP)}
	node.values[device.CLIP_SET] = f32(c.set)
	node.values[device.CLIP_OFFSET] = f32(c.offset)
	node.values[device.CLIP_FADE_IN] = f32(c.fade_in)
	node.values[device.CLIP_FADE_OUT] = f32(c.fade_out)
	node.values[device.CLIP_CURVE] = f32(c.curve)
	node.values[device.CLIP_MONO] = c.mono ? 1 : 0
	node.values[device.CLIP_RATE] = c.rate == 0 ? 1 : f32(c.rate)
	desc := device.Program_Desc{nodes = {node}, out = "clip", velocity = true, path = c.name}
	p := device.params_from_kind(.Voice)
	p[.Program] = f32(device.compile_program(&m.programs, &desc, &m.findings))
	append(&m.devices, device.Device_Kind.Voice)
	append(&m.labels, "Player")
	append(&m.params, p)
	t := Track{part = part, style = -1, instrument = i32(len(m.devices) - 1), gain = c.gain.? or_else 1, room = 1, pan = c.pan, pan_law = .Balance, notes = {i32(len(m.notes)), 1}}
	if c.effects != nil {
		// read for this call only (the song keeps copies of what it plays)
		fx := new(spec.Spec, context.temp_allocator)
		spec.spec_init(fx, context.temp_allocator)
		fx.outer = m.host_rows // the rows it names: the host's
		chain := spec.effects_from_value(fx, c.effects, base.path_join(c.name, "effects"), &m.findings)
		t.chain = chain_into_song(m, fx, chain, CLIP_BEAT_SECONDS)
	}
	if c.ducked {
		t.sidechains = {i32(len(m.sidechains)), 1}
		append(&m.sidechains, duck_under_voice(c.duck.floor, c.duck.attack, c.duck.hold, c.duck.release, c.duck.merge))
	}
	track := i32(len(m.tracks))
	append(&m.tracks, t)
	append_soa(&m.notes, Note_Row{time = c.start, duration = c.stop - c.start, velocity = 1, track = u16(track)})
	if c.voice {
		append(&m.voices, [2]base.Seconds{c.start, c.stop}) // speech: what a spans sidechain ducks under
	}
	append(&m.regions, Region{part, c.start, c.stop, c.name})
	m.duration = max(m.duration, c.stop)
	return track
}

// A spans sidechain with onimite's (fframes') defaults for what is unset
// or 0: down to -12 dB, 0.2 s before the voice, 0.3 s hold, 0.8 s release,
// gaps under 0.8 s merged.
duck_under_voice :: proc(floor: Maybe(base.Gain), attack, hold, release, merge: base.Seconds) -> Sidechain {
	return {mode = .Spans, floor = floor.? or_else base.db_to_gain(-12), attack = attack > 0 ? attack : 0.2, hold = hold > 0 ? hold : 0.3, release = release > 0 ? release : 0.8, merge = merge > 0 ? merge : 0.8}
}

// After the appends: the notes in time order, the voice spans merged by the
// widest merge any ducked track asks (each track then merges by its own
// when it ducks).
mix_end :: proc(m: ^Song) {
	sort_regions(m)
	graph_build(m)
	notes_by_time(m)
	slice.sort_by(m.voices[:], proc(a, b: [2]base.Seconds) -> bool {return a[0] < b[0]})
}

// The mode of the program owning layer `i` (its row's table).
@(private = "file")
layer_mode_of :: proc(progs: ^device.Programs, i: int) -> device.Layer_Mode {
	for p in progs.programs {
		if i32(i) >= p.layers.first && i32(i) < base.span_end(p.layers) {
			return p.layer_mode
		}
	}
	return .One
}

// Appends a song's programs to a mix's, every index moved past what is
// there; the first one's new index.
@(private = "file")
programs_append :: proc(to, from: ^device.Programs) -> i32 {
	p0, n0, m0 := i32(len(to.programs)), i32(len(to.nodes)), i32(len(to.mods))
	i0, pad0, c0 := i32(len(to.inputs)), i32(len(to.layers)), i32(len(to.chokes))
	pads0, regions0 := i32(len(to.pads)), i32(len(to.regions))
	ctl0, tgt0 := i32(len(to.controls)), i32(len(to.control_targets))
	shift :: proc(sp: Span, by: i32) -> Span {return {sp.first + by, sp.count}}
	for p in from.programs {
		x := p
		x.nodes, x.layers, x.controls = shift(p.nodes, n0), shift(p.layers, pad0), shift(p.controls, ctl0)
		append(&to.programs, x)
	}
	for c in from.controls {
		x := c
		x.targets = shift(c.targets, tgt0)
		append(&to.controls, x)
	}
	append(&to.control_names, ..from.control_names[:])
	for t in from.control_targets {
		x := t
		x.node += n0
		if x.mod >= 0 {
			x.mod += m0
		}
		append(&to.control_targets, x)
	}
	for n in from.nodes {
		x := n
		x.mods, x.inputs = shift(n.mods, m0), shift(n.inputs, i0)
		append(&to.nodes, x)
	}
	append(&to.mods, ..from.mods[:])
	append(&to.inputs, ..from.inputs[:])
	t0 := f32(len(to.tables) / device.CURVE_POINTS)
	for pr, i in from.layers {
		x := pr
		if x.program >= 0 {
			x.program += p0
		}
		// its row: a pad's or a region's, by its program's mode
		x.row += layer_mode_of(from, i) == .All ? regions0 : pads0
		// its values, a table field moved past the tables there
		x.params = {i32(len(to.layer_params)), pr.params.count}
		if pr.program >= 0 {
			fp := from.programs[pr.program]
			for lp in from.layer_params[pr.params.first:base.span_end(pr.params)] {
				y := lp
				if int(lp.slot) == device.node_table_slot(from.nodes[fp.nodes.first + i32(lp.node)].kind) {
					y.value += t0
				}
				append(&to.layer_params, y)
			}
		}
		append(&to.layers, x)
	}
	for pad in from.pads {
		x := pad
		x.chokes = shift(pad.chokes, c0)
		append(&to.pads, x)
	}
	append(&to.regions, ..from.regions[:])
	append(&to.chokes, ..from.chokes[:])
	// a table field (a Curve's) moves past the tables there
	if t0 > 0 {
		for &n in to.nodes[n0:] {
			if slot := device.node_table_slot(n.kind); slot >= 0 {
				n.values[slot] += t0
			}
		}
	}
	append(&to.tables, ..from.tables[:])
	return p0
}
