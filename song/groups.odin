package odawg_song

import base "../base"
import device "../device"

// Voice groups: a track's voices split to play side by side. Each group is
// a node of the routing (Voices) feeding its track's node, which sums its
// groups and runs its strip (its chain, its fader, its sends), so a dense
// kit or a held chord's voices render on as many of the caller's workers as
// it has groups. Which group a note's voices play in is a rule over the
// note table (its place among its track's notes, round), never the threads
// a render has: any pool plays the same samples. A track whose voices act
// on one another (a mono instrument's one voice, a layered instrument's
// regions cutting each other, an instrument a lane moves: its program's
// values set as it plays) is one group.
Voice_Group :: struct {
	track: i32,
	index: u16, // which of its track's groups
	of:    u16, // how many its track has
}

// The most voices a group sounds at once (as its notes and their tails
// fall): a track sounding more splits into as many groups as it needs. A
// group's voices of one program still play in one call a node (graph_run's
// lanes), so a group keeps that batching while a kit spreads.
GROUP_VOICES :: 8

// Whether note i of track t plays in group g (its place among the track's
// notes, round its groups).
note_in_group :: #force_inline proc(t: Track, i: i32, g: Voice_Group) -> bool {
	return int(i - t.notes.first) % int(g.of) == int(g.index)
}

// The most voices a track (its group `g`; none: all of it) sounds at once,
// each note's voices (a layered note's every layer it may start) through
// their tails; at least 1.
track_polyphony :: proc(s: ^Song, ti: int, g: Voice_Group = {of = 1}) -> int {
	t := s.tracks[ti]
	p := s.params[t.instrument]
	env := voice_env(s)
	if device.voice_mono(&p, &env) || t.notes.count == 0 {
		return 1
	}
	ends := make([dynamic]base.Seconds, context.temp_allocator)
	most := 0
	program := i32(p[.Program])
	layered := program >= 0 && s.programs.programs[program].layer_mode == .All
	for i in t.notes.first ..< base.span_end(t.notes) {
		if !note_in_group(t, i, g) {
			continue
		}
		n := note_of(s, int(i))
		#reverse for end, k in ends {
			if end <= n.time {
				unordered_remove(&ends, k)
			}
		}
		voices := 1
		if layered {
			layers: [device.MAX_LAYERS]i32
			voices = device.graph_layers(&s.programs, program, n, -1, layers[:])
		}
		for _ in 0 ..< voices {
			append(&ends, n.time + device.note_tail(&p, n, &env))
		}
		most = max(most, len(ends))
	}
	return max(most, 1)
}

// How many groups a track's voices play in: one where they act on one
// another (mono, layered, a lane on its instrument), else as many as hold
// its voices at GROUP_VOICES each.
track_group_count :: proc(s: ^Song, ti: int) -> int {
	t := s.tracks[ti]
	p := s.params[t.instrument]
	env := voice_env(s)
	program := i32(p[.Program])
	if t.notes.count == 0 || device.voice_mono(&p, &env) || (program >= 0 && s.programs.programs[program].layer_mode == .All) {
		return 1
	}
	for a in s.automation {
		if a.kind == .Control && int(a.track) == ti {
			return 1
		}
	}
	return clamp((track_polyphony(s, ti) + GROUP_VOICES - 1) / GROUP_VOICES, 1, int(t.notes.count))
}
