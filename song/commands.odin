package odawg_song

import "core:slice"
import "core:strings"
import base "../base"
import device "../device"
import spec "../spec"

// Editing a composed song: every change is a command row (its kind, the
// path it acts on, a value), applied in one place (command_apply) after
// COMMAND_KINDS checks it. A kind's row says what it does and what it
// touches; applying it moves the versions of what changed, so what was
// measured from the rest (render's tables) stays good. A host's edits (a
// DAW's knobs, an agent's "make the kick louder") are these rows; a spec
// edited and composed again is a new song.
//
// Paths are the song's: "drums" (a part, every track it has), "drums/kick"
// (a pad of it), "bass/filter/frequency" (a control of its instrument,
// else a node's value: "bass/ladder/frequency"; a clip's: "music/clip/fade_in"),
// "keys/sends/hall" (a send), "keys/effects/Filter/frequency" or
// "returns/hall/Reverb/wet" (an effect's param, as automation names them),
// "master". A host playing the song applies a row here, then hands it to
// its engine (render.engine_sync).

Command_Kind :: enum u8 {
	None,
	Part_Gain_Set,
	Part_Gain_Step,
	Part_Pan_Set,
	Part_Mute_Set,
	Pad_Gain_Set,
	Pad_Gain_Step,
	Param_Set,
	Master_Gain_Set,
	Master_Gain_Step,
	Send_Set,
	Effect_Param_Set,
}

// What a command changes, for the versions it moves: a part's own sound
// (its stem and the mix), or only the mix (the master).
Command_Touch :: enum u8 {
	Part,
	Mix,
}

Command_Kind_Row :: struct {
	name:    string,
	about:   string,
	touches: Command_Touch,
	// Applies the row to the tracks it names (`tracks`: the part's), or to
	// the song (Mix). False: it named nothing it can change.
	apply:   proc(s: ^Song, row: Command_Row, tracks: []int) -> bool,
}

Command_Row :: struct {
	kind:  Command_Kind,
	path:  string,
	value: f64,
}

COMMAND_KINDS := [Command_Kind]Command_Kind_Row {
	.None = {},
	.Part_Gain_Set = {"part/gain_db", "a part's level, dB", .Part, proc(s: ^Song, row: Command_Row, tracks: []int) -> bool {
		return part_gain(s, tracks, base.db_to_gain(base.Db(row.value)), false)
	}},
	.Part_Gain_Step = {"part/gain_db+", "a part's level moved by dB", .Part, proc(s: ^Song, row: Command_Row, tracks: []int) -> bool {
		return part_gain(s, tracks, base.db_to_gain(base.Db(row.value)), true)
	}},
	.Part_Pan_Set = {"part/pan", "a part's pan, -1..1", .Part, proc(s: ^Song, row: Command_Row, tracks: []int) -> bool {
		for ti in tracks {
			s.tracks[ti].pan = clamp(row.value, -1, 1)
		}
		return len(tracks) > 0
	}},
	.Part_Mute_Set = {"part/mute", "a part left out (1) or heard (0)", .Part, proc(s: ^Song, row: Command_Row, tracks: []int) -> bool {
		for ti in tracks {
			s.tracks[ti].muted = row.value != 0
		}
		return len(tracks) > 0
	}},
	.Pad_Gain_Set = {"pad/gain_db", "a drum pad's level, dB (\"drums/kick\")", .Part, proc(s: ^Song, row: Command_Row, tracks: []int) -> bool {
		return pad_gain(s, row, tracks, false)
	}},
	.Pad_Gain_Step = {"pad/gain_db+", "a drum pad's level moved by dB", .Part, proc(s: ^Song, row: Command_Row, tracks: []int) -> bool {
		return pad_gain(s, row, tracks, true)
	}},
	.Param_Set = {"param", "a value of a node of a part's instrument (\"bass/filter/frequency\"), in its unit (new notes play it)", .Part, proc(s: ^Song, row: Command_Row, tracks: []int) -> bool {
		_, rest := part_from_path(s, row.path)
		done := false
		for ti in tracks {
			d := s.tracks[ti].instrument
			done ||= node_value_set(s, i32(s.params[d][.Program]), rest, f32(row.value))
		}
		return done
	}},
	.Master_Gain_Set = {"master/gain_db", "the master's gain, dB", .Mix, proc(s: ^Song, row: Command_Row, tracks: []int) -> bool {
		s.master_gain = base.db_to_gain(base.Db(row.value))
		return true
	}},
	.Master_Gain_Step = {"master/gain_db+", "the master's gain moved by dB", .Mix, proc(s: ^Song, row: Command_Row, tracks: []int) -> bool {
		s.master_gain *= base.db_to_gain(base.Db(row.value))
		return true
	}},
	.Send_Set = {"send/gain_db", "a part's send to a return or a bus, dB (\"keys/sends/hall\")", .Part, proc(s: ^Song, row: Command_Row, tracks: []int) -> bool {
		rows := command_rows(s, row)
		g := base.db_to_gain(base.Db(row.value))
		for a in rows {
			if a.kind != .Send {
				continue
			}
			if a.from.kind == .Track {
				t := s.tracks[a.from.ref]
				for &snd in s.sends[t.sends.first:base.span_end(t.sends)] {
					if snd.ret == a.to.ref {
						snd.gain = g
					}
				}
			}
			for &rt in s.routes {
				if rt.from == a.from && rt.to == a.to {
					rt.gain = g
				}
			}
			from, to := node_index(s, a.from), node_index(s, a.to)
			for &x in s.edges {
				if x.from == from && x.to == to && x.kind == .Audio {
					x.gain = g
				}
			}
		}
		return len(rows) > 0
	}},
	.Effect_Param_Set = {"effect", "an effect's param, or an effect row's option, in its unit (\"keys/effects/Filter/frequency\", \"keys/effects/phaser/depth\", \"returns/hall/Reverb/wet\")", .Part, proc(s: ^Song, row: Command_Row, tracks: []int) -> bool {
		rows := command_rows(s, row)
		for a in rows {
			#partial switch a.kind {
			case .Param:
				s.params[a.ref][a.param] = f32(row.value)
			case .Effect_Control:
				device.control_apply(&s.programs, &s.programs.controls[a.ref], f32(row.value))
			}
		}
		programs := command_programs(s, rows)
		for p in programs {
			device.program_derive(&s.programs, p)
		}
		return len(command_devices(s, row)) > 0 || len(programs) > 0
	}},
}

