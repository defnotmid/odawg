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
// else a node's value: "bass/ladder/frequency"; a clip's: "music/clip/fade_in"), "master".

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
		return part_gain(s, tracks, row.value, false)
	}},
	.Part_Gain_Step = {"part/gain_db+", "a part's level moved by dB", .Part, proc(s: ^Song, row: Command_Row, tracks: []int) -> bool {
		return part_gain(s, tracks, row.value, true)
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
			if s.devices[d] == .Voice {
				done ||= node_value_set(s, i32(s.params[d][.Program]), rest, f32(row.value))
			} else if p := param_of(s.devices[d], rest); p != .None {
				s.params[d][p] = f32(row.value)
				done = true
			}
		}
		return done
	}},
	.Master_Gain_Set = {"master/gain_db", "the master's gain, dB", .Mix, proc(s: ^Song, row: Command_Row, tracks: []int) -> bool {
		s.master_gain_db = row.value
		return true
	}},
	.Master_Gain_Step = {"master/gain_db+", "the master's gain moved by dB", .Mix, proc(s: ^Song, row: Command_Row, tracks: []int) -> bool {
		s.master_gain_db += row.value
		return true
	}},
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
	if k.touches == .Part {
		part, _ = part_from_path(s, row.path)
		for t, ti in s.tracks {
			if int(t.part) == part {
				append(&tracks, ti)
			}
		}
	}
	if (k.touches == .Part && part < 0) || !k.apply(s, row, tracks[:]) {
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
part_gain :: proc(s: ^Song, tracks: []int, db: f64, step: bool) -> bool {
	for ti in tracks {
		s.tracks[ti].gain_db = step ? s.tracks[ti].gain_db + db : db
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
		if s.devices[d] == .Voice {
			has := make([dynamic]u32, context.temp_allocator)
			spec.program_pads(&s.programs, i32(s.params[d][.Program]), &has)
			if !slice.contains(has[:], pad) {
				return false
			}
		}
		g: ^Pad_Gain
		for &x in s.pad_gains {
			if x.track == i32(ti) && x.pad == pad {
				g = &x
			}
		}
		if g == nil {
			append(&s.pad_gains, Pad_Gain{track = i32(ti), pad = pad})
			g = &s.pad_gains[len(s.pad_gains) - 1]
		}
		g.db = step ? g.db + f32(row.value) : f32(row.value)
	}
	return len(tracks) > 0
}

@(private = "file")
param_of :: proc(kind: device.Device_Kind, path: string) -> device.Param {
	reads := device.DEVICE_TABLE[kind].reads
	for row, p in device.PARAM_TABLE {
		if p != .None && p in reads && row.path == path {
			return p
		}
	}
	return .None
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
