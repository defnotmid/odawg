package odawg_song

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import base "../base"
import device "../device"
import spec "../spec"
import tempo "../tempo"

// Automation: values moving over song time. A lane names one settable value
// by its path (`parts/pad/cutoff`) and holds points; each row here is one
// thing the engine moves (a part's lane is a row per track). A lane's value
// is a function of the song sample alone (automation_value), so a preview, an
// export, a seek and any thread count hear the same.

// What a row moves.
Automation_Kind :: enum u8 {
	Track_Gain, // a track's fader (a gain): ref the track
	Track_Pan, // its pan (-1..1): ref the track
	Send, // a send's level (a gain): the edge from `from` to `to`
	Param, // an effect's param: ref the device, param it
	Control, // an instrument's control (an option, or a field's own): ref the control in programs, track the track playing it
	Effect_Control, // an effect row's control: ref the control in programs (the effect playing its program reads it)
	Placement_Gain, // a placed song's level (a gain; `master/gain_db`): ref the placement
}

// The kinds that move a level: their lanes are written in dB (`gain_db`)
// and kept as gains, moving evenly in dB.
AUTOMATION_LEVELS := [Automation_Kind]bool {
	.Track_Gain     = true,
	.Track_Pan      = false,
	.Send           = true,
	.Param          = false,
	.Control        = false,
	.Effect_Control = false,
	.Placement_Gain = true,
}

Automation :: struct {
	path:     string, // as written: every row of a lane has it
	kind:     Automation_Kind,
	ref:      i32,
	track:    i32, // a Control's track (its program's)
	param:    device.Param,
	from, to: Node, // a Send's
	points:   Span, // into automation_points: the lane's
}

// How a value travels from the point before to this one.
Automation_Curve :: enum u8 {
	Linear,
	Exp, // geometrically (a frequency, a time)
	Step, // holds, then jumps here
}

AUTOMATION_CURVE_NAMES := [Automation_Curve]string {
	.Linear = "linear",
	.Exp    = "exp",
	.Step   = "step",
}

Automation_Point :: struct {
	at:    i64, // song sample
	value: f32,
	curve: Automation_Curve,
}

// A lane's value holds over each cell of this many samples of song time,
// taken at its start: what an effect or an instrument reads steps at the
// cells' edges (1.3 ms), wherever a block, a note or a seek cuts. Levels
// (a fader, a pan, a send) move every sample.
AUTOMATION_CELL :: 64

// Lane `a`'s value at song sample t: the first point's before it, the last's
// after, between two the later one's curve.
automation_value :: proc(s: ^Song, a: Automation, t: i64) -> f32 {
	pts := s.automation_points[a.points.first:base.span_end(a.points)]
	if len(pts) == 0 {
		return 0
	}
	if t <= pts[0].at {
		return pts[0].value
	}
	// the first point after t
	k, _ := slice.binary_search_by(pts, t, proc(p: Automation_Point, t: i64) -> slice.Ordering {
		return p.at <= t ? .Less : .Greater
	})
	if k >= len(pts) {
		return pts[len(pts) - 1].value
	}
	a0, a1 := pts[k - 1], pts[k]
	x := f64(t - a0.at) / f64(a1.at - a0.at)
	switch a1.curve {
	case .Step:
		return a0.value
	case .Exp:
		return f32(f64(a0.value) * math.pow(f64(a1.value) / f64(a0.value), x))
	case .Linear:
	}
	return a0.value + (a1.value - a0.value) * f32(x)
}

