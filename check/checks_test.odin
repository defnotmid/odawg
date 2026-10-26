package odawg_check

import "core:mem/virtual"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import base "../base"
import render "../render"
import song "../song"
import spec "../spec"

// A render measured as it streams, a chunk at a time (a sink's), is what it
// is measured whole: the same loudness (integrated, range, true and sample
// peak, momentary and short-term), mix peak and parts' peaks, so the same
// findings.
@(test)
test_measured_streaming :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(`{ bpm: 120, seed: 3, sections: [ { name: "a", duration: "4m" } ],
		parts: { drums: { instrument: "MembraneSynth", play: [ { name: "a", notes: "C2 - C2 -", subdivision: "8n" } ] },
		         lead: { instrument: "PluckSynth", effects: [ { name: "FeedbackDelay", delay_time: "8n", feedback: 0.4, wet: 0.3 } ],
		                 play: [ { name: "a", notes: "A4 C5 E5 -", subdivision: "8n" } ] },
		         rest: { instrument: "Synth", play: [] } } }`, sp, &findings))
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s))
	out := render.output_from_song(s, {stems = true})
	whole: Measuring
	measuring_init(&whole, s)
	measuring_push(&whole, out.left, out.right, out.stems)
	a := measures_from(&whole)
	for chunk in ([]int{8192, 1000, 1}) {
		streamed: Measuring
		measuring_init(&streamed, s)
		views := make([][2][]f32, len(out.stems))
		for at := 0; at < out.frames; at += chunk {
			n := min(chunk, out.frames - at)
			for st, p in out.stems {
				views[p] = {st[0][at:][:n], st[1][at:][:n]}
			}
			measuring_push(&streamed, out.left[at:][:n], out.right[at:][:n], views)
		}
		b := measures_from(&streamed)
		testing.expectf(t, a.loudness.integrated == b.loudness.integrated && a.loudness.range == b.loudness.range && a.loudness.true_peak == b.loudness.true_peak && a.loudness.sample_peak == b.loudness.sample_peak, "in chunks of %d: %v, whole: %v", chunk, b.loudness, a.loudness)
		testing.expectf(t, slice.equal(a.loudness.momentary, b.loudness.momentary) && slice.equal(a.loudness.short_term, b.loudness.short_term), "in chunks of %d the momentary or short-term loudness differs", chunk)
		testing.expect(t, a.mix_peak == b.mix_peak && slice.equal(a.part_peaks, b.part_peaks))
		testing.expectf(t, slice.equal(a.mix_energy, b.mix_energy) && len(a.part_energy) == len(b.part_energy), "in chunks of %d the mix's energy differs", chunk)
		for e, p in a.part_energy {
			testing.expectf(t, slice.equal(e, b.part_energy[p]), "in chunks of %d part %d's energy differs", chunk, p)
		}
	}
	// the mix peak is the render's own, the silent part found silent
	testing.expect_value(t, a.mix_peak, render.peak_from_samples(out.left, out.right))
	got := make(base.Findings)
	findings_from_measures(s, &a, &got)
	silent := false
	for f in got {
		silent ||= f.code == "silent_part" && f.path == "parts/rest"
	}
	testing.expectf(t, silent, "the empty part isn't found silent: %v", got[:])
	// a render without stems measures no part: none is found silent
	mix := render.output_from_song(s, {})
	only: Measuring
	measuring_init(&only, s)
	measuring_push(&only, mix.left, mix.right, nil)
	c := measures_from(&only)
	testing.expect_value(t, len(c.part_peaks), 0)
	none := make(base.Findings)
	findings_from_measures(s, &c, &none)
	for f in none {
		testing.expectf(t, f.code != "silent_part", "unmeasured, %s is found silent", f.path)
	}
}

// A part far under the mix in every section it plays is buried, told the
// raise that puts it 12 LU under where it's loudest; a part only somewhat
// under, or silent somewhere, isn't. A range measures what it renders.
@(test)
test_buried_part :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(`{ bpm: 120, seed: 3, sections: [ { name: "a", duration: "4m" }, { name: "b", duration: "4m" } ],
		parts: { lead: { instrument: "Synth", play: [ { name: ["a", "b"], notes: "A4 - C5 -", subdivision: "4n" } ] },
		         under: { instrument: "Synth", gain_db: -10, play: [ { name: ["a", "b"], notes: "E4 - - -", subdivision: "4n" } ] },
		         buried: { instrument: "Synth", gain_db: -32, play: [ { name: ["a", "b"], notes: "C4 - - -", subdivision: "4n" } ] },
		         late: { instrument: "Synth", gain_db: -32, play: [ { name: "b", notes: "G4 - - -", subdivision: "4n" } ] } } }`, sp, &findings))
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s))
	measure :: proc(s: ^song.Song, from, to: f64) -> base.Findings {
		out := render.output_from_song(s, {from = from, to = to, stems = true})
		got := make(base.Findings)
		findings_from_render(s, &out, &got)
		return got
	}
	for f in ([][2]f64{{0, 0}, {8, 16}}) {
		got := measure(s, f[0], f[1])
		said: map[string]string
		for x in got {
			if x.code == "buried_part" {
				said[x.path] = x.message
			}
		}
		testing.expectf(t, "parts/buried" in said, "from %v: a part 30 LU under isn't buried: %v", f, got[:])
		testing.expectf(t, "parts/late" in said, "from %v: a part 30 LU under where it plays isn't buried: %v", f, got[:])
		testing.expectf(t, "parts/under" not_in said && "parts/lead" not_in said, "from %v: a part found buried that isn't: %v", f, said)
		// the raise it names: the 30 LU or so it sits under, less 12
		msg := said["parts/buried"]
		at := strings.index(msg, "by about ")
		testing.expectf(t, at >= 0, "no raise named: %q", msg)
		if at >= 0 {
			db, _ := strconv.parse_f64(strings.fields(msg[at + len("by about "):])[0])
			testing.expectf(t, db > 10 && db < 25, "from %v: a raise of %v dB for a part 32 dB down beside one 10 dB down", f, db)
		}
	}
}
