// check: what a rendered song is told about itself, since nobody can listen
// for the agent. Each check is a row: its code and the rule that reads the
// song and what was measured of its render (Measures) and reports findings.
// Add a row, never a branch. A render is measured whole (findings_from_render)
// or as it streams, chunk by chunk (Measuring), the same way either way.
package odawg_check

import "core:math"
import analyze "../analyze"
import base "../base"
import render "../render"
import song "../song"

Check :: enum u8 {
	True_Peak,
	Clipping,
	Silent_Part,
	Loudness,
}

// What the checks read of a render: its mix's loudness and peak (linear:
// above 1 it clips), and each measured part's peak (song.parts order,
// linear; a render without stems measures none).
Measures :: struct {
	loudness:   analyze.Loudness,
	mix_peak:   f32,
	part_peaks: []f32,
}

Context :: struct {
	song:     ^song.Song,
	measures: ^Measures,
	findings: ^base.Findings,
}

Check_Row :: struct {
	code: string,
	rule: proc(c: ^Context),
}

CHECK_TABLE := [Check]Check_Row {
	.True_Peak = {"true_peak", proc(c: ^Context) {
			if c.measures.loudness.true_peak > -1 {
				base.report(c.findings, "true_peak", .Warning, "mix", "the mix peaks at %.1f dBTP (above -1): lower the parts or master it (--master streaming)", c.measures.loudness.true_peak)
			}
		}},
	.Clipping = {"clipping", proc(c: ^Context) {
			if p := c.measures.mix_peak; p > 1 {
				base.report(c.findings, "clipping", .Error, "mix", "the mix clips: samples reach %.2f (%.1f dBFS)", p, base.gain_to_db(f64(p)))
			}
		}},
	.Silent_Part = {"silent_part", proc(c: ^Context) {
			for peak, i in c.measures.part_peaks[:min(len(c.measures.part_peaks), len(c.song.parts))] {
				if peak < 1e-4 {
					base.report(c.findings, "silent_part", .Warning, base.path_join("parts", c.song.parts[i]), "part %s makes no sound in this range", c.song.parts[i])
				}
			}
		}},
	.Loudness = {"loudness", proc(c: ^Context) {
			l := c.measures.loudness
			if math.is_inf(l.integrated) || l.integrated < -70 {
				base.report(c.findings, "silent_mix", .Error, "mix", "the mix is silent")
				return
			}
			base.report(c.findings, "loudness", .Info, "mix", "%.1f LUFS integrated, %.1f LU range, %.1f dBTP", l.integrated, l.range, l.true_peak)
		}},
}

// Runs every check over what was measured of a render.
findings_from_measures :: proc(s: ^song.Song, m: ^Measures, findings: ^base.Findings) {
	c := Context{song = s, measures = m, findings = findings}
	for row in CHECK_TABLE {
		row.rule(&c)
	}
}

// Runs every check over a render in memory (its stems, the parts' first,
// when it has them): measured whole, the same as streamed.
findings_from_render :: proc(s: ^song.Song, out: ^render.Output, findings: ^base.Findings) {
	m: Measuring
	measuring_init(&m, s, context.temp_allocator)
	defer measuring_destroy(&m)
	measuring_push(&m, out.left, out.right, out.stems)
	measures := measures_from(&m, context.temp_allocator)
	findings_from_measures(s, &measures, findings)
}

// A render being measured as it streams: its mix through a loudness meter,
// each part's peak. Push its chunks in order (a sink's: the mix and the
// stems, the parts' first), then take what was measured.
Measuring :: struct {
	meter:      analyze.Meter,
	part_peaks: []f32,
	measured:   int, // the parts whose stems came
}

measuring_init :: proc(m: ^Measuring, s: ^song.Song, allocator := context.allocator) {
	analyze.meter_init(&m.meter, render.RATE, allocator)
	m.part_peaks = make([]f32, len(s.parts), allocator)
}

measuring_destroy :: proc(m: ^Measuring) {
	analyze.meter_destroy(&m.meter)
}

// The next chunk: the mix, and the stems (stem_count's order: the parts'
// first; nil or fewer: those parts unmeasured).
measuring_push :: proc(m: ^Measuring, l, r: []f32, stems: [][2][]f32) {
	analyze.meter_push(&m.meter, l, r)
	m.measured = max(m.measured, min(len(stems), len(m.part_peaks)))
	for st, i in stems[:min(len(stems), len(m.part_peaks))] {
		m.part_peaks[i] = max(m.part_peaks[i], render.peak_from_samples(st[0], st[1]))
	}
}

measures_from :: proc(m: ^Measuring, allocator := context.allocator) -> Measures {
	return {loudness = analyze.loudness_from_meter(&m.meter, allocator), mix_peak = m.meter.sample_peak, part_peaks = m.part_peaks[:m.measured]}
}
