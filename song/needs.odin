package odawg_song

import "core:math"
import "core:slice"
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
			key := n.pitch
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
