package odawg_song

import "core:math"
import base "../base"
import device "../device"

// The keys each sample set's Samplers play in the song: what a host loads
// (assets.bank_load) after composing, so memory is what the song plays,
// not every key of every instrument. A note plays the key its program
// gives it (a pad's, or its pitch) on the Samplers of the program it plays
// (a machine's: its pad's).
sample_needs :: proc(s: ^Song, out: ^[dynamic]device.Sample_Need) {
	for t in s.tracks {
		if s.devices[t.instrument] != .Voice {
			continue
		}
		program := i32(s.params[t.instrument][.Program])
		for i in t.notes.first ..< base.span_end(t.notes) {
			r := s.notes[i]
			n := device.Note{r.time, r.duration, r.pitch, r.velocity, r.pad, r.accent}
			play, key, ok := device.graph_note(&s.programs, program, n)
			if !ok {
				continue
			}
			prog := s.programs.programs[play]
			for node in s.programs.nodes[prog.nodes.first:base.span_end(prog.nodes)] {
				// a sample set a node plays: a field of its kind's that is one
				row := device.node_row(node.kind)
				for f, fi in row.fields {
					if f.unit == .Asset {
						add_need(out, i32(node.values[row.slots[fi]]), key, n.velocity)
					}
				}
			}
		}
	}
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