// The automation rows a Send_Set's or an Effect_Param_Set's path names
// (automation's grammar under the part: "keys/sends/hall" is
// "parts/keys/sends/hall"; "returns/..." and "buses/..." as they are).
command_rows :: proc(s: ^Song, row: Command_Row) -> []Automation {
	out := make([dynamic]Automation, context.temp_allocator)
	want := row.kind == .Send_Set ? "/sends/" : "/effects/"
	if !strings.contains(row.path, want) && !(row.kind == .Effect_Param_Set && command_on_mix(row.path)) {
		return nil // only a send's or an effect's: never an instrument's value made a control
	}
	name := row.path
	if !command_on_mix(row.path) {
		name = strings.concatenate({"parts/", row.path}, context.temp_allocator)
	}
	unheard := make(base.Findings, context.temp_allocator) // a row naming nothing is command_apply's finding
	automation_targets(s, name, row.path, {}, f32(row.value), f32(row.value), &out, &unheard)
	return out[:]
}

// The devices an Effect_Param_Set's path names.
command_devices :: proc(s: ^Song, row: Command_Row) -> []i32 {
	out := make([dynamic]i32, context.temp_allocator)
	for a in command_rows(s, row) {
		if a.kind == .Param {
			append(&out, a.ref)
		}
	}
	return out[:]
}

// The effect rows' programs whose controls rows name.
command_programs :: proc(s: ^Song, rows: []Automation) -> []i32 {
	out := make([dynamic]i32, context.temp_allocator)
	for a in rows {
		if a.kind != .Effect_Control {
			continue
		}
		if p := device.control_program(&s.programs, a.ref); p >= 0 && !slice.contains(out[:], p) {
			append(&out, p)
		}
	}
	return out[:]
}

// Whether a path names a return's or a bus's value, not a part's.
@(private = "file")
command_on_mix :: proc(path: string) -> bool {
	return strings.has_prefix(path, "returns/") || strings.has_prefix(path, "buses/")
}