// Lane `a`'s values over len(out) samples from song sample `at`: what
// automation_value gives, walking its points once. An exp segment's (a
// level's) is stepped by one factor a sample from the exact value at each
// cell's start, so it is a function of the song sample alone wherever a
// block starts.
automation_values :: proc(s: ^Song, a: Automation, at: i64, out: []f32) {
	pts := s.automation_points[a.points.first:base.span_end(a.points)]
	n := i64(len(out))
	if len(pts) == 0 {
		slice.fill(out, 0)
		return
	}
	k := 0 // the first point after the sample
	for i: i64 = 0; i < n; {
		t := at + i
		for k < len(pts) && pts[k].at <= t {
			k += 1
		}
		if k == 0 || k == len(pts) {
			// before the first point, after the last: held
			v, end := pts[0].value, min(n, pts[0].at - at)
			if k > 0 {
				v, end = pts[len(pts) - 1].value, n
			}
			for ; i < end; i += 1 {
				out[i] = v
			}
			continue
		}
		a0, a1 := pts[k - 1], pts[k]
		end := min(n, a1.at - at)
		span := f64(a1.at - a0.at)
		switch a1.curve {
		case .Step:
			for ; i < end; i += 1 {
				out[i] = a0.value
			}
		case .Linear:
			for ; i < end; i += 1 {
				out[i] = a0.value + (a1.value - a0.value) * f32(f64(at + i - a0.at) / span)
			}
		case .Exp:
			ratio := f64(a1.value) / f64(a0.value)
			step := math.pow(ratio, 1 / span)
			for i < end {
				from := max(automation_cell(at + i), a0.at)
				v := f64(a0.value) * math.pow(ratio, f64(from - a0.at) / span)
				for _ in from ..< at + i {
					v *= step
				}
				for stop := min(end, automation_cell(at + i) + AUTOMATION_CELL - at); i < stop; i += 1 {
					out[i] = f32(v)
					v *= step
				}
			}
		}
	}
}

// Its value held over the cell sample t is in.
automation_cell_value :: proc(s: ^Song, a: Automation, t: i64) -> f32 {
	return automation_value(s, a, automation_cell(t))
}

// The start of the cell sample t is in.
automation_cell :: #force_inline proc(t: i64) -> i64 {
	return t - (t %% AUTOMATION_CELL)
}

// A lane's value by its path at `seconds` of song time (a host's picture
// following a sweep): the engine's own function.
automation_at :: proc(s: ^Song, path: string, seconds: f64) -> (value: f32, ok: bool) {
	for a in s.automation {
		if a.path == path {
			return automation_value(s, a, i64(math.round(seconds * base.RATE))), true
		}
	}
	return 0, false
}

// Device d's params with every lane on it at its largest value: what its
// state, delay lines and memory are sized for, so no value a lane reaches
// outgrows them.
params_largest :: proc(s: ^Song, d: i32) -> device.Params {
	p := s.params[d]
	for a in s.automation {
		if a.kind != .Param || a.ref != d {
			continue
		}
		for pt in s.automation_points[a.points.first:base.span_end(a.points)] {
			p[a.param] = max(p[a.param], pt.value)
		}
	}
	return p
}

// Device d's memory (an effect's) as far as its lanes take it: a built-in's
// params at their largest (params_largest); an effect row's at its values,
// and at each of its lanes' lowest and highest (the most of those), on a
// copy of the values the lanes move.
effect_memory_largest :: proc(s: ^Song, d: i32) -> device.Effect_Memory {
	p := params_largest(s, d)
	m := device.effect_memory(s.devices[d], &p, &s.programs)
	if !device.DEVICE_TABLE[s.devices[d]].program {
		return m
	}
	program := i32(p[.Program])
	if program < 0 || int(program) >= len(s.programs.programs) {
		return m
	}
	progs: device.Programs
	for a in s.automation {
		if a.kind != .Effect_Control || device.control_program(&s.programs, a.ref) != program {
			continue
		}
		if progs.programs == nil {
			progs = s.programs
			progs.nodes = slice.clone_to_dynamic(s.programs.nodes[:], context.temp_allocator)
			progs.mods = slice.clone_to_dynamic(s.programs.mods[:], context.temp_allocator)
			progs.controls = slice.clone_to_dynamic(s.programs.controls[:], context.temp_allocator)
		}
		lo, hi := automation_range(s, a.points)
		for v in ([2]f32{lo, hi}) {
			device.control_apply(&progs, &progs.controls[a.ref], v)
			x := device.effect_memory(s.devices[d], &p, &progs)
			m.ring, m.state = max(m.ring, x.ring), max(m.state, x.state)
		}
		device.control_apply(&progs, &progs.controls[a.ref], s.programs.controls[a.ref].value)
	}
	return m
}

// ---- from the spec -------------------------------------------------------------------

