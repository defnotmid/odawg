package odawg_song

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import base "../base"
import device "../device"

// The keys each sample set's Samplers play in the song: what a host loads
// (assets.bank_load) after composing, so memory is what the song plays,
// not every key of every instrument. A note plays the key its program
// gives it (a pad's, or its pitch) on the Samplers of the program it plays
// (a machine's: its pad's).
sample_needs :: proc(s: ^Song, out: ^[dynamic]device.Sample_Need) {
	for t in s.tracks {
		program := i32(s.params[t.instrument][.Program])
		for i in t.notes.first ..< base.span_end(t.notes) {
			n := note_of(s, int(i))
			// a layered program's note: every layer it may start, each at its
			// pitch; else the program (a pad's) the note plays, at its key
			plays, layers: [device.MAX_LAYERS]i32
			count := 0
			key := f32(n.pitch) // as the program's keys are kept
			if program >= 0 && s.programs.programs[program].layer_mode == .All {
				for l in layers[:device.graph_layers(&s.programs, program, n, -1, layers[:])] {
					plays[count] = s.programs.layers[l].program
					layers[count] = l
					count += 1
				}
			} else if play, k, ok := device.graph_note(&s.programs, program, n); ok {
				plays[0], layers[0], key, count = play, -1, k, 1
			}
			for play, k in plays[:count] {
				needs_of_program(s, play, layers[k], key, n.velocity, out)
			}
		}
	}
}

@(private = "file")
needs_of_program :: proc(s: ^Song, play: i32, layer: i32, key: f32, velocity: f32, out: ^[dynamic]device.Sample_Need) {
	prog := s.programs.programs[play]
	for node, j in s.programs.nodes[prog.nodes.first:base.span_end(prog.nodes)] {
		if node.kind == device.NODE_REGION {
			// a Region plays one zone of its set (its layer's), whatever the key
			set := device.layer_value(&s.programs, layer, play, j, device.REGION_SET)
			zone := device.layer_value(&s.programs, layer, play, j, device.REGION_ZONE)
			add_zone_need(out, i32(set), i32(zone))
			continue
		}
		// a sample set a node plays: a field of its kind's that is one
		row := device.node_row(node.kind)
		for f, fi in row.fields {
			if f.unit == .Asset {
				add_need(out, i32(node.values[row.slots[fi]]), key, velocity)
			}
		}
	}
}

@(private = "file")
add_zone_need :: proc(out: ^[dynamic]device.Sample_Need, set: i32, zone: i32) {
	if set < 0 || zone < 0 {
		return
	}
	for &x in out {
		if x.set == set {
			if !slice.contains(x.zones[:], zone) {
				append(&x.zones, zone)
			}
			return
		}
	}
	need := device.Sample_Need{set = set}
	need.zones = make([dynamic]i32, out.allocator)
	append(&need.zones, zone)
	append(out, need)
}

@(private = "file")
add_need :: proc(out: ^[dynamic]device.Sample_Need, set: i32, key: f32, velocity: f32) {
	if set < 0 {
		return
	}
	need: ^device.Sample_Need
	for &x in out {
		if x.set == set {
			need = &x
		}
	}
	if need == nil {
		append(out, device.Sample_Need{set = set})
		need = &out[len(out) - 1]
	}
	k := int(math.round(key))
	if k >= 0 && k < 128 {
		need.keys += {k}
		need.velocities[k] += {device.velocity_midi(velocity)}
	}
}

// Notes that can't sound, a finding a part: a pitch outside MIDI's 0..127
// (note_range), or a note no layer or pad of its instrument answers (an
// SFZ's regions, a machine's pads: no_region). Played, they'd be silent.
notes_reach :: proc(s: ^Song) {
	Reach :: struct {
		outside, unanswered: int,
		lo, hi:              base.Pitch, // the pitches outside, or unanswered
		ulo, uhi:            base.Pitch,
	}
	reach := make([]Reach, len(s.parts), context.temp_allocator)
	for &r in reach {
		r.lo, r.hi, r.ulo, r.uhi = math.F32_MAX, -math.F32_MAX, math.F32_MAX, -math.F32_MAX
	}
	for t in s.tracks {
		program := i32(s.params[t.instrument][.Program])
		if program < 0 {
			continue
		}
		layered := s.programs.programs[program].layer_mode == .All
		r := &reach[t.part]
		for i in t.notes.first ..< base.span_end(t.notes) {
			if s.notes.kind[i] != .Attack {
				continue
			}
			p := s.notes.pitch[i]
			if p < 0 || p > 127 {
				r.outside += 1
				r.lo, r.hi = min(r.lo, p), max(r.hi, p)
				continue
			}
			n := note_of(s, int(i))
			answered: bool
			if layered {
				layers: [device.MAX_LAYERS]i32
				answered = device.graph_layers(&s.programs, program, n, -1, layers[:]) > 0
			} else {
				_, _, answered = device.graph_note(&s.programs, program, n)
			}
			if !answered {
				r.unanswered += 1
				r.ulo, r.uhi = min(r.ulo, p), max(r.uhi, p)
			}
		}
	}
	for r, part in reach {
		path := base.path_join("parts", s.parts[part])
		if r.outside > 0 {
			base.report(&s.findings, "note_range", .Warning, path, "part %s: %d notes at pitches %.0f..%.0f, outside MIDI's 0..127: they can't sound", s.parts[part], r.outside, r.lo, r.hi)
		}
		if r.unanswered > 0 {
			base.report(&s.findings, "no_region", .Warning, path, "part %s: %d notes (pitches %.0f..%.0f) that no layer, region or pad of its instrument answers: they're silent", s.parts[part], r.unanswered, r.ulo, r.uhi)
		}
	}
}