// Applies `row`: the tracks of the part its path names (a Part kind), its
// rule, then the versions of what it touched. A row naming nothing it can
// change is a finding (`bad_command`) and changes nothing.
command_apply :: proc(s: ^Song, row: Command_Row) -> bool {
	k := COMMAND_KINDS[row.kind]
	if k.apply == nil {
		return false
	}
	tracks := make([dynamic]int, context.temp_allocator)
	part := -1
	if k.touches == .Part && !command_on_mix(row.path) {
		part, _ = part_from_path(s, row.path)
		for t, ti in s.tracks {
			if int(t.part) == part {
				append(&tracks, ti)
			}
		}
	}
	if (k.touches == .Part && part < 0 && !command_on_mix(row.path)) || !k.apply(s, row, tracks[:]) {
		base.report(&s.findings, "bad_command", .Warning, row.path, "%s %s: nothing in the song to change", k.name, row.path)
		return false
	}
	s.version += 1
	if part >= 0 {
		if len(s.part_versions) < len(s.parts) {
			if s.part_versions.allocator.procedure == nil {
				s.part_versions.allocator = s.parts.allocator // the song's
			}
			resize(&s.part_versions, len(s.parts))
		}
		s.part_versions[part] += 1
	}
	return true
}

// Versions start at 1 (0: never measured): the mix's moves with every
// command, a part's with those that change it.
mix_version :: proc(s: ^Song) -> u32 {
	return 1 + s.version
}

part_version :: proc(s: ^Song, part: int) -> u32 {
	return 1 + (part < len(s.part_versions) ? s.part_versions[part] : 0)
}

part_index :: proc(s: ^Song, name: string) -> int {
	for p, i in s.parts {
		if p == name {
			return i
		}
	}
	return -1
}

// The part a path names and what follows it: "drums/kick" -> drums, "kick".
// A part's own name may hold `/` ("score/drums", a mixed song's): the
// longest part the path starts with.
part_from_path :: proc(s: ^Song, path: string) -> (part: int, rest: string) {
	part = -1
	for p, i in s.parts {
		if strings.has_prefix(path, p) && (len(path) == len(p) || path[len(p)] == '/') && (part < 0 || len(p) > len(s.parts[part])) {
			part = i
		}
	}
	if part >= 0 && len(path) > len(s.parts[part]) {
		rest = path[len(s.parts[part]) + 1:]
	}
	return
}

@(private = "file")
part_gain :: proc(s: ^Song, tracks: []int, g: base.Gain, step: bool) -> bool {
	for ti in tracks {
		s.tracks[ti].gain = step ? s.tracks[ti].gain * g : g
	}
	return len(tracks) > 0
}

@(private = "file")
pad_gain :: proc(s: ^Song, row: Command_Row, tracks: []int, step: bool) -> bool {
	_, rest := part_from_path(s, row.path)
	if rest == "" {
		return false
	}
	pad := base.name_id(rest)
	for ti in tracks {
		// only a pad the track's instrument has
		d := s.tracks[ti].instrument
		has := make([dynamic]u32, context.temp_allocator)
		spec.program_pads(&s.programs, i32(s.params[d][.Program]), &has)
		if !slice.contains(has[:], pad) {
			return false
		}
		g: ^Pad_Gain
		for &x in s.pad_gains {
			if x.track == i32(ti) && x.pad == pad {
				g = &x
			}
		}
		if g == nil {
			append(&s.pad_gains, Pad_Gain{track = i32(ti), pad = pad, gain = 1})
			g = &s.pad_gains[len(s.pad_gains) - 1]
		}
		by := base.db_to_gain(base.Db(row.value))
		g.gain = step ? g.gain * by : by
	}
	return len(tracks) > 0
}

// "filter/frequency": a control of a program (a knob its row names), else
// the value of a node of it of that name (its pads' programs' too). False:
// it has none, or the value would change the program's shape.
@(private = "file")
node_value_set :: proc(s: ^Song, program: i32, path: string, value: f32) -> bool {
	if device.control_of(&s.programs, program, base.name_id(path)) != nil {
		return device.control_set(&s.programs, program, base.name_id(path), value)
	}
	slash := strings.index_byte(path, '/')
	if program < 0 || slash < 0 {
		return false
	}
	return device.node_field_set(&s.programs, program, base.name_id(path[:slash]), path[slash + 1:], value)
}