// The spec's lanes resolved into rows (after the tracks and their chains
// are built): each path once, a finding for what it can't move.
automation_from_spec :: proc(s: ^spec.Spec, song: ^Song) {
	for lane in s.automation {
		path := base.path_join("automation", lane.path, context.allocator)
		points, ok := automation_points_from_spec(s, song, lane, path)
		if !ok {
			continue
		}
		first := len(song.automation)
		lo, hi := automation_range(song, points)
		automation_targets(song, lane.path, path, points, lo, hi, &song.automation, &song.findings)
		if len(song.automation) == first {
			continue
		}
		pts := song.automation_points[points.first:base.span_end(points)]
		if AUTOMATION_LEVELS[song.automation[first].kind] {
			// a level, written in dB: kept as gains, moving evenly in dB
			// (geometrically; straight in gain to or from silence) or stepping
			for &pt, i in pts {
				if s.automation_points[lane.points.first + i32(i)].curve == "exp" {
					base.report(&song.findings, "bad_value", .Warning, base.path_index(path, i + 1), "%s: a level moves evenly in dB already (\"linear\") or steps; \"exp\" reads as \"linear\"", base.path_index(path, i + 1))
				}
				pt.value = f32(base.db_to_gain(base.Db(pt.value)))
				if pt.curve != .Step {
					pt.curve = i > 0 && pt.value > 0 && pts[i - 1].value > 0 ? .Exp : .Linear
				}
			}
			continue
		}
		// a lane's values are in its field's unit: a frequency or a time
		// travels geometrically unless written otherwise, and only through
		// values above 0 then
		unit := automation_unit(song, song.automation[first])
		for &pt, i in pts {
			ps := s.automation_points[lane.points.first + i32(i)]
			if ps.curve == "" && (unit == .Hz || unit == .Seconds) {
				pt.curve = .Exp
			}
			if pt.curve == .Exp && i > 0 && (pt.value <= 0 || pts[i - 1].value <= 0) {
				base.report(&song.findings, "bad_value", .Error, base.path_index(path, i + 1), "%s: an exp curve moves through values above 0 (%g to %g); give the point \"linear\"", base.path_index(path, i + 1), pts[i - 1].value, pt.value)
				pt.curve = .Linear
			}
		}
	}
}

@(private = "file")
automation_points_from_spec :: proc(s: ^spec.Spec, song: ^Song, lane: spec.Automation_Spec, path: string) -> (sp: Span, ok: bool) {
	sp = {i32(len(song.automation_points)), 0}
	last := min(i64)
	for ps, i in s.automation_points[lane.points.first:base.span_end(lane.points)] {
		pp := base.path_index(path, i + 1)
		b: f64
		found: bool
		if math.is_nan(ps.at.seconds) {
			b, found = beat_from_position(song, ps.at.text)
		} else {
			b, found = tempo.beat_from_seconds(&song.tempo, ps.at.seconds - s.start), true
		}
		if !found {
			base.report(&song.findings, "bad_value", .Error, pp, "%s: %q is not a position in the song", pp, ps.at.text)
			return sp, false
		}
		at := i64(math.round(tempo.seconds_from_beat(&song.tempo, b) * base.RATE))
		if at < last {
			base.report(&song.findings, "bad_value", .Error, pp, "%s: points go in time order (this one is before the one before it)", pp)
			return sp, false
		}
		last = at
		curve := Automation_Curve.Linear
		if ps.curve != "" {
			known := false
			for name, c in AUTOMATION_CURVE_NAMES {
				if name == ps.curve {
					curve, known = c, true
				}
			}
			if !known {
				base.report(&song.findings, "bad_value", .Error, pp, "%s: %q is not a curve (linear, exp, step)", pp, ps.curve)
			}
		}
		append(&song.automation_points, Automation_Point{at, f32(ps.value), curve})
		sp.count += 1
	}
	return sp, sp.count > 0
}

// The unit a row's values are in.
@(private = "file")
automation_unit :: proc(song: ^Song, a: Automation) -> device.Unit {
	#partial switch a.kind {
	case .Param:
		return device.PARAM_TABLE[a.param].unit
	case .Control, .Effect_Control:
		progs := &song.programs
		c := progs.controls[a.ref]
		if c.targets.count > 0 {
			t := progs.control_targets[c.targets.first]
			if t.mod < 0 && t.op == .Set {
				if f := device.field_of_slot(progs.nodes[t.node].kind, int(t.slot)); f != nil {
					return f.unit
				}
			}
		}
	}
	return .Number
}