// Where the tempo a Tone length was read at isn't the tempo it plays at,
// by this many bpm or more, it is off the beat there.
TEMPO_SLACK :: 0.5

// A Tone length a device read once at one tempo (an envelope's "8n", a
// FeedbackDelay's "8n.", an AutoFilter's "4n"), on a part or a chain that
// plays where the tempo is another: it keeps the length or rate it had, off
// the beat there. A warning a device, naming what it read and the sections
// (tempo_fixed). An Lfo's rate in beats follows the tempo and isn't one.
tempo_fixed :: proc(s: ^Song) {
	if len(s.fixed_lengths) == 0 || len(s.sections) == 0 {
		return
	}
	// per device and section, whether it plays there: a track's instrument
	// and chain where its notes are; a return's, a bus's, the master's
	// chain everywhere
	sections := len(s.sections)
	plays := make([]bool, len(s.devices) * sections, context.temp_allocator)
	mark :: proc(plays: []bool, sections: int, d: i32, j: int) {
		plays[int(d) * sections + j] = true
	}
	everywhere :: proc(s: ^Song, plays: []bool, chain: Span) {
		for d in s.chain[chain.first:base.span_end(chain)] {
			for j in 0 ..< len(s.sections) {
				mark(plays, len(s.sections), d, j)
			}
		}
	}
	for t in s.tracks {
		for i in t.notes.first ..< base.span_end(t.notes) {
			b := s.notes.beat[i]
			for sec, j in s.sections {
				if b >= sec.beat && b < sec.beat + sec.beats {
					mark(plays, sections, t.instrument, j)
					for d in s.chain[t.chain.first:base.span_end(t.chain)] {
						mark(plays, sections, d, j)
					}
				}
			}
		}
	}
	for r in s.returns {
		everywhere(s, plays, r.chain)
	}
	for b in s.buses {
		everywhere(s, plays, b.chain)
	}
	everywhere(s, plays, s.master)
	// a device's lengths are in a row: one warning each
	for first := 0; first < len(s.fixed_lengths); {
		d := s.fixed_lengths[first].device
		last := first
		for last < len(s.fixed_lengths) && s.fixed_lengths[last].device == d {
			last += 1
		}
		rows := s.fixed_lengths[first:last]
		first = last
		bpm := rows[0].bpm
		off := make([dynamic]string, context.temp_allocator)
		for sec, j in s.sections {
			if plays[int(d) * sections + j] && (abs(sec.bpm0 - bpm) >= TEMPO_SLACK || abs(sec.bpm1 - bpm) >= TEMPO_SLACK) {
				tempo := sec.bpm0 == sec.bpm1 ? fmt.tprintf("%g", sec.bpm0) : fmt.tprintf("%g-%g", sec.bpm0, sec.bpm1)
				append(&off, fmt.tprintf("%s (%s bpm)", sec.name, tempo))
			}
		}
		if len(off) == 0 {
			continue
		}
		also := make([dynamic]string, context.temp_allocator)
		rate := rows[0].rate
		for x in rows[1:] {
			append(&also, x.path)
			rate ||= x.rate
		}
		more := len(also) > 0 ? fmt.tprintf(" (and %s)", strings.join(also[:], ", ", context.temp_allocator)) : ""
		hint := rate ? "an Lfo's rate written as a Tone length follows the tempo; for a built-in's (AutoFilter, Chorus), place an effect row with such an Lfo" : "write it in seconds to keep it so, or keep those sections at one tempo"
		base.report(&s.findings, "tempo_fixed", .Warning, rows[0].path, "%s: a Tone length read once at %g bpm%s, where it plays at another tempo: %s. It keeps the time it had and drifts off the beat there; %s", rows[0].path, bpm, more, strings.join(off[:], ", ", context.temp_allocator), hint)
	}
}
