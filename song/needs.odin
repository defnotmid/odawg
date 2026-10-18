package odawg_song

import "core:math"
import base "../base"
import device "../device"

// The keys each sample set's Samplers play in the song: what a host loads
// (assets.bank_load) after composing, so memory is what the song plays,
// not every key of every instrument. A drum pad is its GM key, as the
// Sampler plays it.
sample_needs :: proc(s: ^Song, out: ^[dynamic]device.Sample_Need) {
	for t in s.tracks {
		if s.devices[t.instrument] != .Sampler {
			continue
		}
		set := i32(s.params[t.instrument][.Sample_Set])
		if set < 0 {
			continue
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
		for i in t.notes.first ..< base.span_end(t.notes) {
			n := s.notes[i]
			key := n.pad != .None ? int(device.note_from_pad(n.pad)) : int(math.round(n.pitch))
			if key >= 0 && key < 128 {
				need.keys += {key}
				need.velocities[key] += {device.velocity_midi(n.velocity)}
			}
		}
	}
}