// Rows for what `name` names, appended to `out` (an instrument's value
// checked to move between lo and hi); a finding at `path` for what it can't.
automation_targets :: proc(song: ^Song, name, path: string, points: Span, lo, hi: f32, out: ^[dynamic]Automation, findings: ^base.Findings) {
	add :: proc(out: ^[dynamic]Automation, a: Automation) {
		x := a
		x.path = strings.clone(a.path)
		append(out, x)
	}
	bad :: proc(findings: ^base.Findings, path, format: string, args: ..any) {
		base.report(findings, "unknown_key", .Error, path, format, ..args)
	}
	row := Automation{path = name, points = points}
	switch {
	case strings.has_prefix(name, "parts/"):
		part, rest := part_from_path(song, name[len("parts/"):])
		if part < 0 || rest == "" {
			bad(findings, path, "%s: no part's value is named %q (parts/<part>/gain_db, pan, sends/<name>, effects/<effect>/<param>, an option or node/field; the parts: %s)", path, name, names_joined(song.parts[:]))
			return
		}
		tracks := make([dynamic]i32, context.temp_allocator)
		for t, i in song.tracks {
			if int(t.part) == part {
				append(&tracks, i32(i))
			}
		}
		switch {
		case rest == "gain_db" || rest == "pan":
			for ti in tracks {
				row.kind, row.ref = rest == "pan" ? .Track_Pan : .Track_Gain, ti
				add(out, row)
			}
		case strings.has_prefix(rest, "sends/"):
			to, ok := node_ref_from_name(song, rest[len("sends/"):])
			if !ok || (to.kind != .Return && to.kind != .Bus) {
				bad(findings, path, "%s: there is no return or bus %q (there are: %s)", path, rest[len("sends/"):], sinks_of(song))
				return
			}
			row.kind, row.to = .Send, to
			if to.kind == .Bus {
				// a send to a bus is a route from the part
				row.from = {.Part, i32(part)}
				add(out, row)
				return
			}
			for ti in tracks {
				for snd in song.sends[song.tracks[ti].sends.first:base.span_end(song.tracks[ti].sends)] {
					if snd.ret == to.ref {
						row.from = {.Track, ti}
						add(out, row)
					}
				}
			}
		case strings.has_prefix(rest, "effects/"):
			for ti in tracks {
				automation_effect(song, &row, song.tracks[ti].chain, rest[len("effects/"):], path, lo, hi, out, findings)
			}
		case:
			for ti in tracks {
				program := i32(song.params[song.tracks[ti].instrument][.Program])
				c := device.control_from_path(&song.programs, program, rest)
				if c < 0 {
					bad(findings, path, "%s: the instrument of part %s has no option or node/field %q (its options: %s; or gain_db, pan, sends/<name>, effects/<effect>/<param>)", path, song.parts[part], rest, options_of(song, program))
					return
				}
				if !device.control_moves(&song.programs, program, c, lo, hi) {
					base.report(findings, "fixed_value", .Error, path, "%s: %q can't move (it is read once, or between %g and %g it would change the instrument's shape)", path, rest, lo, hi)
					return
				}
				row.kind, row.ref, row.track = .Control, c, ti
				add(out, row)
			}
		}
	case strings.has_prefix(name, "returns/") || strings.has_prefix(name, "buses/"):
		slash := strings.index_byte(name, '/')
		rest := name[slash + 1:]
		at := strings.index_byte(rest, '/')
		if at < 0 {
			bad(findings, path, "%s: name an effect's param (%s<name>/<effect>/<param>)", path, name[:slash + 1])
			return
		}
		node, ok := node_ref_from_name(song, rest[:at])
		if !ok || (node.kind != .Return && node.kind != .Bus) {
			bad(findings, path, "%s: there is no %s %q (there are: %s)", path, name[:slash], rest[:at], sinks_of(song))
			return
		}
		automation_effect(song, &row, NODE_CHAIN[node.kind](song, node.ref), rest[at + 1:], path, lo, hi, out, findings)
	case name == "master/gain_db":
		row.kind, row.ref = .Placement_Gain, 0
		add(out, row)
	case:
		bad(findings, path, "%s: %q moves nothing (parts/..., returns/..., buses/..., master/gain_db)", path, name)
	}
}

// What a finding lists as the choices: names joined.
@(private = "file")
names_joined :: proc(names: []string) -> string {
	return len(names) == 0 ? "none" : strings.join(names, ", ", context.temp_allocator)
}

// The returns' and buses' names.
@(private = "file")
sinks_of :: proc(song: ^Song) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for r in song.returns {
		append(&names, r.name)
	}
	for b in song.buses {
		append(&names, b.name)
	}
	return names_joined(names[:])
}

// An instrument's options (its controls' names).
@(private = "file")
options_of :: proc(song: ^Song, program: i32) -> string {
	if program < 0 {
		return "none"
	}
	p := song.programs.programs[program]
	return names_joined(song.programs.control_names[p.controls.first:base.span_end(p.controls)])
}

