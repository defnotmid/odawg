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
	Buried_Part,
	Loudness,
}

// What the checks read of a render: its mix's loudness and peak (linear:
// above 1 it clips), and each measured part's peak (song.parts order,
// linear; a render without stems measures none); the K-weighted energy of
// the mix and of each measured part every 100 ms (analyze.Steps), from
// `from` (song seconds) for `samples`, a section's loudness read from them.
Measures :: struct {
	loudness:    analyze.Loudness,
	mix_peak:    f32,
	part_peaks:  []f32,
	mix_energy:  []f64,
	part_energy: [][]f64,
	from:        f64,
	samples:     i64,
}

// A part more than BURIED_LU under the mix in every section it plays is
// buried (inaudible in a mix, SOUND_DESIGN.md); the raise it's told puts it
// BURIED_TARGET_LU under where it's loudest against the mix. A section
// span under 400 ms holds no loudness block and isn't judged.
BURIED_LU :: 15
BURIED_TARGET_LU :: 12

// A section as the measured render holds it: its whole 100 ms steps
// (counted in samples from the render's first, so no rounding moves a
// boundary) and its seconds within the render.
Section_Span :: struct {
	first, last: int, // steps [first, last)
	from, to:    f64, // song seconds
}

// What the rules read: the song, what was measured, and from both once,
// each section's span and where each part plays (plays[part * sections +
// section]: a note of its, an attack of a track that's heard, sounding in
// the section within the render; a tail or silence isn't playing).
Context :: struct {
	song:     ^song.Song,
	measures: ^Measures,
	findings: ^base.Findings,
	spans:    []Section_Span,
	plays:    []bool,
}

// Whether part i plays anywhere in the render.
@(private = "file")
part_plays :: proc(c: ^Context, i: int) -> bool {
	for p in c.plays[i * len(c.spans):][:len(c.spans)] {
		if p {
			return true
		}
	}
	return false
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
				// a part with no notes here is quiet by design
				if peak < 1e-4 && part_plays(c, i) {
					base.report(c.findings, "silent_part", .Warning, base.path_join("parts", c.song.parts[i]), "part %s has notes in this range but makes no sound", c.song.parts[i])
				}
			}
		}},
	.Buried_Part = {"buried_part", proc(c: ^Context) {
			m := c.measures
			for energy, i in m.part_energy[:min(len(m.part_energy), len(c.song.parts))] {
				least := math.INF_F64 // how far under the mix it sits where it's loudest against it
				for sp, j in c.spans {
					if !c.plays[i * len(c.spans) + j] {
						continue
					}
					part := analyze.loudness_of_span(energy, sp.first, sp.last)
					if !math.is_inf(part) {
						least = min(least, analyze.loudness_of_span(m.mix_energy, sp.first, sp.last) - part)
					}
				}
				if !math.is_inf(least) && least > BURIED_LU {
					name := c.song.parts[i]
					base.report(c.findings, "buried_part", .Warning, base.path_join("parts", name), "part %s sits %.1f LU or more under the mix in every section it plays: raise parts/%s/gain_db by about %.0f dB (%d LU under where it's loudest)", name, least, name, least - BURIED_TARGET_LU, BURIED_TARGET_LU)
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
	c.spans, c.plays = section_plays(s, m)
	for row in CHECK_TABLE {
		row.rule(&c)
	}
}

// Each section's span of the render, and where each part plays (Context).
// In temp memory.
@(private = "file")
section_plays :: proc(s: ^song.Song, m: ^Measures) -> (spans: []Section_Span, plays: []bool) {
	STEP :: i64(render.RATE / 10)
	start := i64(math.round(m.from * render.RATE)) // the render's first sample
	from, to := f64(start) / render.RATE, f64(start + m.samples) / render.RATE
	spans = make([]Section_Span, len(s.sections), context.temp_allocator)
	for sec, j in s.sections {
		a := max(i64(math.round(sec.start * render.RATE)) - start, 0)
		b := max(i64(math.round(sec.stop * render.RATE)) - start, 0)
		spans[j] = {first = int((a + STEP - 1) / STEP), last = int(b / STEP), from = max(sec.start, from), to = min(sec.stop, to)}
	}
	plays = make([]bool, len(s.parts) * len(spans), context.temp_allocator)
	for t in s.tracks {
		if t.muted {
			continue
		}
		for n in t.notes.first ..< base.span_end(t.notes) {
			if s.notes.kind[n] != .Attack {
				continue
			}
			t0 := s.notes.time[n]
			t1 := t0 + s.notes.duration[n]
			for sp, j in spans {
				if t0 < sp.to && (t1 > sp.from || t0 >= sp.from) {
					plays[int(t.part) * len(spans) + j] = true
				}
			}
		}
	}
	return
}

// Runs every check over a render in memory (its stems, the parts' first,
// when it has them): measured whole, the same as streamed.
findings_from_render :: proc(s: ^song.Song, out: ^render.Output, findings: ^base.Findings) {
	m: Measuring
	measuring_init(&m, s, context.temp_allocator, out.from)
	defer measuring_destroy(&m)
	measuring_push(&m, out.left, out.right, out.stems)
	measures := measures_from(&m, context.temp_allocator)
	findings_from_measures(s, &measures, findings)
}

// A render being measured as it streams: its mix through a loudness meter,
// each part's peak and K-weighted energy. Push its chunks in order (a
// sink's: the mix and the stems, the parts' first), then take what was
// measured. `from`: the song second it starts at (a range's).
Measuring :: struct {
	meter:      analyze.Meter,
	part_peaks: []f32,
	parts:      []analyze.Steps,
	measured:   int, // the parts whose stems came
	from:       f64,
}

measuring_init :: proc(m: ^Measuring, s: ^song.Song, allocator := context.allocator, from := 0.0) {
	analyze.meter_init(&m.meter, render.RATE, allocator)
	m.part_peaks = make([]f32, len(s.parts), allocator)
	m.parts = make([]analyze.Steps, len(s.parts), allocator)
	for &p in m.parts {
		analyze.steps_init(&p, render.RATE, allocator)
	}
	m.from = from
}

measuring_destroy :: proc(m: ^Measuring) {
	analyze.meter_destroy(&m.meter)
	for &p in m.parts {
		analyze.steps_destroy(&p)
	}
}

// The next chunk: the mix, and the stems (stem_count's order: the parts'
// first; nil or fewer: those parts unmeasured).
measuring_push :: proc(m: ^Measuring, l, r: []f32, stems: [][2][]f32) {
	analyze.meter_push(&m.meter, l, r)
	m.measured = max(m.measured, min(len(stems), len(m.part_peaks)))
	for st, i in stems[:min(len(stems), len(m.part_peaks))] {
		m.part_peaks[i] = max(m.part_peaks[i], render.peak_from_samples(st[0], st[1]))
		analyze.steps_push(&m.parts[i], st[0], st[1])
	}
}

// What was measured; its energies are the Measuring's (valid until it is
// destroyed).
measures_from :: proc(m: ^Measuring, allocator := context.allocator) -> Measures {
	energy := make([][]f64, m.measured, allocator)
	for &e, i in energy {
		e = m.parts[i].energy[:]
	}
	return {loudness = analyze.loudness_from_meter(&m.meter, allocator), mix_peak = m.meter.sample_peak, part_peaks = m.part_peaks[:m.measured], mix_energy = m.meter.energy[:], part_energy = energy, from = m.from, samples = m.meter.pushed}
}