// An effect's param in `chain` (`Filter/frequency`, `2/frequency`: the
// second effect, `Filter#2/frequency`: the second Filter), or an effect
// row's option or node/field (`phaser/depth`, `phaser/lfo/rate`), checked
// to move between lo and hi.
@(private = "file")
automation_effect :: proc(song: ^Song, row: ^Automation, chain: Span, rest, path: string, lo, hi: f32, out: ^[dynamic]Automation, findings: ^base.Findings) {
	at := strings.index_byte(rest, '/')
	if at < 0 {
		base.report(findings, "unknown_key", .Error, path, "%s: name the effect and its param (effects/Filter/frequency)", path)
		return
	}
	which, param_path := rest[:at], rest[at + 1:]
	name, nth := which, 1
	if hash := strings.index_byte(which, '#'); hash >= 0 {
		name = which[:hash]
		nth, _ = strconv.parse_int(which[hash + 1:])
	}
	index, by_index := strconv.parse_int(which)
	seen := 0
	for d, i in song.chain[chain.first:base.span_end(chain)] {
		kind := song.devices[d]
		if by_index ? i + 1 != index : song.labels[d] != name {
			continue
		}
		seen += 1
		if !by_index && seen != nth {
			continue
		}
		if device.DEVICE_TABLE[kind].program {
			// an effect row: its control (an option, or a node/field)
			program := i32(song.params[d][.Program])
			c := device.control_from_path(&song.programs, program, param_path)
			if c < 0 {
				base.report(findings, "unknown_key", .Error, path, "%s: effect row %s has no option or node/field %q (its options: %s)", path, which, param_path, options_of(song, program))
				return
			}
			if f := device.control_pinned(&song.programs, c); f != nil {
				why := f.pace ? "its phase runs on the song clock, so a seek lands where a render from the start is" : "an effect row reads it as it is put in place"
				base.report(findings, "fixed_value", .Error, path, "%s: %q can't move in an effect row (%s); set it in the row, or where the chain places it", path, param_path, why)
				return
			}
			if !device.control_moves(&song.programs, program, c, lo, hi) {
				base.report(findings, "fixed_value", .Error, path, "%s: %q can't move (it is read once, or between %g and %g it would change the row's shape)", path, param_path, lo, hi)
				return
			}
			row.kind, row.ref = .Effect_Control, c
			x := row^
			x.path = strings.clone(row.path)
			append(out, x)
			return
		}
		for p in device.Param {
			pr := device.PARAM_TABLE[p]
			if pr.path != param_path || p not_in device.DEVICE_TABLE[kind].reads {
				continue
			}
			if p in device.PARAM_FIXED || pr.unit == .Choice || pr.unit == .Asset || pr.unit == .Table {
				base.report(findings, "fixed_value", .Error, path, "%s: %s's %s is read once (it shapes the effect) and can't move", path, device.DEVICE_TABLE[kind].name, param_path)
				return
			}
			row.kind, row.ref, row.param = .Param, d, p
			x := row^
			x.path = strings.clone(row.path)
			append(out, x)
			return
		}
		params := make([dynamic]string, context.temp_allocator)
		for q in device.DEVICE_TABLE[kind].reads {
			if pr := device.PARAM_TABLE[q]; pr.path != "" && q not_in device.PARAM_FIXED && pr.unit != .Choice {
				append(&params, pr.path)
			}
		}
		base.report(findings, "unknown_key", .Error, path, "%s: %s has no param %q (it moves: %s)", path, device.DEVICE_TABLE[kind].name, param_path, names_joined(params[:]))
		return
	}
	effects := make([dynamic]string, context.temp_allocator)
	for d, i in song.chain[chain.first:base.span_end(chain)] {
		append(&effects, song.labels[d] != "" ? song.labels[d] : fmt.tprint(i + 1)) // a row written out: by its place
	}
	base.report(findings, "unknown_key", .Error, path, "%s: no effect %q in the chain (it has: %s)", path, which, names_joined(effects[:]))
}

// The smallest and largest value a lane's points reach.
@(private = "file")
automation_range :: proc(song: ^Song, points: Span) -> (lo, hi: f32) {
	lo, hi = max(f32), min(f32)
	for pt in song.automation_points[points.first:base.span_end(points)] {
		lo, hi = min(lo, pt.value), max(hi, pt.value)
	}
	return
}
